# e2b 沙箱 NFS socket 泄漏导致永久无法恢复：根因与修复方案

> 状态：根因已定位（源码闭合），修复方案待决策——主线建议升 guest kernel 到 6.18.25；PR #35 已提待 review
> 事件：2026-09-11 production `SandboxCreateUnavailable`（P1）
> 相关：[Grafana 告警设计](https://github.com/SerendipityOneInc/fastclaw/blob/main/docs/plans/2026-08-24-e2b-grafana-alerting-design.md) · [Azure 部署 runbook](https://github.com/SerendipityOneInc/fastclaw/blob/main/docs/plans/2026-07-17-e2b-infra-azure-setup.md)（均在 fastclaw 仓库）
> 致谢：guest 内部诊断（359 条 FIN_WAIT1、端口耗尽、`mount.nfs` 管道阻塞）由 kaka 完成，见其交接文档《Sandbox pause/resume 后 NFS 连接残留，最终导致恢复失败》

---

## 0. 一句话

guest kernel（6.1.158）在 pause/resume 时泄漏 SUNRPC TCP socket，攒满 SUNRPC 保留端口池（665–1023）后沙箱**永久**无法恢复；而 envd 无法让卡死的挂载失败，把它放大成 40 秒静默超时，再被无退避的重试刷成一场 P1 告警。

---

## 1. 事件数据

两个节点 orchestrator 日志统计（2026-09-11 全天）：

| 指标 | 值 |
|---|---|
| `failed to init envd after retries` 总数 | **162 次 / 仅 4 个沙箱** |
| `iltf773id1tponspbkgiw` | 96 次（两节点各 48，placement 对称重试）|
| `if8gucalsejva0s1bqh5j` | 63 次 |
| 其余 2 个沙箱 | 各 1 次（疑似偶发）|
| 重试次数分布 | **双峰：715 与 530–535** |
| NFS proxy 的 `failed to get path` | **0 次** |

两个峰各自对应一个超时预算：

- `715 × (50ms 请求超时 + 5ms loopDelay) ≈ 39.3s` → orchestrator 的 **40s** envd 看门狗
- `530 × 55ms ≈ 29.2s` → API 给 `SandboxCreate` 的 **30s** gRPC 截止

**159/162 的失败来自 2 个沙箱。P1 的失败率是重试刷出来的，不是集群故障。**

---

## 2. 根因机制（已由 v6.1.158 源码闭合）

```c
// net/sunrpc/xprtsock.c  xs_create_sock()
err = __sock_create(xprt->xprt_net, family, type, protocol, &sock, 1);
//                                                                 ↑ kern=1 → sk_net_refcnt == 0

// net/ipv4/tcp.c
void tcp_close(struct sock *sk, long timeout)
{
	lock_sock(sk);
	__tcp_close(sk, timeout);        // 发出 FIN，进入 FIN_WAIT1
	release_sock(sk);
	if (!sk->sk_net_refcnt)          // SUNRPC socket 恒为真
		inet_csk_clear_xmit_timers_sync(sk);   // 所有发送定时器被清空
	sock_put(sk);
}
```

完整链条：

1. SUNRPC 以 `kern=1` 建 socket → `sk_net_refcnt == 0`
2. NFS transport 关闭（空闲超时，或 resume 后丢弃旧 transport）→ `tcp_close()`
3. FIN 发出 → `FIN_WAIT1`；随即**定时器被同步清空**
4. 对端（旧 netns 里的 proxy 连接）已随 pause 销毁，**永远不会 ACK**
5. 没有重传、没有超时、没有任何东西能推动这个 socket 前进 → **永驻 `FIN_WAIT1`，攥着保留源端口**
6. 每次 resume 泄漏约 1 条，直到 **665–1023 共 359 个端口全满**
7. `mount.nfs` 再也 bind 不到保留端口 → MOUNT v3 RPC 持续 `EAGAIN`，sends/recvs 恒为 0
8. **失败的 resume 不回写快照**，每次都从同一份内存镜像启动 → 确定性复现，永远失败

kaka 的现场证据与此逐条吻合：`SOCK_DEAD`、`timer=00`、`retransmits=0`、受控复现中每次 pause/resume 精确 +1、359 = 满池。我们侧的 `failed to get path` **命中 0** 是独立佐证——proxy 从未收到过 MOUNT 请求，说明 guest 根本没能把请求发出来。

### 上游补丁

[`3f23f96528e8`](https://github.com/torvalds/linux/commit/3f23f96528e8fcf8619895c4c916c52653892ec1) — *"sunrpc: fix one UAF issue caused by sunrpc kernel tcp socket"*（2024-11-12，+11/-0）：

```c
+	if (protocol == IPPROTO_TCP) {
+		__netns_tracker_free(xprt->xprt_net, &sock->sk->ns_tracker, false);
+		sock->sk->sk_net_refcnt = 1;
+		get_net_track(xprt->xprt_net, &sock->sk->ns_tracker, GFP_KERNEL);
+		sock_inuse_add(xprt->xprt_net, 1);
+	}
```

`sk_net_refcnt` 置 1 后，第 3 步那个清定时器的分支不再命中，socket 回到正常关闭路径——定时器保留、FIN 重传、`tcp_orphan_retries` 最终 reset、端口释放。

> **注**：这个 commit 的本意是修 UAF，不是修 socket 泄漏。我们依赖的是 `sk_net_refcnt` 翻转带来的副作用。机制上完全成立，但它不是为这个症状写的。

---

## 3. 这里是四个独立缺陷

必须分开修，**只修任何一个都不够**。

| # | 缺陷 | 性质 | 归属 |
|---|---|---|---|
| **1** | guest kernel 泄漏 SUNRPC socket → 端口耗尽 | **根因** | 内核 |
| **2** | envd 无法让卡死的挂载失败 | 放大器 | [PR #35](https://github.com/SerendipityOneInc/infra/pull/35)（已提）|
| **3** | 恢复失败无退避 → 无限重试刷爆告警 | 放大器 | Engine |
| **4** | 观测缺口（30s/40s 预算倒挂、日志不进 Loki、无失败事件类型）| 诊断成本 | 零散 |

### 缺陷 2 的机制

`mount(8)` fork 出 `mount.nfs(8)`。`setupNFS` 的 10 秒 context 超时**只 signal 直接子进程**，`mount.nfs` 活下来、被 reparent 到 PID 1，并继续攥着 `CombinedOutput()` 那根管道的写端 → `Wait()` 等 EOF 永不返回 → **10 秒预算形同虚设**，`/init` 在整个 resume 期间独占 `initLock`，envd 活着但被永久串行化。

PR #35 的修法：`Setpgid` + 自定义 `Cancel` 杀整个进程组（捕获 fork 出的 `mount.nfs`），加 `WaitDelay` 兜住管道。两者缺一不可——只有 `WaitDelay` 会留下游离的 `mount.nfs` 仍在对卷操作。附带堵掉一条"假 ready"路径（`isMountingNFS` CAS 失败返回 nil → `/init` 在一个卷都没挂的情况下回 204），并补三条边界日志。

---

## 4. 版本盘点：为什么 6.1.y 救不了

`3f23f96528e8` 的分布（均已实测核对）：

| 内核 | 含补丁 | EOL |
|---|---|---|
| mainline v6.12 | ❌ | — |
| mainline v6.13+ | ✅（补丁在此进主线）| — |
| stable **6.6.100** | ✅ | 2027-12 |
| stable **6.12.40** | ✅ | 2028-12 |
| stable **6.18** | ✅ | **2028-12**（最新 LTS）|
| **stable 6.1.y（分支最新）** | ❌ **从未 backport** | **2027-12** |

主线现已走到 v7.2（v7.3-rc2 在滚）。**6.1.y 到今天为止都没有这个修复，留在 6.1 线就必须自己打补丁。**

### 可用的构建源

`e2b-dev/fc-kernels` 的 `build.sh` checkout 的是 **Amazon Linux 的 `microvm-kernel-<版本>-*.amzn2023` tag**。Amazon 实际发布的版本：

```
4.14 : 128 个 tag
5.10 : 102 个
6.1  :  55 个   ← 当前（我们用 6.1.158，该线最新已到 6.1.186）
6.18 :   2 个   ← microvm-kernel-6.18.25-57.115.amzn2023
```

**没有 6.6，也没有 6.12** —— 这两个版本这套流水线做不了。**6.18 是唯一可用的、自带修复的升级目标。**

### 一个关键前提变化

`e2b-dev/fc-kernels`、`fc-versions`、`firecracker` 三个仓库均已于 2026-08 归档，发布迁入 e2b 内部（Tango / e2b-artifact-binaries）。

**这意味着无论走哪条路，我们都得自己构建并发布内核。** "自建成本"是共同项，不构成打补丁方案的优势。

---

## 5. 内核是怎么选的

```
模板构建时
  kernelVersion := featureFlags.StringFlag(ctx, BuildKernelVersion)
        flag "build-kernel-version"
        └─ 回落 env DEFAULT_KERNEL_VERSION
            └─ 回落编译常量 DefaultKernelVersion = "vmlinux-6.1.158"
                        ↓ 写入 build 记录（DB）
创建沙箱
  SandboxConfig.KernelVersion = sbxData.Build.KernelVersion    ← 从 build 记录取，不重新求值
                        ↓
orchestrator
  HostKernelPath() = /fc-kernels/<KernelVersion>/<arch>/vmlinux.bin
                        ↓
  setBootSource()  →  Firecracker PUT /boot-source { kernel_image_path }
```

宿主机上 `/fc-kernels` 是只读 blobfuse 挂载，目录名即版本号，当前有四个：`vmlinux-6.1.102`、`vmlinux-6.1.102-c1a568c`、`vmlinux-6.1.158`、`vmlinux-6.1.158-c1a568c`（`-<shortSHA>` 后缀是打过补丁的构建，惯例已存在）。

**与宿主机 OS 无关。** 宿主是 Ubuntu 22.04.5 / `6.8.0-1062-azure`，只提供 KVM；实测宿主 `mount` 里 NFS 条目为 0、到 2049 的连接为 0——NFS 客户端完全在 guest 内部。升 guest kernel 不需要动宿主机。

---

## 6. 方案

### 主线：guest kernel 升到 `6.18.25`

不是"顺便升级"，而是它恰好是最优解：

- **自带修复**，不需要维护任何本地补丁
- **最新 LTS，EOL 2028-12**，比 6.1 多一年——6.1 只剩约 15 个月，这次不换明年也得换
- **在流水线已经在用的同一个源码树里**，`build.sh` 不用改
- `make olddefconfig` 自动填充新版本引入的配置项，人工只需复核 e2b 特意开的开关

> **退路**：时间压力大时，先出 `6.1.158 + 11 行补丁` 过渡。唯一优势是当天能出构建。

### 并行三件

- **合入 PR #35** —— 与内核正交。修完后卡死的挂载在 10 秒内带真实错误返回，而不是静默挂 40 秒。**即使内核修好，任何其他原因的挂载挂起（proxy 重启、网络分区、后端变慢）都会复现同一形态**，所以独立有价值。
- **Engine 加有界退避** —— 最便宜，直接防止再被 page。对同一沙箱的重复恢复失败退避；不要把所有 timeout/500 都当成可以自动删除用户实例的信号。
- **存量沙箱迁移** —— 见 §7。

### 可选

- **`noresvport`**：不修泄漏，但把可用源端口从 359 扩到约 28000，耗尽时间从约 15 天推到数年级别。若 6.18 迁移周期长，值得作为保险。proxy 侧前提已验证：`getChroot` 走 `GetByHostPort`，内部 `net.SplitHostPort` 后**只用 IP、完全丢弃端口**，不会破坏沙箱归属判定。需另行验证 MOUNT 和 NFS 两个 RPC 都真的走非特权端口。
  - ⚠️ 上游 [#3623](https://github.com/e2b-dev/infra/pull/3623) 正在改同一个 `nfsOptions` 字符串（加 `nolock`），注意冲突。
- **向 `stable@vger.kernel.org` 请求把 `3f23f96528e8` backport 进 6.1.y**：6.6/6.12/6.18 都有、唯独 6.1 漏了，而 6.1 还有 15 个月生命周期。成本极低，被接受的话过渡补丁都能省。

---

## 7. 存量沙箱是单独的一层（最容易被低估）

resume 走的是 **`loadSnapshot`**（`fc/process.go:605`），**不重新加载内核**——快照里带着它自己那份内核镜像。

**所以发布新内核只对新建沙箱生效。** 现有暂停快照仍然带着 6.1.158 和已经泄漏的 TCP 状态恢复，泄漏照旧。

**"发布新内核 = 全量修复"是错的。** 需要明确的迁移方案：保留持久化工作目录与 Agent 配置后受控重建；不可恢复实例同理。

> 这一点对打补丁方案同样成立——两条路在存量问题上**完全一样**。

---

## 8. 验收标准

**核心指标：多轮 pause/resume，guest 内 `/proc/net/tcp` 中对端为 2049 的 `FIN_WAIT1` 条数与 665–1023 占用必须不随循环增长。**

补丁前基线已由 kaka 实测：**每轮 pause/resume +1**（第一次后 1 条 / 源端口 908；第二次后 2 条 / 908、990；均 `timer=00`、`retransmits=0`）。对照非常干净。

采集方式（在**独立测试实例**上，不是生产）：

```sh
ss -tanop '( dst 192.0.2.1 and dport = :2049 )'
# 或直接读 /proc/net/tcp，对端端口 0x0801；
# st 字段 04=FIN_WAIT1，第 6 列 tr:tm->when 为定时器，第 7 列 retrnsmt
```

另需验证：

- FC v1.14 跑 6.18 guest 的兼容性
- envd 的 cgroup freeze/thaw 在 6.18 上的行为
- `/workspace` 读写正确性（内容 SHA-256 对照）
- `olddefconfig` 后 e2b 特定开关仍然开着：`CONFIG_DEBUG_INFO_BTF`、eBPF tracing（tracepoints/uprobes/tc）、Kubernetes CNI + service LB + NetworkPolicy、`CONFIG_INPUT_UINPUT`
- 观察真实 ensure 成功及业务工具执行结果，**不能只看 Grafana NoData、API health 或 schedule 的 succeeded 字段**

---

## 9. 已排除的假说

记录下来，免得后来者重走。前四条是本次调查中被自己的证据推翻的。

| 假说 | 证伪依据 |
|---|---|
| 卡在 `findmnt` / `umount`（卸载阶段） | kaka 的连续任务栈证明**卸载已完成**，卡点在后续新挂载。日志最后停在 `Unmounting stale NFS mount` 极具误导性 |
| 50ms 请求超时与同步挂载"结构性不兼容" | 重试本来就是设计的一部分（`loopDelay=5ms` + 无限重试直到父 ctx 到期）|
| pause 前 `sync` 被 SIGKILL 留下 D 状态任务 | prod 的 reclaim 链默认全关（四步 flag 均为 0），两节点 reclaim 日志各 0 行 |
| 冻结 cgroup 导致循环死锁 | `freeze-user-cgroup` flag 默认仅 dev；且 `mount`/`umount` 用裸 `exec`、不带 `CgroupFD`，跑在 envd 的 root cgroup |
| 后端子树损坏 | `workspaces/<uuid>/bossclaw` 健康：`ls` 5ms、13 项、mtime 正常 |
| proxy 按 IP 查不到沙箱（注册竞态）| `AssignNetwork`(sandbox.go:1016) 早于 `WaitForEnvd`(:1083)；且 `failed to get path` 命中 0 |
| 跨沙箱 chroot 干扰 | chroot 按每次 resume 唯一的 lifecycleID 隔离 |
| 缺少 `zooclaw_managed_by` 标签相关 | kaka 明确否定；4 个受影响沙箱虽都属该形态，但该组共 24 个、只坏了 4 个 |
| 宿主机 conntrack 可做连接普查 | conntrack 的 FIN_WAIT 条目百余秒即过期；泄漏只存在于 guest 内核 socket 表 |

---

## 10. 尚未确认

**没有做过补丁前后的实测对照。** 机制虽已由 v6.1.158 源码闭合，但理论上可能还存在第二个泄漏源（例如 resume 时 proxy 侧连接切换本身使旧连接的关闭无法完成），换内核只解决其中一条。§8 那轮对照实验不能省。

kaka 文档列为"尚缺"的三项中，**`sk_net_refcnt` 直读已可由代码审查替代**——`xs_create_sock()` 用 `__sock_create(..., kern=1)`，且 6.1.y 从未含该补丁，故该值必然为 0，无需在 guest 内上 drgn/bpf。剩余两项（最初关闭的报文、补丁前后对照）仍需在测试实例补齐。

---

## 11. 引用

- 本仓库 PR：#35 — envd 进程组清理
- 上游相关（均**不覆盖**本问题）：[e2b-dev/infra#3617](https://github.com/e2b-dev/infra/pull/3617)（同类 bug、不同代码路径）、[#3623](https://github.com/e2b-dev/infra/pull/3623)（同文件、NLM/flock 缺陷）
- 内核补丁：[torvalds/linux@3f23f96528e8](https://github.com/torvalds/linux/commit/3f23f96528e8fcf8619895c4c916c52653892ec1)
- LTS 与 EOL：<https://www.kernel.org/releases.html>
- kaka 交接文档：《Sandbox pause/resume 后 NFS 连接残留，最终导致恢复失败》（证据目录 `/tmp/sandbox-alert-20260911/recurrence-1600/`，持久化备份 `recovery-backups/20260911-iltf773id1tponspbkgiw/bossclaw/`）
