#!/usr/bin/env node
/**
 * One-off cleanup: find signature logos and other email decoration already
 * sitting in the photo rotation, and take them out.
 *
 * The intake filter (see `isDecorativeImage` in src/intake.js) only applies to
 * mail arriving from now on. Anything stored before it existed is still on the
 * wall, and the two signals that filter uses are no longer both available: R2
 * records the photo's size, but nothing recorded whether the part was inline.
 * So this goes on size alone, which is why it shows you the list first and does
 * nothing until you ask twice.
 *
 * Usage, from the worker/ directory:
 *
 *   node prune-decorative.mjs                 # list candidates, change nothing
 *   node prune-decorative.mjs --under 30000   # try a different size cutoff
 *   node prune-decorative.mjs --apply         # archive them, republish manifest
 *
 * Removed photos are copied to `removed/` in the bucket before deletion, the
 * same as an emailed `delete:` — restore one with:
 *   wrangler r2 object get screendash/removed/<file> --file <file>
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readDevVars } from './oauth-client.mjs';

const BACKEND_URL = process.env.BACKEND_URL;
if (!BACKEND_URL) {
  console.error('set BACKEND_URL, e.g. https://screendash.<your-subdomain>.workers.dev');
  process.exit(2);
}
// rebuild-manifest needs the operator's bearer token (src/admin.js), from the
// environment or worker/.dev.vars. Checked before anything is archived, so a
// missing token can't leave photos deleted with the manifest still listing them.
const ADMIN_TOKEN = process.env.ADMIN_TOKEN || readDevVars().ADMIN_TOKEN || '';
const BUCKET = process.env.BUCKET || 'screendash';

const args = process.argv.slice(2);
const apply = args.includes('--apply');
const underArg = args.indexOf('--under');
// Defaults to MIN_INLINE_PHOTO_BYTES from wrangler.toml: signature logos live
// well below it, and a real photo that survived the resize step well above.
const under = underArg >= 0 ? parseInt(args[underArg + 1], 10) : 81920;

/** Run wrangler, letting its own output through only when it matters. */
function wrangler(argv) {
  return execFileSync('npx', ['wrangler', ...argv], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    shell: true,
  });
}

const kb = (n) => `${(n / 1024).toFixed(1)} KB`;

/**
 * Returns a process exit code. Structured as a function returning rather than
 * calling process.exit() mid-flight: an exit while fetch's sockets are still
 * closing trips a libuv assertion on Windows, which looks like a crash on an
 * otherwise successful run.
 */
async function main() {
  if (!Number.isFinite(under) || under <= 0) {
    console.error(`!! --under needs a positive byte count, got "${args[underArg + 1]}"`);
    return 1;
  }

  // The manifest is the right source here rather than an R2 listing: it is
  // exactly what the wall is showing, and it already carries each photo's size.
  const resp = await fetch(`${BACKEND_URL}/manifest.json?_=${Date.now()}`, {
    headers: { 'cache-control': 'no-cache' },
  });
  if (!resp.ok) {
    console.error(`!! could not read ${BACKEND_URL}/manifest.json — HTTP ${resp.status}`);
    return 1;
  }
  const { photos = [] } = await resp.json();

  const candidates = photos
    .filter((p) => p.bytes && p.bytes < under)
    .sort((a, b) => a.bytes - b.bytes);

  console.log(
    `${photos.length} photo(s) in rotation; ${candidates.length} under ${kb(under)}:\n`,
  );
  if (candidates.length === 0) {
    console.log('Nothing to do.');
    return 0;
  }
  for (const p of candidates) {
    console.log(`  ${kb(p.bytes).padStart(9)}  ${p.file}${p.pinned ? '   [PINNED]' : ''}`);
  }

  if (!apply) {
    console.log(
      `\nNothing changed. Re-run with --apply to archive these ${candidates.length}, ` +
        'or --under <bytes> to move the cutoff.',
    );
    return 0;
  }

  if (!ADMIN_TOKEN) {
    console.error(
      '\n!! No ADMIN_TOKEN, so the manifest could not be republished afterwards and the\n' +
        '   archived photos would stay listed on the wall. Nothing changed. Put it in\n' +
        '   worker/.dev.vars (ADMIN_TOKEN = "...") or the environment, and re-run.',
    );
    return 1;
  }

  // Archive = copy to removed/, then delete. Same contract as photos.js's own
  // archive(), just driven from outside the Worker.
  const scratch = mkdtempSync(join(tmpdir(), 'screendash-prune-'));
  let archived = 0;
  try {
    for (const p of candidates) {
      const local = join(scratch, p.file);
      try {
        wrangler(['r2', 'object', 'get', `${BUCKET}/photos/${p.file}`, '--file', local]);
        wrangler([
          'r2', 'object', 'put', `${BUCKET}/removed/${p.file}`,
          '--file', local, '--content-type', 'image/jpeg',
        ]);
        wrangler(['r2', 'object', 'delete', `${BUCKET}/photos/${p.file}`]);
        archived += 1;
        console.log(`   archived ${p.file}`);
      } catch (err) {
        // Keep going: one unreadable object should not strand the rest.
        console.error(`!! failed on ${p.file}: ${err.message.trim().split('\n').pop()}`);
      }
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }

  if (archived === 0) {
    console.error('\n!! nothing was archived; leaving the manifest alone.');
    return 1;
  }

  // The device only ever reads manifest.json, so until this runs the photos we
  // just deleted are still on the wall.
  console.log('\nRepublishing manifest…');
  const rebuilt = await fetch(`${BACKEND_URL}/admin/rebuild-manifest?_=${Date.now()}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${ADMIN_TOKEN}` },
  });
  const body = await rebuilt.json().catch(() => ({}));
  if (!rebuilt.ok || !body.ok) {
    console.error(`!! rebuild failed (HTTP ${rebuilt.status}) — run it by hand:`);
    console.error(`   curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" ${BACKEND_URL}/admin/rebuild-manifest`);
    return 1;
  }

  console.log(`Done: archived ${archived}, ${body.photos} photo(s) left, hash ${body.hash}.`);
  console.log('Devices pick this up on their next manifest poll (~5 min).');
  return 0;
}

process.exitCode = await main();
