'use strict';

// Estoque de peças — app de demonstração.
// Tudo o que aparece na tela vem do MongoDB: um refresh, um restart de pod ou a
// migração de uma VM do replica set não apagam nada.

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { MongoClient, ObjectId } = require('mongodb');

const PORT = Number(process.env.PORT || 8080);
const URI = process.env.MONGODB_URI || '';
const DB_NAME = process.env.MONGODB_DB || undefined; // vazio = o banco do próprio URI
const COLECAO = process.env.MONGODB_COLECAO || 'estoque_demo';

const ARCH = { x64: 'x86_64', arm64: 'aarch64' }[os.arch()] || os.arch();
const INFO = {
  pod: process.env.HOSTNAME || os.hostname(),
  no: process.env.NODE_NAME || '-',
  arch: ARCH,
  versao: process.env.APP_VERSAO || 'v1',
  cor: process.env.APP_COR || '#0f62fe',
};

// Dados fictícios. Entram só quando a coleção está vazia.
const EXEMPLO = [
  { sku: 'MEC-6204', nome: 'Rolamento 6204-2RS', categoria: 'Mecânica', quantidade: 120, preco: 18.9 },
  { sku: 'MEC-HTD8', nome: 'Correia dentada HTD-8M', categoria: 'Mecânica', quantidade: 45, preco: 64.5 },
  { sku: 'ELE-M12', nome: 'Sensor indutivo M12', categoria: 'Elétrica', quantidade: 60, preco: 89.0 },
  { sku: 'ELE-C25', nome: 'Contator tripolar 25 A', categoria: 'Elétrica', quantidade: 32, preco: 142.3 },
  { sku: 'HID-FO10', nome: 'Filtro de óleo hidráulico', categoria: 'Hidráulica', quantidade: 18, preco: 57.8 },
  { sku: 'HID-V12', nome: 'Válvula solenoide 1/2"', categoria: 'Hidráulica', quantidade: 27, preco: 210.0 },
  { sku: 'EPI-LN100', nome: 'Luva nitrílica (caixa com 100)', categoria: 'EPI', quantidade: 240, preco: 39.9 },
  { sku: 'EPI-OC01', nome: 'Óculos de proteção incolor', categoria: 'EPI', quantidade: 85, preco: 12.4 },
];

const PAGINA = fs.readFileSync(path.join(__dirname, 'public', 'index.html'));

let cliente = null;
let colecao = null;
let erroMongo = URI ? 'conectando ao MongoDB…' : 'MONGODB_URI não configurado (Secret estoque-mongodb)';

function comCarimbo(doc) {
  return { ...doc, criadoEm: new Date(), atualizadoEm: new Date(), atualizadoPor: INFO.pod };
}

async function semear(forcar) {
  if (forcar) await colecao.deleteMany({});
  if ((await colecao.estimatedDocumentCount()) > 0) return;
  try {
    // Dois pods podem subir juntos: o índice único em sku impede duplicar.
    await colecao.insertMany(EXEMPLO.map(comCarimbo), { ordered: false });
  } catch (e) {
    if (e.code !== 11000 && !(e.writeErrors || []).every((w) => w.code === 11000)) throw e;
  }
}

async function conectar() {
  if (!URI) return;
  try {
    cliente = new MongoClient(URI, {
      serverSelectionTimeoutMS: 5000,
      retryWrites: true,
      writeConcern: { w: 'majority' },
      readPreference: 'primary',
      appName: 'estoque-demo',
    });
    await cliente.connect();
    colecao = cliente.db(DB_NAME).collection(COLECAO);
    await colecao.createIndex({ sku: 1 }, { unique: true });
    await semear(false);
    erroMongo = null;
    console.log(`MongoDB conectado — banco ${cliente.db(DB_NAME).databaseName}, coleção ${COLECAO}`);
  } catch (e) {
    erroMongo = `sem conexão com o MongoDB: ${e.message}`;
    console.error(erroMongo);
    if (cliente) await cliente.close().catch(() => {});
    cliente = null;
    colecao = null;
    setTimeout(conectar, 5000);
  }
}

async function estadoMongo() {
  const h = await cliente.db('admin').command({ hello: 1 });
  return {
    replicaSet: h.setName || null,
    primario: h.primary || h.me || null,
    membros: h.hosts || [],
    banco: cliente.db(DB_NAME).databaseName,
    colecao: COLECAO,
  };
}

function lerCorpo(req) {
  return new Promise((resolve, reject) => {
    let dados = '';
    const ruim = (msg) => Object.assign(new Error(msg), { status: 400 });
    req.on('data', (c) => {
      dados += c;
      if (dados.length > 10_000) reject(ruim('corpo grande demais'));
    });
    req.on('end', () => {
      try { resolve(dados ? JSON.parse(dados) : {}); } catch { reject(ruim('JSON inválido')); }
    });
    req.on('error', reject);
  });
}

function responder(res, status, corpo) {
  const json = JSON.stringify(corpo);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(json);
}

function texto(v, max) {
  return String(v ?? '').trim().slice(0, max);
}

function idValido(id) {
  return ObjectId.isValid(id) ? new ObjectId(id) : null;
}

async function tratarApi(req, res, url) {
  if (!colecao) return responder(res, 503, { erro: erroMongo, info: INFO });

  if (req.method === 'GET' && url.pathname === '/api/estado') {
    const inicio = Date.now();
    const [mongo, itens] = await Promise.all([
      estadoMongo(),
      colecao.find({}).sort({ categoria: 1, nome: 1 }).toArray(),
    ]);
    return responder(res, 200, { info: INFO, mongo, itens, lidoEm: new Date(), ms: Date.now() - inicio });
  }

  if (req.method === 'POST' && url.pathname === '/api/itens') {
    const b = await lerCorpo(req);
    const item = {
      sku: texto(b.sku, 20).toUpperCase(),
      nome: texto(b.nome, 80),
      categoria: texto(b.categoria, 30) || 'Geral',
      quantidade: Math.max(0, Math.trunc(Number(b.quantidade) || 0)),
      preco: Math.max(0, Math.round((Number(b.preco) || 0) * 100) / 100),
    };
    if (!item.sku || !item.nome) return responder(res, 400, { erro: 'SKU e nome são obrigatórios' });
    try {
      await colecao.insertOne(comCarimbo(item));
    } catch (e) {
      if (e.code === 11000) return responder(res, 409, { erro: `já existe um item com o SKU ${item.sku}` });
      throw e;
    }
    return responder(res, 201, { ok: true });
  }

  const m = url.pathname.match(/^\/api\/itens\/([0-9a-f]{24})$/);
  if (m) {
    const _id = idValido(m[1]);
    if (req.method === 'PATCH') {
      const b = await lerCorpo(req);
      const carimbo = { atualizadoEm: new Date(), atualizadoPor: INFO.pod };
      let r;
      if (b.quantidade !== undefined) {
        const q = Math.max(0, Math.trunc(Number(b.quantidade) || 0));
        r = await colecao.findOneAndUpdate({ _id }, { $set: { quantidade: q, ...carimbo } }, { returnDocument: 'after' });
      } else {
        const delta = Math.trunc(Number(b.delta) || 0);
        const filtro = delta < 0 ? { _id, quantidade: { $gte: -delta } } : { _id };
        r = await colecao.findOneAndUpdate(filtro, { $inc: { quantidade: delta }, $set: carimbo }, { returnDocument: 'after' });
      }
      if (!r) return responder(res, 409, { erro: 'item não encontrado ou quantidade ficaria negativa' });
      return responder(res, 200, { ok: true, item: r });
    }
    if (req.method === 'DELETE') {
      const r = await colecao.deleteOne({ _id });
      return responder(res, r.deletedCount ? 200 : 404, { ok: !!r.deletedCount });
    }
  }

  if (req.method === 'POST' && url.pathname === '/api/restaurar') {
    await semear(true);
    return responder(res, 200, { ok: true });
  }

  return responder(res, 404, { erro: 'rota não encontrada' });
}

const servidor = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      return res.end('ok');
    }
    if (url.pathname.startsWith('/api/')) return await tratarApi(req, res, url);
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end(PAGINA);
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('não encontrado');
  } catch (e) {
    console.error(`${req.method} ${url.pathname}: ${e.message}`);
    responder(res, e.status || 500, { erro: e.message });
  }
});

servidor.listen(PORT, () => {
  console.log(`estoque-demo ${INFO.versao} em :${PORT} — pod ${INFO.pod}, nó ${INFO.no}, ${INFO.arch}`);
  conectar();
});

for (const sinal of ['SIGTERM', 'SIGINT']) {
  process.on(sinal, () => {
    servidor.close();
    Promise.resolve(cliente && cliente.close()).finally(() => process.exit(0));
  });
}
