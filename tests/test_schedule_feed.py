from datetime import datetime
import unittest
from unittest.mock import Mock, patch
from zoneinfo import ZoneInfo

from icalendar import Calendar

from schedule_feed import ScheduleFeed, format_events, upcoming_events
from torus import expand_message


ZONE = ZoneInfo("Europe/Helsinki")
NOW = datetime(2026, 9, 16, 22, 30, tzinfo=ZONE)


def calendar(*events):
    return Calendar.from_ical("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" +
                              "".join("BEGIN:VEVENT\r\n" + event.replace("\n", "\r\n") +
                                      "\r\nEND:VEVENT\r\n" for event in events) +
                              "END:VCALENDAR\r\n")


class ScheduleTests(unittest.TestCase):
    def test_future_order_timezones_and_cancelled_events(self):
        feed = calendar(
            "UID:later\nDTSTART:20260917T090000\nSUMMARY:Later",
            "UID:first\nDTSTART:20260917T051500Z\nDTEND:20260917T060000Z\nSUMMARY:First\nLOCATION:Room 2",
            "UID:cancelled\nDTSTART:20260917T050000Z\nSTATUS:CANCELLED",
            "UID:running\nDTSTART:20260916T190000Z\nDTEND:20260917T050000Z")
        events = upcoming_events(feed, NOW, ZONE)
        self.assertEqual([str(e["UID"]) for e in events], ["first", "later"])
        text = format_events(events, ZONE)
        self.assertIn("08:15-09:00: First (Room 2)", text)
        self.assertIn("09:00: Later", text)

    def test_recurring_exceptions_and_moved_event(self):
        feed = calendar(
            "UID:lesson\nDTSTART;TZID=Europe/Helsinki:20260916T081500\n"
            "DTEND;TZID=Europe/Helsinki:20260916T090000\nRRULE:FREQ=DAILY;COUNT=5\n"
            "EXDATE;TZID=Europe/Helsinki:20260917T081500\nSUMMARY:Lesson",
            "UID:lesson\nRECURRENCE-ID;TZID=Europe/Helsinki:20260918T081500\n"
            "DTSTART;TZID=Europe/Helsinki:20260918T101500\nSUMMARY:Moved",
            "UID:lesson\nRECURRENCE-ID;TZID=Europe/Helsinki:20260919T081500\n"
            "DTSTART;TZID=Europe/Helsinki:20260919T081500\nSTATUS:CANCELLED")
        events = upcoming_events(feed, NOW, ZONE)
        self.assertEqual([e.decoded("DTSTART").day for e in events], [18, 20])
        self.assertEqual(str(events[0]["SUMMARY"]), "Moved")

    def test_all_day_empty_and_single_event(self):
        feed = calendar("UID:day\nDTSTART;VALUE=DATE:20260917\nSUMMARY:School day")
        events = upcoming_events(feed, NOW, ZONE)
        self.assertEqual(len(events), 1)
        self.assertNotIn("00:00", format_events(events, ZONE))
        self.assertEqual(upcoming_events(feed, NOW.replace(day=17, hour=1), ZONE), [])
        self.assertEqual(format_events([], ZONE), "No upcoming events")

    def test_replacement(self):
        self.assertEqual(expand_message("Next: %schedule% / %schedule%",
                                        schedule="Math"), "Next: Math / Math")

    def test_background_failure_retains_previous_download(self):
        feed = calendar("UID:future\nDTSTART:20990101T080000Z\nSUMMARY:Future")
        service = ScheduleFeed()
        service.stop = Mock()
        service.stop.is_set.side_effect = [False, False, True]
        with patch("schedule_feed.load_config", return_value=("https://example.test", ZONE)), \
             patch("schedule_feed.download_calendar", side_effect=[feed, OSError("offline")]), \
             patch("schedule_feed.time.monotonic", side_effect=[0, 301]):
            service._run()
        self.assertIn("Future", service.text)
        self.assertIn("last downloaded schedule", service.text)

    def test_initial_download_failure(self):
        service = ScheduleFeed()
        service.stop = Mock()
        service.stop.is_set.side_effect = [False, True]
        with patch("schedule_feed.load_config", side_effect=OSError("unavailable")):
            service._run()
        self.assertEqual(service.text, "Schedule unavailable")


if __name__ == "__main__":
    unittest.main()
