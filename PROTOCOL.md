# Torus Drawing Protocol v1

## Transport and Pairing

Run `Drawing Server.command`, or `.venv/bin/python torus.py --server`.
The default listener is TCP port 8765 on all IPv4 interfaces. Use
`--host 127.0.0.1` for local-only use and `--port PORT` to change the port.
The app still starts in dashboard mode; pairing temporarily replaces the scene
on both the Mac preview and Looking Glass. Press **P** to show a new pairing
code; **Tab** dismisses pairing and switches dashboard/drawing locally. The pairing
screen also has clickable **New code** and **Back to scene** buttons in the Mac
preview, an expiry indicator, and the server hostname/port.

Transport is TLS 1.2 or newer. On first startup the app generates a self-signed
certificate/private key in the Git-ignored `.drawing-local/` directory.
The Swift client uses trust on first use: it accepts an unknown server certificate
automatically, then remembers its identity after successful code pairing. No
fingerprint entry is needed. On later connections to the same host and port,
it verifies the saved identity. A changed certificate triggers a warning and
requires a `yes` response before reconnecting; declining leaves the saved identity
unchanged and does not send the pairing code. The replacement is saved only after
successful pairing. This assumes the first connection is to the intended server;
it does not independently authenticate a previously unknown server.

Identities are stored per host/port under
`~/Library/Application Support/TorusDrawingClient/Servers/`. Using a different
hostname or IP creates a separate identity entry. `--trust-directory PATH`
overrides that directory for isolated tests. The certificate's SHA-256 is an
internal implementation detail, never a value the user needs to type.

On its first connection, a client authenticates using the six-digit code on the display over TLS:

```json
{"v":1,"id":"1","op":"pair","code":"123456"}
```

The code expires after 120 seconds and is consumed on successful pairing.
Five incorrect attempts lock pairing globally for 60 seconds. One authenticated
client controls the scene at a time; other clients are rejected. Every new
connection must pair, including reconnects. Disconnecting automatically shows a
fresh code; the drawing is retained behind the pairing screen. If the previous
client is stuck or still connected, press **Shift+P** locally to disconnect it,
or press **P** and click **Disconnect & re-pair**.
The short code authenticates the client; TLS encrypts the connection and the
remembered certificate detects server identity changes after initial pairing.

After successful pairing, the response also contains an opaque `resume_token`.
The client stores it beside the pinned server certificate; the server stores only
its SHA-256 digest in `.drawing-local/drawing-clients.json`. On later connections
to that same host and port, the client resumes without displaying or entering a
code:

```json
{"v":1,"id":"1","op":"resume","token":"opaque-secret"}
```

The token is accepted only inside TLS after the saved certificate has matched.
It is never a replacement for certificate-change confirmation: a changed server
certificate requires user approval and a fresh display-code pairing. A new app
installation, a deleted client identity, or an unknown token also requires the
display code. `resume` can return `unknown_client` or `client_busy`.

Use UTF-8 JSON objects, one per LF-terminated line, inside TLS. Maximum frame
size is 262144 bytes including LF. TCP reads may contain partial or multiple
frames. Each request must include integer `v:1`, string `id` (1-64 characters),
and string `op`. IDs correlate responses, not object identities. Responses are
ordered; the sample client sends one request at a time. Unknown optional fields
are ignored, while unsupported versions, operations, and primitive types are
rejected. Future primitives add new `type` values without changing framing.

Success:

```json
{"v":1,"id":"1","ok":true,"result":{"protocol":"torus-drawing","primitives":["sphere","box","torus","line","polyline"],"limits":{"objects":128,"points_per_object":1024,"scene_points":8192,"message_bytes":262144}}}
```

Error:

```json
{"v":1,"id":"2","ok":false,"error":{"code":"invalid_command","message":"Unsupported primitive type"}}
```

Error codes include `bad_message`, `invalid_code`, `pairing_expired`,
`pairing_locked`, `client_busy`, `authentication_required`, `invalid_command`,
`busy`, `timeout`, and `internal_error`. Authentication and malformed-frame errors
close the connection; an invalid drawing command leaves the connection usable.
Send `ping` at least every 20 seconds when idle; a 60-second receive timeout
disconnects inactive clients. Authentication/handshake timeout is 10 seconds.

## Coordinates and Objects

The scene is right-handed: +X right, +Y up, +Z toward the viewer. Z=0 is the
display plane. Units are display-world units, not meters. For a Go, start within
X [-1,1], Y [-2,2], Z [-0.7,0.7]. The full camera is approximately 2.925 units
wide and 5.2 units high at Z=0. Larger coordinates are accepted but may be clipped
or uncomfortable to inspect. A future visionOS client should map its meter-based
coordinates into this display volume.

Every object has a stable string `id` (1-64 characters) and a `type`. Common
optional fields are `position` (default [0,0,0]), quaternion `rotation` in
**[x,y,z,w]** order (default [0,0,0,1], normalized by server), positive XYZ
`scale` (default [1,1,1]), and opaque RGB `color` in [0,1] (default [0.1,0.8,0.7]).
Colors use the display's RGB values, with directional shading applied.
Transform order is scale, rotation, translation. Points are local to an object.
Trackpad gestures continue to control only the dashboard torus, not the drawing.

| Type | Geometry fields |
| --- | --- |
| `sphere` | `radius`, default 0.25 |
| `box` | `size`: XYZ full dimensions, default [0.5,0.5,0.5] |
| `torus` | `major_radius`: centerline radius, default 0.4; `minor_radius`: tube radius, default 0.12; ring lies in XY |
| `line` | `points`: exactly two XYZ positions; `radius`: tube thickness, default 0.015 |
| `polyline` | `points`: 2-1024 XYZ positions; `radius`: tube thickness, default 0.015 |

Lines are solid 3D tubes with end caps, visible across quilt views. Consecutive
identical points are rejected. Scene limits: 128 objects and 8192 line/polyline
points in total. All numeric inputs must be finite. Position/point coordinates
are bounded to [-10,10], scale to [0.001,10]. The server validates an update
before changing the scene, so a rejected update leaves the previous object intact.

## Commands

Switch modes (preserves the drawing when returning to dashboard):

```json
{"v":1,"id":"2","op":"mode","mode":"drawing"}
{"v":1,"id":"3","op":"mode","mode":"dashboard"}
```

Create or replace a whole object. Reusing the object ID replaces it; omitted
properties revert to defaults. Repeated puts animate transforms/colors. Drawing
commands are accepted in either mode, allowing preparation while dashboard is shown.

```json
{"v":1,"id":"4","op":"put","object":{"id":"ball","type":"sphere","radius":0.3,"position":[0,0.5,0.2],"color":[0.2,0.8,1]}}
{"v":1,"id":"5","op":"put","object":{"id":"stroke","type":"polyline","points":[[0,0,0],[0.1,0.1,0]],"radius":0.02,"color":[1,0.7,0.1]}}
```

Append one or more points to an existing polyline for live drawing:

```json
{"v":1,"id":"6","op":"append","object_id":"stroke","points":[[0.2,0.15,0.1],[0.3,0.2,0.15]]}
```

Erase one object (idempotent), clear the whole drawing, or inspect scene state:

```json
{"v":1,"id":"7","op":"delete","object_id":"ball"}
{"v":1,"id":"8","op":"clear"}
{"v":1,"id":"9","op":"state"}
{"v":1,"id":"10","op":"ping"}
```

Scene replies contain `mode`, `object_ids`, and `revision`. Acknowledgement means
the scene command was validated and applied on the render thread; it is not a
display scan-out timestamp. Changes appear on the next render. The scene remains
visible after disconnect and is not saved across app restarts. Clearing affects
only drawing objects, not dashboard data. Commands are not replayed automatically
on reconnect; obtain state or clear/recreate as needed.

## Swift Test Client

No third-party Swift dependencies are needed. Build on macOS:

```sh
zsh swift-client/build.sh
.build/torus-client --host 127.0.0.1 --demo
```

The client prompts for the one-time code. Use the Mac's LAN address for a remote
client. `--demo` switches to drawing, clears the previous scene, draws all five
primitives, animates a box, and appends a live stroke. It exits leaving the scene
stored on the display. The pairing screen reappears when it disconnects; click
**Back to scene** to view the drawing, or use the new code to reconnect. If you
enter an old/incorrect code, the client explains the failure and prompts for a
new code, even when the original code was supplied using `--code`. Enter a blank
line to cancel. Codes are never reusable; five wrong attempts still trigger the
one-minute lockout.

Omit `--demo` for an interactive terminal. Enter `drawing`, `dashboard`, `clear`,
`state`, `quit`, or JSON command objects. The client adds `v` and request `id`.
`--script FILE` sends a JSON-lines command file. `--code CODE` is available for
automated tests; interactive prompting avoids putting the code in process arguments.

The executable consumes the `TorusDrawingClient` Swift package in `swift-client`.
Its public async API handles transport, trust persistence, pairing, keep-alives,
and typed drawing commands without terminal UI. It uses Network.framework,
Security, and CryptoKit and supports macOS, iOS, and visionOS. See
[the package README](swift-client/README.md) for Xcode/SPM integration, sample
code, error handling, and local-network permission requirements.
