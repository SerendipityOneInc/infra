import { Sandbox } from "e2b";
const sbx = await Sandbox.connect("iikxkztiyx2tjtgsek6xb");
// 1) 默认 commands.run 是谁
const a = await sbx.commands.run("id");
console.log("default run id:", a.stdout.trim());
// 2) 显式 user:"user"
const b = await sbx.commands.run("id", { user: "user" });
console.log("user:user run id:", b.stdout.trim());
// 3) 以 user 身份建文件,看落在 JuiceFS 上的属主
const c = await sbx.commands.run("echo hi > /ws/as-user.txt && stat -c '%n uid=%u gid=%g' /ws/as-user.txt", { user: "user" });
console.log("as-user file:", c.stdout.trim(), "| exit", c.exitCode, c.stderr && ("ERR:"+c.stderr));
