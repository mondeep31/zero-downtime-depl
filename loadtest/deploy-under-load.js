// Constant traffic that runs WHILE a deploy (or a failure) happens.
// The run fails if a single request does not get a 200.
//
//   k6 run -e BASE_URL=http://127.0.0.1:8080 -e DURATION=45s \
//          -e EXPECT_VERSIONS=v1,v2 loadtest/deploy-under-load.js
//
// Two kinds of traffic at once:
//   steady  RATE requests/second of normal API calls. Arrival rate is fixed,
//           so a stalled server cannot hide errors by slowing the test down.
//   slow    a few clients holding long requests open (SLOW_MS each). These are
//           the requests that get cut off when a shutdown is not graceful.
import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:8080';
const RATE = Number(__ENV.RATE || 100);
const DURATION = __ENV.DURATION || '45s';
const SLOW_VUS = Number(__ENV.SLOW_VUS || 5);
const SLOW_MS = Number(__ENV.SLOW_MS || 3000);
// Versions that MUST each serve at least one request, e.g. "v1,v2" proves
// the traffic really moved from the old release to the new one.
const EXPECT_VERSIONS = (__ENV.EXPECT_VERSIONS || '').split(',').filter(Boolean);

const servedBy = new Counter('served_by_version');

const thresholds = {
  http_req_failed: ['rate==0'], // not one failed request
  checks: ['rate==1'], // every response was a 200
  dropped_iterations: ['count==0'], // the test kept up its request rate
};
for (const version of EXPECT_VERSIONS) {
  thresholds[`served_by_version{version:${version}}`] = ['count>0'];
}

export const options = {
  thresholds,
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      exec: 'steady',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 50,
      maxVUs: 400,
    },
    slow: {
      executor: 'constant-vus',
      exec: 'slow',
      vus: SLOW_VUS,
      duration: DURATION,
    },
  },
};

export function setup() {
  const res = http.post(
    `${BASE_URL}/login`,
    JSON.stringify({ username: 'demo', password: 'demo' }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  if (res.status !== 200) {
    exec.test.abort(`login failed with status ${res.status}: is the stack up?`);
  }
  // One session for the whole run. It lives in Redis, so it must keep working
  // on every replica, old and new.
  return { token: res.json('token') };
}

function record(res) {
  servedBy.add(1, { version: res.headers['X-App-Version'] || 'none' });
  check(res, { 'status is 200': (r) => r.status === 200 });
}

export function steady(data) {
  if (exec.scenario.iterationInTest % 2 === 0) {
    record(http.get(`${BASE_URL}/api/version`));
  } else {
    record(http.get(`${BASE_URL}/api/items`, { headers: { Authorization: `Bearer ${data.token}` } }));
  }
}

export function slow() {
  const res = http.get(`${BASE_URL}/slow?ms=${SLOW_MS}`, { timeout: '60s' });
  record(res);
  // During an outage errors come back instantly. Pause so these few clients
  // do not turn into a tight loop and inflate the error count.
  if (res.status !== 200) sleep(1);
}
