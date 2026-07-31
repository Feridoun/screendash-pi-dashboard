/**
 * Gmail intake — the Worker polls the mailbox instead of receiving pushed mail.
 *
 * This removes the need for a domain on Cloudflare: staff email the plain Gmail
 * address, and this cron pulls anything it hasn't already handled.
 *
 * Idempotency comes from a Gmail label (default "screendash-done"). Messages are
 * selected with `-label:screendash-done`, and the label is applied only after the
 * message has been fully applied to the dashboard — so a crash mid-batch simply
 * means the message is retried on the next tick, never silently dropped. Using a
 * label rather than read/unread means a human opening the mail in Gmail doesn't
 * break the pipeline.
 */
import { accessToken } from './google_auth.js';
import { applyMessage, isDecorativeImage } from './intake.js';

const API = 'https://gmail.googleapis.com/gmail/v1/users/me';

async function api(token, path, init = {}) {
  const resp = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      ...(init.headers || {}),
    },
  });
  if (!resp.ok) {
    throw new Error(`gmail ${path} -> ${resp.status} ${await resp.text()}`);
  }
  return resp.json();
}

/** Find the processed-label id, creating the label if it doesn't exist yet. */
async function ensureLabel(token, name) {
  const { labels = [] } = await api(token, '/labels');
  const found = labels.find((l) => l.name === name);
  if (found) return found.id;

  const created = await api(token, '/labels', {
    method: 'POST',
    body: JSON.stringify({
      name,
      labelListVisibility: 'labelShow',
      messageListVisibility: 'show',
    }),
  });
  return created.id;
}

/** Gmail returns base64url; decode to bytes. */
function decodeBase64Url(data = '') {
  const b64 = data.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function headerValue(headers = [], name) {
  const h = headers.find((x) => x.name.toLowerCase() === name.toLowerCase());
  return h ? h.value : '';
}

/** `<abc@mail.gmail.com>` → `abc@mail.gmail.com`. Message-IDs carry brackets. */
function bareMessageId(value = '') {
  return value.replace(/[<>]/g, '').trim();
}

/**
 * Every Message-ID this mail answers, from In-Reply-To and References.
 * The delete path uses these to trace a reply back to the mail that added a
 * photo when the thread ID alone doesn't (an edited subject can split a reply
 * into its own thread, but the headers still point home).
 */
function referencedIds(headers) {
  const raw = `${headerValue(headers, 'In-Reply-To')} ${headerValue(headers, 'References')}`;
  return (raw.match(/<[^>]+>/g) || []).map(bareMessageId);
}

/**
 * Walk the MIME tree, collecting the plain-text body and any attachment stubs.
 * Attachment bytes are fetched separately (Gmail only returns an attachmentId
 * inline once the payload exceeds a small size).
 *
 * Each stub carries the two facts that tell a photo from a signature logo:
 * whether the part is embedded in the body, and how big it is. Both come out of
 * the part metadata, so the decision costs no download — see [isDecorativeImage].
 */
function walkParts(payload, out = { text: '', attachments: [] }) {
  if (!payload) return out;

  const { mimeType = '', filename = '', body = {}, parts, headers = [] } = payload;

  if (filename && body.attachmentId) {
    const disposition = headerValue(headers, 'Content-Disposition').toLowerCase();
    out.attachments.push({
      filename,
      mimeType,
      attachmentId: body.attachmentId,
      size: body.size || 0,
      // A Content-ID means the HTML body references this part as `cid:…`, which
      // is how every signature logo is stitched into a message.
      inline:
        disposition.trimStart().startsWith('inline') ||
        Boolean(headerValue(headers, 'Content-ID')),
    });
  } else if (mimeType === 'text/plain' && body.data) {
    out.text += new TextDecoder().decode(decodeBase64Url(body.data));
  }

  for (const part of parts || []) walkParts(part, out);
  return out;
}

/** Fetch the actual bytes for one attachment. */
async function fetchAttachment(token, messageId, attachmentId) {
  const { data } = await api(
    token,
    `/messages/${messageId}/attachments/${attachmentId}`,
  );
  return decodeBase64Url(data);
}

/**
 * Poll the mailbox and apply every unprocessed message.
 * Returns the number of messages handled.
 */
export async function pollGmail(env) {
  const labelName = env.GMAIL_PROCESSED_LABEL || 'screendash-done';
  const maxBatch = parseInt(env.GMAIL_MAX_BATCH || '10', 10);

  const token = await accessToken(env);
  const labelId = await ensureLabel(token, labelName);

  // Only look at mail we haven't handled. `has:attachment OR subject:notice` would
  // be tempting, but we want to log ignored messages too, so keep it broad and
  // let intake.js decide.
  const query = encodeURIComponent(`-label:${labelName} -in:spam -in:trash`);
  const list = await api(
    token,
    `/messages?q=${query}&maxResults=${maxBatch}`,
  );

  const ids = (list.messages || []).map((m) => m.id);
  if (ids.length === 0) {
    console.log('gmail: nothing new');
    return 0;
  }

  let handled = 0;

  // Oldest first, so photos enter the rotation in the order they were sent.
  for (const id of ids.reverse()) {
    try {
      const msg = await api(token, `/messages/${id}?format=full`);
      const headers = msg.payload?.headers || [];
      const from = headerValue(headers, 'From');
      const subject = headerValue(headers, 'Subject');

      const { text, attachments } = walkParts(msg.payload);

      // Pull attachment bytes only for images — no point downloading a PDF —
      // and only for images that are actually photos. Both filters run on the
      // metadata alone, so a signature logo costs neither a download nor a
      // resize; it is simply never seen by the rest of the pipeline.
      const withBytes = [];
      for (const att of attachments) {
        if (!String(att.mimeType).toLowerCase().startsWith('image/')) continue;
        if (isDecorativeImage(att, env)) {
          console.log(
            `gmail ${id}: skipping decoration ${att.filename} ` +
              `(${att.size}B, inline=${att.inline})`,
          );
          continue;
        }
        withBytes.push({
          mimeType: att.mimeType,
          content: await fetchAttachment(token, id, att.attachmentId),
        });
      }

      const result = await applyMessage(env, {
        from,
        subject,
        body: text,
        attachments: withBytes,
        // Mail identity, recorded against stored photos so a `delete:` reply can
        // find them again. Gmail hands us threadId on the message itself.
        threadId: msg.threadId || null,
        messageId: bareMessageId(headerValue(headers, 'Message-ID')) || null,
        references: referencedIds(headers),
      });
      console.log(`gmail ${id}: ${result}`);

      // Label only after success, so a failure retries next tick.
      await api(token, `/messages/${id}/modify`, {
        method: 'POST',
        body: JSON.stringify({ addLabelIds: [labelId] }),
      });
      handled += 1;
    } catch (err) {
      // Leave it unlabelled and move on; the next tick will retry this message.
      console.log(`gmail ${id}: FAILED ${err}`);
    }
  }

  return handled;
}
