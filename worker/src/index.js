/**
 * screendash — Cloudflare Worker backend.
 *
 * Two entry points:
 *   scheduled()  cron → poll Gmail for photos/notices/pins, and sync Google Calendar
 *   fetch()      HTTP → serve the artifacts the Pi polls, and the /admin/*
 *                triggers (who may pull which: see admin.js)
 *
 * There is deliberately no inbound-email handler: mail is *pulled* from Gmail
 * rather than pushed by Cloudflare Email Routing, which means this whole backend
 * runs without owning a domain. The Pi can poll the free *.workers.dev URL.
 *
 * All secrets live as Worker secrets and never reach the device.
 */
import { pollGmail } from './gmail.js';
import { syncCalendar } from './calendar.js';
import { syncDirectory } from './directory.js';
import { syncRota } from './rota.js';
import { syncWeather } from './weather.js';
import { serveArtifact } from './serve.js';
import { pruneAndRebuildManifest } from './photos.js';
import { refuseAdmin } from './admin.js';

/**
 * The manual triggers under /admin/: force a job now rather than waiting for
 * its cron. `board: true` marks the three the device's refresh button pulls,
 * which admin.js lets anonymous callers run once a minute; the rest need the
 * ADMIN_TOKEN bearer secret. Each `run` returns the fields that go beside
 * `ok: true` in the response.
 */
const TRIGGERS = {
  'sync-calendar': { board: true, run: async (env) => ({ events: await syncCalendar(env) }) },
  'sync-directory': { board: true, run: (env) => syncDirectory(env) },
  'sync-rota': { board: true, run: (env) => syncRota(env) },
  'sync-weather': { run: async (env) => ({ days: await syncWeather(env) }) },
  'poll-gmail': { run: async (env) => ({ handled: await pollGmail(env) }) },
  // Republish manifest.json from whatever is in R2 right now. Needed after
  // editing the bucket by hand — the device only ever reads the manifest, so
  // an object deleted underneath it stays on the wall until this runs.
  // Idempotent, and destroys nothing: the MAX_PHOTOS prune it runs archives
  // to `removed/` rather than deleting.
  'rebuild-manifest': {
    run: async (env) => {
      const m = await pruneAndRebuildManifest(env);
      return { hash: m.hash, photos: m.photos.length };
    },
  },
};

export default {
  /**
   * Cron. Two schedules are registered in wrangler.toml:
   *   every 5 min  → Gmail intake (photos + notices + pins)
   *   every 15 min → Calendar sync + directory sync + rota sync
   * Anything unrecognised runs both, so a schedule change can't silently
   * disable intake.
   *
   * The directory, the rota and the weather ride the 15-minute tick rather
   * than owning a schedule: each is one or two cheap API calls, and none
   * changes fast — the directory a few times a year, the rota when someone
   * books leave, the forecast hourly at best.
   */
  async scheduled(event, env, ctx) {
    const cron = event.cron || '';
    const doGmail = cron.startsWith('*/5') || !cron.startsWith('*/15');
    const doCalendar = cron.startsWith('*/15') || !cron.startsWith('*/5');

    ctx.waitUntil(
      (async () => {
        if (doGmail) {
          try {
            const n = await pollGmail(env);
            if (n) console.log(`gmail: handled ${n} message(s)`);
          } catch (err) {
            console.log(`gmail poll failed: ${err}`);
          }
        }
        if (doCalendar) {
          try {
            await syncCalendar(env);
          } catch (err) {
            console.log(`calendar sync failed: ${err}`);
          }
          // Separate try/catch: a broken sheet must not cost us the calendar.
          try {
            await syncDirectory(env);
          } catch (err) {
            console.log(`directory sync failed: ${err}`);
          }
          // And a broken rota tab must not cost us the directory, or vice versa.
          try {
            await syncRota(env);
          } catch (err) {
            console.log(`rota sync failed: ${err}`);
          }
          // Likewise the weather — it is the least important thing on the wall
          // and must not take the other two down with it.
          try {
            await syncWeather(env);
          } catch (err) {
            console.log(`weather sync failed: ${err}`);
          }
        }
      })(),
    );
  },

  /** Read path for the dashboard, plus manual triggers for setup/debugging. */
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/healthz') {
      return new Response('ok', { headers: { 'content-type': 'text/plain' } });
    }

    if (request.method === 'POST' && url.pathname.startsWith('/admin/')) {
      const name = url.pathname.slice('/admin/'.length);
      // hasOwn, so `/admin/constructor` is a 404 rather than Object's.
      const trigger = Object.hasOwn(TRIGGERS, name) ? TRIGGERS[name] : null;
      if (!trigger) return new Response('Not found', { status: 404 });
      const refusal = await refuseAdmin(request, env, name, { board: trigger.board });
      if (refusal) return refusal;
      try {
        return json({ ok: true, ...(await trigger.run(env)) });
      } catch (err) {
        return json({ ok: false, error: String(err) }, 500);
      }
    }

    return serveArtifact(request, url, env);
  },
};

export function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}
