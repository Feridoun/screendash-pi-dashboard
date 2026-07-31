/**
 * Shared intake rules — who may write to the display, and what they wrote.
 *
 * Transport-agnostic on purpose: it takes an already-parsed message and decides
 * what to do with it, so the Gmail poller (and any future push transport) share
 * exactly one copy of the security gate and the routing rule.
 *
 * The subject decides, and there are four outcomes:
 *   `delete:`   → take photos back down (see below)
 *   `pinphoto:` → hold one photo on screen (see below)
 *   `notice:`   → update the banner
 *   `message:`  → append to the chat feed
 *   anything else with image attachments → add photos to the rotation
 *
 * Not every image in a mail is a photo, though — see [isDecorativeImage] for the
 * rule that keeps signature logos off the wall.
 */
import {
  storePhotos,
  setPin,
  resolvePhotoName,
  removePhotosByThread,
  removePhotoByFragment,
} from './photos.js';
import { writeMotd, cleanText } from './motd.js';
import { writeMessage } from './messages.js';

const NOTICE_PREFIX = 'notice:';
const MESSAGE_PREFIX = 'message:';
const PIN_PREFIX = 'pinphoto:';
const DELETE_PREFIX = 'delete:';

/** What can follow `pinphoto:` to mean "stop pinning". */
const CLEAR_WORDS = new Set(['', 'clear', 'off', 'none', 'unpin']);

/**
 * Is this image part decoration rather than a photo someone meant to put on the
 * wall — a signature logo, a tracking pixel, an email-client flourish?
 *
 * Two signals, and the main rule needs both:
 *   * **inline** — the part is embedded in the message body (`Content-Disposition:
 *     inline`, or it carries a Content-ID the HTML references as `cid:`), rather
 *     than attached to it. Every signature logo is inline.
 *   * **small** — a signature logo is a few KB; a photo off a phone is megabytes.
 *
 * Requiring both is what keeps this conservative. Someone who pastes a holiday
 * snap straight into the compose window sends an *inline* image too, and that
 * one is meant for the wall — it's just far too big to trip this.
 *
 * The lone-size floor underneath is a separate claim: below it an image cannot
 * look like anything across a room on a 1080p panel, however it arrived.
 *
 * Unknown size (0) never matches. Storing a stray logo is a minor annoyance;
 * silently dropping the photo someone sent is not, so this fails open.
 */
export function isDecorativeImage({ inline = false, size = 0 } = {}, env = {}) {
  if (!size) return false;
  if (size < parseInt(env.MIN_PHOTO_BYTES || '10240', 10)) return true;
  return inline && size < parseInt(env.MIN_INLINE_PHOTO_BYTES || '51200', 10);
}

/** Extract the bare address from a From header value. */
export function bareAddress(value = '') {
  const m = value.match(/<([^>]+)>/);
  return (m ? m[1] : value).trim().toLowerCase();
}

/**
 * Drop the trailing organisation that corporate directories append to a
 * display name — "SMITH, Alex (NORTHERN REGIONAL SERVICES)" is far too long
 * for a message line, and the org name says nothing the board needs.
 *
 * Only trailing brackets go, and only while a name is left over, so a sender
 * whose whole display name is bracketed keeps it rather than becoming blank.
 */
export function stripOrganisation(name = '') {
  let out = name.trim();
  for (;;) {
    const shorter = out.replace(/\s*[([{][^)\]}]*[)\]}]$/, '').trim();
    if (!shorter || shorter === out) return out;
    out = shorter;
  }
}

/**
 * The name a chat message should show as its sender: the display name off a
 * `"Jane Doe" <jane@x.com>` From header, falling back to the bare address when
 * there isn't one.
 */
export function displayNameFrom(value = '') {
  const m = value.match(/^\s*"?([^"<]+?)"?\s*<[^>]+>\s*$/);
  const name = m ? stripOrganisation(m[1]) : '';
  return name || bareAddress(value);
}

/** True when `address` sits under one of the allowed domains. */
export function isAllowedSender(address, allowedCsv) {
  const domains = String(allowedCsv || '')
    .split(',')
    .map((d) => d.trim().toLowerCase())
    .filter(Boolean);
  if (domains.length === 0) return false;
  const at = address.lastIndexOf('@');
  if (at < 0) return false;
  const domain = address.slice(at + 1);
  // Exact domain match, or a subdomain of an allowed domain.
  return domains.some((d) => domain === d || domain.endsWith(`.${d}`));
}

/** True when `address` is one of the addresses listed verbatim. */
export function isAllowedAddress(address, allowedCsv) {
  const list = String(allowedCsv || '')
    .split(',')
    .map((a) => a.trim().toLowerCase())
    .filter(Boolean);
  return list.includes(address);
}

/**
 * Strip however many `Re:` / `Fwd:` prefixes a client has stacked on the front.
 *
 * Only the delete path uses this: removing a photo means replying to the mail
 * that added it, and a reply arrives as `Re: <whatever they originally sent>`.
 * Editing that down to `delete:` is one step people will half-do, so accept
 * `Re: delete:` as meaning what it plainly means.
 */
function stripReplyPrefixes(subject = '') {
  return subject.trim().replace(/^((re|fwd|fw)\s*:\s*)+/i, '');
}

function hasPrefix(subject = '', prefix) {
  return subject.trim().toLowerCase().startsWith(prefix);
}

function afterPrefix(subject = '', prefix) {
  return subject.trim().slice(prefix.length).trim();
}

/** Does this subject mean "update the banner"? */
export function isNoticeSubject(subject = '') {
  return hasPrefix(subject, NOTICE_PREFIX);
}

/** The banner text carried by a notice subject (may be empty = clear the banner). */
export function noticeTextFrom(subject = '', body = '') {
  return afterPrefix(subject, NOTICE_PREFIX) || body.trim();
}

/** Does this subject mean "add this to the chat feed"? */
export function isMessageSubject(subject = '') {
  return hasPrefix(subject, MESSAGE_PREFIX);
}

/** The chat text carried by a message subject, falling back to the body. */
export function messageTextFrom(subject = '', body = '') {
  return afterPrefix(subject, MESSAGE_PREFIX) || body.trim();
}

/** Does this subject mean "hold a photo on screen"? */
export function isPinSubject(subject = '') {
  return hasPrefix(subject, PIN_PREFIX);
}

/** The photo the pin subject names — empty means "clear the pin". */
export function pinTargetFrom(subject = '') {
  return afterPrefix(subject, PIN_PREFIX);
}

/** Does this subject mean "take photos back down"? */
export function isDeleteSubject(subject = '') {
  return hasPrefix(stripReplyPrefixes(subject), DELETE_PREFIX);
}

/**
 * The photo the delete subject names, if any. Empty is the normal case — it
 * means "the photos this thread added".
 */
export function deleteTargetFrom(subject = '') {
  return afterPrefix(stripReplyPrefixes(subject), DELETE_PREFIX);
}

/**
 * A bare positive integer after `delete:` picks one photo out of the thread by
 * position — `delete: 2` is "the second photo this mail added", counting in the
 * order they arrived, which is the order they sit in the mail.
 *
 * This is the answer to "one of these three is a dud": filenames are
 * machine-generated and nothing on the wall ever shows one, but anyone can
 * count their own attachments. Non-numeric text stays a filename fragment.
 */
export function deleteOrdinalFrom(target = '') {
  if (!/^\d+$/.test(target.trim())) return null;
  const n = parseInt(target, 10);
  return n >= 1 ? n : null;
}

function imagesIn(message) {
  return (message.attachments || []).filter((a) =>
    String(a.mimeType || '').toLowerCase().startsWith('image/'),
  );
}

/**
 * Handle a `pinphoto:` message.
 *
 * An attachment wins over the subject text, because "pin the photo I just
 * attached" needs no filename — and filenames are machine-generated, so nobody
 * can type one from memory.
 */
async function applyPin(env, message, from, images) {
  if (images.length > 0) {
    const [file] = await storePhotos(env, images.slice(0, 1), from, {
      pin: true,
      threadId: message.threadId,
      messageId: message.messageId,
    });
    return `pinned new photo ${file} from ${from}`;
  }

  const target = pinTargetFrom(message.subject);
  if (CLEAR_WORDS.has(target.toLowerCase())) {
    await setPin(env, null, from);
    return `pin cleared by ${from}`;
  }

  const file = await resolvePhotoName(env, target);
  if (!file) {
    return `pin failed: no unique photo matching "${target}" (${from})`;
  }

  await setPin(env, file, from);
  return `pinned ${file} by ${from}`;
}

/**
 * Handle a `delete:` message.
 *
 * Photos are identified by the mail that added them, not by name: open the
 * mailbox, find that mail, reply to it with the subject `delete:`. Filenames
 * are machine-generated and nothing on the wall displays one, so the
 * originating email is the only handle on a photo that anyone actually has.
 *
 * Three ways to say which:
 *   `delete:`            every photo that mail added
 *   `delete: 2`          just the second one (see [deleteOrdinalFrom])
 *   `delete: <fragment>` by filename, for a photo whose mail is long gone
 *
 * Attachments are ignored outright: a *forward* carries the original images,
 * and re-adding what you were asked to remove is the one outcome here that
 * would be actively confusing.
 */
async function applyDelete(env, message, from) {
  const target = deleteTargetFrom(message.subject);
  const ordinal = deleteOrdinalFrom(target);

  // Text that isn't a bare number is a filename fragment.
  if (target && ordinal === null) {
    const file = await removePhotoByFragment(env, target);
    return file
      ? `removed ${file} by ${from}`
      : `delete failed: no unique photo matching "${target}" (${from})`;
  }

  const { matched, removed } = await removePhotosByThread(env, {
    threadId: message.threadId,
    replyIds: message.references,
    ordinal,
  });

  if (matched === 0) {
    return `delete failed: no photos traced to this thread (${from}) — `
      + 'reply to the mail that added them, or send "delete: <filename fragment>"';
  }
  // Asking for the 4th of three is a typo worth naming, not a silent no-op.
  if (removed.length === 0) {
    return `delete failed: this thread added ${matched} photo(s), so there is `
      + `no #${ordinal} (${from})`;
  }
  return `removed ${removed.length} photo(s) by ${from}: ${removed.join(', ')}`;
}

/**
 * Apply one message to the dashboard.
 *
 * `message` is `{ from, subject, body, attachments, threadId, messageId,
 * references }` where each attachment is `{ mimeType, content:
 * ArrayBuffer|Uint8Array }` — the shape photos.js expects. The three mail
 * identity fields are only load-bearing for `delete:`; everything else ignores
 * them.
 *
 * Returns a short string describing what happened, for logging.
 */
export async function applyMessage(env, message) {
  const from = bareAddress(message.from);

  // The domain gate is the general rule; the address list exists for the
  // dashboard's own mailbox, since deleting a photo means replying from inside
  // that inbox and the reply is therefore *from* a gmail.com address. Whoever
  // sends it had the account's password, which is a stronger claim than any
  // From header the domain gate is checking.
  const allowed =
    isAllowedSender(from, env.ALLOWED_SENDER_DOMAINS) ||
    isAllowedAddress(from, env.ALLOWED_SENDER_ADDRESSES);
  if (!allowed) {
    return `skipped: sender not allowed (${from})`;
  }

  const images = imagesIn(message);

  // Checked first: it is the one destructive branch, and it must not fall
  // through to the "has images, so store them" rule below.
  if (isDeleteSubject(message.subject)) {
    return applyDelete(env, message, from);
  }

  if (isPinSubject(message.subject)) {
    return applyPin(env, message, from, images);
  }

  if (isNoticeSubject(message.subject)) {
    const text = noticeTextFrom(message.subject, message.body);
    await writeMotd(env, { text, from, body: message.body || '' });
    return `notice updated by ${from}: ${text.slice(0, 60)}`;
  }

  if (isMessageSubject(message.subject)) {
    const text = cleanText(messageTextFrom(message.subject, message.body));
    if (!text) return `message ignored: empty (${from})`;
    await writeMessage(env, { sender: displayNameFrom(message.from), text });
    return `message recorded from ${from}: ${text.slice(0, 60)}`;
  }

  if (images.length === 0) {
    return `ignored: no images and no "notice:"/"message:"/"pinphoto:"/"delete:" subject (${from})`;
  }

  const max = parseInt(env.MAX_ATTACHMENTS || '10', 10);
  const accepted = images.slice(0, max);
  await storePhotos(env, accepted, from, {
    threadId: message.threadId,
    messageId: message.messageId,
  });
  return `stored ${accepted.length} image(s) from ${from}`;
}
