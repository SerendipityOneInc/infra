import { Sandbox } from "e2b";
const marker = "jfs-persist-" + Math.floor(Math.random()*1e9);
// 1) 挂卷写文件
const a = await Sandbox.create("base", { volumeMounts: { "/mnt/data": "e2b-jfs-test" }, timeoutMs: 120000 });
await a.commands.run(`echo ${marker} > /mnt/data/persist.txt && sync`);
console.log("wrote in sandbox A:", a.sandboxId);
await a.kill();
// 2) 新沙箱挂同一卷读回(跨沙箱持久 = JuiceFS 落地)
const b = await Sandbox.create("base", { volumeMounts: { "/mnt/data": "e2b-jfs-test" }, timeoutMs: 120000 });
const r = await b.commands.run("cat /mnt/data/persist.txt");
console.log("read in sandbox B:", b.sandboxId, "->", r.stdout.trim());
await b.kill();
console.log(r.stdout.trim() === marker ? "JUICEFS VOLUME PERSISTENCE — PASS" : "FAIL: marker mismatch");
