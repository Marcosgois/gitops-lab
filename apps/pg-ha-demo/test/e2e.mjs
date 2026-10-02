// Teste de ponta a ponta contra o painel em http://localhost:$PORT (cluster local).
// Uso: node e2e.mjs sync|async [split]
const base = `http://localhost:${process.env.PORT || 8080}`;
const mode = process.argv[2] || 'sync';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const get = async () => (await fetch(base + '/api/state')).json();
const post = async (p, b) => (await fetch(base + p, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(b || {}) })).json();

// Cenário A (padrão): queda do primário. Com 'split' só roda o B — rodar os dois em seguida
// deixaria o primário do A pausado e a partição começaria com um nó a menos.
let s;
if (process.argv[3] !== 'split') {
  await post('/api/reset');
  console.log(`== modo ${mode}: iniciando carga`);
  console.log(await post('/api/load', { action: 'start', workers: 8, mode }));
  await sleep(8000);
  s = await get();
  console.log(`TPS em regime: ${s.totals.tpsNow}  p95: ${s.totals.p95?.toFixed(1)} ms  confirmadas: ${s.totals.acked}`);
  console.log('nós:', s.nodes.map((n) => `${n.name}:${n.role}${n.syncState ? '/' + n.syncState : ''}`).join(' '));

  console.log('== pausando o primário');
  const t0 = Date.now();
  console.log(await post('/api/chaos', { action: 'pause', target: 'primary' }));
  for (let i = 0; i < 80; i++) {
    await sleep(500); s = await get();
    if (s.events.length && !s.outage) break;
}
console.log(`evento após ${(Date.now() - t0) / 1000}s:`, JSON.stringify(s.events[0]));
await sleep(5000); s = await get();
const ev = s.events[0];
console.log(`RTO: ${ev ? (ev.rtoMs / 1000).toFixed(2) + ' s' : '—'}  perdidas (evento): ${ev?.lost}  perdidas (total): ${s.totals.lost}  confirmadas: ${s.totals.acked}  TPS agora: ${s.totals.tpsNow}`);
console.log('nós:', s.nodes.map((n) => `${n.name}:${n.role}${n.paused ? '(pausada)' : ''}/tl${n.tl}`).join(' '));
console.log('notas:'); s.notes.slice(0, 8).reverse().forEach((n) => console.log('  ', n.msg));
await post('/api/load', { action: 'stop' });
console.log('== carga parada');
}

// ---------------------------------------------------------------------------
// Cenário B (argumento 'split'): os dois standbys somem, o primário segue gravando (assíncrono)
// ou trava (síncrono); depois o primário cai e os standbys voltam. A diferença entre os modos
// aparece em TPS durante a partição e em perdas depois do failover.
if (process.argv[3] === 'split') {
  await post('/api/reset');
  console.log(`\n== cenário B (${mode}): partição dos standbys, depois queda do primário`);
  await post('/api/load', { action: 'start', workers: 8, mode });
  await sleep(6000);
  s = await get();
  const standbys = s.nodes.filter((n) => n.role === 'standby').map((n) => n.name);
  const primary = s.nodes.find((n) => n.role === 'primary').name;
  console.log(`primário: ${primary}; TPS antes: ${s.totals.tpsNow}; standbys: ${standbys}`);
  for (const nm of standbys) await post('/api/chaos', { action: 'pause', target: nm });
  await sleep(6000); s = await get();
  console.log(`durante a partição: TPS ${s.totals.tpsNow}, confirmadas ${s.totals.acked}, erros ${s.totals.errors}`);
  const ackedBefore = s.totals.acked;
  await post('/api/chaos', { action: 'pause', target: primary });
  for (const nm of standbys) await post('/api/chaos', { action: 'resume', target: nm });
  for (let i = 0; i < 100; i++) { await sleep(500); s = await get(); if (s.events.length && !s.outage && s.nodes.some((n) => n.role === 'primary' && !n.paused)) break; }
  await sleep(5000); s = await get();
  const e2 = s.events[0];
  console.log(`RTO: ${e2 ? (e2.rtoMs / 1000).toFixed(2) + ' s' : '—'}  perdidas: ${s.totals.lost}  confirmadas: ${s.totals.acked} (antes da queda do primário: ${ackedBefore})  TPS: ${s.totals.tpsNow}`);
  console.log('nós:', s.nodes.map((n) => `${n.name}:${n.role}${n.paused ? '(pausada)' : ''}/tl${n.tl}`).join(' '));
  await post('/api/load', { action: 'stop' });
}
