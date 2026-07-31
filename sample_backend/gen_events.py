#!/usr/bin/env python3
"""Regenerate sample_backend/events.json relative to *today*.

The dashboard renders a rolling 13-day grid anchored at today, so hardcoded
sample dates go stale within a fortnight. Run this to refresh the fixture:

    python sample_backend/gen_events.py
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

    out = Path(__file__).parent / "events.json"
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} — {len(events)} events across {SPAN} days")


if __name__ == "__main__":
    main()
