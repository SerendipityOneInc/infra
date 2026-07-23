// PTY (bidirectional HTTP/2 stream) smoke test — the operation that timed out
// through the App Gateway and drove the L4 data-plane work. Creates a sandbox,
// opens a PTY, sends a command, and asserts the echoed output comes back.
import { Sandbox } from "e2b";

async function main() {
  const sbx = await Sandbox.create("base", { timeoutMs: 120_000 });
  console.log("[pty] sandbox:", sbx.sandboxId);

  let out = "";
  const pty = await sbx.pty.create({
    cols: 80,
    rows: 24,
    timeoutMs: 60_000,
    onData: (d) => { out += new TextDecoder().decode(d); },
  });

  await sbx.pty.sendInput(pty.pid, new TextEncoder().encode("echo pty-over-h2-works\n"));
  await new Promise((r) => setTimeout(r, 3000));
  await sbx.pty.kill(pty.pid);
  await sbx.kill();

  console.log("[pty] output:\n" + out.trim());
  if (out.includes("pty-over-h2-works")) {
    console.log("[pty] PTY OVER L4/HTTP2 — PASS");
  } else {
    console.error("[pty] FAIL: expected echo not seen");
    process.exit(1);
  }
}

main().catch((e) => { console.error("[pty] FAILED:", e.message ?? e); process.exit(1); });
