#!/usr/bin/env node
/**
 * One-time helper: obtain a long-lived Google refresh token covering all three
 * scopes this backend needs — calendar (read), Gmail (read + label) and Sheets
 * (read).
 *
 * Run this ON YOUR LAPTOP (it opens a browser). The Pi never runs it — the
 * resulting refresh token is stored as a Worker secret and the device only ever
 * reads the artifacts the Worker publishes.
 *
 *   node get-refresh-token.mjs <CLIENT_ID> <CLIENT_SECRET>
 *
 * Prerequisites in Google Cloud Console:
 *   1. Enable the "Google Calendar API", the "Gmail API" and the
 *      "Google Sheets API".
 *   2. Create an OAuth client ID of type "Web application".
 *   3. Add  http://localhost:8976/callback  as an authorised redirect URI.
 *   4. On the OAuth consent screen, add the Google account you'll be reading
 *      (e.g. your-dashboard@gmail.com) as a Test user.
 *
 * Sign in as that same account when the browser opens.
 *
 * Node 18+ only; no dependencies.
 */
import http from 'node:http';
import { spawn } from 'node:child_process';

const [, , CLIENT_ID, CLIENT_SECRET] = process.argv;

if (!CLIENT_ID || !CLIENT_SECRET) {
  console.error('usage: node get-refresh-token.mjs <CLIENT_ID> <CLIENT_SECRET>');
  process.exit(1);
}

const PORT = 8976;
const REDIRECT = `http://localhost:${PORT}/callback`;
// calendar.readonly    -> events.json
// gmail.modify         -> read messages + apply the processed label (readonly is
//                         not enough: we must label handled mail so the poller is
//                         idempotent).
// spreadsheets.readonly-> the directory sheet behind directory.json
const SCOPE = [
  'https://www.googleapis.com/auth/calendar.readonly',
  'https://www.googleapis.com/auth/gmail.modify',
  'https://www.googleapis.com/auth/spreadsheets.readonly',
].join(' ');

const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth');
authUrl.searchParams.set('client_id', CLIENT_ID);
authUrl.searchParams.set('redirect_uri', REDIRECT);
authUrl.searchParams.set('response_type', 'code');
authUrl.searchParams.set('scope', SCOPE);
// Both of these are required or Google will not return a refresh token.
authUrl.searchParams.set('access_type', 'offline');
authUrl.searchParams.set('prompt', 'consent');

/** Open a URL in the platform's default browser. */
function openBrowser(url) {
  const cmd = process.platform === 'win32' ? 'cmd'
    : process.platform === 'darwin' ? 'open'
    : 'xdg-open';
  const args = process.platform === 'win32' ? ['/c', 'start', '', url] : [url];
  spawn(cmd, args, { detached: true, stdio: 'ignore' }).unref();
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname !== '/callback') {
    res.writeHead(404).end('not found');
    return;
  }

  const error = url.searchParams.get('error');
  if (error) {
    res.writeHead(400, { 'content-type': 'text/plain' })
       .end(`Authorisation failed: ${error}`);
    console.error(`\n✗ authorisation failed: ${error}`);
    server.close();
    process.exit(1);
  }

  const code = url.searchParams.get('code');

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      redirect_uri: REDIRECT,
      grant_type: 'authorization_code',
    }),
  });

  const data = await resp.json();

  if (!resp.ok || !data.refresh_token) {
    res.writeHead(500, { 'content-type': 'text/plain' })
       .end('Token exchange failed — see the terminal.');
    console.error('\n✗ token exchange failed:', JSON.stringify(data, null, 2));
    console.error(
      '\nIf you got an access_token but no refresh_token, Google has already\n' +
      'issued one for this client. Revoke it at\n' +
      '  https://myaccount.google.com/permissions\n' +
      'and run this again.',
    );
    server.close();
    process.exit(1);
  }

  res.writeHead(200, { 'content-type': 'text/html' }).end(
    '<h2>Done.</h2><p>Refresh token printed in your terminal. ' +
    'You can close this tab.</p>',
  );

  console.log('\n✓ Success. Store these as Worker secrets:\n');
  console.log(`  npx wrangler secret put GOOGLE_CLIENT_ID`);
  console.log(`      ${CLIENT_ID}\n`);
  console.log(`  npx wrangler secret put GOOGLE_CLIENT_SECRET`);
  console.log(`      ${CLIENT_SECRET}\n`);
  console.log(`  npx wrangler secret put GOOGLE_REFRESH_TOKEN`);
  console.log(`      ${data.refresh_token}\n`);
  console.log('Treat the refresh token like a password — it grants read access');
  console.log('to your calendar until you revoke it.\n');

  server.close();
  process.exit(0);
});

server.listen(PORT, () => {
  console.log(`Listening on ${REDIRECT}`);
  console.log('Opening your browser to authorise…\n');
  console.log(`If it does not open, visit:\n${authUrl}\n`);
  openBrowser(authUrl.toString());
});
