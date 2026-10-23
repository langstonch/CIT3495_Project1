const express = require('express');

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const log = (o) => console.log(JSON.stringify({ svc: 'showresults', ...o }));

const page = (body) => `<!doctype html><meta charset=utf-8><title>Show Results</title>
<style>body{font-family:sans-serif;max-width:42rem;margin:2rem auto}table{border-collapse:collapse;width:100%}td,th{border:1px solid #999;padding:.35rem .5rem;text-align:left}</style>
<body>${body}`;
const loginForm = (msg = '') => page(`<h1>Login</h1><p>${esc(msg)}</p><form method=post action=/login>
<p><input name=username placeholder=username maxlength=64 required></p>
<p><input name=password type=password placeholder=password maxlength=72 required></p><button>Login</button></form>`);

const cell = (v) => esc(v);
function resultsPage(user, stats) {
  let table = '<p>Results are temporarily unavailable. Try again shortly.</p>';
  if (stats) {
    table = stats.length
      ? `<table><tr><th>Category</th><th>Min</th><th>Max</th><th>Average</th><th>Count</th><th>Updated</th></tr>${
        stats.map((s) => `<tr><td>${cell(s.category)}</td><td>${cell(s.min)}</td><td>${cell(s.max)}</td><td>${cell(s.avg)}</td><td>${cell(s.count)}</td><td>${cell(s.updated_at)}</td></tr>`).join('')
      }</table>`
      : '<p>No results yet. Add measurements in Enter Data, then wait for the analytics job.</p>';
  }
  return page(`<h1>Results</h1><p>Signed in as ${esc(user)}</p>${table}
<form method=post action=/logout><button>Logout</button></form>`);
}

const cookie = (req) => /(?:^|; )token=([^;]+)/.exec(req.headers.cookie || '')?.[1];
const tokenOf = (req) => {
  const bearer = /^Bearer\s+(\S+)/i.exec(req.headers.authorization || '');
  return (bearer && bearer[1]) || cookie(req) || '';
};
// A JWT is base64url segments. Anything else can break Set-Cookie or the validate request.
const safeToken = (t) => /^[A-Za-z0-9._-]+$/.test(t);

// deps: authLogin(u,p)->token|null, authValidate(token)->user|null, listStats()->docs
function createApp({ authLogin, authValidate, listStats }) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.urlencoded({ extended: false, limit: '4kb' }));
  app.use((_, res, next) => {
    res.set({
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
    });
    next();
  });

  const guard = async (req, res, next) => {
    const t = tokenOf(req);
    if (!safeToken(t)) return res.status(401).send(loginForm('Please log in'));
    let user = null;
    try { user = await authValidate(t); } catch { return res.status(503).send(loginForm('Auth unavailable')); }
    if (!user) return res.status(401).send(loginForm('Please log in'));
    req.user = user;
    next();
  };

  app.get('/health', (_, res) => res.json({ status: 'ok' }));
  app.get('/', (req, res) => res.send(loginForm()));

  app.post('/login', async (req, res) => {
    const { username, password } = req.body;
    if (typeof username !== 'string' || typeof password !== 'string') return res.status(400).send(loginForm('Bad request'));
    let token;
    try { token = await authLogin(username, password); } catch { return res.status(503).send(loginForm('Auth unavailable')); }
    if (!token) { log({ event: 'login_fail' }); return res.status(401).send(loginForm('Invalid credentials')); }
    if (!safeToken(token)) { log({ event: 'login_bad_token' }); return res.status(503).send(loginForm('Auth unavailable')); }
    log({ event: 'login_ok' });
    res.set('Set-Cookie', `token=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=3600`);
    res.redirect(303, '/results');
  });

  app.post('/logout', (req, res) => {
    res.set('Set-Cookie', 'token=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
    res.redirect(303, '/');
  });

  app.get('/results', guard, async (req, res) => {
    try {
      const stats = await listStats();
      log({ event: 'results', user: req.user, count: stats.length });
      res.send(resultsPage(req.user, stats));
    } catch (e) {
      log({ event: 'results_error', name: e.name || 'Error' });
      res.status(503).send(resultsPage(req.user, null));
    }
  });
  return app;
}

module.exports = { createApp, esc };
