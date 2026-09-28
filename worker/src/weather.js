/**
 * Scheduled weather sync.
 *
 * Open-Meteo needs no account and no key, so unlike the Gmail and Calendar jobs
 * this one has no auth step at all — it is a plain fetch, a flatten, and a put.
 * It still runs here rather than on the device for the usual reason: the Pi
 * polls one origin and knows nothing about where it is or who serves forecasts.
 *
 * Only two days are published. The strip beside the clock shows today and
 * tomorrow; anything more is a weather app, not ambient furniture.
 */

/**
 * WMO weather code → English text.
 *
 * Lives on the backend on purpose: rewording "Light rain" costs a Worker deploy
 * rather than an app rebuild and a 15-minute wait on the device's update timer.
 * The app gets the raw code alongside it and picks its own icon.
 */
const WMO_TEXT = {
  0: 'Clear',
  1: 'Mostly clear',
  2: 'Partly cloudy',
  3: 'Cloudy',
  45: 'Fog',
  48: 'Freezing fog',
  51: 'Light drizzle',
  53: 'Drizzle',
  55: 'Heavy drizzle',
  56: 'Freezing drizzle',
  57: 'Freezing drizzle',
  61: 'Light rain',
  63: 'Rain',
  65: 'Heavy rain',
  66: 'Freezing rain',
  67: 'Freezing rain',
  71: 'Light snow',
  73: 'Snow',
  75: 'Heavy snow',
  77: 'Snow grains',
  80: 'Showers',
  81: 'Showers',
  82: 'Heavy showers',
  85: 'Snow showers',
  86: 'Snow showers',
  95: 'Thunderstorms',
  96: 'Thunderstorms',
  99: 'Thunderstorms',
};

/** Text for a WMO code, or a blank rather than a wrong guess. */
export function wmoText(code) {
  return WMO_TEXT[code] ?? '';
}

/** Whole degrees — a wall display has no use for a decimal point. */
function round(value) {
  return typeof value === 'number' && Number.isFinite(value)
    ? Math.round(value)
    : null;
}

export async function syncWeather(env) {
  const lat = env.WEATHER_LAT;
  const lon = env.WEATHER_LON;
  // No coordinates configured is a deliberate "off", not a failure: the app
  // simply never sees a weather.json and the strip stays absent.
  if (!lat || !lon) {
    console.log('weather: WEATHER_LAT/WEATHER_LON unset — skipping');
    return 0;
  }

  const url = new URL('https://api.open-meteo.com/v1/forecast');
  url.searchParams.set('latitude', lat);
  url.searchParams.set('longitude', lon);
  // Without this Open-Meteo cuts its "days" on UTC boundaries, so on a British
  // summer evening `daily[0]` would already be tomorrow. With it, day zero is
  // today as the office experiences it.
  url.searchParams.set('timezone', env.WEATHER_TZ || 'Europe/London');
  url.searchParams.set('forecast_days', '2');
  url.searchParams.set(
    'daily',
    'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
  );

  const resp = await fetch(url);
  if (!resp.ok) {
    throw new Error(`weather fetch failed: ${resp.status} ${await resp.text()}`);
  }

  const data = await resp.json();
  const daily = data.daily || {};
  const dates = daily.time || [];

  const days = [];
  for (let i = 0; i < dates.length && i < 2; i++) {
    const code = daily.weather_code?.[i];
    const high = round(daily.temperature_2m_max?.[i]);
    const low = round(daily.temperature_2m_min?.[i]);
    // A day with no temperatures is nothing to show; drop it rather than
    // publishing a row of blanks.
    if (high === null && low === null) continue;
    days.push({
      date: dates[i],
      code: typeof code === 'number' ? code : null,
      high,
      low,
      rain: round(daily.precipitation_probability_max?.[i]),
      condition: wmoText(code),
    });
  }

  if (days.length === 0) {
    throw new Error('weather fetch returned no usable days');
  }

  const payload = {
    updated: new Date().toISOString(),
    place: env.WEATHER_PLACE || '',
    days,
  };

  await env.DASH.put('weather.json', JSON.stringify(payload, null, 2), {
    httpMetadata: { contentType: 'application/json' },
  });

  console.log(`weather synced: ${days.length} day(s) for ${payload.place || `${lat},${lon}`}`);
  return days.length;
}
