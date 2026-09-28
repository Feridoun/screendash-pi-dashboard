/**
 * cleanText is the one function standing between a mail client's signature
 * block and the wall. Each case here is a body shape a real client produces;
 * when a new one leaks onto the banner, add it as a case before fixing it.
 *
 * Run with `npm test` in worker/.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanText, parseAccent } from '../src/motd.js';

const CRLF = '\r\n';
const lines = (...ls) => ls.join(CRLF) + CRLF;

test('a signature below a blank line is dropped (Outlook / Exchange desktop)', () => {
  const body = lines(
    'Coffee machine is fixed',
    '',
    'Kind regards',
    '',
    'Jane Smith | Ward Manager',
    'Northern Regional Services',
    'Tel: 01322 428100',
  );
  assert.equal(cleanText(body), 'Coffee machine is fixed');
});

test('a hand-typed sign-off with no blank line in front is dropped', () => {
  assert.equal(cleanText(lines('Coffee machine is fixed', 'Kind regards', 'Jane')), 'Coffee machine is fixed');
  assert.equal(cleanText(lines('Coffee machine is fixed', 'Thanks,', 'Jane')), 'Coffee machine is fixed');
  assert.equal(cleanText(lines('Coffee machine is fixed', 'Many thanks', 'Jane')), 'Coffee machine is fixed');
});

test('a sign-off word inside prose is not a sign-off', () => {
  assert.equal(cleanText(lines('Thanks to Dave for fixing the boiler', '', 'Jane')), 'Thanks to Dave for fixing the boiler');
});

test('a message that is only a sign-off still posts', () => {
  assert.equal(cleanText(lines('Thanks!', '', 'Jane')), 'Thanks!');
});

test('Outlook mobile and phone footers are dropped', () => {
  assert.equal(
    cleanText(lines('Coffee machine is fixed', '', 'Get Outlook for iOS<https://aka.ms/o0ukef>')),
    'Coffee machine is fixed',
  );
  assert.equal(cleanText(lines('Coffee machine is fixed', '', 'Sent from my iPhone')), 'Coffee machine is fixed');
});

test('an empty body that is only a footer reads as empty (clears the banner)', () => {
  assert.equal(cleanText(lines('', 'Get Outlook for iOS<https://aka.ms/o0ukef>')), '');
  assert.equal(cleanText(lines('', 'Sent from my iPhone')), '');
  assert.equal(cleanText(''), '');
});

test('a hard-wrapped sentence is one paragraph, not two notices', () => {
  const body = lines(
    'The lift on the east wing is out of order until Thursday, please use the',
    'stairs or the west wing lift if you need to move equipment.',
    '',
    'Thanks',
    'Jane',
  );
  assert.equal(
    cleanText(body),
    'The lift on the east wing is out of order until Thursday, please use the\n'
      + 'stairs or the west wing lift if you need to move equipment.',
  );
});

test('leading blank lines do not read as an empty first paragraph', () => {
  assert.equal(cleanText(lines('', '', 'Coffee machine is fixed', '', 'Jane')), 'Coffee machine is fixed');
});

test('a line of NBSP is a blank line (Outlook HTML empty paragraph)', () => {
  assert.equal(cleanText(lines('Coffee machine is fixed', '\u00a0', 'Jane Smith')), 'Coffee machine is fixed');
});

test('the accent line is removed wherever it sits, without splitting the notice', () => {
  assert.equal(cleanText(lines('#accent=#E8A33D', 'Fire drill 2pm', '', 'Jane')), 'Fire drill 2pm');
  assert.equal(cleanText(lines('Fire drill 2pm', '#accent=#E8A33D', 'East wing only', '', 'Jane')), 'Fire drill 2pm\nEast wing only');
  assert.equal(cleanText(lines('Fire drill 2pm', '', '#accent=#E8A33D', '', 'Jane')), 'Fire drill 2pm');
  // Mid-line was never documented, but it used to work and costs nothing to keep.
  assert.equal(cleanText('Fire drill 2pm #accent=#E8A33D'), 'Fire drill 2pm');
});

test('parseAccent still reads the directive off the raw body', () => {
  assert.equal(parseAccent(lines('Fire drill 2pm', '', '#accent=#e8a33d', '', 'Jane')), '#E8A33D');
  assert.equal(parseAccent('Fire drill 2pm'), null);
});

test('the older tail markers still apply', () => {
  assert.equal(cleanText(lines('delete', '', 'On Mon, 8 Sep 2026 at 10:00, Jane <j@yourteam.dev> wrote:', '> photos')), 'delete');
  assert.equal(cleanText(lines('2', '', 'From: Jane Smith <j@yourteam.dev>', 'Sent: Monday')), '2');
  assert.equal(cleanText(lines('Coffee machine is fixed', '-- ', 'Jane')), 'Coffee machine is fixed');
});

test('a multi-line notice with no blank line survives intact', () => {
  assert.equal(cleanText(lines('Fire drill today:', '- 10am east wing', '- 2pm west wing')), 'Fire drill today:\n- 10am east wing\n- 2pm west wing');
});
