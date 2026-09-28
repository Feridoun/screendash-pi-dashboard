/**
 * Staffing alerts: mail someone when a leave booking leaves the ward short.
 *
 * rota.js works out the days when more than ROTA_ALERT_LIMIT doctors (not
 * counting the roles in ROTA_ALERT_EXCLUDE_ROLES, consultants by default) are
 * away for the whole of a day they'd normally work. This decides who hears
 * about it and when. It mails the notify list (see recipients), and the person whose booking
 * tipped the day over (the latest Leave row on it), from the dashboard's own
 * mailbox.
 *
 * Each short day is mailed about once per person who joins it, not once per
 * sync. `rota-alerts.json` in R2 (never served; see serve.js) records who was
 * already away on each short day when it was last reported, so the next
 * booking onto the same day is news and the fifteen-minute tick repeating
 * itself is not. A day that stops being short is forgotten, so if it goes
 * short again later, that is reported afresh.
 *
 * The first run with alerts switched on has nothing to compare against. It
 * records what is already short and sends nothing, so switching the feature
 * on doesn't mail about every clash booked in the past year.
 */

import { sendMail } from './gmail.js';
import { rowsToGroups } from './directory.js';
import { readRange } from './sheets.js';
import { nameKey } from './rota.js';

const STATE_KEY = 'rota-alerts.json';

const splitList = (s) => String(s || '').split(/[,;\s]+/).filter((a) => a.includes('@'));

/**
 * Every address in a block of sheet cells, lower-cased and de-duplicated. A
 * header ("Notify_list"), a stray name, or a note is skipped for having no @;
 * a cell holding several addresses is split on commas, semicolons or spaces.
 */
export function addressesIn(rows) {
  const out = [];
  for (const row of rows || []) {
    for (const c of row) {
      for (const a of splitList(c)) {
        const address = a.toLowerCase();
        if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(address) && !out.includes(address)) out.push(address);
      }
    }
  }
  return out;
}

/**
 * Who hears about bookings and short days: the Notify_list tab of the rota
 * spreadsheet (ROTA_NOTIFY_RANGE), so whoever runs the rota can change it
 * without Cloudflare access. If the tab can't be read or has no addresses in
 * it, the ROTA_ALERT_TO secret is used instead: an emptied or renamed tab
 * mustn't make notifications stop without anyone noticing. To stop them
 * entirely, clear both.
 */
export async function recipients(env) {
  const range = env.ROTA_NOTIFY_RANGE ?? 'Notify_list!A:Z';
  if (range && env.ROTA_SHEET_ID) {
    try {
      const list = addressesIn(await readRange(env, env.ROTA_SHEET_ID, range));
      if (list.length) return list;
      console.log(`rota: no addresses in ${range}, using ROTA_ALERT_TO`);
    } catch (err) {
      console.log(`rota: ${range} unreadable, using ROTA_ALERT_TO: ${err}`);
    }
  }
  return splitList(env.ROTA_ALERT_TO);
}

/**
 * Pure: what to send, given the short days and what was reported before.
 *
 * `state` is null on the first run. Returns `mails`, one per person whose
 * booking made a day short or joined one, listing each such day, plus `seen`:
 * who is on each short day now. Save `seen` once the mails have gone.
 */
export function planAlerts(short, state) {
  const seen = Object.fromEntries(short.map((d) => [d.date, d.away.map((p) => p.key)]));
  if (!state) return { mails: [], seen };

  const byPerson = new Map();
  for (const day of short) {
    // A day that has just gone short is news to whoever booked last, not to
    // everyone whose leave was already on it; a day already short is news to
    // each name that has joined it since.
    const known = state.dates?.[day.date];
    const latest = Math.max(...day.away.map((p) => p.booked ?? -1));
    const before = new Set(known || day.away.filter((p) => (p.booked ?? -1) !== latest).map((p) => p.key));
    for (const person of day.away) {
      if (before.has(person.key)) continue;
      if (!byPerson.has(person.key)) byPerson.set(person.key, { person, days: [] });
      byPerson.get(person.key).days.push(day);
    }
  }
  return { mails: [...byPerson.values()], seen };
}

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** `2026-10-06` → "Tue 6 Oct 2026". By hand: Intl's punctuation varies by runtime. */
const dayLabel = (iso) => {
  const d = new Date(`${iso}T00:00:00Z`);
  return `${DAYS[d.getUTCDay()]} ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
};

/** The mail about one person's booking, as `{ subject, text }`. */
export function composeAlert({ person, days }, { limit, exclude = [], copied }) {
  const first = days[0];
  const more = days.length > 1 ? ` (+${days.length - 1} more day${days.length > 2 ? 's' : ''})` : '';
  const subject = `Rota: ${first.away.length} doctors away on ${dayLabel(first.date)}${more}`;

  const notCounting = exclude.length ? `, not counting ${exclude.map((r) => `${r.toLowerCase()}s`).join(' or ')},` : '';
  const lines = [
    `Leave booked for ${person.name} means more than ${limit} doctors${notCounting}`,
    `are away for the whole day on ${days.length === 1 ? 'this day' : 'these days'}:`,
    '',
  ];
  for (const day of days) {
    lines.push(`${dayLabel(day.date)}: ${day.away.length} away`);
    for (const p of day.away) {
      const role = p.role ? `, ${p.role}` : '';
      lines.push(`  - ${p.name}${role}: ${p.label}${p.key === person.key ? '  <- new' : ''}`);
    }
    lines.push('');
  }
  if (!copied) {
    lines.push(`${person.name} has no email address on the rota's Team tab, so they have not been sent this.`, '');
  }
  lines.push(
    'The booking has not been refused or changed: this is a heads-up so cover can be',
    'arranged, or the leave moved. To cancel it, submit the leave form again with the',
    'same dates and Type "Cancel".',
    '',
    'Sent automatically by the ward screen. Replies go to the people copied, not the screen.',
  );
  return { subject, text: lines.join('\n') };
}

/** Name → email from the directory sheet, for doctors the Team tab has no address for. */
async function directoryEmails(env) {
  if (!env.DIRECTORY_SHEET_ID) return new Map();
  const rows = await readRange(env, env.DIRECTORY_SHEET_ID, env.DIRECTORY_SHEET_RANGE || 'Directory!A:E');
  const out = new Map();
  for (const group of rowsToGroups(rows)) {
    for (const p of group.people || []) {
      if (p.email && !out.has(nameKey(p.name))) out.set(nameKey(p.name), p.email);
    }
  }
  return out;
}

async function readState(env) {
  try {
    const object = await env.DASH.get(STATE_KEY);
    return object ? await object.json() : null;
  } catch (err) {
    // Unreadable is not the same as absent: treating it as a first run would
    // swallow real alerts. Throw, and try again next tick.
    throw new Error(`${STATE_KEY} unreadable: ${err}`);
  }
}

export async function alertShortStaffed(env, short, { limit, exclude, to: alertTo }) {
  if (!alertTo.length) return { skipped: 'nobody to notify' };

  const state = await readState(env);
  const { mails, seen } = planAlerts(short, state);

  let directory = null;
  const failed = new Set();
  for (const mail of mails) {
    let email = mail.person.email;
    if (!email) {
      directory ??= await directoryEmails(env).catch((err) => {
        console.log(`rota: directory lookup for alert emails failed: ${err}`);
        return new Map();
      });
      email = directory.get(mail.person.key);
    }
    const { subject, text } = composeAlert(mail, { limit, exclude, copied: Boolean(email) });
    try {
      await sendMail(env, {
        to: email ? [email] : alertTo,
        cc: email ? alertTo : [],
        replyTo: email ? [email, ...alertTo] : alertTo,
        subject,
        text,
      });
      console.log(`rota: staffing alert sent for ${mail.person.name} (${mail.days.map((d) => d.date).join(', ')})`);
    } catch (err) {
      console.log(`rota: staffing alert for ${mail.person.name} failed, will retry: ${err}`);
      failed.add(mail.person.key);
    }
  }

  // A mail that didn't go leaves its person out of `seen`, so the next tick
  // finds them new again and retries.
  const dates = {};
  for (const [date, keys] of Object.entries(seen)) {
    dates[date] = keys.filter((k) => !failed.has(k));
  }
  if (!state || JSON.stringify(state.dates) !== JSON.stringify(dates)) {
    await env.DASH.put(STATE_KEY, JSON.stringify({ updated: new Date().toISOString(), dates }), {
      httpMetadata: { contentType: 'application/json' },
    });
  }
  if (!state) console.log(`rota: staffing alerts on; ${short.length} short day(s) already booked, not mailed`);
  return { sent: mails.length - failed.size, failed: failed.size };
}

// --- Every booking ----------------------------------------------------------
//
// Separately from the staffing check, each new Leave row (each Form
// submission) is mailed to the notify list as it arrives, so the people who
// arrange cover see every booking without watching the sheet.
// `rota-bookings.json` holds the fingerprints of the rows already seen; a row
// whose fingerprint is new is a new submission, or an old one edited by hand,
// and either is worth a mail. Like the staffing alert, the first run records
// and sends nothing.

const BOOKINGS_KEY = 'rota-bookings.json';

/** More new rows than this at once is a sheet that was swapped or re-sorted, not bookings. */
const MAX_BOOKING_MAILS = 10;

/**
 * Pure: which bookings to mail, given the fingerprints already seen (null on
 * the first run). A flood — more than MAX_BOOKING_MAILS at once — is recorded
 * and not mailed: fifty mails because someone re-pointed the Leave range
 * would teach everyone to ignore these.
 */
export function planBookings(bookings, seen) {
  if (!seen) return { mails: [], flood: false };
  const known = new Set(seen);
  const fresh = bookings.filter((b) => !known.has(b.fp));
  if (fresh.length > MAX_BOOKING_MAILS) return { mails: [], flood: fresh.length };
  return { mails: fresh, flood: false };
}

/** The mail about one booking, as `{ subject, text }`. */
export function composeBooking(b) {
  const when = b.first === b.last ? dayLabel(b.first) : `${dayLabel(b.first)} to ${dayLabel(b.last)}`;
  const subject = `Leave form: ${b.name}, ${b.label}, ${when}`;
  const lines = [
    `${b.name}${b.role ? ` (${b.role})` : ''} has submitted the leave form.`,
    '',
    `Type:     ${b.label}`,
    `Dates:    ${when}`,
    `Hours:    ${b.hours || 'whole day'}`,
    `Contact:  ${b.contact || 'not given'}`,
  ];
  if (b.note) lines.push(`Note:     ${b.note}`);
  lines.push('');
  if (!b.onTeam) {
    lines.push(`"${b.name}" is not on the rota's Team tab, so this does not show on the screen.`, '');
  }
  lines.push('Sent automatically by the ward screen.');
  return { subject, text: lines.join('\n') };
}

export async function notifyBookings(env, bookings, { to }) {
  if (!to.length) return { skipped: 'nobody to notify' };

  let state = null;
  try {
    const object = await env.DASH.get(BOOKINGS_KEY);
    state = object ? await object.json() : null;
  } catch (err) {
    throw new Error(`${BOOKINGS_KEY} unreadable: ${err}`);
  }

  const { mails, flood } = planBookings(bookings, state?.seen ?? null);
  if (flood) console.log(`rota: ${flood} new Leave rows at once, recorded without mailing`);

  const failed = new Set();
  for (const b of mails) {
    const { subject, text } = composeBooking(b);
    try {
      await sendMail(env, { to, replyTo: b.email ? [b.email] : to, subject, text });
      console.log(`rota: booking mailed: ${subject}`);
    } catch (err) {
      console.log(`rota: booking mail for ${b.name} failed, will retry: ${err}`);
      failed.add(b.fp);
    }
  }

  const seen = bookings.map((b) => b.fp).filter((fp) => !failed.has(fp));
  if (!state || JSON.stringify(state.seen) !== JSON.stringify(seen)) {
    await env.DASH.put(BOOKINGS_KEY, JSON.stringify({ updated: new Date().toISOString(), seen }), {
      httpMetadata: { contentType: 'application/json' },
    });
  }
  if (!state) console.log(`rota: booking mails on; ${bookings.length} existing row(s) recorded, not mailed`);
  return { sent: mails.length - failed.size, failed: failed.size };
}
