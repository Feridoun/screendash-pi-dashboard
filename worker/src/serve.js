/**
 * Read path: serve the artifacts the Pi polls, straight out of R2.
 *
 * ETags matter here — the device sends If-None-Match, and a 304 means it does
 * no parsing and no download. R2 gives us an etag per object for free.
 *
 * Everything under here is public EXCEPT `bundles/`. The bundle is the app
 * itself, and it can carry build-time secrets (a Tailscale auth key baked in
 * via --dart-define; see deploy/deploy.sh). Serving it anonymously made the
 * whole chain public: GET /version.json -> bundle_url -> untar -> read the key.
 * So bundles require the DEVICE_TOKEN bearer secret; see docs/tailnet-security.md.
 */

const ALLOWED = new Set([
  'manifest.json',
  'events.json',
  'motd.json',
  'messages.json',
  'directory.json',
  'rota.json',
  'weather.json',
  'version.json',
]);

function contentTypeFor(key) {
  if (key.endsWith('.json')) return 'application/json';
  if (key.endsWith('.jpg') || key.endsWith('.jpeg')) return 'image/jpeg';
  if (key.endsWith('.tar.gz')) return 'application/gzip';
  return 'application/octet-stream';
}

/**
 * Compare in time independent of how much of the token matched, so a caller
 * can't recover it byte by byte from response timing. Length is allowed to
 * leak — knowing the length of a random token buys nothing.
 */
export function tokenMatches(presented, expected) {
  if (presented.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= presented.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

/** The token from an `Authorization: Bearer …` header, or '' if there isn't one. */
export function bearerToken(request) {
  const header = request.headers.get('authorization') || '';
  return header.startsWith('Bearer ') ? header.slice(7) : '';
}

/** Returns a Response to send instead of the object, or null to allow it. */
function refuseBundle(request, env) {
  const expected = env.DEVICE_TOKEN;
  if (!expected) {
    // Fail CLOSED, and say why in the log. The alternative — serving bundles
    // publicly whenever the secret is missing — is the exact hole this gate
    // exists to close, and it would fail silently. Devices keep running the
    // version they already have, so the cost of getting here is paused
    // updates, not a dead wall. Fix: `wrangler secret put DEVICE_TOKEN`.
    console.log('bundle refused: DEVICE_TOKEN is not configured on this Worker');
    return new Response('Bundle downloads are not configured', { status: 503 });
  }
  if (!tokenMatches(bearerToken(request), expected)) {
    // 404 rather than 401: there is no auth scheme to negotiate with a
    // stranger, and this way an anonymous caller cannot even confirm which
    // versions exist.
    return new Response('Not found', { status: 404 });
  }
  return null;
}

export async function serveArtifact(request, url, env) {
  const key = url.pathname.replace(/^\/+/, '');

  const isPhoto = key.startsWith('photos/');
  const isBundle = key.startsWith('bundles/');
  if (!ALLOWED.has(key) && !isPhoto && !isBundle) {
    return new Response('Not found', { status: 404 });
  }

  if (isBundle) {
    const refusal = refuseBundle(request, env);
    if (refusal) return refusal;
  }

  // Hand R2 the request headers so it evaluates If-None-Match for us. When the
  // precondition fails it returns an R2Object with metadata but no `body`, which
  // is our cue to answer 304.
  //
  // In practice on *.workers.dev the Cloudflare edge answers conditional
  // requests before we run (the Worker sees if-none-match as null), so this path
  // is belt-and-braces: it keeps the Worker correct on its own, in case the edge
  // stops intercepting or the artifacts get fronted by different cache settings.
  const object = await env.DASH.get(key, { onlyIf: request.headers });
  if (!object) {
    return new Response('Not found', { status: 404 });
  }

  const headers = new Headers();
  headers.set('content-type', contentTypeFor(key));
  headers.set('etag', object.httpEtag);
  // JSON changes often and is tiny; images and bundles are immutable once named.
  // Bundles are `private`, not `public`: they are behind DEVICE_TOKEN now, and a
  // shared cache holding an authorised response would hand it to the next
  // anonymous caller and undo the gate. Vary says the same thing to any cache
  // that ignores `private`.
  if (isBundle) {
    headers.set('cache-control', 'private, max-age=31536000, immutable');
    headers.set('vary', 'Authorization');
  } else {
    headers.set(
      'cache-control',
      key.endsWith('.json') ? 'public, max-age=60' : 'public, max-age=31536000, immutable',
    );
  }

  // No body => the ETag matched. 304 must not carry a payload.
  if (!('body' in object) || object.body === undefined) {
    return new Response(null, { status: 304, headers });
  }

  return new Response(object.body, { headers });
}
