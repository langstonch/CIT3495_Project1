const test = require('node:test');
const assert = require('node:assert');
const { createApp } = require('./app');

const stats = [{
  category: '<script>alert(1)</script>',
  min: 10,
  max: 30,
  avg: 20,
  count: 3,
  updated_at: '2026-01-01T00:00:00Z',
}];
const app = createApp({
  authLogin: async (u, p) => (u === 'alice' && p === 'pw' ? 'good.token' : null),
  authValidate: async (t) => (t === 'good.token' ? 'alice' : null),
  listStats: async () => stats,
});
let base, srv;
test.before(() => { srv = app.listen(0); base = `http://127.0.0.1:${srv.address().port}`; });
test.after(() => srv.close());

const post = (path, body) => fetch(base + path, {
  method: 'POST', redirect: 'manual',
  headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams(body),
});

test('health is open', async () => {
  const r = await fetch(base + '/health');
  assert.strictEqual(r.status, 200);
  assert.deepStrictEqual(await r.json(), { status: 'ok' });
});

test('results reject a missing or bad token and accept a good one', async () => {
  const missing = await fetch(base + '/results');
  assert.strictEqual(missing.status, 401);
  assert.doesNotMatch(await missing.text(), /alert\(1\)/);

  const badBearer = await fetch(base + '/results', { headers: { authorization: 'Bearer nope' } });
  assert.strictEqual(badBearer.status, 401);
  const badCookie = await fetch(base + '/results', { headers: { cookie: 'token=forged' } });
  assert.strictEqual(badCookie.status, 401);

  const ok = await fetch(base + '/results', { headers: { authorization: 'Bearer good.token' } });
  assert.strictEqual(ok.status, 200);
  const html = await ok.text();
  assert.match(html, /&#60;script&#62;alert\(1\)&#60;\/script&#62;/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, />10</);
  assert.match(html, />30</);
  assert.match(html, />20</);
  assert.strictEqual(ok.headers.get('x-content-type-options'), 'nosniff');
  assert.match(ok.headers.get('content-security-policy'), /default-src 'none'/);

  const cookieOk = await fetch(base + '/results', { headers: { cookie: 'token=good.token' } });
  assert.strictEqual(cookieOk.status, 200);
});

test('login failure and success', async () => {
  assert.strictEqual((await post('/login', { username: 'alice', password: 'bad' })).status, 401);
  const r = await post('/login', { username: 'alice', password: 'pw' });
  assert.strictEqual(r.status, 303);
  assert.match(r.headers.get('set-cookie'), /HttpOnly/);
  assert.match(r.headers.get('set-cookie'), /SameSite=Strict/);
  assert.match(r.headers.get('location'), /\/results$/);
});

test('unsafe token characters are not forwarded', async () => {
  let calls = 0;
  const local = createApp({
    authLogin: async () => 'good\r\nSet-Cookie: evil',
    authValidate: async () => { calls += 1; return 'alice'; },
    listStats: async () => [],
  });
  const localSrv = local.listen(0);
  const url = `http://127.0.0.1:${localSrv.address().port}`;
  try {
    const login = await fetch(url + '/login', {
      method: 'POST', redirect: 'manual',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ username: 'a', password: 'b' }),
    });
    assert.strictEqual(login.status, 503);
    assert.doesNotMatch(login.headers.get('set-cookie') || '', /evil/);
    const page = await fetch(url + '/results', { headers: { cookie: 'token=aaa*bbb' } });
    assert.strictEqual(page.status, 401);
    assert.strictEqual(calls, 0);
  } finally {
    localSrv.close();
  }
});

test('empty stats are not an error', async () => {
  const empty = createApp({
    authLogin: async () => null,
    authValidate: async () => 'alice',
    listStats: async () => [],
  });
  const emptySrv = empty.listen(0);
  try {
    const r = await fetch(`http://127.0.0.1:${emptySrv.address().port}/results`, {
      headers: { authorization: 'Bearer anything' },
    });
    assert.strictEqual(r.status, 200);
    assert.match(await r.text(), /No results yet/);
  } finally {
    emptySrv.close();
  }
});

test('mongo down returns 503 and stays up', async () => {
  const lines = [];
  const orig = console.log;
  console.log = (line) => lines.push(String(line));
  const broken = createApp({
    authLogin: async () => null,
    authValidate: async (t) => (t === 'good.token' ? 'alice' : null),
    listStats: async () => { throw Object.assign(new Error('mongodb://user:secret@mongo:27017/collector'), { name: 'MongoServerSelectionError' }); },
  });
  const down = broken.listen(0);
  const url = `http://127.0.0.1:${down.address().port}`;
  try {
    const r = await fetch(url + '/results', { headers: { authorization: 'Bearer good.token' } });
    assert.strictEqual(r.status, 503);
    const html = await r.text();
    assert.match(html, /unavailable/i);
    assert.doesNotMatch(html, /secret/);
    assert.strictEqual((await fetch(url + '/health')).status, 200);
    assert.strictEqual((await fetch(url + '/results', { headers: { cookie: 'token=good.token' } })).status, 503);
    assert.ok(lines.some((l) => l.includes('results_error')));
    assert.ok(lines.every((l) => !l.includes('secret') && !l.includes('mongodb://')));
  } finally {
    console.log = orig;
    down.close();
  }
});
