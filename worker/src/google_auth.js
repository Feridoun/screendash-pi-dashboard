/**
 * Google OAuth: exchange the long-lived refresh token for a short-lived access
 * token. Shared by the Calendar sync and the Gmail poller — one refresh token
 * covers both scopes.
 *
 * The refresh token is a Worker secret. It is never sent to the Pi.
 */

const TOKEN_URL = 'https://oauth2.googleapis.com/token';

export async function accessToken(env) {
  const body = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    client_secret: env.GOOGLE_CLIENT_SECRET,
    refresh_token: env.GOOGLE_REFRESH_TOKEN,
    grant_type: 'refresh_token',
  });

  const resp = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });

  if (!resp.ok) {
    const detail = await resp.text();
    // invalid_grant almost always means the refresh token expired because the
    // OAuth consent screen is still in "Testing" (7-day expiry) — see the README.
    throw new Error(`token exchange failed: ${resp.status} ${detail}`);
  }

  const json = await resp.json();
  return json.access_token;
}
