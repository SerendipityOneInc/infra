import { Sandbox } from "e2b";
const sbx = await Sandbox.connect("iikxkztiyx2tjtgsek6xb");
const r = await sbx.commands.run("mount | grep -iE '/ws|nfs' | head; echo '---'; nfsstat -m 2>/dev/null | head", { user: "user" });
console.log(r.stdout.trim() || "(no nfs mount line)");
