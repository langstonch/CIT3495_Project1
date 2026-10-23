const test = require('node:test');
const assert = require('node:assert');
const { createApp, validate } = require('./app');

const rows = [];
const app = createApp({
  authLogin: async (u, p) => (u === 'alice' && p === 'pw' ? 'good' : null),
  authValidate: async (t) => (t === 'good' ? 'alice' : null),
  insert: async (...r) => rows.push(r),
});
let base, srv;
test.before(() => { srv = app.listen(0); base = `http://127.0.0.1:${srv.address().port}`; });
test.after(() => srv.close());

const post = (path, body, cookie) => fetch(base + path, {
  method: 'POST', redirect: 'manual',
  headers: { 'content-type': 'application/x-www-form-urlencoded', ...(cookie && { cookie }) },
  body: new URLSearchParams(body),
});

test('validate accepts good, rejects bad', () => {
  assert.deepStrictEqual(validate({ category: ' temp ', value: '-3.5' }), { category: 'temp', value: -3.5 });
  for (const b of [{ category: '', value: '1' }, { category: "a'; DROP", value: '1' }, { category: 'a', value: 'abc' },
    { category: 'a', value: '1e9999' }, { category: 'a', value: 'NaN' }, { category: 'a', value: '9999999999999' },
    { category: ['a'], value: '1' }, { category: 'a' }]) assert.ok(validate(b).error, JSON.stringify(b));
});

test('data page needs login', async () => {
  assert.strictEqual((await fetch(base + '/data')).status, 401);
  assert.strictEqual((await post('/data', { category: 'a', value: '1' })).status, 401);
  assert.strictEqual((await post('/data', { category: 'a', value: '1' }, 'token=forged')).status, 401);
  assert.strictEqual(rows.length, 0);
});

test('login then insert', async () => {
  assert.strictEqual((await post('/login', { username: 'alice', password: 'bad' })).status, 401);
  const r = await post('/login', { username: 'alice', password: 'pw' });
  assert.strictEqual(r.status, 303);
  assert.match(r.headers.get('set-cookie'), /HttpOnly/);
  assert.strictEqual((await post('/data', { category: 'temp', value: '21.5' }, 'token=good')).status, 200);
  assert.deepStrictEqual(rows[0], ['alice', 'temp', 21.5]);
  assert.strictEqual((await post('/data', { category: 'temp', value: 'x' }, 'token=good')).status, 400);
  assert.strictEqual(rows.length, 1);
});
