/**
 * Read path: serve the artifacts the Pi polls, straight out of R2.
 *
 * ETags matter here — the device sends If-None-Match, and a 304 means it does
 * no parsing and no download. R2 gives us an etag per object for free.
 */

const ALLOWED = new Set([
  'manifest.json',
  'events.json',
  'motd.json',
  'messages.json',
  'directory.json',
  'version.json',
]);

function contentTypeFor(key) {
  if (key.endsWith('.json')) return 'application/json';
  if (key.endsWith('.jpg') || key.endsWith('.jpeg')) return 'image/jpeg';
  if (key.endsWith('.tar.gz')) return 'application/gzip';
  return 'application/octet-stream';
}

export async function serveArtifact(request, url, env) {
  const key = url.pathname.replace(/^\/+/, '');

  const isPhoto = key.startsWith('photos/');
  const isBundle = key.startsWith('bundles/');
  if (!ALLOWED.has(key) && !isPhoto && !isBundle) {
    return new Response('Not found', { status: 404 });
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
  headers.set(
    'cache-control',
    key.endsWith('.json') ? 'public, max-age=60' : 'public, max-age=31536000, immutable',
  );

  // No body => the ETag matched. 304 must not carry a payload.
  if (!('body' in object) || object.body === undefined) {
    return new Response(null, { status: 304, headers });
  }

  return new Response(object.body, { headers });
}
