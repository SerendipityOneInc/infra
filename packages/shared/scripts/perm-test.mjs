import { Sandbox } from "e2b";
const sbx = await Sandbox.connect("iikxkztiyx2tjtgsek6xb");
const script = `
echo "== whoami =="; id
echo "== mounted view (uid as sandbox sees) =="; ls -lan /ws /ws/subdir
echo "== read existing (node-owned) =="; cat /ws/existing.txt
echo "== write NEW file =="; echo "written by sandbox user" > /ws/newfile.txt && echo "NEW-OK" || echo "NEW-FAIL"
echo "== modify EXISTING (append) =="; echo "appended by sandbox user" >> /ws/existing.txt && echo "MODIFY-OK" || echo "MODIFY-FAIL"
echo "== write in subdir =="; echo x > /ws/subdir/sbx.txt && echo "SUBDIR-OK" || echo "SUBDIR-FAIL"
echo "== resulting ownership (sandbox view) =="; ls -lan /ws
echo "== final existing.txt content =="; cat /ws/existing.txt
`;
const r = await sbx.commands.run(script, { user: "user" });
console.log(r.stdout);
if (r.stderr) console.log("STDERR:", r.stderr);
