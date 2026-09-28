/**
 * Who gets mailed about a short-staffed day, and when. The failure modes are
 * a mail every fifteen minutes about the same day, or silence about a new
 * booking onto a day that was already short.
 *
 * Run with `npm test` in worker/.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { addressesIn, composeAlert, composeBooking, planAlerts, planBookings } from '../src/rota_alerts.js';
import { findNameItem } from '../src/forms.js';

const p = (key, extra = {}) => ({ name: `Dr ${key}`, key, role: 'F1', label: 'Annual leave', ...extra });
// Keys in booking order: the last one listed booked last.
const day = (date, ...keys) => ({ date, away: keys.map((k, booked) => p(k, { booked })) });

test('the first run records what is short and mails nobody', () => {
  const { mails, seen } = planAlerts([day('2026-10-06', 'a', 'b', 'c', 'd')], null);
  assert.deepEqual(mails, []);
  assert.deepEqual(seen, { '2026-10-06': ['a', 'b', 'c', 'd'] });
});

test('a day going short mails whoever booked last, once', () => {
  const short = [day('2026-10-06', 'a', 'b', 'c', 'd')];
  const first = planAlerts(short, { dates: {} });
  assert.deepEqual(first.mails.map((m) => m.person.key), ['d']);
  assert.deepEqual(planAlerts(short, { dates: first.seen }).mails, []);
});

test('another booking onto a short day mails just the new person, with all their days', () => {
  const state = { dates: { '2026-10-06': ['a', 'b', 'c', 'd'] } };
  const { mails } = planAlerts(
    [day('2026-10-06', 'a', 'b', 'c', 'd', 'e'), day('2026-10-07', 'b', 'c', 'd', 'e')],
    state,
  );
  assert.equal(mails.length, 1);
  assert.equal(mails[0].person.key, 'e');
  assert.deepEqual(mails[0].days.map((d) => d.date), ['2026-10-06', '2026-10-07']);
});

test('the mail names the day, everyone away, and who is new', () => {
  const { subject, text } = composeAlert(
    { person: p('e'), days: [day('2026-10-06', 'a', 'b', 'c', 'e')] },
    { limit: 3, exclude: ['consultant'], copied: false },
  );
  assert.equal(subject, 'Rota: 4 doctors away on Tue 6 Oct 2026');
  assert.match(text, /more than 3 doctors, not counting consultants,/);
  assert.match(text, /Dr e, F1: Annual leave {2}<- new/);
  assert.match(text, /no email address on the rota's Team tab/);
});

test('the Form name question is found by title, among choice questions only', () => {
  const items = [
    { title: 'Name', textItem: {} },
    { title: 'Type', questionItem: { question: { choiceQuestion: { options: [] } } } },
    { title: 'Your name?', questionItem: { question: { choiceQuestion: { options: [] } } } },
  ];
  assert.equal(findNameItem(items).index, 2);
  assert.equal(findNameItem(items.slice(0, 2)), null);
});

// --- Every booking ----------------------------------------------------------

const booking = (fp, extra = {}) => ({
  fp, name: 'Dr A Khan', role: 'Consultant', onTeam: true, label: 'Annual leave',
  first: '2026-10-06', last: '2026-10-09', ...extra,
});

test('bookings: the first run mails nothing, then each new row once', () => {
  assert.deepEqual(planBookings([booking('a')], null).mails, []);
  assert.deepEqual(planBookings([booking('a'), booking('b')], ['a']).mails.map((b) => b.fp), ['b']);
  assert.deepEqual(planBookings([booking('a'), booking('b')], ['a', 'b']).mails, []);
});

test('bookings: a flood of new rows is recorded, not mailed', () => {
  const many = Array.from({ length: 11 }, (_, i) => booking(`r${i}`));
  assert.deepEqual(planBookings(many, []), { mails: [], flood: 11 });
});

test('bookings: the mail says who, what and when', () => {
  const { subject, text } = composeBooking(booking('a', { contact: 'phone', note: 'Wedding' }));
  assert.equal(subject, 'Leave form: Dr A Khan, Annual leave, Tue 6 Oct 2026 to Fri 9 Oct 2026');
  assert.match(text, /Dr A Khan \(Consultant\) has submitted/);
  assert.match(text, /Hours: +whole day/);
  assert.match(text, /Note: +Wedding/);
  assert.doesNotMatch(text, /not on the rota's Team tab/);
});

test('the notify list is every address on the tab, header and notes skipped', () => {
  assert.deepEqual(addressesIn([
    ['Notify_list'],
    ['A.Khan@example.yourteam.dev'],
    [],
    ['b.jones@example.yourteam.dev; c.lee@example.yourteam.dev', 'office manager'],
    ['a.khan@example.yourteam.dev'],
    ['not an address @ all'],
  ]), ['a.khan@example.yourteam.dev', 'b.jones@example.yourteam.dev', 'c.lee@example.yourteam.dev']);
});
