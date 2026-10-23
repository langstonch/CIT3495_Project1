// Repeatable load against the published web apps.
// Install k6, start the stack, then from the repo root:
//   k6 run tests/load/k6_test.js
// Optional: k6 run -e VUS=10 -e DURATION=30s -e ADMIN_USER=admin -e ADMIN_PASSWORD=change_this_password tests/load/k6_test.js
// In a second terminal: pwsh scripts/sample_stats.ps1 -Seconds 40
import http from 'k6/http';
import { check, group, sleep } from 'k6';

const ENTER = __ENV.ENTERDATA_URL || 'http://localhost:3001';
const SHOW = __ENV.SHOWRESULTS_URL || 'http://localhost:3002';
const USER = __ENV.ADMIN_USER || 'admin';
const PASS = __ENV.ADMIN_PASSWORD || 'change_this_password';

export const options = {
  vus: Number(__ENV.VUS || 5),
  duration: __ENV.DURATION || '30s',
};

export function setup() {
  const health = http.get(`${ENTER}/health`, { timeout: '5s' });
  if (health.status !== 200) {
    throw new Error(`enterdata /health returned ${health.status}. Start the stack before this test.`);
  }
}

export default function () {
  group('enterdata login', () => {
    const res = http.post(`${ENTER}/login`, { username: USER, password: PASS }, {
      redirects: 0,
      tags: { name: 'enterdata_login' },
    });
    check(res, { 'enterdata login is 303': (r) => r.status === 303 });
  });

  group('enterdata insert', () => {
    const value = String(Math.floor(Math.random() * 1000));
    const res = http.post(`${ENTER}/data`, { category: 'loadtest', value }, {
      redirects: 0,
      tags: { name: 'enterdata_insert' },
    });
    check(res, {
      'insert is 200': (r) => r.status === 200,
      'insert saved': (r) => String(r.body).indexOf('Saved') !== -1,
    });
  });

  group('showresults login', () => {
    const res = http.post(`${SHOW}/login`, { username: USER, password: PASS }, {
      redirects: 0,
      tags: { name: 'showresults_login' },
    });
    check(res, { 'showresults login is 303': (r) => r.status === 303 });
  });

  group('showresults read', () => {
    const res = http.get(`${SHOW}/results`, {
      tags: { name: 'showresults_results' },
    });
    check(res, {
      'results is 200': (r) => r.status === 200,
      'results is the signed-in page': (r) => String(r.body).indexOf('Please log in') === -1,
    });
  });

  sleep(Number(__ENV.SLEEP || 0.2));
}
