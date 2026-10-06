# TorusDrawingClient

A dependency-free Swift package for the Torus display's paired TLS drawing
protocol. Supports macOS 12+, iOS 15+, and visionOS 1+. The `torus-client`
executable uses this same library; transport and trust handling are not duplicated
in the CLI.

## Add to an App

In Xcode, use **Add Local Package** and select this `swift-client` directory,
then add the **TorusDrawingClient** library product to your app target.

For another Swift package:

```swift
dependencies: [.package(path: "../lggo/swift-client")],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "TorusDrawingClient", package: "swift-client")
    ])
]
```

## Draw

Keep a client instance for the lifetime of the connection. Calls are asynchronous;
the library runs socket waits on its own serial queue, including when called
from a SwiftUI task or the main actor.

```swift
import TorusDrawingClient

let client = TorusClient(host: "Ferrum.local")
let capabilities = try await client.connect(pairingCode: codeFromUser)
let updates = Task {
    for await scene in client.sceneUpdates {
        // Refresh local UI from scene.objects. Updates come from other clients.
    }
}
try await client.setMode(.drawing)
try await client.put(DrawingObject(
    id: "ball", type: .sphere,
    position: [0, 0.5, 0], color: [0.2, 0.8, 1], radius: 0.3
))
try await client.put(DrawingObject(
    id: "stroke", type: .polyline, color: [1, 0.8, 0.1], radius: 0.02,
    points: [[0, 0, 0], [0.1, 0.1, 0]]
))
try await client.append(to: "stroke", points: [[0.2, 0.3, 0.1]])
let scene = try await client.state()
try await client.delete("ball")
try await client.clear()
try await client.setMode(.dashboard)
await client.disconnect()
updates.cancel()
```

All vectors are XYZ, quaternions XYZW, and colors RGB arrays. Scene coordinates
are display-world units, not meters. Await commands during drawing to maintain
backpressure; small point batches are preferable to creating an unbounded task
for every tracking sample. The transport sends keep-alives automatically.
The server pushes complete, revisioned scene snapshots when another client changes
the shared scene; `sceneUpdates` continuously receives them even while this client
is idle. Apply only newer revisions when combining updates with an initial `state()`.
Cancellation is checked before queuing work; already-running socket operations
finish or time out (up to 10 seconds). `disconnect()` runs after previously
queued operations. Do not enqueue unlimited work ahead of it.

## Pairing and Recovery

The library never reads stdin, presents UI, or prints messages. The app owns
those interactions and catches `TorusClientError`:

After the first successful code pairing, `connect()` automatically resumes with
the opaque credential stored alongside the pinned certificate. Supply a code only
for the first pairing, an unknown client, or an approved certificate replacement.

- `.server(code, message)`: display the message. For `invalid_code` or
  `pairing_expired`, ask for a new display code and call `connect` again on the
  same client. `pairing_locked` requires waiting.
- `.certificateChanged(fingerprint)`: show a warning and ask the user whether
  to trust the changed server. Only if approved, call
  `connect(pairingCode: newCode, approvedCertificate: fingerprint)` with that
  exact fingerprint. Declining requires no action; the previous saved identity
  remains unchanged. Do not automatically approve this error.
- `.message(description)` or a networking error: show the failure and offer
  retry. There is no automatic re-pairing or command replay.

Certificates are accepted on first use, remembered after successful pairing,
and checked on later connections per hostname/port. Store files live in the
app's Application Support directory. Pass `trustDirectory:` to isolate a test
or choose another application-owned directory. No private keys or pairing codes
are persisted by the client. Connections always require a fresh single-use code.

Future commands and primitives can use the Codable `JSONValue` escape hatch:

```swift
let reply = try await client.send(["op": .string("state")])
let state = try reply.decodeResult(SceneState.self)
```

The app must provide its local-network permission description
(`NSLocalNetworkUsageDescription`) on Apple platforms that require it. Sandboxed
macOS apps also need the outgoing-network client entitlement. There are no app
permissions or entitlements embedded in the library itself.

## Build and Test

```sh
swift build --package-path swift-client --product torus-client
swift test --package-path swift-client
```

From the repository root, `zsh swift-client/build.sh` builds the SPM executable
in release mode and places it at `.build/torus-client` for existing workflows.
The Python integration tests exercise this binary against a real TLS server,
including first use, changed certificates, incorrect codes, and code retry.
See [the protocol](../PROTOCOL.md) for wire details and limits.
