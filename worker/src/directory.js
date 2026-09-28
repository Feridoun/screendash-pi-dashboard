/**
 * Scheduled Google Sheet → directory.json sync.
 *
 * The directory is the one artifact with no email flow: it changes a few times a
 * year and is easier to maintain as a spreadsheet than as a JSON file someone has
 * to hand-edit and re-upload. This reads a single flat tab and writes the same
 * grouped shape the app has always consumed, so nothing on the device changes.
 *
 * Sheet layout (row 1 is a header; columns are matched by name, not position):
 *
 *   Group        | Name       | Role      | Phone | Email
 *   Engineering  | Priya Shah | Eng Lead  | x4021 | priya@yourteam.dev
 *   Engineering  | Sam Cole   | Backend   | x4022 | sam@yourteam.dev
 *   Operations   | Front Desk |           | x4000 | reception@yourteam.dev
 *
 * The fetch and the header matching are shared with the rota sync (sheets.js).
 */

import { cell, mapHeader, nonEmptyRows, readRange } from './sheets.js';

const KEY = 'directory.json';

/**
 * Accepted header spellings, in the order we prefer them. Matching is done on a
 * squashed form (lowercase, alphanumerics only) so "E-Mail", "email" and "Email "
 * all land on the same column, and so someone can reorder or add columns without
 * breaking the sync.
 */
const COLUMNS = {
  group: ['group', 'team', 'department', 'dept', 'section'],
  name: ['name', 'fullname', 'person', 'staff'],
  role: ['role', 'title', 'jobtitle', 'position'],
  phone: ['phone', 'ext', 'extension', 'telephone', 'tel', 'number', 'contact'],
  email: ['email', 'mail'],
};

/**
 * Turn the sheet's raw rows into the app's grouped shape.
 *
 * Pure — no network, no env — so it can be reasoned about (and tested) on its own.
 * Group order follows first appearance in the sheet, which is what the app renders:
 * DirectoryController preserves backend order rather than sorting.
 */
export function rowsToGroups(values) {
  const rows = nonEmptyRows(values);
  if (!rows.length) return [];

  const index = mapHeader(rows[0], COLUMNS);
  if (index.name === undefined) {
    // A missing Name column means the range points somewhere unexpected — a
    // renamed tab, or data that starts below a title row. Fail loudly rather
    // than quietly publishing nothing.
    throw new Error(
      `no "Name" column in the header row: ${JSON.stringify(rows[0])}`,
    );
  }

  const groups = new Map(); // name -> people[], insertion-ordered
  let lastGroup = '';

  for (const row of rows.slice(1)) {
    const name = cell(row, index.name);
    if (!name) continue; // spacer row, or a stray note in another column

    // A blank Group cell inherits the row above: people habitually write the
    // group once at the top of a block. Only the very first rows can be
    // orphaned, and those land in a clearly-named catch-all.
    const group = cell(row, index.group) || lastGroup || 'Directory';
    lastGroup = group;

    if (!groups.has(group)) groups.set(group, []);
    groups.get(group).push({
      name,
      // undefined (not '') so JSON.stringify drops the key entirely — the model
      // treats a missing field as null and hides that line.
      role: cell(row, index.role) || undefined,
      phone: cell(row, index.phone) || undefined,
      email: cell(row, index.email) || undefined,
    });
  }

  return [...groups].map(([name, people]) => ({ name, people }));
}

/** The groups currently published, or null if there's nothing readable in R2. */
async function publishedGroups(env) {
  try {
    const object = await env.DASH.get(KEY);
    if (!object) return null;
    const json = await object.json();
    return json.groups ?? null;
  } catch (err) {
    console.log(`directory: existing ${KEY} unreadable (${err})`);
    return null;
  }
}

export async function syncDirectory(env) {
  const sheetId = env.DIRECTORY_SHEET_ID;
  if (!sheetId) {
    // Not an error: a deployment that hasn't set up the sheet yet keeps whatever
    // directory.json was uploaded by hand.
    console.log('directory: DIRECTORY_SHEET_ID not set, skipping');
    return { skipped: 'DIRECTORY_SHEET_ID not set' };
  }
  const range = env.DIRECTORY_SHEET_RANGE || 'Directory!A:E';

  // FORMATTED_VALUE is the default, but it is load-bearing here: it returns what
  // the cell displays, so extensions like "x4021" and numbers like "020 7946 0011"
  // arrive as strings instead of being coerced into floats.
  const values = await readRange(env, sheetId, range, { render: 'FORMATTED_VALUE' });
  const groups = rowsToGroups(values);
  const people = groups.reduce((n, g) => n + g.people.length, 0);

  // Refuse to publish an empty directory. A wrong range, a renamed tab or a sheet
  // someone cleared mid-edit would otherwise wipe the directory off the wall; the
  // last good copy is far better than a blank column.
  if (!people) {
    console.log(`directory: sheet yielded no people for range ${range}, keeping existing`);
    return { skipped: 'sheet yielded no people' };
  }

  // Write only when the content actually differs. Re-putting an identical file
  // would rotate the R2 ETag and make every device re-download on its next poll,
  // and would move `updated` on a day nothing changed.
  const current = await publishedGroups(env);
  if (current && JSON.stringify(current) === JSON.stringify(groups)) {
    console.log(`directory: unchanged (${people} people in ${groups.length} groups)`);
    return { changed: false, groups: groups.length, people };
  }

  const payload = { updated: new Date().toISOString(), groups };
  await env.DASH.put(KEY, JSON.stringify(payload, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });

  console.log(`directory synced: ${people} people in ${groups.length} groups`);
  return { changed: true, groups: groups.length, people };
}
