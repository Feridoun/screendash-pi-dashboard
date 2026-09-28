/**
 * Scheduled Google Sheet → rota.json sync: who is in today, and when.
 *
 * Two tabs of one spreadsheet. `Team` is the usual weekly pattern — a row per
 * doctor, a cell per weekday with their hours — and changes only when the
 * rotation does. `Leave` is the exceptions: a row per absence, study day or
 * meeting, usually arriving through a Google Form that writes straight into
 * it. This job resolves the two into one status per person per day for the
 * next ROTA_SPAN_DAYS and publishes that, so the device does no reasoning
 * about precedence, dates or timezones: it looks up today and draws the rows.
 *
 * Team tab (row 1 is a header; columns are matched by name, not position):
 *
 *   Name       | Role       | Mon         | Tue | Wed | Thu         | Fri         | From       | Until
 *   Dr A Khan  | Consultant | 08:00-18:00 |     |     | 08:00-18:00 | 08:00-18:00 |            |
 *   Dr G Brown | F1         | 09:00-17:00 | ... | ... | 09:00-17:00 | 09:00-17:00 | 2026-08-05 | 2026-12-01
 *
 * Leave tab (a Form writes a Timestamp first; it is ignored):
 *
 *   Name       | First day  | Last day   | Type         | Hours | Contact | Note
 *   Dr A Khan  | 2026-09-22 | 2026-09-26 | Annual leave |       | none    |
 *   Dr D Patel | 2026-09-18 | 2026-09-18 | Meeting      | 10-12 | phone   | Trust board
 *
 * Row order on the Team tab is row order on the wall, and the roster is
 * whatever that tab holds — eight doctors this rotation, some other number
 * the next. `From`/`Until` let the next rotation be typed in before it starts
 * and the old one lapse on its own. A weekday cell may hold a word instead of
 * hours — `WFH`, `Clinic`, `Study` — for a regular day that isn't a ward day,
 * and the wall shows the word. A Leave row with Hours is a window inside a
 * working day; without, it is the whole day, and it beats whatever the
 * pattern says. Later rows win, and a row of type `cancel` puts those dates
 * back to the usual pattern.
 */

import { cell, mapHeader, nonEmptyRows, raw, readRange, squash } from './sheets.js';
import { syncFormNames } from './forms.js';
import { alertShortStaffed, notifyBookings, recipients } from './rota_alerts.js';

const KEY = 'rota.json';

const WEEKDAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

const TEAM_COLUMNS = {
  name: ['name', 'fullname', 'doctor', 'person', 'staff'],
  role: ['role', 'grade', 'title', 'jobtitle', 'position'],
  mon: ['mon', 'monday'],
  tue: ['tue', 'tues', 'tuesday'],
  wed: ['wed', 'weds', 'wednesday'],
  thu: ['thu', 'thur', 'thurs', 'thursday'],
  fri: ['fri', 'friday'],
  sat: ['sat', 'saturday'],
  sun: ['sun', 'sunday'],
  from: ['from', 'start', 'starts', 'startdate', 'firstday', 'joins'],
  until: ['until', 'to', 'end', 'ends', 'enddate', 'lastday', 'leaves'],
  // Optional, and never published: where a staffing alert about this person's
  // leave is copied to (see rota_alerts.js).
  email: ['email', 'emailaddress', 'mail'],
};

const LEAVE_COLUMNS = {
  name: ['name', 'fullname', 'doctor', 'person', 'staff', 'who', 'whoareyou'],
  first: ['firstday', 'from', 'start', 'startdate', 'date', 'firstdate'],
  last: ['lastday', 'to', 'until', 'end', 'enddate', 'lastdate'],
  type: ['type', 'reason', 'kind', 'leavetype', 'what', 'category'],
  hours: ['hours', 'time', 'times', 'window', 'between'],
  contact: ['contact', 'contactable', 'contactableby', 'availability', 'available', 'reach'],
  note: ['note', 'notes', 'detail', 'details', 'comment', 'comments'],
};

/**
 * Kinds of exception: the words a Leave row (or a Form dropdown) may use for
 * each, the label the wall shows, and the status a whole day of it implies.
 *
 * The status is what the device colours, and there are deliberately four —
 * in / partial / away / off is all a dot can say from across a room. The
 * wording sits beside it in `label`, and lives here rather than in the app
 * for the same reason the weather text does: rewording "Study leave" is a
 * Worker deploy, not an app rebuild and a wait on the update timer.
 *
 * Order matters where words overlap: `sick` sits above `off` so "off sick"
 * reads as sick, and `cancel` is last because nothing else means it.
 */
const KINDS = [
  { kind: 'leave', label: 'Annual leave', status: 'away',
    words: ['annualleave', 'annual', 'holiday', 'hols', 'vacation', 'leave', 'al', 'hol'] },
  { kind: 'study', label: 'Study leave', status: 'away',
    words: ['studyleave', 'study', 'course', 'training', 'conference', 'exams', 'exam', 'sl'] },
  { kind: 'sick', label: 'Sick', status: 'away',
    words: ['sickleave', 'offsick', 'sick', 'unwell', 'ill'] },
  { kind: 'meeting', label: 'Meeting', status: 'partial',
    words: ['meetings', 'meeting', 'clinic', 'teaching', 'supervision', 'mtg'] },
  { kind: 'remote', label: 'Remote', status: 'partial',
    words: ['workingfromhome', 'fromhome', 'remote', 'wfh', 'home'] },
  { kind: 'off', label: 'Off', status: 'off',
    words: ['dayoff', 'notworking', 'zeroday', 'nightsoff', 'toil', 'rest', 'off'] },
  { kind: 'cancel', label: '', status: null,
    words: ['cancelled', 'canceled', 'cancel', 'delete', 'remove', 'ignore'] },
];

/**
 * Read a Type cell.
 *
 * A cell that *starts with* one of a kind's words gets that kind's label, so
 * "Annual leave (2 weeks)" shows as "Annual leave". A cell that merely
 * *contains* one gets the kind's status but keeps its own wording, so
 * "Compassionate leave" is red on the wall and says compassionate leave, not
 * annual. Anything unrecognised is treated as an absence with its text as the
 * label: a row on the Leave tab means someone is not doing their usual day,
 * whatever they called it, and hiding that is the one wrong answer.
 */
export function classify(text) {
  const s = squash(text);
  if (!s) return { kind: 'other', label: 'Away', status: 'away' };
  for (const k of KINDS) {
    for (const w of k.words) {
      if (s === w || (w.length >= 4 && s.startsWith(w))) {
        return { kind: k.kind, label: k.label, status: k.status };
      }
    }
  }
  for (const k of KINDS) {
    if (k.kind === 'cancel') continue;
    if (k.words.some((w) => w.length >= 5 && s.includes(w))) {
      return { kind: k.kind, label: tidy(text), status: k.status };
    }
  }
  return { kind: 'other', label: tidy(text), status: 'away' };
}

/** Free text as a label: one line, first letter up, short enough for a row. */
function tidy(text) {
  const t = String(text).replace(/\s+/g, ' ').trim().slice(0, 40);
  return t.charAt(0).toUpperCase() + t.slice(1);
}

/**
 * Normalise a Contact cell to the few words the wall shows. A Form checkbox
 * question returns "Phone, Email" for both ticked; free text is kept, lower
 * case, when it says something else.
 */
export function normaliseContact(text) {
  const s = squash(text);
  if (!s) return undefined;
  // Negations first: "do not call" contains "call".
  if (/^(no|none|not|un|dont|donot)/.test(s)) return 'none';
  const phone = /phone|mobile|call|bleep|tel|text/.test(s);
  const email = /mail/.test(s);
  if (phone && email) return 'phone or email';
  if (phone) return 'phone';
  if (email) return 'email';
  return String(text).replace(/\s+/g, ' ').trim().toLowerCase().slice(0, 24);
}

// --- Hours -----------------------------------------------------------------

const RANGE_RE =
  /^(\d{1,2})(?:[:.]?(\d{2}))?\s*(am|pm)?\s*(?:-|–|—|to|until)\s*(\d{1,2})(?:[:.]?(\d{2}))?\s*(am|pm)?$/;

/**
 * A time-of-day range as minutes since midnight, or null if the text isn't one.
 *
 * Accepts `8-6`, `08:00-18:00`, `0800-1800`, `8.30-17.00`, `8am-6pm`, and
 * `AM` / `PM` for a half day against [defaults]. Without am/pm, an hour of 1–6
 * is taken as afternoon and an end at or before the start rolls forward, so
 * `9-5` is 09:00–17:00 the way anyone writing a rota means it.
 */
export function parseRange(text, defaults) {
  const s = String(text ?? '').toLowerCase().replace(/\s+/g, '');
  if (!s) return null;
  if (defaults) {
    const noon = 13 * 60;
    if (s === 'am' || s === 'morning') return { start: defaults.start, end: noon };
    if (s === 'pm' || s === 'afternoon') return { start: noon, end: defaults.end };
  }
  const m = s.match(RANGE_RE);
  if (!m) return null;

  const hour = (h, meridian) => {
    let v = parseInt(h, 10);
    if (v > 24) return null;
    if (meridian === 'pm' && v < 12) v += 12;
    else if (meridian === 'am' && v === 12) v = 0;
    else if (!meridian && v >= 1 && v <= 6) v += 12;
    return v;
  };
  const sh = hour(m[1], m[3]);
  const eh = hour(m[4], m[6]);
  if (sh === null || eh === null) return null;
  const sm = parseInt(m[2] || '0', 10);
  const em = parseInt(m[5] || '0', 10);
  if (sm > 59 || em > 59) return null;

  const start = sh * 60 + sm;
  let end = eh * 60 + em;
  if (end <= start && !m[6] && eh < 12) end += 12 * 60;
  if (end <= start) return null;
  return { start, end };
}

/** Words in a pattern cell that mean "not working that day". */
const NOT_WORKING = new Set(['', '-', '–', '—', 'no', 'n', 'off', 'none', '0']);

/** Words in a pattern cell that mean "working, as usual" and nothing more. */
const AFFIRMATIVE = new Set(['y', 'yes', 'x', 'ok', 'in', 'on', 'true', 'tick', 'work', 'working']);

/**
 * Pull a time range out of a cell that has other words in it, so `WFH 9-5`
 * is hours of 9–5 with `WFH` left over. Null range when there isn't one.
 */
const INNER_RANGE_RE = new RegExp(RANGE_RE.source.slice(1, -1), 'i');
function splitRange(text, defaults) {
  const m = String(text ?? '').match(INNER_RANGE_RE);
  if (!m) return { range: null, rest: String(text ?? '') };
  const range = parseRange(m[0], defaults);
  if (!range) return { range: null, rest: String(text ?? '') };
  return { range, rest: (text.slice(0, m.index) + ' ' + text.slice(m.index + m[0].length)).trim() };
}

/**
 * A Team pattern cell: null for a day they don't work, otherwise what they
 * do — their `hours`, and a `label` and `status` when the cell said something
 * other than hours.
 *
 * A cell is usually hours (`08:00-18:00`, `AM`) or a bare `y`, and that is a
 * plain working day. But a regular Wednesday at home or in clinic is part of
 * the pattern too, and the cell can just say so: `WFH`, `Clinic 10-12`,
 * `Study`. The word is the label — shown as typed, since it is the person's
 * own description of the day — and the colour is whatever the same word would
 * mean on a Leave row; a word the vocabulary doesn't know is amber, "working,
 * read the label". `hoursGiven` says whether the hours were typed or are the
 * defaults, which decides whether the wall leads with them.
 *
 * Fails open. Anything not recognised as a range or a word — a tick, `1`, or
 * a cell Google Sheets quietly turned into a date because someone typed `8-6`
 * without setting the column to plain text — still means "working", at the
 * default hours. Being on the wall with slightly wrong hours beats being
 * missing from it.
 */
export function parsePattern(text, defaults) {
  const s = String(text ?? '').toLowerCase().replace(/\s+/g, '');
  if (NOT_WORKING.has(s)) return null;
  const whole = parseRange(s, defaults);
  if (whole) return { hours: whole, hoursGiven: true };

  const { range, rest } = splitRange(String(text ?? ''), defaults);
  const word = squash(rest);
  // No word to speak of: a tick, a number, a date serial. Working.
  if (!word || AFFIRMATIVE.has(word) || !/[a-z]{2}/.test(word)) {
    return { hours: range || defaults, hoursGiven: Boolean(range) };
  }
  const kind = classify(rest);
  if (kind.status === 'off') return null;
  if (kind.kind === 'cancel') return { hours: range || defaults, hoursGiven: Boolean(range) };
  return {
    hours: range || defaults,
    hoursGiven: Boolean(range),
    label: tidy(rest),
    status: kind.kind === 'other' ? 'partial' : kind.status,
  };
}

/** `08:00–18:00` → "8–6"; `08:30–17:00` → "8:30–5". Minutes only when they matter. */
export function hoursLabel({ start, end }) {
  const fmt = (m) => {
    let h = Math.floor(m / 60) % 24;
    const mm = m % 60;
    if (h > 12) h -= 12;
    if (h === 0) h = 12;
    return mm ? `${h}:${String(mm).padStart(2, '0')}` : `${h}`;
  };
  return `${fmt(start)}–${fmt(end)}`;
}

// --- Dates -----------------------------------------------------------------

const DAY_MS = 86400000;
// Google Sheets' epoch: a date cell is days since 1899-12-30.
const SHEETS_EPOCH_MS = Date.UTC(1899, 11, 30);
const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

const isoOf = (ms) => new Date(ms).toISOString().slice(0, 10);
const utcOf = (iso) => {
  const [y, m, d] = iso.split('-').map(Number);
  return Date.UTC(y, m - 1, d);
};
const validIso = (y, m, d) => {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const ms = Date.UTC(y, m - 1, d);
  const iso = isoOf(ms);
  // Date.UTC rolls 31 Feb into March; refuse rather than publish the wrong day.
  return iso === `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}` ? iso : null;
};

/**
 * A date cell as `YYYY-MM-DD`, or null.
 *
 * Read as UNFORMATTED_VALUE, a real date cell arrives as a serial number, which
 * is what a Form writes and what Sheets makes of anything typed that looks
 * like a date — and it carries no locale ambiguity. Text is the fallback, for
 * a cell someone forced to plain text: ISO, British day-first, or "22 Sep 2026".
 */
export function parseDate(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value > 0 ? isoOf(SHEETS_EPOCH_MS + Math.floor(value) * DAY_MS) : null;
  }
  const s = String(value ?? '').trim().toLowerCase();
  if (!s) return null;

  let m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (m) return validIso(+m[1], +m[2], +m[3]);

  m = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/);
  if (m) return validIso(m[3].length === 2 ? 2000 + +m[3] : +m[3], +m[2], +m[1]);

  m = s.match(/^(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]+)\s+(\d{4})$/);
  if (m) {
    const month = MONTHS.indexOf(m[2].slice(0, 3)) + 1;
    return month ? validIso(+m[3], month, +m[1]) : null;
  }
  return null;
}

/** The calendar date it is right now in [tz], as `YYYY-MM-DD`. */
export function localDate(now, tz) {
  // en-CA is the locale whose short date is ISO order.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now);
}

const addDays = (iso, n) => isoOf(utcOf(iso) + n * DAY_MS);
const weekdayOf = (iso) => WEEKDAYS[new Date(utcOf(iso)).getUTCDay()];

// --- Rows → roster ---------------------------------------------------------

/**
 * How a Leave row names someone is matched to the Team tab: squashed, minus
 * any bracketed suffix a Form dropdown might carry ("Dr A Khan (Consultant)")
 * and minus a leading "Dr", so "A Khan" and "Dr A Khan" are the same person.
 */
export const nameKey = (name) =>
  squash(String(name).replace(/\(.*?\)/g, '')).replace(/^dr(?=[a-z])/, '');

function parseTeam(values, defaults) {
  const rows = nonEmptyRows(values);
  if (!rows.length) return [];
  const index = mapHeader(rows[0], TEAM_COLUMNS);
  if (index.name === undefined) {
    throw new Error(`no "Name" column in the Team header row: ${JSON.stringify(rows[0])}`);
  }

  const people = [];
  for (const row of rows.slice(1)) {
    const name = cell(row, index.name);
    if (!name) continue;
    const pattern = {};
    for (const day of WEEKDAYS) {
      pattern[day] = parsePattern(cell(row, index[day]), defaults);
    }
    people.push({
      name,
      key: nameKey(name),
      role: cell(row, index.role) || undefined,
      pattern,
      from: parseDate(raw(row, index.from)),
      until: parseDate(raw(row, index.until)),
      email: cell(row, index.email) || undefined,
    });
  }
  return people;
}

function parseLeave(values, defaults) {
  const rows = nonEmptyRows(values);
  if (!rows.length) return [];
  const index = mapHeader(rows[0], LEAVE_COLUMNS);
  if (index.name === undefined || index.first === undefined) {
    // Publishing the pattern without its exceptions would put someone on the
    // wall as "in" on a day they are on leave. Better the last good rota.
    throw new Error(
      `Leave header row needs a Name and a First day column: ${JSON.stringify(rows[0])}`,
    );
  }

  const out = [];
  for (const row of rows.slice(1)) {
    const name = cell(row, index.name);
    const first = parseDate(raw(row, index.first));
    if (!name || !first) continue;
    const last = parseDate(raw(row, index.last)) || first;
    const kind = classify(cell(row, index.type));
    const note = cell(row, index.note).replace(/\s+/g, ' ').slice(0, 60) || undefined;
    out.push({
      name,
      key: nameKey(name),
      // Which submission this is, whatever else changes around it: the whole
      // row, Timestamp included, hashed. See leaveBookings.
      fp: fingerprint(row),
      first,
      last: last < first ? first : last,
      ...kind,
      // A Form's "Other" says nothing on its own; the note is where they
      // said what it was, so that is what the wall shows.
      label: kind.kind === 'other' && note ? tidy(note) : kind.label,
      // Only a real range counts as a window; "all day" or a stray "y" is the
      // whole day, which is the safer reading of an exception.
      hours: parseRange(cell(row, index.hours), defaults),
      contact: normaliseContact(cell(row, index.contact)),
      note,
    });
  }
  return out;
}

/** A short, stable hash of a row (FNV-1a, 32-bit, as hex). */
function fingerprint(row) {
  let h = 0x811c9dc5;
  for (const ch of JSON.stringify(row)) {
    h ^= ch.codePointAt(0);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

/** Drop undefined fields, so an entry in memory is exactly what gets published. */
const compact = (obj) =>
  Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));

/** One person's entry for one day, exceptions already filtered to that day. */
function statusFor(person, weekday, exceptions) {
  return compact(resolve(person, weekday, exceptions));
}

function resolve(person, weekday, exceptions) {
  const usual = person.pattern[weekday];

  // Later rows win, and a cancel voids everything before it — so a leave that
  // was called off is put back by adding a row, never by finding and deleting
  // the old one, which is the operation people get wrong.
  let ex = null;
  for (const e of exceptions) ex = e.kind === 'cancel' ? null : e;

  const base = { name: person.name, role: person.role };
  if (!ex) {
    if (!usual) return { ...base, status: 'off', label: 'Off' };
    if (!usual.label) return { ...base, status: 'in', label: hoursLabel(usual.hours) };
    // A regular day that isn't a ward day. The word is the point, so it is
    // the label — unless the cell gave hours too, in which case the shape is
    // the same as a window inside a day: hours first, and the word with the
    // hours as the detail, since that is what a narrow cell leads with.
    if (!usual.hoursGiven) return { ...base, status: usual.status, label: usual.label };
    const hours = hoursLabel(usual.hours);
    return { ...base, status: usual.status, label: hours, detail: `${usual.label} ${hours}` };
  }
  if (ex.hours) {
    // A window inside the day: on a working day they are in, with a caveat;
    // on a day off they are in for the window only. Either way the detail
    // carries the window, since that is what the card leads with.
    return {
      ...base,
      status: 'partial',
      label: hoursLabel(usual ? usual.hours : ex.hours),
      detail: `${ex.label} ${hoursLabel(ex.hours)}`,
      contact: ex.contact,
      note: ex.note,
    };
  }
  return { ...base, status: ex.status, label: ex.label, contact: ex.contact, note: ex.note };
}

/**
 * Resolve the two tabs into a day-by-day roster.
 *
 * Pure — no network, no env — so it can be reasoned about (and tested) on its
 * own. `today` is a `YYYY-MM-DD` in the office's timezone; `defaults` the
 * hours a cell means when it says only "yes".
 */
export function buildRota(teamRows, leaveRows, { today, span, defaults }) {
  const team = parseTeam(teamRows, defaults);
  const leave = parseLeave(leaveRows, defaults);

  const known = new Set(team.map((p) => p.key));
  const unmatched = [...new Set(leave.filter((l) => !known.has(l.key)).map((l) => l.name))];

  const days = [];
  for (let i = 0; i < span; i++) {
    const date = addDays(today, i);
    const weekday = weekdayOf(date);
    const people = [];
    for (const person of team) {
      if (person.from && date < person.from) continue;
      if (person.until && date > person.until) continue;
      const todays = leave.filter(
        (l) => l.key === person.key && l.first <= date && date <= l.last,
      );
      people.push(statusFor(person, weekday, todays));
    }
    days.push({ date, people });
  }

  return { days, people: team.length, unmatched };
}

/**
 * The names the leave Form's dropdown should offer: everyone on the Team tab
 * who hasn't left yet, in Team order. Someone whose `From` is still ahead is
 * in, so a new doctor can book leave before their first day; someone past
 * their `Until` is out, so the outgoing rotation drops off by itself.
 */
export function formNames(teamRows, today) {
  const names = [];
  for (const person of parseTeam(teamRows, null)) {
    if (person.until && person.until < today) continue;
    if (!names.includes(person.name)) names.push(person.name);
  }
  return names;
}

/**
 * Every Leave row as a booking to tell people about: who, what, when, plus
 * their role and email from the Team tab. `fp` identifies the row, so a
 * caller that remembers the ones it has seen can pick out what is new.
 */
export function leaveBookings(teamRows, leaveRows, defaults) {
  const team = new Map(parseTeam(teamRows, defaults).map((p) => [p.key, p]));
  return parseLeave(leaveRows, defaults).map((l) => {
    const person = team.get(l.key);
    return compact({
      fp: l.fp,
      name: person?.name || l.name,
      role: person?.role,
      email: person?.email,
      onTeam: Boolean(person),
      label: l.kind === 'cancel' ? 'Cancellation' : l.label,
      first: l.first,
      last: l.last,
      hours: l.hours ? hoursLabel(l.hours) : undefined,
      contact: l.contact,
      note: l.note,
    });
  });
}

/** The furthest ahead a staffing check looks, however far off the leave is. */
const CHECK_HORIZON_DAYS = 366;

/**
 * Days when more than [limit] doctors are away for the whole of a day they'd
 * normally work, not counting anyone whose role matches [exclude].
 *
 * "Away" is what the wall would show red: a whole-day Leave row (annual,
 * study, sick, or anything unrecognised) over a working day. A meeting or a
 * window of hours doesn't count, since they're in for the rest of it, and
 * neither does a day that isn't one of theirs anyway: a part-timer's Tuesday
 * off was already planned around. Looks from [today] to the last day any
 * Leave row covers, because leave is booked months ahead and that is when a
 * clash is worth knowing about.
 *
 * Pure, like buildRota. Returns `[{ date, away: [{ name, key, role, email,
 * label, booked }] }]`, earliest first; `booked` is the Leave row's position.
 */
export function findShortStaffed(teamRows, leaveRows, { today, defaults, limit, exclude = [] }) {
  const excluded = exclude.map(squash).filter(Boolean);
  const team = parseTeam(teamRows, defaults).filter(
    (p) => !excluded.some((word) => squash(p.role).includes(word)),
  );
  const leave = parseLeave(leaveRows, defaults);

  const lastLeave = leave.reduce((max, l) => (l.last > max ? l.last : max), today);
  const end = [lastLeave, addDays(today, CHECK_HORIZON_DAYS)].sort()[0];

  const out = [];
  for (let date = today; date <= end; date = addDays(date, 1)) {
    const weekday = weekdayOf(date);
    const away = [];
    for (const person of team) {
      if (person.from && date < person.from) continue;
      if (person.until && date > person.until) continue;
      if (!person.pattern[weekday]) continue;
      const todays = leave.filter((l) => l.key === person.key && l.first <= date && date <= l.last);
      if (!todays.length) continue;
      const entry = resolve(person, weekday, todays);
      if (entry.status !== 'away') continue;
      away.push({
        name: person.name, key: person.key, role: person.role, email: person.email, label: entry.label,
        // Row order is booking order on a Form's responses tab, so this says
        // whose booking came last — whose tipped the day over.
        booked: leave.indexOf(todays[todays.length - 1]),
      });
    }
    if (away.length > limit) out.push({ date, away });
  }
  return out;
}

/** The days currently published, or null if there's nothing readable in R2. */
async function publishedDays(env) {
  try {
    const object = await env.DASH.get(KEY);
    if (!object) return null;
    const json = await object.json();
    return json.days ?? null;
  } catch (err) {
    console.log(`rota: existing ${KEY} unreadable (${err})`);
    return null;
  }
}

export async function syncRota(env) {
  const sheetId = env.ROTA_SHEET_ID;
  if (!sheetId) {
    // Not an error: a deployment without a rota simply never publishes one,
    // and the app shows its placeholder.
    console.log('rota: ROTA_SHEET_ID not set, skipping');
    return { skipped: 'ROTA_SHEET_ID not set' };
  }
  const teamRange = env.ROTA_TEAM_RANGE || 'Team!A:J';
  const leaveRange = env.ROTA_LEAVE_RANGE ?? 'Leave!A:J';
  // The exceptions may live in a second spreadsheet — a Form's own response
  // sheet, or a Leave sheet someone made separately. Same spreadsheet by default.
  const leaveSheetId = env.ROTA_LEAVE_SHEET_ID || sheetId;
  const span = parseInt(env.ROTA_SPAN_DAYS || '14', 10);
  const defaults = parseRange(env.ROTA_DEFAULT_HOURS || '08:00-18:00') || {
    start: 8 * 60,
    end: 18 * 60,
  };

  // UNFORMATTED_VALUE so dates come as serial numbers rather than as whatever
  // the sheet's locale prints — see sheets.js.
  const render = 'UNFORMATTED_VALUE';
  const teamRows = await readRange(env, sheetId, teamRange, { render });
  // An empty ROTA_LEAVE_RANGE means "no exceptions tab yet": pattern only.
  const leaveRows = leaveRange ? await readRange(env, leaveSheetId, leaveRange, { render }) : [];

  const today = localDate(new Date(), env.ROTA_TZ || 'Europe/London');
  const { days, people, unmatched } = buildRota(teamRows, leaveRows, { today, span, defaults });

  for (const name of unmatched) {
    console.log(`rota: Leave row for "${name}" matches nobody on the Team tab — ignored`);
  }

  // Neither of these touches rota.json, and each fails on its own: a Form the
  // token can't edit, or a mail that won't send, must not keep the wall stale.
  try {
    await syncFormNames(env, formNames(teamRows, today));
  } catch (err) {
    console.log(`rota: Form name sync failed: ${err}`);
  }
  const to = await recipients(env);
  try {
    const limit = parseInt(env.ROTA_ALERT_LIMIT || '3', 10);
    const exclude = (env.ROTA_ALERT_EXCLUDE_ROLES ?? 'consultant').split(',').map((r) => r.trim()).filter(Boolean);
    const short = findShortStaffed(teamRows, leaveRows, { today, defaults, limit, exclude });
    await alertShortStaffed(env, short, { limit, exclude, to });
  } catch (err) {
    console.log(`rota: staffing check failed: ${err}`);
  }
  try {
    await notifyBookings(env, leaveBookings(teamRows, leaveRows, defaults), { to });
  } catch (err) {
    console.log(`rota: booking notice failed: ${err}`);
  }

  // Refuse to publish an empty roster, for the same reason the directory does:
  // a renamed tab or a mid-edit clear must not take the card off the wall.
  if (!people) {
    console.log(`rota: Team tab yielded nobody for range ${teamRange}, keeping existing`);
    return { skipped: 'sheet yielded no people' };
  }

  // Write only when the content differs. The window rolls forward once a day,
  // so this still rewrites daily; it just stops the other 95 ticks rotating
  // the ETag for nothing.
  const current = await publishedDays(env);
  if (current && JSON.stringify(current) === JSON.stringify(days)) {
    console.log(`rota: unchanged (${people} people over ${span} days)`);
    return { changed: false, people, days: span };
  }

  const payload = { updated: new Date().toISOString(), days };
  await env.DASH.put(KEY, JSON.stringify(payload, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });

  console.log(`rota synced: ${people} people over ${span} days from ${today}`);
  return { changed: true, people, days: span };
}
