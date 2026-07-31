/**
 * Notice banner: written by an email whose subject starts with "notice:".
 *
 * Text comes from the subject after the prefix, falling back to the plain-text
 * body. An optional accent color may be given as "#accent=#RRGGBB" on its own
 * line in the body. Sending "notice:" with no text clears the banner.
 *
 * Superseded notices are not thrown away: each write pushes the outgoing one
 * onto a capped `history` array inside the same object, newest first, so the
 * device can let someone step back through what they missed without a second
 * artifact or a second poll.
 *
 * The published artifact stays `motd.json` — that name is the contract with the
 * device, and only the email keyword changed.
 */

const ACCENT_RE = /#accent\s*=\s*(#[0-9a-f]{6})/i;

/** How many superseded notices stay readable on the device. */
const DEFAULT_HISTORY = 5;

export function parseAccent(body = '') {
  const m = body.match(ACCENT_RE);
  return m ? m[1].toUpperCase() : null;
}

/** Strip the accent directive and any trailing quoted reply chain. */
export function cleanText(text = '') {
  return text
    .replace(ACCENT_RE, '')
    // Drop a quoted reply / forwarded chain if someone replies to set the notice.
    .split(/^\s*(?:>|On .+ wrote:|-----Original Message-----)/m)[0]
    .trim();
}

/** The notice currently published, or null when there is none (or it's corrupt). */
async function readMotd(env) {
  const obj = await env.DASH.get('motd.json');
  if (!obj) return null;
  try {
    return await obj.json();
  } catch {
    return null; // unreadable notice is the same as no notice
  }
}

/**
 * The history array to publish alongside `next`, newest first.
 *
 * The notice being replaced goes to the front, unless it was blank (a cleared
 * banner is not something anyone wants to scroll back to) or said the same
 * thing as the incoming one — reposting a notice shouldn't stack duplicates.
 */
export function historyFor(previous, next, max = DEFAULT_HISTORY) {
  if (!previous) return [];

  const older = (previous.history || []).filter((n) => n && String(n.text || '').trim());
  const outgoing = String(previous.text || '').trim();
  if (!outgoing || outgoing === String(next.text || '').trim()) {
    return older.slice(0, max);
  }

  const entry = { text: previous.text, updated: previous.updated, source: previous.source };
  if (previous.accent) entry.accent = previous.accent;
  return [entry, ...older].slice(0, max);
}

export async function writeMotd(env, { text, from, body }) {
  const accent = parseAccent(body);
  const previous = await readMotd(env);
  const payload = {
    text: cleanText(text),
    updated: new Date().toISOString(),
    // Keep provenance for debugging; the app ignores unknown fields.
    source: from,
  };
  if (accent) payload.accent = accent;

  const max = parseInt(env.MAX_NOTICE_HISTORY || String(DEFAULT_HISTORY), 10);
  const history = historyFor(previous, payload, max);
  if (history.length > 0) payload.history = history;

  await env.DASH.put('motd.json', JSON.stringify(payload, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });

  return payload;
}
