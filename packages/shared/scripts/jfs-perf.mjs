import { Sandbox } from "e2b";
const sbx = await Sandbox.connect("i73eg3rz3wllcn891vt7m");
const bench = `
set -e
LOCAL=/home/user/perf; JFS=/mnt/jfs/perf
mkdir -p $LOCAL $JFS
run() {  # $1=label $2=dir
  local d=$2
  echo "===== $1 ($d) ====="
  # 1) 顺序写 512MB
  sync
  local w=$( { /usr/bin/time -f "%e" dd if=/dev/zero of=$d/big bs=1M count=512 conv=fdatasync 2>&1 1>/dev/null | tail -1; } )
  echo "seq-write 512MB: $(awk -v t=$w 'BEGIN{printf "%.1f MB/s (%ss)", 512/t, t}')"
  # 2) 顺序读 512MB
  local r=$( { /usr/bin/time -f "%e" dd if=$d/big of=/dev/null bs=1M 2>&1 1>/dev/null | tail -1; } )
  echo "seq-read  512MB: $(awk -v t=$r 'BEGIN{printf "%.1f MB/s (%ss)", 512/t, t}')"
  rm -f $d/big
  # 3) 500 个小文件(4KB)写
  mkdir -p $d/small
  local sw=$( { /usr/bin/time -f "%e" sh -c 'for i in $(seq 1 500); do dd if=/dev/zero of='"$d"'/small/f$i bs=4k count=1 2>/dev/null; done' 2>&1; } )
  echo "500x4KB write:   $(awk -v t=$sw 'BEGIN{printf "%.2fs (%.0f files/s)", t, 500/t}')"
  # 4) 500 个小文件 stat+read
  local sr=$( { /usr/bin/time -f "%e" sh -c 'for i in $(seq 1 500); do cat '"$d"'/small/f$i >/dev/null; done' 2>&1; } )
  echo "500x4KB read:    $(awk -v t=$sr 'BEGIN{printf "%.2fs (%.0f files/s)", t, 500/t}')"
  rm -rf $d/small
}
run "LOCAL DISK" $LOCAL
run "JUICEFS   " $JFS
echo "===== df ====="; df -h /home/user /mnt/jfs | grep -vE "^Filesystem"
`;
const r = await sbx.commands.run(bench, { user: "user", timeoutMs: 600000 });
console.log(r.stdout);
if (r.stderr) console.log("STDERR:", r.stderr.slice(-400));
