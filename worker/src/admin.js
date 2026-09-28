/**
 * Who may pull the /admin/* triggers.
 *
 * They used to be open, on the grounds that each one only re-reads the owner's
 * own sources and republishes — the worst a stranger could do was make it
 * happen early. But "early" had no floor: every POST is a Sheets, Calendar or
 * Gmail round-trip, so a loop of anonymous POSTs could spend the Google quota
 * the cron needs and leave the wall stale. Two kinds of caller use them, and
 * they get different answers:
 *
 *   * The operator, from a laptop — curl, prune-decorative.mjs. Presents the
 *     ADMIN_TOKEN secret as a bearer token and is never refused or rate-limited.
 *
 *   * The board's refresh button, which POSTs sync-calendar, sync-directory and
 *     sync-rota so that someone who has just booked leave on their phone sees it
 *     on the next tap. The app holds no credential — DEVICE_TOKEN belongs to the
 *     updater script, not the Flutter process — so those three stay open to
 *     anonymous callers, but get at most one real run per COOLDOWN_MS each,
 *     across every caller. Inside the window the answer is 429, and the device
 *     pulls the latest artifact anyway, as it does after any failed trigger.
 *
 * Everything else under /admin/ needs the token outright.
 */
import { bearerToken, tokenMatches } from './serve.js';

/** How often an anonymous caller may run each board trigger. */
export const COOLDOWN_MS = 60_000;

/**
 * Where the last anonymous run of each trigger is stamped. Not in serve.js's
 * ALLOWED set, so it is never served back out.
 */
export const stampKey = (name) => `admin/last-run/${name}`;

// The same stamps, remembered per isolate. A flood from one client lands on one
// or a few isolates, and this turns it away without so much as an R2 read; the
// R2 stamp is what makes the limit hold across isolates.
const recent = new Map();

/** When [name] last ran for an anonymous caller, per R2, or 0 if never. */
async function lastRun(env, name) {
  try {
    const object = await env.DASH.get(stampKey(name));
    return object ? Number(await object.text()) || 0 : 0;
  } catch (err) {
    // No stamp to go on. Allow the run: if R2 is down, the sync's own write
    // fails too, so there is nothing for a flood to amplify.
    console.log(`admin: reading the ${name} stamp failed (${err})`);
    return 0;
  }
}

/**
 * A Response refusing the call, or null to let it through.
 *
 * [board] marks the three triggers the device's refresh button pulls. [now] is
 * injectable so the tests can walk the clock through a cooldown.
 */
export async function refuseAdmin(request, env, name, { board = false, now = Date.now() } = {}) {
  const presented = bearerToken(request);
  const expected = env.ADMIN_TOKEN;

  if (presented) {
    // A token that is presented and wrong is refused even on a board trigger.
    // Quietly demoting it to the anonymous path would hide a stale or mistyped
    // ADMIN_TOKEN behind the occasional 429.
    if (expected && tokenMatches(presented, expected)) return null;
    return unauthorised(expected);
  }
  if (!board) return unauthorised(expected);

  // An anonymous caller on a board trigger: at most one run per window. The
  // isolate's own memory answers first, and only past that is R2 asked.
  const memo = recent.get(name) ?? 0;
  const last = now - memo < COOLDOWN_MS ? memo : Math.max(memo, await lastRun(env, name));
  const wait = last + COOLDOWN_MS - now;
  if (wait > 0) {
    recent.set(name, last);
    const seconds = Math.ceil(wait / 1000);
    return new Response(
      JSON.stringify({ ok: false, error: 'cooldown', retryAfter: seconds }),
      { status: 429, headers: { 'content-type': 'application/json', 'retry-after': String(seconds) } },
    );
  }

  // Claim the slot before running, so a concurrent caller sees it. Two callers
  // that both read R2 before either wrote will both run — harmless, and bounded
  // by the window.
  recent.set(name, now);
  try {
    await env.DASH.put(stampKey(name), String(now));
  } catch (err) {
    console.log(`admin: stamping ${name} failed (${err})`);
  }
  return null;
}

function unauthorised(expected) {
  if (!expected) {
    // Fail CLOSED, as the bundle gate does: an unset secret must not quietly
    // reopen the triggers. Fix: `wrangler secret put ADMIN_TOKEN`.
    console.log('admin refused: ADMIN_TOKEN is not configured on this Worker');
    return new Response('Admin triggers are not configured', { status: 503 });
  }
  // 401, not the bundle gate's 404: these paths are documented in the repo, so
  // there is nothing to hide, and an operator who forgot the header should be
  // told so rather than left wondering whether the route exists.
  return new Response('Bearer token required', {
    status: 401,
    headers: { 'www-authenticate': 'Bearer' },
  });
}
