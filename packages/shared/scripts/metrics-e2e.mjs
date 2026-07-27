import { Sandbox } from 'e2b';
const sbx = await Sandbox.create('base', { timeoutMs: 120000 });
await sbx.commands.run('yes > /dev/null & sleep 8; kill %1');   // 制造点 CPU
await new Promise(r => setTimeout(r, 25000));                    // 等指标落库
const res = await fetch(`https://api.sandbox2.yesy.dev/sandboxes/${sbx.sandboxId}/metrics`, { headers: { 'X-API-Key': process.env.E2B_API_KEY } });
const body = await res.json();
const m = Array.isArray(body) ? body : (body.metrics || []);
console.log('metrics API:', res.status, '| points:', m.length);
if (m.length) console.log('sample:', JSON.stringify(m[m.length-1]));
await sbx.kill();
console.log(m.length > 0 ? 'METRICS E2E — PASS' : 'METRICS E2E — EMPTY');
