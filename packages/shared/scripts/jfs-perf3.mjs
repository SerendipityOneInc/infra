import { Sandbox } from "e2b";
const sbx = await Sandbox.connect("ii5swl10nva07tje0srfh");
const bench = String.raw`
LOCAL=/home/user/perf; JFS=/mnt/jfs/perf
mkdir -p $LOCAL $JFS
echo "== mounts =="; mount | grep -E 'on / |/mnt/jfs' | sed 's/ (.*//'
now(){ date +%s.%N; }
el(){ awk -v a=$1 -v b=$(now) 'BEGIN{printf "%.3f", b-a}'; }
run(){
  d=$2; echo "===== $1 ($d) ====="
  sync
  t=$(now); dd if=/dev/zero of=$d/big bs=1M count=512 conv=fdatasync 2>/dev/null; e=$(el $t)
  echo "seq-write 512MB : $(awk -v t=$e 'BEGIN{printf "%.0f MB/s (%.1fs)",512/t,t}')"
  t=$(now); dd if=$d/big of=/dev/null bs=1M 2>/dev/null; e=$(el $t)
  echo "seq-read  512MB : $(awk -v t=$e 'BEGIN{printf "%.0f MB/s (%.1fs)",512/t,t}')"
  rm -f $d/big
  mkdir -p $d/small
  t=$(now); for i in $(seq 1 500); do dd if=/dev/zero of=$d/small/f$i bs=4k count=1 2>/dev/null; done; e=$(el $t)
  echo "500x4KB write  : $(awk -v t=$e 'BEGIN{printf "%.2fs (%.0f files/s)",t,500/t}')"
  t=$(now); for i in $(seq 1 500); do cat $d/small/f$i >/dev/null; done; e=$(el $t)
  echo "500x4KB read   : $(awk -v t=$e 'BEGIN{printf "%.2fs (%.0f files/s)",t,500/t}')"
  rm -rf $d/small
}
run "LOCAL" $LOCAL
run "JUICEFS" $JFS
`;
const r = await sbx.commands.run(bench, { user: "user", timeoutMs: 600000 });
console.log(r.stdout);
if (r.stderr) console.log("STDERR:", r.stderr.slice(-200));
