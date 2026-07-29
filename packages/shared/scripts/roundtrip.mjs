import { Sandbox } from "e2b";
const sbx = await Sandbox.connect("iikxkztiyx2tjtgsek6xb");
const r = await sbx.commands.run(`
echo '== 1. user 建文件 =='; echo v1 > /ws/rt.txt; stat -c '%n %U:%G %a' /ws/rt.txt
echo '== 2. user 再改同一文件(append) =='; (echo v2 >> /ws/rt.txt && echo APPEND-OK || echo APPEND-FAIL)
echo '== 3. user 覆盖写 =='; (echo v3 > /ws/rt.txt && echo OVERWRITE-OK || echo OVERWRITE-FAIL)
echo '== 4. 内容 =='; cat /ws/rt.txt 2>&1
echo '== 5. 目录里 mkdir/写 =='; (mkdir -p /ws/d2 && echo x > /ws/d2/f && echo MKDIR-OK || echo MKDIR-FAIL); stat -c '%n %U:%G' /ws/d2 2>/dev/null
`, { user: "user" });
console.log(r.stdout);
