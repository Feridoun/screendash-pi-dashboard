#!/usr/bin/env node
/**
 * One-time helper: build the rota spreadsheet (and the leave Form) that feed
 * rota.json, so nobody has to type headers, set column formats or click
 * through seven Form questions by hand.
 *
 * Run this ON YOUR LAPTOP (it opens a browser). Sign in as the dashboard's
 * Google account when it does — the spreadsheet must be owned by (or visible
 * to) the account whose refresh token the Worker holds, and signing in as it
 * is the simplest way to guarantee that. The token this script gets is used
 * once and thrown away; nothing is stored.
 *
 *   node create-rota-sheet.mjs <CLIENT_ID> <CLIENT_SECRET> [--team <csv>] [--no-form] [--title <name>]
 *   node create-rota-sheet.mjs <CLIENT_ID> <CLIENT_SECRET> --form-only --names "A,B,C"   # sheet exists already
 *   node create-rota-sheet.mjs <CLIENT_ID> <CLIENT_SECRET> --form-only --form-id <ID> --names "A,B,C"   # fill a Form made by hand
 *   node create-rota-sheet.mjs --dry-run [...]                            # print what it would build
 *
 * The client ID and secret may be left off entirely once they are in
 * worker/.dev.vars; see oauth-client.mjs.
 *
 * It creates:
 *   * a spreadsheet with a `Team` tab seeded from the CSV (default
 *     ../sample_backend/Team.csv — edit that first, or pass your own) and an
 *     empty `Leave` tab: header row frozen, the weekday columns forced to
 *     plain text (so "8-6" can never turn into the 8th of June), date columns
 *     formatted day-first, and dropdowns on Name / Type / Contact;
 *   * a Google Form with the questions the Worker's Leave columns expect,
 *     the Name dropdown mirroring the Team tab. With --form-id it fills a
 *     Form that already exists (one made in Drive and linked to a sheet,
 *     say) instead: whatever questions it has are replaced.
 *
 * Two things the APIs can't do, which it prints at the end:
 *   1. link the Form's responses to the spreadsheet (Responses → Link to
 *      Sheets — one click, and then set ROTA_LEAVE_RANGE to that tab);
 *   2. share the spreadsheet by link, if the doctors will edit Team themselves.
 *
 * Prerequisites in Google Cloud Console, on the same project as the Worker's
 * OAuth client: the Google Sheets API is already enabled; also enable the
 * **Google Forms API** (or pass --no-form). The redirect URI is the one
 * get-refresh-token.mjs registered, so nothing else to add.
 *
 * Node 18+ only; no dependencies.
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { oauthClient } from './oauth-client.mjs';

// --- Arguments ---------------------------------------------------------------

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(name);
  if (at === -1) return undefined;
  const [, value] = args.splice(at, 2);
  return value;
};
const has = (name) => {
  const at = args.indexOf(name);
  if (at === -1) return false;
  args.splice(at, 1);
  return true;
};

const noForm = has('--no-form');
const formOnly = has('--form-only');
const dryRun = has('--dry-run');
const title = flag('--title') || 'Team Rota';
const here = path.dirname(fileURLToPath(import.meta.url));
// The Form's Name dropdown: either the names on a Team CSV, or given outright
// (--form-only, when the spreadsheet already exists somewhere else).
const names = flag('--names');
// An existing Form to fill in place of creating one: the token between /d/
// and /edit in its editor URL.
const formId = flag('--form-id');
const teamCsv = flag('--team') || path.join(here, '..', 'sample_backend', 'Team.csv');
// Arguments, the environment, or worker/.dev.vars — see oauth-client.mjs.
// A dry run signs in to nothing, so it needs no credentials at all.
const { CLIENT_ID, CLIENT_SECRET } = oauthClient(args, {
  script: 'create-rota-sheet.mjs',
  optional: dryRun,
});

if (formOnly && noForm) {
  console.error('--form-only and --no-form together leave nothing to do');
  process.exit(1);
}
if (formId && noForm) {
  console.error('--form-id and --no-form together leave nothing to do');
  process.exit(1);
}

// --- The Team tab, from CSV --------------------------------------------------

/** A small CSV reader: commas, double quotes, CRLF. Enough for these files. */
function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (c === '"') {
        quoted = false;
      } else {
        cell += c;
      }
    } else if (c === '"') {
      quoted = true;
    } else if (c === ',') {
      row.push(cell);
      cell = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(cell);
      if (row.some((v) => v.trim())) rows.push(row);
      row = [];
      cell = '';
    } else {
      cell += c;
    }
  }
  row.push(cell);
  if (row.some((v) => v.trim())) rows.push(row);
  return rows;
}

let teamRows = [];
let teamHeader = [];
let doctors = [];
if (names) {
  doctors = names.split(',').map((n) => n.trim()).filter(Boolean);
} else {
  teamRows = parseCsv(fs.readFileSync(teamCsv, 'utf8'));
  if (teamRows.length < 2) {
    console.error(`${teamCsv} needs a header row and at least one doctor`);
    process.exit(1);
  }
  teamHeader = teamRows[0].map((h) => h.trim());
  const nameCol = teamHeader.findIndex((h) => h.toLowerCase() === 'name');
  if (nameCol === -1) {
    console.error(`${teamCsv} has no "Name" column in its header row`);
    process.exit(1);
  }
  doctors = teamRows.slice(1).map((r) => (r[nameCol] || '').trim()).filter(Boolean);
}
if (!doctors.length) {
  console.error('no doctors: give a Team CSV with names in it, or --names "A,B,C"');
  process.exit(1);
}
if (formOnly && !names) {
  console.error('--form-only needs --names "A,B,C" (the Form\'s Name dropdown), spelled as on the Team sheet');
  process.exit(1);
}

const LEAVE_HEADER = ['Name', 'First day', 'Last day', 'Type', 'Hours', 'Contact', 'Note'];

// The Type and Contact vocabularies, spelled the way rota.js's KINDS and
// normaliseContact() read them. Keep these in step with that file.
const TYPES = ['Annual leave', 'Study leave', 'Sick', 'Meeting', 'Working from home', 'Off', 'Cancel', 'Other'];
const CONTACTS = ['Phone', 'Email', 'Phone or email', 'None'];

// --- OAuth: a one-off access token via the browser --------------------------

const PORT = 8976;
const REDIRECT = `http://localhost:${PORT}/callback`;
const SCOPE = [
  ...(formOnly ? [] : ['https://www.googleapis.com/auth/spreadsheets']),
  ...(noForm ? [] : ['https://www.googleapis.com/auth/forms.body']),
].join(' ');

function openBrowser(url) {
  const cmd = process.platform === 'win32' ? 'cmd'
    : process.platform === 'darwin' ? 'open'
    : 'xdg-open';
  const cmdArgs = process.platform === 'win32' ? ['/c', 'start', '', url] : [url];
  spawn(cmd, cmdArgs, { detached: true, stdio: 'ignore' }).unref();
}

function authorise() {
  const authUrl = new URL('https://accounts.google.com/o/oauth2/v2/auth');
  authUrl.searchParams.set('client_id', CLIENT_ID);
  authUrl.searchParams.set('redirect_uri', REDIRECT);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('scope', SCOPE);
  // `online`: we want an access token for the next minute, not a refresh
  // token to keep. Nothing this script obtains outlives it.
  authUrl.searchParams.set('access_type', 'online');
  authUrl.searchParams.set('prompt', 'consent');

  return new Promise((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      const url = new URL(req.url, `http://localhost:${PORT}`);
      if (url.pathname !== '/callback') {
        res.writeHead(404).end('not found');
        return;
      }
      const error = url.searchParams.get('error');
      if (error) {
        res.writeHead(400, { 'content-type': 'text/plain' }).end(`Authorisation failed: ${error}`);
        server.close();
        reject(new Error(`authorisation failed: ${error}`));
        return;
      }
      const resp = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          code: url.searchParams.get('code'),
          client_id: CLIENT_ID,
          client_secret: CLIENT_SECRET,
          redirect_uri: REDIRECT,
          grant_type: 'authorization_code',
        }),
      });
      const data = await resp.json();
      if (!resp.ok || !data.access_token) {
        res.writeHead(500, { 'content-type': 'text/plain' }).end('Token exchange failed — see the terminal.');
        server.close();
        reject(new Error(`token exchange failed: ${JSON.stringify(data)}`));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/html' }).end(
        '<h2>Signed in.</h2><p>Building the rota sheet — back to the terminal. You can close this tab.</p>',
      );
      server.close();
      resolve(data.access_token);
    });
    server.listen(PORT, () => {
      console.log(`Listening on ${REDIRECT}`);
      console.log("Opening your browser — sign in as the dashboard's Google account.\n");
      console.log(`If it does not open, visit:\n${authUrl}\n`);
      openBrowser(authUrl.toString());
    });
  });
}

// --- Google API calls ---------------------------------------------------------

let token;

/** Canned answers for --dry-run, shaped like the real ones where later steps read them. */
function pretend(method, url, body) {
  console.log(`
--- ${method} ${url}`);
  console.log(JSON.stringify(body, null, 2));
  if (url.endsWith('/v4/spreadsheets')) {
    return {
      spreadsheetId: 'DRY-RUN-SHEET-ID',
      spreadsheetUrl: 'https://docs.google.com/spreadsheets/d/DRY-RUN-SHEET-ID/edit',
      sheets: body.sheets.map((s, i) => ({ properties: { title: s.properties.title, sheetId: i } })),
    };
  }
  if (url.endsWith('/v1/forms') || /\/v1\/forms\/[^:]+$/.test(url)) {
    return { formId: 'DRY-RUN-FORM-ID', responderUri: 'https://docs.google.com/forms/d/e/DRY-RUN/viewform' };
  }
  return {};
}

async function api(method, url, body) {
  if (dryRun) return pretend(method, url, body);
  const resp = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await resp.text();
  if (!resp.ok) {
    throw new Error(`${method} ${url} → ${resp.status}\n${text}`);
  }
  return text ? JSON.parse(text) : {};
}

const str = (value) => ({ userEnteredValue: { stringValue: String(value ?? '') } });
const rowOf = (cells) => ({ values: cells.map(str) });

/** Column letter → zero-based index, for ranges built from the CSV header. */
const colIndex = (header, name) =>
  header.findIndex((h) => h.trim().toLowerCase() === name.toLowerCase());

async function createSpreadsheet() {
  const created = await api('POST', 'https://sheets.googleapis.com/v4/spreadsheets', {
    properties: {
      title,
      // en_GB: dates typed by hand read day-first. The Worker reads serial
      // numbers, so this is for the humans looking at the sheet.
      locale: 'en_GB',
      timeZone: 'Europe/London',
    },
    sheets: [
      {
        properties: { title: 'Team', gridProperties: { frozenRowCount: 1 } },
        data: [{ startRow: 0, startColumn: 0, rowData: teamRows.map(rowOf) }],
      },
      {
        properties: { title: 'Leave', gridProperties: { frozenRowCount: 1 } },
        data: [{ startRow: 0, startColumn: 0, rowData: [rowOf(LEAVE_HEADER)] }],
      },
    ],
  });

  const sheetId = (name) =>
    created.sheets.find((s) => s.properties.title === name).properties.sheetId;
  const team = sheetId('Team');
  const leave = sheetId('Leave');

  const requests = [];

  // Bold, frozen headers on both tabs.
  for (const id of [team, leave]) {
    requests.push({
      repeatCell: {
        range: { sheetId: id, startRowIndex: 0, endRowIndex: 1 },
        cell: { userEnteredFormat: { textFormat: { bold: true } } },
        fields: 'userEnteredFormat.textFormat.bold',
      },
    });
  }

  // Team: weekday columns as PLAIN TEXT. This is the whole reason the sheet
  // is built by script — a hand-made sheet turns "8-6" into 8 June and the
  // Worker then shows that doctor at default hours.
  const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  for (const day of days) {
    const at = colIndex(teamHeader, day);
    if (at === -1) continue;
    requests.push({
      repeatCell: {
        range: { sheetId: team, startRowIndex: 1, startColumnIndex: at, endColumnIndex: at + 1 },
        cell: { userEnteredFormat: { numberFormat: { type: 'TEXT' } } },
        fields: 'userEnteredFormat.numberFormat',
      },
    });
  }

  // Date columns, day-first, on both tabs.
  const dateFormat = { userEnteredFormat: { numberFormat: { type: 'DATE', pattern: 'dd/mm/yyyy' } } };
  for (const name of ['from', 'until']) {
    const at = colIndex(teamHeader, name);
    if (at === -1) continue;
    requests.push({
      repeatCell: {
        range: { sheetId: team, startRowIndex: 1, startColumnIndex: at, endColumnIndex: at + 1 },
        cell: dateFormat,
        fields: 'userEnteredFormat.numberFormat',
      },
    });
  }
  requests.push({
    repeatCell: {
      range: { sheetId: leave, startRowIndex: 1, startColumnIndex: 1, endColumnIndex: 3 },
      cell: dateFormat,
      fields: 'userEnteredFormat.numberFormat',
    },
  });

  // Leave: dropdowns. Name comes from the Team tab, so a typo can't create a
  // doctor the Worker has never heard of; Type and Contact use the words
  // rota.js understands. None of them is strict — a value outside the list
  // gets a warning, not a refusal, because "Compassionate leave" is valid.
  const validation = (col, condition) => ({
    setDataValidation: {
      range: { sheetId: leave, startRowIndex: 1, endRowIndex: 500, startColumnIndex: col, endColumnIndex: col + 1 },
      rule: { condition, showCustomUi: true, strict: false },
    },
  });
  const nameRange = `=Team!$A$2:$A$200`;
  requests.push(validation(0, { type: 'ONE_OF_RANGE', values: [{ userEnteredValue: nameRange }] }));
  requests.push(validation(3, { type: 'ONE_OF_LIST', values: TYPES.map((v) => ({ userEnteredValue: v })) }));
  requests.push(validation(5, { type: 'ONE_OF_LIST', values: CONTACTS.map((v) => ({ userEnteredValue: v })) }));

  // Readable column widths.
  for (const id of [team, leave]) {
    requests.push({
      autoResizeDimensions: {
        dimensions: { sheetId: id, dimension: 'COLUMNS', startIndex: 0, endIndex: 12 },
      },
    });
  }

  await api('POST', `https://sheets.googleapis.com/v4/spreadsheets/${created.spreadsheetId}:batchUpdate`, {
    requests,
  });

  return created;
}

async function createForm() {
  const info = {
    title: `${title} — leave & availability`,
    documentTitle: `${title} form`,
  };
  const form = formId
    ? await api('GET', `https://forms.googleapis.com/v1/forms/${formId}`)
    : await api('POST', 'https://forms.googleapis.com/v1/forms', { info });

  // Question titles become the response sheet's column headers, and those
  // are what rota.js matches on — so they are spelled exactly as LEAVE_HEADER.
  const question = (index, itemTitle, description, required, q) => ({
    createItem: {
      item: {
        title: itemTitle,
        description,
        questionItem: { question: { required, ...q } },
      },
      location: { index },
    },
  });
  const dropdown = (options) => ({
    choiceQuestion: { type: 'DROP_DOWN', options: options.map((value) => ({ value })) },
  });

  const requests = [
    // A Form made by hand starts with an "Untitled Question", and one being
    // refilled has last time's. Clear them first so the response sheet's
    // headers are exactly LEAVE_HEADER; deleting from the end keeps the
    // indices of the rest valid as each goes.
    ...(form.items ?? []).map((_, i, all) => ({ deleteItem: { location: { index: all.length - 1 - i } } })),
    question(0, 'Name', 'Pick yourself.', true, dropdown(doctors)),
    question(1, 'First day', '', true, { dateQuestion: { includeYear: true, includeTime: false } }),
    question(2, 'Last day', 'Leave blank for a single day.', false, {
      dateQuestion: { includeYear: true, includeTime: false },
    }),
    question(3, 'Type', 'Other: say what in the note.', true, dropdown(TYPES)),
    question(
      4,
      'Hours',
      'Leave blank for the whole day. Only for something inside a working day, e.g. 10-12 for a meeting.',
      false,
      { textQuestion: { paragraph: false } },
    ),
    question(5, 'Contact', 'How can you be reached? Nothing ticked means not contactable.', false, {
      choiceQuestion: { type: 'CHECKBOX', options: [{ value: 'Phone' }, { value: 'Email' }] },
    }),
    question(6, 'Note', 'Optional — a word or two, e.g. Trust board, MRCPsych.', false, {
      textQuestion: { paragraph: false },
    }),
    {
      updateFormInfo: {
        info: {
          ...(formId ? { title: info.title } : {}),
          description:
            'Book leave, a study day, a meeting or a day at home. It reaches the office screen ' +
            'within about 15 minutes. To cancel, submit again with Type = Cancel.',
        },
        // The title is set at creation; an existing Form keeps its own
        // document name in Drive but gets the same heading on the page.
        updateMask: formId ? 'title,description' : 'description',
      },
    },
  ];

  await api('POST', `https://forms.googleapis.com/v1/forms/${form.formId}:batchUpdate`, { requests });
  return api('GET', `https://forms.googleapis.com/v1/forms/${form.formId}`);
}

// --- Main -----------------------------------------------------------------------

try {
  token = dryRun ? 'dry-run' : await authorise();

  const source = names ? '--names' : path.relative(process.cwd(), teamCsv);
  let sheet = null;
  if (!formOnly) {
    console.log(`\nCreating "${title}" with ${doctors.length} doctor(s) from ${source}…`);
    sheet = await createSpreadsheet();
    console.log(`✓ Spreadsheet: ${sheet.spreadsheetUrl}`);
  }

  let form = null;
  if (!noForm) {
    console.log(
      formId
        ? `\nFilling Form ${formId} with ${doctors.length} name(s) from ${source}…`
        : `\nCreating the Form with ${doctors.length} name(s) from ${source}…`,
    );
    form = await createForm();
    console.log(`✓ Form (editor): https://docs.google.com/forms/d/${form.formId}/edit`);
  }

  console.log('\nNow put this in worker/wrangler.toml and `npx wrangler deploy`:\n');
  if (sheet) console.log(`  ROTA_SHEET_ID = "${sheet.spreadsheetId}"`);
  if (form) {
    console.log(`  ROTA_LEAVE_RANGE = "Form responses 1!A:J"   # after step 1 below`);
    if (formOnly) {
      console.log('  ROTA_LEAVE_SHEET_ID = "<the spreadsheet you link the Form to, if not ROTA_SHEET_ID>"');
    }
  }
  console.log('\nBy hand — the APIs cannot do these:\n');
  let n = 1;
  if (form) {
    if (!formId) {
      console.log(`  ${n++}. Open the Form → Responses → "Link to Sheets" → Select existing spreadsheet${sheet ? ` → "${title}"` : ''}.`);
      console.log('     That adds a "Form responses 1" tab; the Worker reads it instead of Leave.');
    }
    console.log(`  ${n++}. Under Settings, check "Collect email addresses" is OFF (yourteam.dev users have no Google login).`);
    console.log(`  ${n++}. Give the doctors the form link:  ${form.responderUri}`);
  }
  if (sheet) {
    console.log(`  ${n++}. If doctors will edit the Team tab themselves: Share → "Anyone with the link" → Editor.`);
    console.log(`  ${n++}. Replace the sample names on the Team tab with the real team${form ? " (and in the Form's Name list)" : ''}.`);
  }
  console.log('\nThen:  curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $BACKEND/admin/sync-rota  and  curl $BACKEND/rota.json');
  process.exit(0);
} catch (err) {
  console.error(`\n✗ ${err.message}`);
  if (/forms\.googleapis/.test(err.message) && /403|not been used|disabled/.test(err.message)) {
    console.error(
      '\nThe Google Forms API is not enabled on this Cloud project. Enable it under\n' +
      'APIs & Services → Library, or re-run with --no-form and build the Form by hand\n' +
      '(docs/cloudflare-setup.md, step 10b).',
    );
  }
  process.exit(1);
}
