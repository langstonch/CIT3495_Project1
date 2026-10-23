const { MongoClient } = require('mongodb');
const { createApp } = require('./app');

const AUTH = process.env.AUTH_URL;
const MONGO_URI = process.env.MONGO_URI;
if (!AUTH || !MONGO_URI) {
  console.log(JSON.stringify({
    svc: 'showresults',
    event: 'config_error',
    missing: [!AUTH && 'AUTH_URL', !MONGO_URI && 'MONGO_URI'].filter(Boolean),
  }));
  process.exit(1);
}

let client;

function dbName(uri) {
  const path = uri.split('?')[0].replace(/\/+$/, '').split('/').slice(3).join('/');
  try { return decodeURIComponent(path) || 'collector'; } catch { return 'collector'; }
}

async function listStats() {
  if (!client) {
    client = new MongoClient(MONGO_URI, { serverSelectionTimeoutMS: 3000, socketTimeoutMS: 8000 });
  }
  try {
    await client.connect();
    return await client.db(dbName(MONGO_URI)).collection('stats')
      .find({}, { projection: { _id: 0 } })
      .sort({ category: 1 })
      .toArray();
  } catch (err) {
    const failed = client;
    client = null;
    try { await failed.close(); } catch { /* the server is already gone */ }
    throw err;
  }
}

const app = createApp({
  authLogin: async (username, password) => {
    const r = await fetch(`${AUTH}/login`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ username, password }), signal: AbortSignal.timeout(3000),
    });
    if (r.status === 401 || r.status === 400) return null;
    if (!r.ok) throw new Error('auth');
    return (await r.json()).token;
  },
  authValidate: async (token) => {
    const r = await fetch(`${AUTH}/validate`, {
      headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(3000),
    });
    if (r.status === 401) return null;
    if (!r.ok) throw new Error('auth');
    return (await r.json()).user;
  },
  listStats,
});

app.listen(3002, () => console.log(JSON.stringify({ svc: 'showresults', event: 'listening', port: 3002 })));
