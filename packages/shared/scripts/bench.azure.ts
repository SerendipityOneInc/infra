// Measure Sandbox.create latency distribution (client wall-clock) — 5 rounds.
import { Sandbox } from "e2b";

async function main() {
  const times: number[] = [];
  for (let i = 0; i < 5; i++) {
    const t0 = Date.now();
    const sbx = await Sandbox.create("base", { timeoutMs: 60_000 });
    const dt = Date.now() - t0;
    times.push(dt);
    console.log(`[bench] #${i + 1} ${sbx.sandboxId} create=${dt}ms`);
    await sbx.kill();
  }
  times.sort((a, b) => a - b);
  console.log(`[bench] min=${times[0]}ms median=${times[2]}ms max=${times[4]}ms`);
}

main().catch((e) => { console.error(e); process.exit(1); });
