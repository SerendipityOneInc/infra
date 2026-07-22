// One-shot smoke test for the Azure PoC (sandbox2.yesy.dev).
// Creates a sandbox from the freshly built "base" template, runs a command,
// prints the output, and kills the sandbox. Mirrors the GCP PoC verification.
import { Sandbox } from "e2b";

async function main() {
  console.log("[smoke] creating sandbox from template 'base'...");
  const t0 = Date.now();
  const sbx = await Sandbox.create("base", { timeoutMs: 120_000 });
  console.log(`[smoke] sandbox created: ${sbx.sandboxId} (${Date.now() - t0}ms)`);

  try {
    const r1 = await sbx.commands.run("echo hello-from-azure-e2b && uname -a && cat /etc/os-release | head -2");
    console.log("[smoke] exit:", r1.exitCode);
    console.log("[smoke] stdout:\n" + r1.stdout);

    const r2 = await sbx.commands.run("python3 -c 'print(6*7)' || echo no-python");
    console.log("[smoke] python:", r2.stdout.trim());
  } finally {
    await sbx.kill();
    console.log("[smoke] sandbox killed. PASS");
  }
}

main().catch((err) => {
  console.error("[smoke] FAILED:", err);
  process.exit(1);
});
