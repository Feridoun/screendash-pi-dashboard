import test from 'node:test';
import assert from 'node:assert/strict';

import { COOLDOWN_MS, refuseAdmin, stampKey } from '../src/admin.js';

/** Just enough of an R2 binding: get → { text() } or null, and put. */
function fakeR2(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async get(key) {
      return store.has(key) ? { text: async () => store.get(key) } : null;
    },
    async put(key, value) {
      store.set(key, value);
    },
  };
}

const TOKEN = 'a'.repeat(64);

const post = (token) =>
  new Request('https://example.test/admin/x', {
    method: 'POST',
    headers: token === undefined ? {} : { authorization: `Bearer ${token}` },
  });

// admin.js remembers stamps per isolate, which here means per test file. Each
// test uses its own trigger name so none sees another's cooldown.
let counter = 0;
const fresh = () => `trigger-${++counter}`;

test('the admin token runs any trigger, and a board one without a cooldown', async () => {
  const env = { ADMIN_TOKEN: TOKEN, DASH: fakeR2() };
  const name = fresh();
  assert.equal(await refuseAdmin(post(TOKEN), env, fresh()), null);
  // Twice in the same instant: the operator is never rate-limited.
  assert.equal(await refuseAdmin(post(TOKEN), env, name, { board: true, now: 1_000 }), null);
  assert.equal(await refuseAdmin(post(TOKEN), env, name, { board: true, now: 1_000 }), null);
  // And an authorised run leaves no stamp to hold anonymous callers back.
  assert.equal(env.DASH.store.has(stampKey(name)), false);
});

test('a wrong token is refused, even on a board trigger', async () => {
  const env = { ADMIN_TOKEN: TOKEN, DASH: fakeR2() };
  const refusal = await refuseAdmin(post('b'.repeat(64)), env, fresh(), { board: true });
  assert.equal(refusal.status, 401);
  assert.equal(refusal.headers.get('www-authenticate'), 'Bearer');
});

test('no token on an operator-only trigger is 401', async () => {
  const env = { ADMIN_TOKEN: TOKEN, DASH: fakeR2() };
  assert.equal((await refuseAdmin(post(), env, fresh())).status, 401);
});

test('an unset ADMIN_TOKEN fails closed, but leaves the board its triggers', async () => {
  const env = { DASH: fakeR2() };
  assert.equal((await refuseAdmin(post(), env, fresh())).status, 503);
  // Presenting some token doesn't talk its way past an unconfigured secret.
  assert.equal((await refuseAdmin(post(TOKEN), env, fresh())).status, 503);
  // The refresh button keeps working meanwhile.
  assert.equal(await refuseAdmin(post(), env, fresh(), { board: true }), null);
});

test('an anonymous board trigger runs once per window, then 429 until it passes', async () => {
  const env = { ADMIN_TOKEN: TOKEN, DASH: fakeR2() };
  const name = fresh();
  const t0 = 5_000_000;

  assert.equal(await refuseAdmin(post(), env, name, { board: true, now: t0 }), null);
  assert.equal(env.DASH.store.get(stampKey(name)), String(t0));

  const early = await refuseAdmin(post(), env, name, { board: true, now: t0 + 10_000 });
  assert.equal(early.status, 429);
  assert.equal(early.headers.get('retry-after'), String((COOLDOWN_MS - 10_000) / 1000));
  assert.deepEqual(await early.json(), {
    ok: false,
    error: 'cooldown',
    retryAfter: (COOLDOWN_MS - 10_000) / 1000,
  });

  assert.equal(await refuseAdmin(post(), env, name, { board: true, now: t0 + COOLDOWN_MS }), null);
});

test('a run stamped by another isolate holds this one back too', async () => {
  // Nothing in this isolate's memory, but R2 says it ran 20s ago elsewhere.
  const name = fresh();
  const now = 9_000_000;
  const env = { ADMIN_TOKEN: TOKEN, DASH: fakeR2({ [stampKey(name)]: String(now - 20_000) }) };
  const refusal = await refuseAdmin(post(), env, name, { board: true, now });
  assert.equal(refusal.status, 429);
  assert.equal(refusal.headers.get('retry-after'), String((COOLDOWN_MS - 20_000) / 1000));
});

test('once the isolate knows of a run, it answers without asking R2', async () => {
  const name = fresh();
  const now = 12_000_000;
  let reads = 0;
  const dash = fakeR2();
  const counting = { ...dash, get: (key) => (reads++, dash.get(key)), put: dash.put };
  const env = { ADMIN_TOKEN: TOKEN, DASH: counting };

  assert.equal(await refuseAdmin(post(), env, name, { board: true, now }), null);
  const before = reads;
  for (let i = 1; i <= 5; i++) {
    const refusal = await refuseAdmin(post(), env, name, { board: true, now: now + i * 1000 });
    assert.equal(refusal.status, 429);
  }
  assert.equal(reads, before, 'the flood was answered from memory');
});

test('an R2 that cannot be read lets the run through rather than wedging it', async () => {
  const env = {
    ADMIN_TOKEN: TOKEN,
    DASH: {
      get: async () => {
        throw new Error('R2 down');
      },
      put: async () => {
        throw new Error('R2 down');
      },
    },
  };
  assert.equal(await refuseAdmin(post(), env, fresh(), { board: true }), null);
});
