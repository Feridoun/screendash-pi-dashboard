/**
 * Notice banner: written by an email whose subject is "notice".
 *
 * The text is the plain-text body (the subject carries the command, not the
 * content). An optional accent color may be given as "#accent=#RRGGBB" on its
 * own line in the body. Sending "notice" with an empty body clears the banner.
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

/**
 * The accent directive as a whole line, for stripping. Removing only the match
 * would leave an empty line behind, and an empty line is exactly what
 * [PARAGRAPH_END_RE] treats as the end of the notice.
 */
const ACCENT_LINE_RE = /^[ \t]*#accent\s*=\s*#[0-9a-f]{6}[ \t]*\n?/im;

/** How many superseded notices stay readable on the device. */
const DEFAULT_HISTORY = 5;

export function parseAccent(body = '') {
  const m = body.match(ACCENT_RE);
  return m ? m[1].toUpperCase() : null;
}

/**
 * Where a body stops being what somebody typed and starts being the mail
 * client's furniture. A quoted reply chain, Outlook's `From:` header block, the
 * `--` signature delimiter or a phone's "Sent from my ..." all mean the same
 * thing: everything below this line was not written for the wall.
 *
 * This carries real weight now that the body *is* the notice — an untrimmed
 * signature block would otherwise become the banner. It stays deliberately
 * narrow: each marker is a line mail clients generate verbatim, so ordinary
 * prose does not trip it. The `From:` line needs an address on it for the same
 * reason.
 *
 * Unlike the two rules below, this one may match on the very first line: a
 * `notice` sent from a phone with nothing typed arrives as *only* the footer,
 * and that has to read as an empty body (clear the banner), not as a notice
 * saying "Get Outlook for iOS".
 */
const BODY_TAIL_RE = new RegExp(
  String.raw`^\s*(?:`
    + String.raw`>`                                   // quoted reply
    + String.raw`|On .+ wrote:`                       // Gmail / Apple Mail attribution
    + String.raw`|-{3,} ?Original Message ?-{3,}`     // Outlook attribution
    + String.raw`|From:\s.*\S+@\S+`                   // Outlook reply header block
    + String.raw`|--\s*$`                             // RFC 3676 signature delimiter
    + String.raw`|(?:Sent from|Get Outlook for) \S+`  // phone / Outlook mobile footer
    + String.raw`)`,
  'im',
);

/**
 * A sign-off standing alone on a line — "Kind regards", "Thanks," — which is
 * how a hand-typed signature starts when there is no blank line in front of it.
 *
 * Only the bare sign-off counts, so "Thanks to Dave for fixing the boiler" is
 * still a notice. And it must be preceded by a newline: a message that is
 * just "Thanks!" was written for the wall, not signed off from it.
 */
const SIGN_OFF_RE =
  /\n[ \t]*(?:(?:kind|best|warm|many)\s+)?(?:regards|thanks|thank you|wishes|cheers)[,.!]*[ \t]*(?:\n|$)/i;

/**
 * The first blank line ends the notice. Nearly every signature block — the
 * ones Exchange, Outlook and Gmail insert, and the ones people type — sits
 * below a blank line, whereas the notice itself never contains one: a long
 * sentence that a client has hard-wrapped at 76 columns is still one
 * paragraph, which is why this cuts at a blank line and not at the first line
 * break.
 *
 * "Blank" includes a line of nothing but NBSP, because an empty Outlook HTML
 * paragraph is `<p>&nbsp;</p>`.
 */
const PARAGRAPH_END_RE = /\n[ \t\u00a0]*\n/;

/**
 * The part of a body that was written for the wall: the accent directive
 * stripped, then everything up to the first tail marker, sign-off or blank
 * line, whichever comes first.
 *
 * Line endings are normalised first so each rule only has to know about `\n`,
 * and the text is trimmed before the paragraph cut so that leading blank lines
 * (Outlook puts the cursor two lines above the signature) don't read as an
 * empty first paragraph.
 */
export function cleanText(text = '') {
  return text
    .replace(/\r\n?/g, '\n')
    .replace(ACCENT_LINE_RE, '')
    .replace(ACCENT_RE, '') // one written mid-line, which the guide never promised but used to work
    .split(BODY_TAIL_RE)[0]
    .trim()
    .split(SIGN_OFF_RE)[0]
    .split(PARAGRAPH_END_RE)[0]
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
