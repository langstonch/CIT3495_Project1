const express = require('express');

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const log = (o) => console.log(JSON.stringify({ svc: 'enterdata', ...o }));

// Returns {category, value} or {error}. Trust boundary: everything from the form.
function validate(b) {
  const category = typeof b.category === 'string' ? b.category.trim() : '';
  if (!/^[A-Za-z0-9 _-]{1,64}$/.test(category)) return { error: 'category: 1-64 letters, digits, space, _ or -' };
  if (typeof b.value !== 'string' || !/^-?\d{1,12}(\.\d{1,6})?$/.test(b.value.trim()))
    return { error: 'value: a plain number' };
  const value = Number(b.value);
  if (Math.abs(value) > 1e9) return { error: 'value: out of range' };
  return { category, value };
}

const page = (body) => `<!doctype html><meta charset=utf-8><title>Enter Data</title><body style="font-family:sans-serif;max-width:30rem;margin:2rem auto">${body}`;
const loginForm = (msg = '') => page(`<h1>Login</h1><p>${esc(msg)}</p><form method=post action=/login>
<p><input name=username placeholder=username maxlength=64 required></p>
<p><input name=password type=password placeholder=password maxlength=72 required></p><button>Login</button></form>`);
const dataForm = (user, msg = '') => page(`<h1>Enter data</h1><p>Signed in as ${esc(user)}</p><p>${esc(msg)}</p><form method=post action=/data>
<p><input name=category placeholder=category maxlength=64 required></p>
<p><input name=value placeholder=value required inputmode=decimal></p><button>Save</button></form>
<form method=post action=/logout><button>Logout</button></form>`);

const cookie = (req) => /(?:^|; )token=([^;]+)/.exec(req.headers.cookie || '')?.[1];

// deps: authLogin(u,p)->token|null, authValidate(token)->user|null, insert(user,category,value)
function createApp({ authLogin, authValidate, insert }) {
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
    const t = cookie(req);
    let user = null;
    try { user = t && (await authValidate(t)); } catch { return res.status(503).send(loginForm('Auth unavailable')); }
    if (!user) return res.status(401).send(loginForm('Please log in'));
    req.user = user;
    next();
  };

  app.get('/health', (_, res) => res.json({ status: 'ok' }));
  app.get('/', (req, res) => res.send(loginForm()));
  app.get('/data', guard, (req, res) => res.send(dataForm(req.user)));

  app.post('/login', async (req, res) => {
    const { username, password } = req.body;
    if (typeof username !== 'string' || typeof password !== 'string') return res.status(400).send(loginForm('Bad request'));
    let token;
    try { token = await authLogin(username, password); } catch { return res.status(503).send(loginForm('Auth unavailable')); }
    if (!token) { log({ event: 'login_fail' }); return res.status(401).send(loginForm('Invalid credentials')); }
    res.set('Set-Cookie', `token=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=3600`);
    res.redirect(303, '/data');
  });

  app.post('/logout', (req, res) => {
    res.set('Set-Cookie', 'token=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
    res.redirect(303, '/');
  });

  app.post('/data', guard, async (req, res) => {
    const v = validate(req.body);
    if (v.error) return res.status(400).send(dataForm(req.user, v.error));
    try { await insert(req.user, v.category, v.value); } catch (e) {
      log({ event: 'insert_error', code: e.code });
      return res.status(503).send(dataForm(req.user, 'Database unavailable, try again'));
    }
    log({ event: 'insert', user: req.user, category: v.category });
    res.send(dataForm(req.user, 'Saved'));
  });
  return app;
}

module.exports = { createApp, validate };
