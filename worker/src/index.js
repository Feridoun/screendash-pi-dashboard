/**
 * screendash — Cloudflare Worker backend.
 *
 * Two entry points:
 *   scheduled()  cron → poll Gmail for photos/notices/pins, and sync Google Calendar
 *   fetch()      HTTP → serve the artifacts the Pi polls
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
import { serveArtifact } from './serve.js';
import { pruneAndRebuildManifest } from './photos.js';

export default {
  /**
   * Cron. Two schedules are registered in wrangler.toml:
   *   every 5 min  → Gmail intake (photos + notices + pins)
   *   every 15 min → Calendar sync + directory sync
   * Anything unrecognised runs both, so a schedule change can't silently
   * disable intake.
   *
   * The directory rides the 15-minute tick rather than owning a schedule: it is
   * one cheap API call, and the sheet changes a few times a year.
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

    if (request.method === 'POST') {
      // Handy while setting things up: force either job immediately.
      if (url.pathname === '/admin/sync-calendar') {
        try {
          const n = await syncCalendar(env);
          return json({ ok: true, events: n });
        } catch (err) {
          return json({ ok: false, error: String(err) }, 500);
        }
      }
      if (url.pathname === '/admin/sync-directory') {
        try {
          return json({ ok: true, ...(await syncDirectory(env)) });
        } catch (err) {
          return json({ ok: false, error: String(err) }, 500);
        }
      }
      if (url.pathname === '/admin/poll-gmail') {
        try {
          const n = await pollGmail(env);
          return json({ ok: true, handled: n });
        } catch (err) {
          return json({ ok: false, error: String(err) }, 500);
        }
      }
      // Republish manifest.json from whatever is in R2 right now. Needed after
      // editing the bucket by hand — the device only ever reads the manifest,
      // so an object deleted underneath it stays on the wall until this runs.
      // Idempotent and non-destructive (bar the MAX_PHOTOS prune it already
      // does on every intake), which is why it sits with the other open
      // /admin/* triggers rather than behind a credential.
      if (url.pathname === '/admin/rebuild-manifest') {
        try {
          const m = await pruneAndRebuildManifest(env);
          return json({ ok: true, hash: m.hash, photos: m.photos.length });
        } catch (err) {
          return json({ ok: false, error: String(err) }, 500);
        }
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
