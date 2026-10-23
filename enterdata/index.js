const mysql = require('mysql2/promise');
const { createApp } = require('./app');

const AUTH = process.env.AUTH_URL;
const pool = mysql.createPool({
  host: process.env.MYSQL_HOST, user: process.env.MYSQL_USER, password: process.env.MYSQL_PASSWORD,
  database: process.env.MYSQL_DB, connectionLimit: 10, connectTimeout: 3000,
});

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
    const r = await fetch(`${AUTH}/validate`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(3000) });
    if (r.status === 401) return null;
    if (!r.ok) throw new Error('auth');
    return (await r.json()).user;
  },
  insert: (user, category, value) =>
    pool.execute('INSERT INTO measurements (user, category, value) VALUES (?,?,?)', [user, category, value]),
});

app.listen(3001, () => console.log(JSON.stringify({ svc: 'enterdata', event: 'listening', port: 3001 })));
