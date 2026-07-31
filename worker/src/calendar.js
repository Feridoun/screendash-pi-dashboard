/**
 * Scheduled Google Calendar sync.
 *
 * A personal Google account authorises once on a laptop; the resulting refresh
 * token lives here as a Worker secret. This cron path exchanges it for a
 * short-lived access token, reads the next CALENDAR_SPAN_DAYS of events, and
 * writes a flattened events.json the Pi can read anonymously.
 */

import { accessToken } from './google_auth.js';

/** Normalize a Google event into the app's flat shape. */
function flatten(item) {
  // All-day events use `date`; timed events use `dateTime`.
  const start = item.start?.dateTime || item.start?.date;
  const end = item.end?.dateTime || item.end?.date;
  if (!start) return null;

  // Prefer a physical location; fall back to "Online" for video-only meetings.
  let room;
  if (item.location) room = item.location;
  else if (item.hangoutLink) room = 'Online';

  return {
    title: item.summary || '(no title)',
    start: new Date(start).toISOString(),
    end: end ? new Date(end).toISOString() : undefined,
    room,
    allDay: Boolean(item.start?.date),
  };
}

export async function syncCalendar(env) {
  const span = parseInt(env.CALENDAR_SPAN_DAYS || '13', 10);
  const calendarId = encodeURIComponent(env.GOOGLE_CALENDAR_ID || 'primary');

  const now = new Date();
  const from = new Date(now);
  from.setUTCHours(0, 0, 0, 0);
  const to = new Date(from);
  to.setUTCDate(to.getUTCDate() + span);

  const token = await accessToken(env);

  const url = new URL(
    `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events`,
  );
  url.searchParams.set('timeMin', from.toISOString());
  url.searchParams.set('timeMax', to.toISOString());
  url.searchParams.set('singleEvents', 'true'); // expand recurring series
  url.searchParams.set('orderBy', 'startTime');
  url.searchParams.set('maxResults', '250');

  const resp = await fetch(url, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!resp.ok) {
    throw new Error(`calendar fetch failed: ${resp.status} ${await resp.text()}`);
  }

  const data = await resp.json();
  const events = (data.items || [])
    // Drop events the user declined — do this before mapping, while each item
    // still carries its attendee list.
    .filter((item) => {
      const self = (item.attendees || []).find((a) => a.self);
      return !self || self.responseStatus !== 'declined';
    })
    .map(flatten)
    .filter(Boolean);

  const payload = {
    updated: new Date().toISOString(),
    range: {
      from: from.toISOString().slice(0, 10),
      to: new Date(to.getTime() - 86400000).toISOString().slice(0, 10),
    },
    events,
  };

  await env.DASH.put('events.json', JSON.stringify(payload, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });

  console.log(`calendar synced: ${events.length} events over ${span} days`);
  return events.length;
}
