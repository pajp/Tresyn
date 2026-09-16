# Trackpad Torus

A Python/OpenGL torus with a Mac preview and live multiview output to a
Looking Glass Go, using the installed [Bridge Python SDK](https://github.com/Looking-Glass/Bridge-Python-SDK).
Uses the existing `.venv`. Dependencies, including the iCalendar parser and
recurrence support, are listed in `requirements.txt`.

Connect and power the Go, start Looking Glass Bridge, then double-click
`Torus.command`, or run from this directory:

```sh
.venv/bin/python torus.py
```

Keep the pointer over the Mac preview window for trackpad input.

| Input | Action |
| --- | --- |
| Click and drag | Rotate around horizontal and vertical axes |
| Two-finger scroll | Move left/right and up/down |
| Shift + two-finger scroll | Move in/out of the display plane |
| Shift + drag, or secondary-click drag | Move left/right and up/down |
| Option + drag or scroll | Roll around the viewing axis |
| R | Reset position and orientation |
| Escape or close window | Quit |

Scroll direction follows macOS scrolling preferences. Translation is bounded
to keep the torus near the display volume. Pinch and native rotation gestures
are not used; all controls work through GLFW's trackpad mouse events.

The title indicates whether Bridge connected. If it is unavailable, the app
continues in preview mode; connect the display and restart to try again.
The default target is Bridge's primary display; use `--display INDEX` to
select another Bridge display index.

```sh
.venv/bin/python torus.py --preview
.venv/bin/python torus.py --frames 10 --screenshot /tmp/torus.png
.venv/bin/python -m unittest discover -s tests
```

The quilt resolution, grid, aspect ratio, and view cone come from Bridge.
The Mac preview is the center view, letterboxed to the display's aspect ratio.
Stripes on the torus make its rotation visible, including roll.

Text is read from `~/torusmessage.txt` as UTF-8 and flows word by word from
behind the torus through its center. The stream follows the torus position and
orientation and repeats continuously. File changes appear automatically within
half a second. An empty or missing file hides the text; creating it resumes the
stream. Use `--message PATH` to select another file.

Include `%datetime%` anywhere in the file to show the current local weekday,
date, and 24-hour time, for example `onsdag 16 september 2026 22:32:15`.
Weekday and month names use the Mac's Language & Region locale. The displayed
time updates every second without restarting the stream or changing the file.

`%schedule%` expands to the next two events whose start times have not passed,
with localized weekday/date, time range, title, and location. Recurring events,
exceptions, cancellations, time zones, and all-day events are handled by the
iCalendar libraries. All-day events start at midnight; ongoing events are omitted.
If there is only one upcoming event, only that event is shown.

The feed downloads in the background when this placeholder is first used and
refreshes every five minutes. Selection advances every second as events start.
Failed downloads retry after a minute and retain the last downloaded schedule
with a status note. Empty feeds display `No upcoming events`.

The private URL is in Git-ignored `schedule.local.json` next to the app. On a new
checkout, install with `.venv/bin/python -m pip install -r requirements.txt` and
create that local config with `url` and `timezone` (such as `Europe/Helsinki`).
The feed URL and calendar contents are not stored in Git.
