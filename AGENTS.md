# Tresyn repository guide

This repository combines a Python Looking Glass application, a TLS drawing server, a reusable Swift protocol client, and a macOS/visionOS SwiftUI client. Read this map before searching broadly, and keep this document as well as the README.md file up to date as you make changes.

## Top-level architecture

- `torus.py`: main Python/OpenGL application. Runs the dashboard, Mac preview, Looking Glass output, input handling, and optional drawing-server mode.
  Its event loop checks server and pairing state at 30 Hz, redraws static drawing/pairing views only when changed, and caps the animated dashboard at 30 fps.
- `drawing_server.py`: authenticated TLS JSON-lines server, pairing/resume credentials, client fan-out, command queue, and persisted scene snapshots.
- `drawing.py`: authoritative Python drawing protocol validation, `Scene` mutation, model transforms, and CPU mesh generation.
- `drawing_renderer.py`: uploads geometry from `drawing.py` to OpenGL and renders it.
- `pairing_ui.py`: pairing screen UI and hit testing.
- `schedule_feed.py`: iCalendar download, recurrence handling, and dashboard schedule formatting. This is mostly independent of drawing.
- `PROTOCOL.md`: human-readable drawing wire protocol and coordinate conventions.
- `swift-client/`: Swift package named `TorusDrawingClient`, plus its CLI.
- `Tresyn/`: Xcode project containing the macOS/visionOS app and Quick Look extensions.
- `tests/`: Python server, renderer, dashboard, schedule, and Swift integration tests.
- `tools/verify_drawing.py`: end-to-end drawing verification against the renderer, optionally through the Swift client.

## Swift app map

Open `Tresyn/Tresyn.xcodeproj`. The main app source is under `Tresyn/Tresyn/`:

- `ContentView.swift`: SwiftUI tools/sidebar, drawing gestures, Inspect/Front controls, scene open/save/export UI. It has separate `#if os(visionOS)` and macOS gesture branches; update both when adding tools.
- `DrawingSession.swift`: client connection state, tool enum, placement, selection/manipulation, undo/redo, scene synchronization, and display-bound calculations.
- `RealityDrawingPreview.swift`: live RealityKit entities, custom meshes, materials, collision shapes, and Mac camera inspection.
- `SceneArchive.swift`: `.tres` document format and validation.
- `USDZExporter.swift`: SceneKit construction for USDZ export.
- `MyApp.swift`: app entry point and commands.

Quick Look support is split into two targets:

- `Tresyn/TresynPreview/`: full preview extension. `ScenePreviewRenderer.swift` is the SceneKit path; `PreviewProvider.swift` contains a simpler SVG fallback.
- `Tresyn/TresynThumbnail/`: Finder thumbnail extension. `SceneThumbnailRenderer.swift` is the SceneKit path; `ThumbnailProvider.swift` contains a Core Graphics fallback.

The Swift package lives at `swift-client/`, although Xcode may expose it under the workspace name `TorusDrawingClient`:

- `Sources/TorusDrawingClient/Models.swift`: wire enums and Codable payloads.
- `Sources/TorusDrawingClient/TorusClient.swift`: typed async client operations.
- `Sources/TorusDrawingClient/Transport.swift`: TLS transport and trust handling.
- `Sources/TorusCLI/TorusCLI.swift`: command-line client/demo.
- `Tests/TorusDrawingClientTests/`: package model and client tests.

## Drawing data flow

The graphical app creates a `DrawingObject` in `DrawingSession`, previews it locally with RealityKit, and sends it through `TorusDrawingClient`. The Python server validates and stores it in `drawing.py`; `drawing_renderer.py` renders the geometry to the normal preview and Looking Glass output. Server scene snapshots are broadcast back to all clients.

Primitive payload conventions:

- All objects: `id`, `type`, optional `position`, XYZW quaternion `rotation`, XYZ `scale`, and RGB `color`.
- Sphere: `radius`.
- Box and tetrahedron: XYZ `size`.
- Cylinder, cone, and capsule: `radius` plus XYZ `size`; height is `size[1]` and the local axis is Y.
- Torus: `major_radius` and `minor_radius` on the wire (`majorRadius`/`minorRadius` in Swift).
- Line/polyline: `radius` and XYZ `points`.

Coordinates use X right, Y up, and Z depth. The live RealityKit preview, Python renderer, SceneKit export/preview paths, and collision bounds must agree on local axes and dimensions.

## Adding or changing a primitive

A primitive is cross-stack work. Check all of these locations:

1. `PROTOCOL.md` for protocol documentation.
2. `swift-client/Sources/TorusDrawingClient/Models.swift` for `Primitive` and payload fields.
3. `drawing.py` for `PRIMITIVES`, validation/defaults, and CPU geometry.
4. `DrawingSession.swift` for the tool, symbol, default placement payload, and local bounds.
5. Every exhaustive tool switch in `ContentView.swift`, including both platform branches.
6. `RealityDrawingPreview.swift` for the visible mesh and visionOS collision shape.
7. `USDZExporter.swift`.
8. Both Quick Look SceneKit renderers and both 2D fallback providers.
9. Python and Swift tests.

For custom triangle meshes, use consistent outward-facing winding everywhere. RealityKit normals are calculated from `cross(b - a, c - a)`. Inward normals make a convex object look hollow and can create an apparent reverse-rotation illusion under Inspect. The Python test suite includes a tetrahedron outward-normal regression test.

## Build and test commands

Use the repository virtual environment; the system Python may not have NumPy or the project dependencies:

```sh
cd ~/lggo
.venv/bin/python -m unittest discover -s tests
```

Useful focused runs:

```sh
.venv/bin/python -m unittest tests.test_drawing tests.test_drawing_server
.venv/bin/python tools/verify_drawing.py --bridge
zsh swift-client/build.sh
```

For the app, prefer Xcode's build command/tool so package dependencies, app extensions, and the selected destination are included. Platform conditionals can hide failures: verify a Mac destination after editing macOS gestures/UI, and verify visionOS after editing spatial gestures or collision code. The active `Tresyn` test plan may report zero tests because Swift package tests are not part of that app scheme.

## Runtime entry points

```sh
# Drawing Server with Looking Glass output
.venv/bin/python torus.py --server

# Dashboard only
.venv/bin/python torus.py

# Preview without Bridge hardware
.venv/bin/python torus.py --preview
```

`Drawing Server.command` and `Torus.command` are Finder-launchable wrappers for the common modes.

## Persistence, generated files, and local state

- `.drawing-local/` contains private keys, certificates, resume credentials, and the last server scene. It is local runtime state; do not commit or rewrite it during normal development.
- `schedule.local.json` contains a private calendar URL and is local-only.
- `.venv/`, `.build/`, `__pycache__/`, Xcode user data, captured videos, and generated preview assets are not source.
- The server writes `drawing-scene.json` on normal shutdown; a crash can lose changes from the current run.
- Do not treat Xcode's `.swiftpm/xcode/xcuserdata/.../xcschememanagement.plist` changes as feature work; Xcode can modify scheme ordering merely by building or testing.

## High-value starting points by task

- Protocol/server rejection: start in `drawing.py`, then `drawing_server.py` and `PROTOCOL.md`.
- Wrong shape or lighting on the Looking Glass: start in `drawing.py` geometry and `drawing_renderer.py`.
- Wrong shape only in the app canvas: start in `RealityDrawingPreview.swift`.
- Mac Inspect behavior: `ContentView.swift` plus camera state in `RealityDrawingPreview.swift`.
- Incorrect export/preview/thumbnail: inspect `USDZExporter.swift`, then the corresponding Quick Look renderer and fallback provider.
- Connection, pairing, reconnect, or scene broadcast: `drawing_server.py`, `TorusClient.swift`, and `DrawingSession.swift`.
- Scene-file import/export: `SceneArchive.swift` and the scene-transfer methods in `DrawingSession.swift`.
- Dashboard/calendar behavior: `torus.py`, `schedule_feed.py`, and their focused tests; drawing files are usually irrelevant.
