'use strict';
/*
 * pg-ha-demo — painel de HA do PostgreSQL (3 réplicas).
 *
 * O que faz:
 *   1. gera carga contínua de gravações no primário (N workers);
 *   2. mede transações por segundo (TPS) e latência;
 *   3. detecta a queda do primário e mede o TEMPO DE RECUPERAÇÃO (RTO) do ponto de vista
 *      da aplicação: do último commit confirmado antes da falha ao primeiro commit depois;
 *   4. conta as PERDAS: transações que o banco confirmou ("COMMIT ok") e que não existem
 *      mais no novo primário.
 *
 * Quem faz o failover NÃO é este programa: é o Patroni (ou promoção manual). Existe um modo
 * de laboratório (AUTO_PROMOTE=1) que promove o standby mais adiantado — só para quando o
 * Patroni não estiver disponível. Ver README.md.
 */
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const { Client } = require('pg');

// ---------------------------------------------------------------- configuração
function parseHosts(s) {
  return s.split(',').map((x) => x.trim()).filter(Boolean).map((x) => {
    const [host, port] = x.split(':');
    return { host, port: Number(port) || 5432 };
  });
}
const hosts = parseHosts(process.env.PG_HOSTS || '192.168.5.123,192.168.5.124,192.168.5.125');
const cfg = {
  port: Number(process.env.PORT) || 8080,
  user: process.env.PG_USER || 'demo',
  password: process.env.PG_PASSWORD || '',
  database: process.env.PG_DB || 'demo',
  names: (process.env.PG_NAMES || 'pg-lab-1,pg-lab-2,pg-lab-3').split(',').map((x) => x.trim()),
  // endereço que os nós usam entre si (pode diferir do que o app enxerga, ex.: testes locais)
  peers: process.env.PG_PEER_HOSTS ? parseHosts(process.env.PG_PEER_HOSTS) : hosts,
  replUser: process.env.PG_REPL_USER || 'replicator',
  replPassword: process.env.PG_REPL_PASSWORD || '',
  connectTimeoutMs: Number(process.env.CONNECT_TIMEOUT_MS) || 1000,
  queryTimeoutMs: Number(process.env.QUERY_TIMEOUT_MS) || 1500,
  autoPromote: process.env.AUTO_PROMOTE === '1',
  promoteAfterMs: Number(process.env.PROMOTE_AFTER_MS) || 4000,
  chaosCmd: process.env.CHAOS_CMD || '', // ex.: "podman {action} {name}" (testes locais)
  vmNamespace: process.env.VM_NAMESPACE || 'demos',
  patroniPort: Number(process.env.PATRONI_PORT) || 8008, // API REST do Patroni nas VMs (se houver)
  maxWorkers: 64,
};

const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';
const inCluster = fs.existsSync(path.join(SA_DIR, 'token'));
const chaosAvailable = Boolean(cfg.chaosCmd) || inCluster;

// ---------------------------------------------------------------- estado
const nodes = hosts.map((h, i) => ({
  idx: i, name: cfg.names[i] || `pg-${i + 1}`, host: h.host, port: h.port,
  up: false, role: 'indefinido', lsn: null, tl: null, lagBytes: null, syncState: null,
  replicas: [], error: null, seenAt: 0, paused: false,
}));

const state = {
  running: false, mode: 'sync', workerCount: 8, runId: 0, startedAt: 0,
  acked: 0, errors: 0, lostTotal: 0, verifiedAt: 0, verifying: false,
  lastAckAt: 0, currentPrimary: null, maxTl: 0,
  outage: null, events: [], seq: 0,
  buckets: new Map(), // segundo -> {n, errs, lat[]}
  workers: [], promoting: false, notes: [],
  patroni: null, // {ttl, loopWait, retryTimeout, seenAt} quando o Patroni responde nas VMs
};

function note(msg) {
  state.notes.unshift({ t: Date.now(), msg });
  state.notes.length = Math.min(state.notes.length, 30);
  console.log(new Date().toISOString(), msg);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => Date.now();

function bucket(sec) {
  let b = state.buckets.get(sec);
  if (!b) {
    b = { n: 0, errs: 0, lat: [] };
    state.buckets.set(sec, b);
    for (const k of state.buckets.keys()) if (k < sec - 400) state.buckets.delete(k);
  }
  return b;
}

// ---------------------------------------------------------------- conexões
function newClient(n, extra = {}) {
  const c = new Client({
    host: n.host, port: n.port, user: cfg.user, password: cfg.password, database: cfg.database,
    connectionTimeoutMillis: cfg.connectTimeoutMs, query_timeout: cfg.queryTimeoutMs,
    keepAlive: true, ...extra,
  });
  c.on('error', () => {});
  return c;
}

const WHO_SQL = `SELECT pg_is_in_recovery() AS rec,
  CASE WHEN pg_is_in_recovery() THEN NULL
       ELSE ('x' || substring(pg_walfile_name(pg_current_wal_lsn()) from 1 for 8))::bit(32)::int END AS tl`;

// Conecta ao primário vigente (maior timeline). Parte do último primário conhecido.
async function connectPrimary(w) {
  const order = nodes.slice().sort((a, b) => (b.idx === state.currentPrimary) - (a.idx === state.currentPrimary));
  let lastErr = new Error('sem primário disponível');
  for (const n of order) {
    const c = newClient(n, { application_name: `pg-ha-demo-w${w.id}` });
    try {
      await c.connect();
      const r = await c.query(WHO_SQL);
      if (r.rows[0].rec) { c.end().catch(() => {}); continue; }
      const tl = r.rows[0].tl;
      if (tl < state.maxTl) { c.end().catch(() => {}); lastErr = new Error(`${n.name} é um primário obsoleto (timeline ${tl})`); continue; }
      state.maxTl = tl;
      if (state.currentPrimary !== n.idx) {
        note(`app conectou em ${n.name} (primário, timeline ${tl})`);
        state.currentPrimary = n.idx;
      }
      await c.query(`SET synchronous_commit TO ${state.mode === 'sync' ? 'on' : 'local'}`);
      w.mode = state.mode;
      return c;
    } catch (e) {
      lastErr = e;
      c.end().catch(() => {});
    }
  }
  throw lastErr;
}

// ---------------------------------------------------------------- carga
const PAYLOAD = 'x'.repeat(100);

function addAck(w, seq) {
  const last = w.ranges[w.ranges.length - 1];
  if (last && last[1] + 1 === seq) last[1] = seq; else w.ranges.push([seq, seq]);
}

function onAck(w, seq, latMs, sentAt) {
  addAck(w, seq);
  state.acked++;
  state.lastAckAt = now();
  const b = bucket(Math.floor(state.lastAckAt / 1000));
  b.n++;
  if (b.lat.length < 4000) b.lat.push(latMs);
  // só fecha a queda uma gravação ENVIADA depois do primeiro erro: a resposta de um INSERT que
  // já estava em voo quando o primário caiu não prova que o serviço voltou (abria eventos de 0 ms)
  if (state.outage && sentAt >= state.outage.firstErrorAt) recover();
  else if (state.outage) state.outage.startedAt = state.lastAckAt; // ainda é o "último antes da falha"
}

function onError(w, e) {
  state.errors++;
  bucket(Math.floor(now() / 1000)).errs++;
  if (!state.outage) {
    state.outage = {
      id: ++state.seq, startedAt: state.lastAckAt || now(), firstErrorAt: now(),
      oldPrimary: state.currentPrimary, errors: 0, firstError: String(e.message || e).slice(0, 120),
    };
    note(`falha detectada: ${state.outage.firstError}`);
  }
  state.outage.errors++;
}

function recover() {
  const o = state.outage;
  state.outage = null;
  const t = now();
  const ev = {
    id: o.id, startedAt: o.startedAt, detectedAt: o.firstErrorAt, recoveredAt: t,
    rtoMs: t - o.startedAt, errors: o.errors,
    oldPrimary: o.oldPrimary != null ? nodes[o.oldPrimary].name : null,
    newPrimary: state.currentPrimary != null ? nodes[state.currentPrimary].name : null,
    mode: state.mode, lost: null, lostBefore: state.lostTotal, verified: false, error: o.firstError,
  };
  ev.trocou = ev.oldPrimary !== ev.newPrimary;
  state.events.unshift(ev);
  state.events.length = Math.min(state.events.length, 40);
  note(`recuperado em ${(ev.rtoMs / 1000).toFixed(2)} s (${ev.oldPrimary} → ${ev.newPrimary})`);
  setTimeout(() => verify(`evento ${ev.id}`).catch(() => {}), 1500);
}

async function workerLoop(w, runId) {
  while (state.running && state.runId === runId) {
    try {
      if (!w.client) w.client = await connectPrimary(w);
      if (w.mode !== state.mode) {
        await w.client.query(`SET synchronous_commit TO ${state.mode === 'sync' ? 'on' : 'local'}`);
        w.mode = state.mode;
      }
      // Síncrono sem nenhum standby no quórum: o COMMIT ficaria preso no servidor e cada nova
      // tentativa prenderia mais uma conexão até esgotar o max_connections. Espera sem gravar.
      // Não conta como erro: a queda real já abriu o evento pelos timeouts; aqui seria só ruído
      // (ex.: o standby reapontado ainda em 'catchup' logo depois do failover).
      const prim = nodes[state.currentPrimary];
      if (state.mode === 'sync' && prim && prim.role === 'primary' &&
          !prim.replicas.some((r) => r.state === 'streaming' && (r.sync_state === 'quorum' || r.sync_state === 'sync'))) {
        if (!state.quorumWaitNoted) { state.quorumWaitNoted = true; note(`${prim.name} sem standby para o quórum — gravações em espera`); }
        await sleep(250);
        continue;
      }
      state.quorumWaitNoted = false;
      const seq = w.next;
      const sentAt = now();
      const t0 = process.hrtime.bigint();
      await w.client.query('INSERT INTO ledger(run, worker, seq, payload) VALUES ($1, $2, $3, $4)',
        [runId, w.id, seq, PAYLOAD]);
      onAck(w, seq, Number(process.hrtime.bigint() - t0) / 1e6, sentAt);
      w.next = seq + 1;
    } catch (e) {
      onError(w, e);
      w.next += 1; // pula a sequência em voo: não sabemos se chegou a gravar
      if (w.client) { w.client.end().catch(() => {}); w.client = null; }
      await sleep(150);
    }
  }
  if (w.client) { w.client.end().catch(() => {}); w.client = null; }
}

async function ensureSchema() {
  const w = { id: -1 };
  for (let i = 0; i < 20; i++) {
    try {
      const c = await connectPrimary(w);
      await c.query(`CREATE TABLE IF NOT EXISTS ledger (
        run int NOT NULL, worker int NOT NULL, seq bigint NOT NULL,
        payload text, ts timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (run, worker, seq))`);
      c.end().catch(() => {});
      return;
    } catch (e) { await sleep(500); }
  }
  throw new Error('não consegui preparar a tabela ledger (sem primário?)');
}

async function startLoad(workers, mode) {
  if (state.running) return;
  state.workerCount = Math.max(1, Math.min(cfg.maxWorkers, Number(workers) || state.workerCount));
  if (mode === 'sync' || mode === 'async') state.mode = mode;
  // nova rodada: recalcula a timeline de referência a partir dos primários visíveis agora
  // (ex.: o cluster foi recriado, ou um nó obsoleto foi reconstruído)
  state.maxTl = Math.max(0, ...nodes.filter((n) => n.role === 'primary' && n.tl).map((n) => n.tl));
  await ensureSchema();
  state.runId = Math.floor(Date.now() / 1000);
  state.running = true;
  state.startedAt = now();
  state.acked = 0; state.errors = 0; state.lostTotal = 0; state.verifiedAt = 0;
  state.lastAckAt = now(); state.outage = null; state.buckets.clear();
  state.workers = Array.from({ length: state.workerCount }, (_, i) => ({ id: i, next: 1, ranges: [], client: null, mode: null }));
  for (const w of state.workers) workerLoop(w, state.runId);
  note(`carga iniciada: ${state.workerCount} workers, modo ${state.mode === 'sync' ? 'síncrono (quórum)' : 'assíncrono'}`);
}

async function stopLoad() {
  if (!state.running) return;
  state.running = false;
  note('carga parada');
  await sleep(400);
  verify('fim da carga').catch(() => {});
}

// ---------------------------------------------------------------- perdas
async function verify(reason) {
  if (state.verifying || !state.workers.length) return;
  state.verifying = true;
  let c;
  try {
    c = await connectPrimary({ id: -2 });
    let acked = 0; let present = 0;
    const runId = state.runId;
    const snap = state.workers.map((w) => ({ id: w.id, ranges: w.ranges.map((r) => [r[0], r[1]]) }));
    for (const w of snap) {
      for (const [a, b] of w.ranges) {
        acked += b - a + 1;
        const r = await c.query('SELECT count(*)::int AS c FROM ledger WHERE run=$1 AND worker=$2 AND seq BETWEEN $3 AND $4',
          [runId, w.id, a, b]);
        present += r.rows[0].c;
      }
    }
    state.lostTotal = acked - present;
    state.verifiedAt = now();
    for (const ev of state.events) {
      if (!ev.verified) { ev.lost = state.lostTotal - ev.lostBefore; ev.verified = true; }
    }
    note(`verificação (${reason}): ${acked} confirmadas, ${present} presentes, ${acked - present} perdidas`);
  } catch (e) {
    note(`verificação falhou (${reason}): ${e.message}`);
  } finally {
    if (c) c.end().catch(() => {});
    state.verifying = false;
  }
}

// ---------------------------------------------------------------- monitor
const lsnToBig = (s) => { if (!s) return 0n; const [a, b] = s.split('/'); return (BigInt('0x' + a) << 32n) + BigInt('0x' + b); };

async function probe(n) {
  const c = newClient(n, { application_name: 'pg-ha-demo-monitor' });
  try {
    await c.connect();
    const r = await c.query(`SELECT pg_is_in_recovery() AS rec,
      (CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END)::text AS lsn,
      CASE WHEN pg_is_in_recovery() THEN NULL
           ELSE ('x' || substring(pg_walfile_name(pg_current_wal_lsn()) from 1 for 8))::bit(32)::int END AS tl`);
    n.up = true; n.error = null; n.seenAt = now();
    n.role = r.rows[0].rec ? 'standby' : 'primary';
    n.lsn = r.rows[0].lsn; n.tl = r.rows[0].tl;
    if (n.role === 'primary') {
      if (n.tl > state.maxTl) state.maxTl = n.tl;
      try {
        const rep = await c.query(`SELECT application_name, state, sync_state,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS lag FROM pg_stat_replication`);
        n.replicas = rep.rows;
      } catch (e) { n.replicas = []; }
    } else { n.replicas = []; n.lagBytes = null; n.syncState = null; }
  } catch (e) {
    n.up = false; n.role = 'fora'; n.error = String(e.message || e).slice(0, 100); n.replicas = [];
    n.lagBytes = null; n.syncState = null; n.tl = null;
  } finally { c.end().catch(() => {}); }
}

async function monitorTick() {
  await Promise.all(nodes.map(probe));
  const prims = nodes.filter((n) => n.role === 'primary');
  // Obsoleto = timeline menor que a MAIOR já vista, não só a maior visível agora: se o primário
  // atual cair enquanto um antigo está de pé, o antigo não pode passar por primário válido
  // (bloquearia o failover e a aplicação o recusaria de qualquer jeito).
  const maxTl = Math.max(state.maxTl || 0, ...prims.map((n) => n.tl || 0));
  for (const n of nodes) {
    n.stale = n.role === 'primary' && n.tl < maxTl;
    // o pg-autorejoin da VM (lab/pg-autorejoin.sh) devolve o obsoleto ao pool sozinho
    if (n.wasStale && n.role === 'standby') note(`${n.name} voltou ao pool como standby`);
    n.wasStale = n.stale || (n.wasStale && n.role !== 'standby');
  }
  const best = prims.filter((n) => !n.stale).sort((a, b) => b.tl - a.tl)[0];
  if (best) {
    for (const n of nodes) {
      if (n.role !== 'standby') continue;
      const rep = best.replicas.find((r) => r.application_name === n.name);
      n.lagBytes = rep ? Number(rep.lag) : null;
      n.syncState = rep ? rep.sync_state : null;
    }
  }
  await promoterTick(best);
}

// ---------------------------------------------------------------- failover assistido (laboratório)
let noPrimarySince = null;
const q = (s) => `'${String(s).replace(/'/g, "''")}'`;

async function adminQuery(n, sql) {
  const c = newClient(n, { application_name: 'pg-ha-demo-promoter' });
  try { await c.connect(); return await c.query(sql); } finally { c.end().catch(() => {}); }
}

async function promoterTick(best) {
  // com o Patroni nas VMs quem elege é ele: os dois juntos disputariam a promoção
  if (!cfg.autoPromote || state.patroni) return;
  if (best) { noPrimarySince = null; return; }
  if (!noPrimarySince) noPrimarySince = now();
  if (now() - noPrimarySince < cfg.promoteAfterMs || state.promoting) return;
  const cands = nodes.filter((n) => n.role === 'standby' && n.up).sort((a, b) => (lsnToBig(b.lsn) > lsnToBig(a.lsn) ? 1 : -1));
  if (!cands.length) return;
  state.promoting = true;
  try {
    const win = cands[0];
    note(`failover assistido: promovendo ${win.name} (LSN ${win.lsn})`);
    await adminQuery(win, 'SELECT pg_promote(true, 30)');
    const peer = cfg.peers[win.idx] || { host: win.host, port: win.port };
    for (const other of nodes) {
      if (other === win || !other.up || other.role !== 'standby') continue;
      const ci = `host=${peer.host} port=${peer.port} user=${cfg.replUser} password=${cfg.replPassword} application_name=${other.name}`;
      try {
        await adminQuery(other, `ALTER SYSTEM SET primary_conninfo = ${q(ci)}`);
        await adminQuery(other, 'SELECT pg_reload_conf()');
        note(`${other.name} passou a seguir ${win.name}`);
      } catch (e) { note(`não consegui reapontar ${other.name}: ${e.message}`); }
    }
  } catch (e) {
    note(`failover assistido falhou: ${e.message}`);
  } finally { state.promoting = false; noPrimarySince = null; }
}

// ---------------------------------------------------------------- caos (pausar/retomar a VM)
function execP(cmd) {
  return new Promise((resolve, reject) => exec(cmd, { timeout: 15000 }, (e, out, err) => (e ? reject(new Error(err || e.message)) : resolve(out))));
}

function kubeRequest(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const token = fs.readFileSync(path.join(SA_DIR, 'token'), 'utf8').trim();
    const ca = fs.readFileSync(path.join(SA_DIR, 'ca.crt'));
    const req = https.request({
      host: process.env.KUBERNETES_SERVICE_HOST || 'kubernetes.default.svc',
      port: process.env.KUBERNETES_SERVICE_PORT || 443, path: urlPath, method, ca,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    }, (res) => {
      let data = '';
      res.on('data', (d) => { data += d; });
      res.on('end', () => (res.statusCode < 300 ? resolve(data) : reject(new Error(`API ${res.statusCode}: ${data.slice(0, 200)}`))));
    });
    req.on('error', reject);
    req.end(body ? JSON.stringify(body) : '{}');
  });
}

async function chaos(action, target) {
  let n = nodes.find((x) => x.name === target);
  if (target === 'primary' || !n) n = nodes.find((x) => x.role === 'primary' && !x.stale) || nodes[state.currentPrimary];
  if (!n) throw new Error('não achei o nó alvo');
  const verb = action === 'pause' ? 'pause' : 'unpause';
  if (cfg.chaosCmd) await execP(cfg.chaosCmd.replace('{action}', verb).replace('{name}', n.name));
  else if (inCluster) {
    await kubeRequest('PUT', `/apis/subresources.kubevirt.io/v1/namespaces/${cfg.vmNamespace}/virtualmachineinstances/${n.name}/${verb}`);
  } else throw new Error('sem como pausar a VM (nem CHAOS_CMD nem ServiceAccount)');
  n.paused = action === 'pause';
  note(`${action === 'pause' ? 'PAUSEI' : 'RETOMEI'} ${n.name}`);
  return n.name;
}

// ---------------------------------------------------------------- estado para o front
function pct(arr, p) {
  if (!arr.length) return null;
  const s = arr.slice().sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
}

function snapshot() {
  const t = now();
  const sec = Math.floor(t / 1000);
  const series = [];
  for (let s = sec - 179; s <= sec; s++) {
    const b = state.buckets.get(s);
    series.push({ t: s * 1000, tps: b ? b.n : 0, errs: b ? b.errs : 0, p95: b ? pct(b.lat, 95) : null });
  }
  const last3 = [sec - 3, sec - 2, sec - 1].map((s) => (state.buckets.get(s) || { n: 0 }).n);
  const lat = [];
  for (let s = sec - 3; s <= sec - 1; s++) { const b = state.buckets.get(s); if (b) lat.push(...b.lat); }
  const prim = nodes.filter((n) => n.role === 'primary');
  return {
    now: t, running: state.running, runId: state.runId, mode: state.mode, workers: state.workerCount,
    chaosAvailable, autoPromote: cfg.autoPromote && !state.patroni, hasPassword: Boolean(cfg.password), patroni: state.patroni,
    nodes: nodes.map((n) => ({
      name: n.name, role: n.role, up: n.up, lsn: n.lsn, tl: n.tl, lagBytes: n.lagBytes, syncState: n.syncState,
      paused: n.paused, stale: Boolean(n.stale), error: n.error, current: n.idx === state.currentPrimary,
    })),
    splitBrain: prim.length > 1,
    totals: {
      acked: state.acked, errors: state.errors, lost: state.lostTotal, verifiedAt: state.verifiedAt, verifying: state.verifying,
      tpsNow: Math.round(last3.reduce((a, b) => a + b, 0) / 3), p95: pct(lat, 95), p50: pct(lat, 50),
      runningMs: state.running ? t - state.startedAt : 0,
    },
    outage: state.outage ? { since: state.outage.startedAt, elapsedMs: t - state.outage.startedAt, errors: state.outage.errors } : null,
    series, events: state.events, notes: state.notes.slice(0, 12),
  };
}

// ---------------------------------------------------------------- HTTP
const PUBLIC = path.join(__dirname, 'public');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };

function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', (c) => { d += c; if (d.length > 1e5) req.destroy(); });
    req.on('end', () => { try { resolve(d ? JSON.parse(d) : {}); } catch (e) { resolve({}); } });
  });
}
const json = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(obj)); };

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/healthz') return json(res, 200, { ok: true });
    if (url.pathname === '/api/state') return json(res, 200, snapshot());
    if (req.method === 'POST' && url.pathname.startsWith('/api/')) {
      const b = await readBody(req);
      if (url.pathname === '/api/load') {
        if (b.action === 'stop') await stopLoad(); else await startLoad(b.workers, b.mode);
        return json(res, 200, { ok: true });
      }
      if (url.pathname === '/api/mode') {
        if (b.mode === 'sync' || b.mode === 'async') { state.mode = b.mode; note(`modo: ${b.mode === 'sync' ? 'síncrono (quórum)' : 'assíncrono'}`); }
        return json(res, 200, { ok: true });
      }
      if (url.pathname === '/api/chaos') {
        const name = await chaos(b.action === 'resume' ? 'resume' : 'pause', b.target || 'primary');
        return json(res, 200, { ok: true, node: name });
      }
      if (url.pathname === '/api/verify') { verify('manual').catch(() => {}); return json(res, 200, { ok: true }); }
      if (url.pathname === '/api/reset') {
        state.events = []; state.notes = []; state.lostTotal = 0; state.acked = 0; state.errors = 0; state.buckets.clear();
        state.workers.forEach((w) => { w.ranges = []; });
        return json(res, 200, { ok: true });
      }
      return json(res, 404, { error: 'rota desconhecida' });
    }
    let file = url.pathname === '/' ? '/index.html' : url.pathname;
    file = path.normalize(file).replace(/^(\.\.[/\\])+/, '');
    const full = path.join(PUBLIC, file);
    if (!full.startsWith(PUBLIC) || !fs.existsSync(full) || fs.statSync(full).isDirectory()) { res.writeHead(404); return res.end('não encontrado'); }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(full).pipe(res);
  } catch (e) {
    json(res, 500, { error: String(e.message || e) });
  }
});

process.on('unhandledRejection', (e) => console.error('unhandledRejection', e && e.message));
process.on('uncaughtException', (e) => console.error('uncaughtException', e && e.message));

// Patroni: lê ttl/loop_wait da API REST de qualquer nó, a cada 10 s. Serve para a contagem
// regressiva do painel — o líder só é trocado quando o cadeado dele expira no etcd (ttl).
let patroniCheckedAt = 0;
async function patroniTick() {
  if (now() - patroniCheckedAt < 10000) return;
  patroniCheckedAt = now();
  for (const n of nodes) {
    try {
      const r = await fetch(`http://${n.host}:${cfg.patroniPort}/config`, { signal: AbortSignal.timeout(1000) });
      if (!r.ok) continue;
      const c = await r.json();
      if (!state.patroni) note(`Patroni detectado (ttl ${c.ttl} s): ele elege o primário${cfg.autoPromote ? ' — failover do painel em espera' : ''}`);
      state.patroni = { ttl: c.ttl, loopWait: c.loop_wait, retryTimeout: c.retry_timeout, seenAt: now() };
      return;
    } catch (e) { /* nó fora ou sem Patroni */ }
  }
  if (state.patroni && now() - state.patroni.seenAt > 60000) {
    state.patroni = null;
    note(`Patroni não responde há 60 s${cfg.autoPromote ? ': failover do painel religado' : ''}`);
  }
}

(async function loop() {
  for (;;) {
    // Patroni primeiro: o monitor (e o failover do painel) já precisa saber se ele está no comando
    try { await patroniTick(); } catch (e) { console.error('patroni', e.message); }
    try { await monitorTick(); } catch (e) { console.error('monitor', e.message); }
    await sleep(1000);
  }
}());

server.listen(cfg.port, () => {
  console.log(`pg-ha-demo na porta ${cfg.port}; nós: ${nodes.map((n) => `${n.name}=${n.host}:${n.port}`).join(', ')}`);
  console.log(`failover assistido: ${cfg.autoPromote ? 'LIGADO' : 'desligado'}; pausar VM: ${chaosAvailable ? 'disponível' : 'indisponível'}`);
});
