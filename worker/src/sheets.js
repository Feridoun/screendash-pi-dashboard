/**
 * Google Sheets: the read path shared by the directory and rota syncs.
 *
 * Both jobs read tabs whose first row is a header, and both match columns by
 * header *name* rather than position, so a sheet someone reorders, annotates
 * or builds from a Google Form keeps syncing. This holds the fetch and the
 * matching; what the rows mean is each job's own business.
 *
 * Uses the same refresh token as the Calendar and Gmail paths — it just needs
 * the extra `spreadsheets.readonly` scope (see get-refresh-token.mjs).
 */

import { accessToken } from './google_auth.js';

/**
 * Lowercase, alphanumerics only. Header matching happens on this form so
 * "E-Mail", "email" and "Email " all land on the same column, and so a Form
 * question titled "First day?" still finds `firstday`.
 */
export const squash = (s) =>
  String(s ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');

/**
 * Map header cells to column indices, given `{ field: [aliases...] }`.
 *
 * Aliases are tried in order, so list the preferred spelling first. Fields
 * with no matching header are simply absent from the result — callers decide
 * which ones are mandatory.
 */
export function mapHeader(row, columns) {
  const seen = row.map(squash);
  const index = {};
  for (const [field, aliases] of Object.entries(columns)) {
    for (const alias of aliases) {
      const at = seen.indexOf(alias);
      if (at !== -1) {
        index[field] = at;
        break;
      }
    }
  }
  return index;
}

/**
 * A trimmed cell as a string, or '' when the column is unmapped or the row is
 * too short — Sheets omits trailing empty cells, so rows are often shorter
 * than the header.
 */
export const cell = (row, at) =>
  at === undefined ? '' : String(row[at] ?? '').trim();

/** The cell as the API returned it (a number for an unformatted date), or undefined. */
export const raw = (row, at) => (at === undefined ? undefined : row[at]);

/** Rows that have something in them; a spacer row is not data. */
export const nonEmptyRows = (values) =>
  (values || []).filter((r) => r.some((c) => String(c ?? '').trim()));

/**
 * Fetch one range as rows.
 *
 * `render` is the Sheets `valueRenderOption`. FORMATTED_VALUE returns what the
 * cell displays, so "x4021" and "020 7946 0011" arrive as strings; that is
 * what a directory wants. UNFORMATTED_VALUE returns the underlying value, so a
 * date arrives as a serial number independent of the sheet's locale; that is
 * what a rota wants, where "22/09/2026" and "9/22/2026" must not be guessed at.
 */
export async function readRange(env, sheetId, range, { render = 'FORMATTED_VALUE' } = {}) {
  const token = await accessToken(env);

  const url = new URL(
    `https://sheets.googleapis.com/v4/spreadsheets/${encodeURIComponent(
      sheetId,
    )}/values/${encodeURIComponent(range)}`,
  );
  url.searchParams.set('valueRenderOption', render);
  url.searchParams.set('majorDimension', 'ROWS');

  const resp = await fetch(url, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!resp.ok) {
    throw new Error(`sheet fetch failed for ${range}: ${resp.status} ${await resp.text()}`);
  }

  const data = await resp.json();
  return data.values || [];
}
