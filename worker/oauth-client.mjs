/**
 * Where the Google OAuth client ID and secret come from, for the two one-off
 * helpers that need them: get-refresh-token.mjs and create-rota-sheet.mjs.
 *
 * The Worker itself never reads this. In production all three Google values are
 * Cloudflare secrets (`wrangler secret put`), and `wrangler secret list` shows
 * their names but never their values — so the client ID and secret have to come
 * from somewhere on the laptop when a token is re-minted. Putting them in the
 * command line works but leaves the secret in shell history, and typing them
 * out is how the wrong project's client ends up being used.
 *
 * In order: command-line arguments, then the environment, then `.dev.vars` next
 * to this file. That last one is the place to paste them once: it is gitignored
 * (twice — root and worker/), and it is the same file `wrangler dev` reads, so
 * a local dev run picks the same credentials up for free.
 *
 * Node 18+ only; no dependencies.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

/** The file to paste credentials into. */
export const DEV_VARS = path.join(here, '.dev.vars');

/**
 * `KEY=value` lines, `#` comments, optional surrounding quotes — enough for a
 * .dev.vars, and deliberately not a full dotenv parser. A quoted value is kept
 * verbatim (a Google client secret may legitimately contain a `#`); an unquoted
 * one is cut at the first `#` that follows whitespace.
 */
export function readDevVars(file = DEV_VARS) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return {}; // No file is the normal case on a fresh clone.
  }
  const vars = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!match) continue;
    const [, key, rest] = match;
    let value = rest.trim();
    const quoted = value.match(/^"(.*)"$/s) || value.match(/^'(.*)'$/s);
    value = quoted ? quoted[1] : value.replace(/\s+#.*$/, '').trim();
    vars[key] = value;
  }
  return vars;
}

/**
 * A value that is present but obviously not filled in yet — an empty string, or
 * the `<paste …>` placeholder the template ships with. Treated as absent so the
 * error below fires instead of Google rejecting the request for no clear reason.
 */
const isPlaceholder = (value) => !value || /^<.*>$/.test(value);

/**
 * The client ID and secret, from wherever they are.
 *
 * [args] are the leftover positional arguments (ID then secret). Pass
 * `optional: true` for a dry run, which needs no credentials; the caller then
 * gets whatever was found, empty strings included.
 */
export function oauthClient(args = [], { script, optional = false } = {}) {
  const file = readDevVars();
  const resolve = (arg, key) =>
    [arg, process.env[key], file[key]]
      .map((value) => (value ?? '').trim())
      .find((value) => !isPlaceholder(value)) ?? '';

  const CLIENT_ID = resolve(args[0], 'GOOGLE_CLIENT_ID');
  const CLIENT_SECRET = resolve(args[1], 'GOOGLE_CLIENT_SECRET');

  if (!optional && (!CLIENT_ID || !CLIENT_SECRET)) {
    const missing = [!CLIENT_ID && 'GOOGLE_CLIENT_ID', !CLIENT_SECRET && 'GOOGLE_CLIENT_SECRET']
      .filter(Boolean)
      .join(' and ');
    console.error(
      `${script}: no Google OAuth client (${missing} not found).\n\n` +
        `Paste them into ${DEV_VARS}\n` +
        '(gitignored, and what `wrangler dev` reads):\n\n' +
        '  GOOGLE_CLIENT_ID = "....apps.googleusercontent.com"\n' +
        '  GOOGLE_CLIENT_SECRET = "GOCSPX-..."\n\n' +
        'They come from Google Cloud Console → APIs & Services → Credentials →\n' +
        'the "Web application" OAuth client. Or pass them as arguments:\n\n' +
        `  node ${script} <CLIENT_ID> <CLIENT_SECRET>\n`,
    );
    process.exit(1);
  }
  return { CLIENT_ID, CLIENT_SECRET };
}
