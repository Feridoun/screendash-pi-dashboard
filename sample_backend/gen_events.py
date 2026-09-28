#!/usr/bin/env python3
"""Regenerate the date-sensitive sample fixtures relative to *today*.

The dashboard renders a rolling 13-day grid anchored at today, it refuses to
show a forecast whose first day isn't today, and the doctors rota only shows a
rota that covers today — so all three fixtures go stale on their own. Run this
to refresh them:

    python sample_backend/gen_events.py

Writes events.json, weather.json and rota.json.
"""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

SPAN = 13  # must match CalendarGrid.span

# (day offset from today, hour, minute, duration_min, title, room)
TEMPLATE = [
    (0,  9, 30, 15, "Daily Standup",              "Zoom"),
    (0, 14,  0, 60, "Design Review — Dashboard",  "Focus Room A"),
    (1,  9, 30, 15, "Daily Standup",              "Zoom"),
    (1, 11,  0, 30, "1:1 with Priya",             "Booth 3"),
    (2,  9, 30, 15, "Daily Standup",              "Zoom"),
    (2, 12,  0, 60, "Lunch & Learn: flutter-pi",  "Kitchen"),
    (3,  9, 30, 15, "Daily Standup",              "Zoom"),
    (4, 10,  0, 45, "Sprint Retro",               "All-Hands"),
    (6, 15,  0, 30, "Estates walkaround",         "Main Corridor"),
    (7,  9, 30, 15, "Daily Standup",              "Zoom"),
    (8, 13, 30, 60, "Safeguarding Training",      "Room 2.4"),
    (10, 9, 30, 15, "Daily Standup",              "Zoom"),
    (11, 16, 0, 45, "Quarterly Planning",         "Board Room"),
    (12, 11, 0, 30, "New starter induction",      "Reception"),
]


# Two days of plausible British weather. (WMO code, high, low, rain %).
WEATHER = [
    (3,  21, 13, 20),   # Cloudy
    (61, 18, 12, 70),   # Light rain
]

WMO_TEXT = {
    0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Cloudy",
    45: "Fog", 48: "Freezing fog",
    51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle",
    61: "Light rain", 63: "Rain", 65: "Heavy rain",
    71: "Light snow", 73: "Snow", 75: "Heavy snow",
    80: "Showers", 81: "Showers", 82: "Heavy showers",
    95: "Thunderstorms",
}


# The team, as the Team tab of the rota sheet would list them: name, role, and
# which weekdays (Mon=0) they usually work. Eight this rotation — the card takes
# however many the sheet holds.
TEAM = [
    ("Dr A Khan",   "Consultant",       {0, 3, 4}),
    ("Dr B Smith",  "Consultant",       {1, 2, 4}),
    ("Dr C Lee",    "Higher Resident",  {0, 1, 2, 3}),
    ("Dr D Patel",  "Specialty Doctor", {0, 1, 2, 3, 4}),
    ("Dr E Wong",   "Core Resident",    {0, 1, 2, 3, 4}),
    ("Dr F Ali",    "Core Resident",    {0, 1, 2, 3, 4}),
    ("Dr G Brown",  "F1",               {0, 1, 2, 3, 4}),
    ("Dr H Green",  "F1",               {0, 1, 2, 3, 4}),
]

# (name, first day offset, last day offset, status, label, detail, contact) —
# what the Leave tab would resolve to. Offsets are from today, so the sample
# always has something happening on the day it is viewed.
LEAVE = [
    ("Dr B Smith", 0, 0,  "away",    "Study leave",  None,            "email"),
    ("Dr D Patel", 0, 0,  "partial", None,           "Meeting 10–12", "phone"),
    ("Dr F Ali",   0, 4,  "away",    "Annual leave", None,            "none"),
    ("Dr H Green", 0, 1,  "away",    "Sick",         None,            None),
    ("Dr A Khan",  3, 7,  "away",    "Annual leave", None,            "none"),
    ("Dr E Wong",  1, 1,  "partial", "Remote",       None,            "phone or email"),
]

# A weekday cell on the Team tab that holds a word instead of hours — a regular
# day at home or in clinic. The card shows the word, amber.
WORDS = {
    ("Dr C Lee", 2): "WFH",
}

ROTA_SPAN = 14  # must match ROTA_SPAN_DAYS in worker/wrangler.toml


def write_rota(out_dir: Path, now: datetime) -> None:
    """Stamp a fortnight of rota into rota.json, resolved the way the Worker
    resolves it: pattern first, then the leave rows on top, as local dates."""
    today = datetime.now().date()
    days = []
    for offset in range(ROTA_SPAN):
        day = today + timedelta(days=offset)
        people = []
        for name, role, weekdays in TEAM:
            usual = day.weekday() in weekdays
            word = WORDS.get((name, day.weekday()))
            entry = {"name": name, "role": role}
            hit = next(
                (l for l in LEAVE if l[0] == name and l[1] <= offset <= l[2]), None
            )
            if hit is None:
                entry.update(
                    {"status": "partial", "label": word} if word
                    else {"status": "in", "label": "8–6"} if usual
                    else {"status": "off", "label": "Off"}
                )
            else:
                _, _, _, status, label, detail, contact = hit
                entry["status"] = status
                entry["label"] = label or ("8–6" if usual else "Off")
                if detail:
                    entry["detail"] = detail
                if contact:
                    entry["contact"] = contact
            people.append(entry)
        days.append({"date": day.strftime("%Y-%m-%d"), "people": people})

    payload = {"updated": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "days": days}
    out = out_dir / "rota.json"
    out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {out} — {len(TEAM)} people over {ROTA_SPAN} days from {days[0]['date']}")


def write_weather(out_dir: Path, now: datetime) -> None:
    """Stamp today and tomorrow into weather.json.

    Dates are *local*, matching what the real backend publishes: it asks
    Open-Meteo for days in the office's own timezone, and the app compares the
    first one against the device's local date.
    """
    today = datetime.now().date()
    days = []
    for offset, (code, high, low, rain) in enumerate(WEATHER):
        days.append({
            "date": (today + timedelta(days=offset)).strftime("%Y-%m-%d"),
            "code": code,
            "high": high,
            "low": low,
            "rain": rain,
            "condition": WMO_TEXT.get(code, ""),
        })

    payload = {
        "updated": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "place": "Anytown",
        "days": days,
    }

    out = out_dir / "weather.json"
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} — {len(days)} days from {days[0]['date']}")


def main() -> None:
    now = datetime.now(timezone.utc)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)

    events = []
    for offset, hh, mm, dur, title, room in TEMPLATE:
        start = today + timedelta(days=offset, hours=hh, minutes=mm)
        end = start + timedelta(minutes=dur)
        events.append({
            "title": title,
            "start": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "end": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "room": room,
        })

    payload = {
        "updated": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "range": {
            "from": today.strftime("%Y-%m-%d"),
            "to": (today + timedelta(days=SPAN - 1)).strftime("%Y-%m-%d"),
        },
        "events": events,
    }

    out_dir = Path(__file__).parent
    out = out_dir / "events.json"
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} — {len(events)} events across {SPAN} days")

    write_weather(out_dir, now)
    write_rota(out_dir, now)


if __name__ == "__main__":
    main()
