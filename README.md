# Trackpad Torus

## Remote 3D Drawing

Open `Drawing Server.command` to enable the TLS server, or run
`.venv/bin/python torus.py --server`. Pair using just the one-time code
shown on the display the first time. Later connections securely resume without a
code using a secret bound to the remembered server certificate. The client remembers the server's certificate automatically
and warns before accepting a changed certificate. Press **P** to show pairing; **Tab** switches
between dashboard and drawing. On disconnect, a fresh pairing code appears
automatically. Use **New code** to refresh it, **Back to scene** to return to your
drawing, or **Shift+P** to disconnect a stuck client locally. The Swift client
prompts for a replacement after an incorrect/expired code.
The usual `Torus.command` runs the dashboard
without opening a network socket.

The new drawing mode supports colored spheres, boxes, toruses, thick 3D lines,
and polylines, including live stroke appends, updates, erasing, and clearing.

### Tresyn visionOS client

The `Tresyn` Xcode project provides a native visionOS drawing client with a live
RealityKit preview of the 3D scene shown on Looking Glass Go. It supports strokes,
spheres, boxes, and toruses at selectable depth. The preview keeps one RealityKit
entity per drawing object and renders each stroke as a combined tube mesh, avoiding
the per-point entity churn and SwiftUI state mutations that previously caused
physical-device flicker and compositor corruption. The full supported depth range,
including objects behind the display plane, remains visible in the preview.

Tresyn can also persist the server's in-memory scene without any server or protocol
extensions:

- **Save Scene** requests a fresh scene snapshot from the connected server and
  exports it as a versioned JSON document.
- **Open Scene** validates a saved document, clears the connected server, and
  rebuilds the scene using the existing `put` commands. If replay fails, the client
  attempts to restore the previous server snapshot.

The server itself still keeps drawings only in memory. Restarting it loses the
current scene unless it was saved from Tresyn first. Opening and saving therefore
require an active server connection.

Build and run the macOS Swift demo:

```sh
zsh swift-client/build.sh
.build/torus-client --host 127.0.0.1 --demo
```

It prompts for the pairing code. See [PROTOCOL.md](PROTOCOL.md) for the complete
wire protocol, coordinates, security model, interactive client, and examples.
The client protocol is also available as the reusable
[TorusDrawingClient Swift package](swift-client/README.md), with async APIs for
macOS, iOS, and visionOS. The terminal client uses that package.
`.venv/bin/python tools/verify_drawing.py --bridge` runs the actual Swift demo
against the renderer and captures previews; omit `--bridge` for preview only.

## Dashboard

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

Text is read from the first three lines of `~/torusmessage.txt` as UTF-8:

1. A looping, tilted Star Wars-style crawl moving up and away above the torus.
2. The original word-by-word stream from behind the torus through its center.
3. A continuous right-to-left horizontal ticker below the torus.

All three animations follow the torus position and orientation. Blank or missing
lines hide the corresponding animation; additional lines are ignored. File changes
appear automatically within half a second. An empty or missing file hides all text.
Use `--message PATH` to select another file. For example:

```text
%datetime%
hello world
%schedule%
```

Include `%datetime%` anywhere in the file to show the current local weekday,
date, and 24-hour time, for example `onsdag 16 september 2026 22:32:15`.
Weekday and month names use the Mac's Language & Region locale. The displayed
time updates every second without restarting the stream or changing the file.

`%greeting%` uses Swedish greetings based on the Mac's local time and updates
automatically: `god morgon` (05:00-09:59), `god förmiddag` (10:00-11:59),
`god eftermiddag` (12:00-17:59), `god kväll` (18:00-22:59), and `god natt`
(23:00-04:59). It works on all three lines, regardless of the system language.

`%schedule%` expands to the next two events whose start times have not passed,
with localized weekday/date, time range, title, and location. Recurring events,
exceptions, cancellations, time zones, and all-day events are handled by the
iCalendar libraries. All-day events start at midnight; ongoing events are omitted.
If there is only one upcoming event, only that event is shown.
In the upper crawl, events are grouped into date, time, title, and location rows
with a gap between events. Wrapping uses rendered word widths; long individual
words scale to fit instead of being split into fragments.

The feed downloads in the background when this placeholder is first used and
refreshes every five minutes. Selection advances every second as events start.
Failed downloads retry after a minute and retain the last downloaded schedule
with a status note. Empty feeds display `No upcoming events`.

The private URL is in Git-ignored `schedule.local.json` next to the app. On a new
checkout, install with `.venv/bin/python -m pip install -r requirements.txt` and
create that local config with `url` and `timezone` (such as `Europe/Helsinki`).
The feed URL and calendar contents are not stored in Git.
