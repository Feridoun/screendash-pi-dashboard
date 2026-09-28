/**
 * buildRota turns two sheet tabs into what the wall says about each doctor
 * each day. Every rule that decides a row's colour or wording is pinned here,
 * because the failure mode is a doctor shown as "in" on a day they are on
 * leave — and nobody at the wall can tell that from the truth.
 *
 * Run with `npm test` in worker/.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildRota,
  classify,
  findShortStaffed,
  formNames,
  leaveBookings,
  hoursLabel,
  localDate,
  normaliseContact,
  parseDate,
  parsePattern,
  parseRange,
} from '../src/rota.js';

const DEFAULTS = { start: 8 * 60, end: 18 * 60 };

/** Google Sheets serial for an ISO date (days since 1899-12-30). */
const serial = (iso) => (Date.UTC(...iso.split('-').map((n, i) => (i === 1 ? +n - 1 : +n))) - Date.UTC(1899, 11, 30)) / 86400000;

// Thursday 17 Sep 2026; the fortnight runs to Wed 30 Sep.
const TODAY = '2026-09-17';

const TEAM_HEADER = ['Name', 'Role', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'From', 'Until'];
const LEAVE_HEADER = ['Timestamp', 'Name', 'First day', 'Last day', 'Type', 'Hours', 'Contact', 'Note'];

const team = (...rows) => [TEAM_HEADER, ...rows];
const leave = (...rows) => [LEAVE_HEADER, ...rows.map((r) => ['2026-09-01 09:00', ...r])];

const build = (teamRows, leaveRows = [LEAVE_HEADER], span = 14) =>
  buildRota(teamRows, leaveRows, { today: TODAY, span, defaults: DEFAULTS });

/** The entry for [name] on [date]. */
const on = (rota, date, name) => {
  const day = rota.days.find((d) => d.date === date);
  assert.ok(day, `no day ${date} published`);
  return day.people.find((p) => p.name === name);
};

// --- The usual pattern ------------------------------------------------------

test('a pattern cell means in, a blank means off, and hours are shown short', () => {
  const rota = build(team(['Dr A Khan', 'Consultant', '08:00-18:00', '', '', '08:00-18:00', '08:00-18:00']));
  assert.deepEqual(on(rota, '2026-09-17', 'Dr A Khan'), {
    name: 'Dr A Khan', role: 'Consultant', status: 'in', label: '8–6',
  });
  assert.deepEqual(on(rota, '2026-09-22', 'Dr A Khan'), { // Tuesday
    name: 'Dr A Khan', role: 'Consultant', status: 'off', label: 'Off',
  });
});

test('a word in a pattern cell is what the wall says for that day', () => {
  const rota = build(team(['Dr C Lee', 'Higher Resident', 'y', 'WFH', 'Clinic 10-12', 'y', 'Study']));
  assert.deepEqual(on(rota, '2026-09-22', 'Dr C Lee'), { // Tuesday
    name: 'Dr C Lee', role: 'Higher Resident', status: 'partial', label: 'WFH',
  });
  assert.deepEqual(on(rota, '2026-09-23', 'Dr C Lee'), { // Wednesday: hours lead, the word is the detail
    name: 'Dr C Lee', role: 'Higher Resident', status: 'partial', label: '10–12', detail: 'Clinic 10–12',
  });
  assert.deepEqual(on(rota, '2026-09-18', 'Dr C Lee'), { // Friday
    name: 'Dr C Lee', role: 'Higher Resident', status: 'away', label: 'Study',
  });
});

test('a Leave row beats the word in the pattern cell', () => {
  const rota = build(
    team(['Dr C Lee', 'Higher Resident', 'y', 'WFH', 'y', 'y', 'y']),
    leave(
      ['Dr C Lee', serial('2026-09-22'), '', 'Annual leave', '', 'None', ''],
      ['Dr C Lee', serial('2026-09-29'), '', 'Meeting', '10-12', 'Phone', ''],
    ),
  );
  assert.deepEqual(on(rota, '2026-09-22', 'Dr C Lee'), {
    name: 'Dr C Lee', role: 'Higher Resident', status: 'away', label: 'Annual leave', contact: 'none',
  });
  // A window on a WFH day: the day's hours, the window as the caveat.
  assert.deepEqual(on(rota, '2026-09-29', 'Dr C Lee'), {
    name: 'Dr C Lee', role: 'Higher Resident', status: 'partial',
    label: '8–6', detail: 'Meeting 10–12', contact: 'phone',
  });
});

test('publishes exactly span days starting today, weekends included', () => {
  const rota = build(team(['Dr A Khan', 'Consultant', 'y', 'y', 'y', 'y', 'y']));
  assert.equal(rota.days.length, 14);
  assert.equal(rota.days[0].date, '2026-09-17');
  assert.equal(rota.days[13].date, '2026-09-30');
  // Saturday 19th: no Sat column, so off.
  assert.equal(on(rota, '2026-09-19', 'Dr A Khan').status, 'off');
});

test('row order on the Team tab is row order on the wall, whatever the count', () => {
  const rota = build(team(
    ['Dr One', 'Consultant', 'y'],
    ['Dr Two', 'Consultant', 'y'],
    ['Dr Three', 'Higher Resident', 'y'],
    ['Dr Four', 'Specialty Doctor', 'y'],
    ['Dr Five', 'Core Resident', 'y'],
    ['Dr Six', 'Core Resident', 'y'],
    ['Dr Seven', 'F1', 'y'],
    ['Dr Eight', 'F1', 'y'],
    ['Dr Nine', 'F1', 'y'],
  ));
  assert.equal(rota.people, 9);
  assert.deepEqual(
    rota.days[0].people.map((p) => p.name),
    ['Dr One', 'Dr Two', 'Dr Three', 'Dr Four', 'Dr Five', 'Dr Six', 'Dr Seven', 'Dr Eight', 'Dr Nine'],
  );
});

test('From / Until bring a rotation in and let the old one lapse', () => {
  const rota = build(team(
    ['Dr Old', 'F1', 'y', 'y', 'y', 'y', 'y', '', serial('2026-09-20')],
    ['Dr New', 'F1', 'y', 'y', 'y', 'y', 'y', serial('2026-09-21'), ''],
  ));
  assert.ok(on(rota, '2026-09-18', 'Dr Old'));
  assert.equal(on(rota, '2026-09-18', 'Dr New'), undefined);
  assert.equal(on(rota, '2026-09-21', 'Dr Old'), undefined);
  assert.ok(on(rota, '2026-09-21', 'Dr New'));
});

test('a row with no name is skipped; a header with no Name column throws', () => {
  const rota = build(team(['', 'Consultant', 'y'], ['Dr A Khan', 'Consultant', 'y']));
  assert.equal(rota.people, 1);
  assert.throws(
    () => build([['Doctor name', 'Grade', 'Mon'], ['Dr A Khan', 'Consultant', 'y']]),
    /no "Name" column/,
  );
});

// --- Exceptions -------------------------------------------------------------

test('a whole-day leave row overrides the pattern and carries the contact', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y', 'y', 'y', 'y', 'y']),
    leave(['Dr A Khan', serial('2026-09-21'), serial('2026-09-25'), 'Annual leave', '', 'None', '']),
  );
  assert.deepEqual(on(rota, '2026-09-23', 'Dr A Khan'), {
    name: 'Dr A Khan', role: 'Consultant', status: 'away', label: 'Annual leave', contact: 'none',
  });
  // Outside the range the pattern is untouched.
  assert.equal(on(rota, '2026-09-18', 'Dr A Khan').status, 'in');
  assert.equal(on(rota, '2026-09-28', 'Dr A Khan').status, 'in');
});

test('a leave row spanning a non-working day still shows the leave', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y', '', 'y', 'y', 'y']),
    leave(['Dr A Khan', serial('2026-09-21'), serial('2026-09-25'), 'Study leave', '', 'email', 'MRCPsych']),
  );
  const tue = on(rota, '2026-09-22', 'Dr A Khan');
  assert.equal(tue.status, 'away');
  assert.equal(tue.label, 'Study leave');
  assert.equal(tue.contact, 'email');
  assert.equal(tue.note, 'MRCPsych');
});

test('a window inside a working day keeps them in, with the caveat as detail', () => {
  const rota = build(
    team(['Dr D Patel', 'Specialty Doctor', 'y', 'y', 'y', 'y', 'y']),
    leave(['Dr D Patel', serial('2026-09-17'), '', 'Meeting', '10-12', 'Phone', 'Trust board']),
  );
  assert.deepEqual(on(rota, '2026-09-17', 'Dr D Patel'), {
    name: 'Dr D Patel', role: 'Specialty Doctor', status: 'partial',
    label: '8–6', detail: 'Meeting 10–12', contact: 'phone', note: 'Trust board',
  });
});

test('a window on a day off means in for the window only', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y', '', 'y', 'y', 'y']),
    leave(['Dr A Khan', serial('2026-09-22'), serial('2026-09-22'), 'Clinic', 'PM', '', '']),
  );
  assert.deepEqual(on(rota, '2026-09-22', 'Dr A Khan'), {
    name: 'Dr A Khan', role: 'Consultant', status: 'partial', label: '1–6', detail: 'Meeting 1–6',
  });
});

test('a blank Last day is a single day', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y', 'y', 'y', 'y', 'y']),
    leave(['Dr A Khan', serial('2026-09-18'), '', 'Sick', '', '', '']),
  );
  assert.equal(on(rota, '2026-09-18', 'Dr A Khan').label, 'Sick');
  assert.equal(on(rota, '2026-09-21', 'Dr A Khan').status, 'in');
});

test('later rows win, and a cancel row puts the pattern back', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y', 'y', 'y', 'y', 'y']),
    leave(
      ['Dr A Khan', serial('2026-09-21'), serial('2026-09-25'), 'Annual leave', '', '', ''],
      ['Dr A Khan', serial('2026-09-23'), serial('2026-09-23'), 'Meeting', '', 'phone', ''],
      ['Dr A Khan', serial('2026-09-25'), serial('2026-09-25'), 'Cancel', '', '', ''],
    ),
  );
  assert.equal(on(rota, '2026-09-22', 'Dr A Khan').label, 'Annual leave');
  assert.equal(on(rota, '2026-09-23', 'Dr A Khan').label, 'Meeting');
  assert.equal(on(rota, '2026-09-25', 'Dr A Khan').status, 'in');
});

test('names match loosely: no "Dr", no bracketed role, any spacing', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y', 'y', 'y', 'y', 'y']),
    leave(['A. Khan (Consultant)', serial('2026-09-18'), '', 'AL', '', '', '']),
  );
  assert.equal(on(rota, '2026-09-18', 'Dr A Khan').label, 'Annual leave');
  assert.deepEqual(rota.unmatched, []);
});

test('a leave row for nobody on the Team tab is reported, not published', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y']),
    leave(['Dr Nobody', serial('2026-09-18'), '', 'AL', '', '', '']),
  );
  assert.deepEqual(rota.unmatched, ['Dr Nobody']);
  assert.equal(rota.days[0].people.length, 1);
});

test('an unreadable Leave header throws rather than publishing the pattern alone', () => {
  assert.throws(
    () => build(team(['Dr A Khan', 'Consultant', 'y']), [['Who', 'When'], ['Dr A Khan', 'tomorrow']]),
    /Leave header row/,
  );
});

test('an empty Leave tab (header only, or nothing at all) is just no exceptions', () => {
  const daily = team(['Dr A Khan', 'Consultant', 'y', 'y', 'y', 'y', 'y']);
  assert.equal(build(daily, [LEAVE_HEADER]).days[0].people[0].status, 'in');
  assert.equal(build(daily, []).days[0].people[0].status, 'in');
});

// --- Vocabulary -------------------------------------------------------------

test('classify: the words people actually type', () => {
  const kind = (t) => classify(t).kind;
  assert.equal(kind('Annual leave'), 'leave');
  assert.equal(kind('AL'), 'leave');
  assert.equal(kind('Holiday'), 'leave');
  assert.equal(kind('Study leave'), 'study');
  assert.equal(kind('SL'), 'study');
  assert.equal(kind('Course'), 'study');
  assert.equal(kind('Sick'), 'sick');
  assert.equal(kind('Off sick'), 'sick');
  assert.equal(kind('Meeting - trust board'), 'meeting');
  assert.equal(kind('WFH'), 'remote');
  assert.equal(kind('Working from home'), 'remote');
  assert.equal(kind('Day off'), 'off');
  assert.equal(kind('TOIL'), 'off');
  assert.equal(kind('Cancel'), 'cancel');
  assert.equal(kind('Cancelled'), 'cancel');
});

test('classify: a leave it has no word for keeps its own wording, and is still an absence', () => {
  assert.deepEqual(classify('Compassionate leave'), { kind: 'leave', label: 'Compassionate leave', status: 'away' });
  assert.deepEqual(classify('Jury service'), { kind: 'other', label: 'Jury service', status: 'away' });
  assert.deepEqual(classify(''), { kind: 'other', label: 'Away', status: 'away' });
});

test('a Type of "Other" takes its label from the note', () => {
  const rota = build(
    team(['Dr A Khan', 'Consultant', 'y', 'y', 'y', 'y', 'y']),
    leave(
      ['Dr A Khan', serial('2026-09-18'), '', 'Other', '', '', 'Jury service'],
      ['Dr A Khan', serial('2026-09-21'), '', 'Other', '', '', ''],
    ),
  );
  assert.equal(on(rota, '2026-09-18', 'Dr A Khan').label, 'Jury service');
  assert.equal(on(rota, '2026-09-18', 'Dr A Khan').status, 'away');
  assert.equal(on(rota, '2026-09-21', 'Dr A Khan').label, 'Other');
});

test('classify: a recognised word with trailing chatter gets the clean label', () => {
  assert.equal(classify('Annual leave (2 weeks)').label, 'Annual leave');
  assert.equal(classify('meeting: ward round review').label, 'Meeting');
});

test('normaliseContact: phone / email / both / none / other', () => {
  assert.equal(normaliseContact('Phone'), 'phone');
  assert.equal(normaliseContact('Mobile'), 'phone');
  assert.equal(normaliseContact('Bleep 1234'), 'phone');
  assert.equal(normaliseContact('Email'), 'email');
  assert.equal(normaliseContact('Phone, Email'), 'phone or email');
  assert.equal(normaliseContact('None'), 'none');
  assert.equal(normaliseContact('Not contactable'), 'none');
  assert.equal(normaliseContact('Do not call'), 'none');
  assert.equal(normaliseContact('Teams'), 'teams');
  assert.equal(normaliseContact(''), undefined);
});

// --- Hours ------------------------------------------------------------------

test('parseRange: the ways a range gets written', () => {
  const r = (t) => parseRange(t, DEFAULTS);
  assert.deepEqual(r('8-6'), { start: 480, end: 1080 });
  assert.deepEqual(r('08:00-18:00'), { start: 480, end: 1080 });
  assert.deepEqual(r('0800-1800'), { start: 480, end: 1080 });
  assert.deepEqual(r('8.30-17.00'), { start: 510, end: 1020 });
  assert.deepEqual(r('8am-6pm'), { start: 480, end: 1080 });
  assert.deepEqual(r('9 to 5'), { start: 540, end: 1020 });
  assert.deepEqual(r('10-12'), { start: 600, end: 720 });
  assert.deepEqual(r('12-4'), { start: 720, end: 960 });
  assert.deepEqual(r('1-5'), { start: 780, end: 1020 });
  assert.deepEqual(r('11-1'), { start: 660, end: 780 });
  assert.deepEqual(r('AM'), { start: 480, end: 780 });
  assert.deepEqual(r('pm'), { start: 780, end: 1080 });
  assert.equal(r('all day'), null);
  assert.equal(r('y'), null);
  assert.equal(r(''), null);
});

test('parsePattern: blank or a dash is off; anything unrecognised is in at default hours', () => {
  const h = (t) => parsePattern(t, DEFAULTS);
  const usual = { hours: DEFAULTS, hoursGiven: false };
  assert.equal(h(''), null);
  assert.equal(h('-'), null);
  assert.equal(h('off'), null);
  assert.equal(h('Day off'), null);
  assert.deepEqual(h('y'), usual);
  assert.deepEqual(h('Yes'), usual);
  assert.deepEqual(h('✓'), usual);
  assert.deepEqual(h('1'), usual);
  // "8-6" typed into a cell Sheets auto-formats as a date arrives as a serial.
  assert.deepEqual(h(46000), usual);
  assert.deepEqual(h('9-5'), { hours: { start: 540, end: 1020 }, hoursGiven: true });
});

test('parsePattern: a word in the cell is the label, coloured as a Leave row would be', () => {
  const h = (t) => parsePattern(t, DEFAULTS);
  assert.deepEqual(h('WFH'), { hours: DEFAULTS, hoursGiven: false, label: 'WFH', status: 'partial' });
  assert.deepEqual(h('working from home'),
    { hours: DEFAULTS, hoursGiven: false, label: 'Working from home', status: 'partial' });
  assert.deepEqual(h('Clinic'), { hours: DEFAULTS, hoursGiven: false, label: 'Clinic', status: 'partial' });
  assert.deepEqual(h('Study'), { hours: DEFAULTS, hoursGiven: false, label: 'Study', status: 'away' });
  // A word it has no colour for is still a working day: amber, read the label.
  assert.deepEqual(h('Community'), { hours: DEFAULTS, hoursGiven: false, label: 'Community', status: 'partial' });
  // Hours alongside the word are the hours; the word stays.
  assert.deepEqual(h('WFH 9-5'),
    { hours: { start: 540, end: 1020 }, hoursGiven: true, label: 'WFH', status: 'partial' });
  assert.deepEqual(h('10:00-12:00 clinic'),
    { hours: { start: 600, end: 720 }, hoursGiven: true, label: 'Clinic', status: 'partial' });
});

test('hoursLabel drops noise, keeps minutes that matter', () => {
  assert.equal(hoursLabel({ start: 480, end: 1080 }), '8–6');
  assert.equal(hoursLabel({ start: 510, end: 1020 }), '8:30–5');
  assert.equal(hoursLabel({ start: 720, end: 960 }), '12–4');
  assert.equal(hoursLabel({ start: 540, end: 750 }), '9–12:30');
});

// --- Dates ------------------------------------------------------------------

test('parseDate: serials, ISO, British day-first, and spelled-out months', () => {
  assert.equal(parseDate(serial('2026-09-22')), '2026-09-22');
  assert.equal(parseDate(serial('2026-09-22') + 0.375), '2026-09-22'); // a datetime cell
  assert.equal(parseDate('2026-09-22'), '2026-09-22');
  assert.equal(parseDate('22/09/2026'), '2026-09-22');
  assert.equal(parseDate('22/9/26'), '2026-09-22');
  assert.equal(parseDate('22.09.2026'), '2026-09-22');
  assert.equal(parseDate('22 Sep 2026'), '2026-09-22');
  assert.equal(parseDate('22nd September 2026'), '2026-09-22');
  assert.equal(parseDate('31/02/2026'), null);
  assert.equal(parseDate('tomorrow'), null);
  assert.equal(parseDate(''), null);
  assert.equal(parseDate(undefined), null);
});

test('localDate: a summer evening in UTC is already tomorrow in London', () => {
  assert.equal(localDate(new Date('2026-06-30T23:30:00Z'), 'Europe/London'), '2026-07-01');
  assert.equal(localDate(new Date('2026-01-30T23:30:00Z'), 'Europe/London'), '2026-01-30');
});

// --- The Form's names, and staffing ----------------------------------------

test('the Form offers everyone who has not left, starters included', () => {
  const rows = team(
    ['Dr Old', 'F1', 'y', '', '', '', '', '', serial('2026-09-16')],
    ['Dr Here', 'F1', 'y'],
    ['Dr New', 'F1', 'y', '', '', '', '', serial('2026-10-05'), ''],
    ['Dr Last Day', 'F1', 'y', '', '', '', '', '', serial('2026-09-17')],
  );
  assert.deepEqual(formNames(rows, TODAY), ['Dr Here', 'Dr New', 'Dr Last Day']);
});

const WARD = team(
  ['Dr Cons', 'Consultant', 'y', 'y', 'y', 'y', 'y'],
  ['Dr A', 'Higher Resident', 'y', 'y', 'y', 'y', 'y'],
  ['Dr B', 'Core Resident', 'y', 'y', 'y', 'y', 'y'],
  ['Dr C', 'F1', 'y', 'y', 'y', 'y', 'y'],
  ['Dr D', 'F1', 'y', 'y', 'y', 'y', 'y'],
  ['Dr Part', 'F2', 'y', '', 'y', 'y', 'y'], // not Tuesdays
);
const short = (leaveRows, limit = 3) =>
  findShortStaffed(WARD, leaveRows, { today: TODAY, defaults: DEFAULTS, limit, exclude: ['consultant'] });

test('four doctors away all day is short; three is not', () => {
  const tue = serial('2026-10-06');
  const three = leave(
    ['Dr A', tue, '', 'Annual leave', '', '', ''],
    ['Dr B', tue, '', 'Study leave', '', '', ''],
    ['Dr C', tue, '', 'Sick', '', '', ''],
  );
  assert.deepEqual(short(three), []);
  const four = [...three, ['2026-09-01', 'Dr D', tue, '', 'Annual leave', '', '', '']];
  const days = short(four);
  assert.deepEqual(days.map((d) => d.date), ['2026-10-06']);
  assert.deepEqual(days[0].away.map((p) => [p.name, p.label]), [
    ['Dr A', 'Annual leave'], ['Dr B', 'Study leave'], ['Dr C', 'Sick'], ['Dr D', 'Annual leave'],
  ]);
});

test('consultants, windows of hours, cancels and days off do not count', () => {
  const tue = serial('2026-10-06');
  const days = short(leave(
    ['Dr Cons', tue, '', 'Annual leave', '', '', ''],
    ['Dr A', tue, '', 'Annual leave', '', '', ''],
    ['Dr B', tue, '', 'Meeting', '10-12', '', ''],
    ['Dr C', tue, '', 'Annual leave', '', '', ''],
    ['Dr C', tue, '', 'Cancel', '', '', ''],
    ['Dr D', tue, '', 'Annual leave', '', '', ''],
    ['Dr Part', tue, '', 'Annual leave', '', '', ''], // Tuesday is not one of theirs
  ), 1);
  assert.deepEqual(days.map((d) => d.away.map((p) => p.name)), [['Dr A', 'Dr D']]);
});

test('the check reaches as far ahead as the leave does', () => {
  const far = serial('2027-03-02');
  const days = short(leave(
    ['Dr A', far, '', 'Annual leave', '', '', ''],
    ['Dr B', far, '', 'Annual leave', '', '', ''],
  ), 1);
  assert.deepEqual(days.map((d) => d.date), ['2027-03-02']);
});

test('each Leave row is a booking, with its Team details and a stable id', () => {
  const rows = leave(['Dr C', serial('2026-10-06'), '', 'Cancel', '', '', '']);
  const [b] = leaveBookings(WARD, rows, DEFAULTS);
  assert.equal(b.name, 'Dr C');
  assert.equal(b.role, 'F1');
  assert.equal(b.label, 'Cancellation');
  assert.equal(b.first, '2026-10-06');
  assert.equal(b.fp, leaveBookings(WARD, rows, DEFAULTS)[0].fp);
  assert.notEqual(b.fp, leaveBookings(WARD, leave(['Dr C', serial('2026-10-07'), '', 'Cancel']), DEFAULTS)[0].fp);
});
