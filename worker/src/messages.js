/**
 * Chat panel: written by an email whose subject starts with "message:".
 *
 * Text comes from the subject after the prefix, falling back to the plain-text
 * body. Unlike motd.js, there's no "current vs superseded" notion here — every
 * message is appended to a capped feed stored in `messages.json`, newest
 * first, so the device can show a scrolling log of the last N without any
 * history bookkeeping.
 */

/** How many messages stay in the feed before the oldest fall off. */
const DEFAULT_MAX = 50;

/** The feed currently published, or an empty list when there is none (or it's corrupt). */
async function readMessages(env) {
  const obj = await env.DASH.get('messages.json');
  if (!obj) return [];
  try {
    const data = await obj.json();
    return Array.isArray(data.messages) ? data.messages : [];
  } catch {
    return []; // an unreadable feed is the same as an empty one
  }
}

export async function writeMessage(env, { sender, text }) {
  const trimmed = String(text || '').trim();
  if (!trimmed) return null; // nothing to record

  const entry = {
    sender: sender || 'unknown',
    text: trimmed,
    sent: new Date().toISOString(),
  };

  const max = parseInt(env.MAX_MESSAGES || String(DEFAULT_MAX), 10);
  const existing = await readMessages(env);
  const messages = [entry, ...existing].slice(0, max);

  await env.DASH.put('messages.json', JSON.stringify({ messages }, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });

  return entry;
}
