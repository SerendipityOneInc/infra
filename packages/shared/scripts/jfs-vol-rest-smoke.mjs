import { Sandbox } from "e2b";
const API = "https://api.sandbox2.yesy.dev";
const KEY = process.env.E2B_API_KEY;
const marker = "jfs-persist-" + Math.floor(Math.random()*1e9);

async function createWithVolume() {
  const r = await fetch(`${API}/sandboxes`, {
    method: "POST",
    headers: { "X-API-Key": KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ templateID: "base", timeout: 300,
      volumeMounts: [{ name: "e2b-jfs-test", path: "/mnt/data" }] }),
  });
  if (!r.ok) throw new Error(`create ${r.status}: ${await r.text()}`);
  return (await r.json()).sandboxID;
}

// A: mount + write
const idA = await createWithVolume();
const a = await Sandbox.connect(idA);
const w = await a.commands.run(`echo ${marker} > /mnt/data/persist.txt && sync && ls -la /mnt/data`);
console.log("A", idA, "write exit", w.exitCode, "\n" + w.stdout.trim());
await a.kill();

// B: mount same volume + read (cross-sandbox persistence)
const idB = await createWithVolume();
const b = await Sandbox.connect(idB);
const rd = await b.commands.run("cat /mnt/data/persist.txt");
console.log("B", idB, "read ->", rd.stdout.trim());
await b.kill();
console.log(rd.stdout.trim() === marker ? "JUICEFS VOLUME PERSISTENCE — PASS" : "FAIL");
