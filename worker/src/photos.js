/**
 * Photo pipeline: normalize each attachment, write it to R2, prune the oldest
 * beyond the retention cap, then regenerate manifest.json with a fresh hash.
 *
 * The manifest hash is what the Pi diffs — an unchanged hash means the device
 * does no work at all beyond one small conditional GET.
 *
 * The pin lives in its own R2 object rather than inside manifest.json, because
 * the manifest is regenerated from scratch on every intake and would otherwise
 * lose it. It surfaces to the device as `"pinned": true` on one manifest entry,
 * which changes the hash and so propagates on the next poll.
 */

/** R2 key holding the current pin. Internal — not served to the device. */
const PIN_KEY = 'pin.json';

/**
 * Where photos go when they leave the rotation — both an emailed `delete:` and
 * an age-out under MAX_PHOTOS. A delete is one keystroke away from a mistake
 * and a cull is nobody's decision at all, so neither gets to destroy the only
 * copy. This prefix is not in serve.js's allow-list, so archiving costs a few
 * hundred KB and buys a restore path:
 *   wrangler r2 object get screendash/removed/<file> --file <file> --remote
 *
 * Nothing prunes `removed/` itself; it grows forever by design. At ~300 KB a
 * photo that is a few MB a year — cheap against losing one.
 */
const REMOVED_PREFIX = 'removed/';

/** Slugify an email address into a filename-safe fragment. */
function senderSlug(from) {
  return from.split('@')[0].replace(/[^a-z0-9]+/gi, '-').toLowerCase().slice(0, 24);
}

/** Stable-ish short hash over the manifest contents. */
async function hashOf(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].slice(0, 8)
    .map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Resize + re-encode via Cloudflare Images' resizing fetch. Runs the bytes back
 * through the edge so we never ship a full-resolution frame to the Pi. Its 1 GB
 * makes an oversized frame survivable, not free: decode cost scales with pixels,
 * and the panel is only 1080p either way.
 *
 * Requires Image Resizing to be enabled on the zone. If it isn't available the
 * original bytes are stored unchanged (still gated by MAX_ATTACHMENTS), so the
 * pipeline degrades rather than breaking.
 */
async function normalize(bytes, mimeType, env) {
  const maxEdge = parseInt(env.MAX_IMAGE_EDGE || '1920', 10);
  try {
    const resized = await fetch(
      new Request('https://screendash.invalid/resize', {
        method: 'POST',
        body: bytes,
        headers: { 'content-type': mimeType },
      }),
      {
        cf: {
          image: {
            width: maxEdge,
            height: maxEdge,
            fit: 'scale-down',
            quality: 80,
            format: 'jpeg',
            metadata: 'none', // strips EXIF
          },
        },
      },
    );
    if (resized.ok) {
      return new Uint8Array(await resized.arrayBuffer());
    }
    console.log(`resize returned ${resized.status}; storing original`);
  } catch (err) {
    console.log(`resize unavailable (${err}); storing original`);
  }
  return bytes;
}

/** The filename currently pinned, or null. Tolerates a missing/corrupt object. */
export async function readPin(env) {
  const obj = await env.DASH.get(PIN_KEY);
  if (!obj) return null;
  try {
    const { file } = await obj.json();
    return file || null;
  } catch {
    return null; // unreadable pin is the same as no pin
  }
}

async function writePinRecord(env, file, from) {
  const payload = { file: file || null, by: from || null, at: new Date().toISOString() };
  await env.DASH.put(PIN_KEY, JSON.stringify(payload, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });
}

/** Pin `file` (or clear the pin with null), then republish the manifest. */
export async function setPin(env, file, from) {
  await writePinRecord(env, file, from);
  return pruneAndRebuildManifest(env);
}

/**
 * Map a human-typed fragment onto a stored filename. Names are machine-generated
 * (`2026-07-28-jsmith-1753...-1.jpg`), so an exact match is unlikely — a unique
 * substring is what people can realistically type. Ambiguous input returns null
 * rather than guessing which photo they meant.
 */
export async function resolvePhotoName(env, fragment) {
  const needle = String(fragment || '').trim().toLowerCase();
  if (!needle) return null;

  const listed = await env.DASH.list({ prefix: 'photos/' });
  const names = listed.objects.map((o) => o.key.replace(/^photos\//, ''));

  const exact = names.find((n) => n.toLowerCase() === needle);
  if (exact) return exact;

  const hits = names.filter((n) => n.toLowerCase().includes(needle));
  return hits.length === 1 ? hits[0] : null;
}

/**
 * Take one photo out of rotation, keeping the bytes under `removed/`.
 * Returns false when the object wasn't there (already gone, or never stored).
 */
async function archive(env, file) {
  const key = `photos/${file}`;
  const obj = await env.DASH.get(key);
  if (!obj) return false;

  await env.DASH.put(`${REMOVED_PREFIX}${file}`, obj.body, {
    httpMetadata: obj.httpMetadata,
    customMetadata: obj.customMetadata,
  });
  await env.DASH.delete(key);
  return true;
}

/**
 * Remove every photo that arrived on a given mail thread.
 *
 * `threadId` is the Gmail thread of the `delete:` message itself — a reply sits
 * in the same thread as the mail it answers, so this matches the photos that
 * mail added. `replyIds` are the RFC Message-IDs from its In-Reply-To /
 * References headers, and cover the case where a client (or an edited subject)
 * splits the reply into a thread of its own: the headers still point back at
 * the original even when the thread ID no longer does.
 *
 * `ordinal` (1-based) narrows the batch to a single photo by arrival position,
 * for "the second one is a dud, keep the rest". Out of range removes nothing.
 *
 * Returns `{ matched, removed }`. The counts differ in the one case worth
 * distinguishing: a thread that added photos but has no #N is a typo in the
 * subject, not a delete aimed at the wrong mail.
 */
export async function removePhotosByThread(
  env,
  { threadId = null, replyIds = [], ordinal = null } = {},
) {
  const ids = new Set(replyIds.filter(Boolean));
  if (!threadId && ids.size === 0) return { matched: 0, removed: [] };

  // `include` gets the metadata in the list call rather than one HEAD per photo.
  const listed = await env.DASH.list({
    prefix: 'photos/',
    include: ['customMetadata'],
  });

  const matched = listed.objects
    .filter((o) => {
      const meta = o.customMetadata || {};
      if (threadId && meta.threadId === threadId) return true;
      return meta.messageId ? ids.has(meta.messageId) : false;
    })
    // Oldest first, so `ordinal` counts the way the sender does. Attachments of
    // one mail can land inside the same millisecond, so the key breaks the tie —
    // it ends in the attachment's own index (`…-1.jpg`, `…-2.jpg`).
    .sort((a, b) => (a.uploaded - b.uploaded) || (a.key < b.key ? -1 : 1))
    .map((o) => o.key.replace(/^photos\//, ''));

  const targets = ordinal === null ? matched : matched.slice(ordinal - 1, ordinal);

  const removed = [];
  for (const file of targets) {
    if (await archive(env, file)) removed.push(file);
  }

  // One rebuild for the batch. Skipped entirely when nothing matched, so a
  // misaddressed delete doesn't churn the manifest hash and cost every device
  // a re-download for no change. The rebuild also clears the pin by itself if
  // the pinned photo was one of these.
  if (removed.length > 0) await pruneAndRebuildManifest(env);
  return { matched: matched.length, removed };
}

/**
 * Remove a single photo named by a fragment of its filename — the fallback for
 * when the mail that added it is long gone. Returns the filename, or null when
 * the fragment matched nothing or was ambiguous.
 */
export async function removePhotoByFragment(env, fragment) {
  const file = await resolvePhotoName(env, fragment);
  if (!file) return null;
  if (!(await archive(env, file))) return null;

  await pruneAndRebuildManifest(env);
  return file;
}

/**
 * Write accepted attachments to R2, then refresh the manifest.
 * With `{ pin: true }` the first stored image is pinned as part of the same
 * rebuild. Returns the stored filenames.
 *
 * `threadId` / `messageId` are recorded against each object so a later
 * `delete:` reply can trace photos back to the mail that added them — the
 * filenames are machine-generated and nothing on the wall shows one, so the
 * originating email is the only handle anyone actually has on a photo.
 */
export async function storePhotos(
  env,
  attachments,
  from,
  { pin = false, threadId = null, messageId = null } = {},
) {
  const stamp = new Date().toISOString().slice(0, 10);
  const slug = senderSlug(from);

  const stored = [];
  let n = 0;
  for (const att of attachments) {
    n += 1;
    const raw = att.content instanceof ArrayBuffer
      ? new Uint8Array(att.content)
      : new Uint8Array(await new Response(att.content).arrayBuffer());

    const bytes = await normalize(raw, att.mimeType, env);
    const key = `photos/${stamp}-${slug}-${Date.now()}-${n}.jpg`;

    await env.DASH.put(key, bytes, {
      httpMetadata: { contentType: 'image/jpeg' },
      customMetadata: {
        from,
        received: new Date().toISOString(),
        // Omitted rather than stored empty, so the delete matcher can treat
        // "absent" and "no match" the same way.
        ...(threadId ? { threadId } : {}),
        ...(messageId ? { messageId } : {}),
      },
    });
    stored.push(key.replace(/^photos\//, ''));
  }

  // Set the pin before rebuilding so this costs one manifest write, not two.
  if (pin && stored.length > 0) await writePinRecord(env, stored[0], from);

  await pruneAndRebuildManifest(env);
  return stored;
}

/**
 * Keep only the newest MAX_PHOTOS images in rotation, archiving the rest to
 * `removed/`, then write manifest.json.
 */
export async function pruneAndRebuildManifest(env) {
  const max = parseInt(env.MAX_PHOTOS || '40', 10);

  let pinnedFile = await readPin(env);
  const pinnedKey = pinnedFile ? `photos/${pinnedFile}` : null;

  const listed = await env.DASH.list({ prefix: 'photos/' });
  const objects = listed.objects
    .slice()
    .sort((a, b) => (a.uploaded < b.uploaded ? 1 : -1)); // newest first

  // The newest `max` survive, plus the pinned photo even once it has aged past
  // the cap — deleting the one image someone asked to hold would be a nasty
  // surprise. That makes the effective ceiling max+1 while a pin is old.
  const keep = [];
  const drop = [];
  for (const obj of objects) {
    if (keep.length < max || obj.key === pinnedKey) keep.push(obj);
    else drop.push(obj);
  }

  // Archived, not deleted — same as an emailed `delete:`. Aging out of the
  // rotation is a display decision, and it should not be the thing that loses
  // the only copy of a photo somebody sent in. `drop` is empty on almost every
  // intake, so the extra get+put this costs over a bare delete is rarely paid.
  for (const obj of drop) {
    await archive(env, obj.key.replace(/^photos\//, ''));
  }

  // A pin can outlive its photo (deleted by hand, or never stored). Clear it
  // rather than publishing a manifest whose pin points at nothing.
  if (pinnedKey && !keep.some((o) => o.key === pinnedKey)) {
    await writePinRecord(env, null, null);
    pinnedFile = null;
  }

  // Oldest-first in the manifest so rotation feels chronological.
  const photos = keep
    .slice()
    .reverse()
    .map((o) => {
      const file = o.key.replace(/^photos\//, '');
      const entry = { file, w: 1920, h: 1080, bytes: o.size };
      // Only present when true, so the hash changes exactly when the pin does.
      if (file === pinnedFile) entry.pinned = true;
      return entry;
    });

  const body = { generated: new Date().toISOString(), photos };
  const hash = await hashOf(JSON.stringify(body.photos));
  const manifest = { hash, ...body };

  await env.DASH.put('manifest.json', JSON.stringify(manifest, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });

  return manifest;
}
