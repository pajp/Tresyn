"""Background iCalendar download and selection for the message stream."""

from datetime import datetime, time as day_time
from copy import copy
import json
from pathlib import Path
import threading
import time
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

from icalendar import Calendar
import recurring_ical_events


CONFIG_PATH = Path(__file__).with_name("schedule.local.json")


def load_config(path=CONFIG_PATH):
    config = json.loads(path.read_text(encoding="utf-8"))
    url = config["url"]
    if not isinstance(url, str) or not url.startswith("https://"):
        raise ValueError("The calendar URL must use HTTPS")
    return url, ZoneInfo(config.get("timezone", "Europe/Helsinki"))


def download_calendar(url):
    request = Request(url, headers={"User-Agent": "TrackpadTorus/1.0",
                                    "Accept": "text/calendar"})
    with urlopen(request, timeout=15) as response:
        data = response.read(5 * 1024 * 1024 + 1)
    if len(data) > 5 * 1024 * 1024:
        raise ValueError("Calendar exceeds 5 MB")
    calendar = Calendar.from_ical(data)
    if calendar.name != "VCALENDAR":
        raise ValueError("Response is not an iCalendar feed")
    return calendar


def event_datetime(value, zone):
    if not isinstance(value, datetime):
        return datetime.combine(value, day_time(), zone)
    if value.tzinfo is None:
        return value.replace(tzinfo=zone)
    return value.astimezone(zone)


def upcoming_events(calendar, now, zone, limit=2):
    """Expand recurrences and select future starts, not already-running events."""
    result = []
    calendar = copy(calendar)
    calendar.subcomponents = [event for event in calendar.subcomponents
                              if not (event.name == "VEVENT"
                                      and str(event.get("STATUS", "")).upper() == "CANCELLED"
                                      and "RECURRENCE-ID" not in event)]
    # Query from local midnight to include floating-time and all-day events.
    start = datetime.combine(now.astimezone(zone).date(), day_time(), zone)
    for event in recurring_ical_events.of(calendar).after(start):
        if str(event.get("STATUS", "")).upper() == "CANCELLED":
            continue
        when = event_datetime(event.decoded("DTSTART"), zone)
        if when < now:
            continue
        result.append(event)
        if len(result) >= limit:
            break
    return result


def format_events(events, zone):
    parts = []
    for event in events:
        value = event.decoded("DTSTART")
        start = event_datetime(value, zone)
        date_text = start.strftime("%A ") + str(start.day) + start.strftime(" %B %Y")
        if isinstance(value, datetime):
            date_text += start.strftime(" %H:%M")
            end_value = event.decoded("DTEND", None)
            if end_value is not None:
                end = event_datetime(end_value, zone)
                if end > start:
                    date_text += "-" + (end.strftime("%H:%M") if end.date() == start.date()
                                        else end.strftime("%Y-%m-%d %H:%M"))
        title = " ".join(str(event.get("SUMMARY", "Untitled event")).split())
        location = " ".join(str(event.get("LOCATION", "")).split())
        parts.append(f"{date_text}: {title}" + (f" ({location})" if location else ""))
    return " | ".join(parts) if parts else "No upcoming events"


class ScheduleFeed:
    """Publish immutable text snapshots; networking never runs on the GL thread."""

    def __init__(self, config_path=CONFIG_PATH):
        self.config_path = config_path
        self.text = "Loading schedule"
        self.stop = threading.Event()
        self.thread = None

    def snapshot(self):
        if self.thread is None:
            self.thread = threading.Thread(target=self._run, name="calendar-feed", daemon=True)
            self.thread.start()
        return self.text

    def _run(self):
        calendar = None
        zone = ZoneInfo("Europe/Helsinki")
        next_download = next_selection = 0
        stale = False
        while not self.stop.is_set():
            monotonic = time.monotonic()
            if monotonic >= next_download:
                try:
                    url, fresh_zone = load_config(self.config_path)
                    fresh = download_calendar(url)
                    # Validate recurrence data before replacing a working snapshot.
                    upcoming_events(fresh, datetime.now(fresh_zone), fresh_zone)
                    calendar = fresh
                    zone = fresh_zone
                    stale = False
                    next_download = monotonic + 300
                except Exception:
                    # Exceptions may contain the private feed URL; never print them.
                    stale = True
                    next_download = monotonic + 60
                next_selection = 0
            if monotonic >= next_selection:
                if calendar is None:
                    self.text = "Schedule unavailable"
                else:
                    try:
                        now = datetime.now(zone)
                        events = upcoming_events(calendar, now, zone)
                        self.text = format_events(events, zone)
                        if stale:
                            self.text += " (last downloaded schedule)"
                    except Exception:
                        self.text = "Schedule unavailable"
                next_selection = monotonic + 1
            self.stop.wait(1)

    def close(self):
        self.stop.set()
