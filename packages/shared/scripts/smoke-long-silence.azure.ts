import { Sandbox } from "e2b";
async function main() {
  const sbx = await Sandbox.create("base", { timeoutMs: 300_000 });
  console.log("[t] sandbox:", sbx.sandboxId, "— running 130s silent command...");
  const t0 = Date.now();
  // requestTimeoutMs: the SDK's own per-request abort — must exceed the silent
  // window or the CLIENT kills the stream before the network path is tested.
  const r = await sbx.commands.run("sleep 130 && echo survived-130s-silence", {
    timeoutMs: 200_000,
    requestTimeoutMs: 200_000,
  });
  console.log(`[t] exit=${r.exitCode} stdout=${r.stdout.trim()} elapsed=${Math.round((Date.now() - t0) / 1000)}s`);
  await sbx.kill();
  console.log(r.stdout.includes("survived") ? "[t] 100s-TIMEOUT TEST PASS" : "[t] FAIL");
}
main().catch((e) => { console.error("[t] FAILED:", e.message); process.exit(1); });
