import Foundation

/// Async facade. Socket waits run on a private serial queue, never on the UI actor.
/// Calls are ordered; await commands to apply backpressure during live drawing.
public final class TorusClient: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let sceneUpdates: AsyncStream<SceneState>
    private let work = DispatchQueue(label: "torus.client.commands")
    private let trust: TrustStore
    private let sceneContinuation: AsyncStream<SceneState>.Continuation
    private var connection: TLSConnection?
    // Retain the observed identity across code retries, before it is persisted.
    private var sessionFingerprint: String?

    public static var defaultTrustDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorusDrawingClient/Servers", isDirectory: true)
    }

    public init(host: String = "127.0.0.1", port: UInt16 = 8765, trustDirectory: URL? = nil) {
        self.host = host
        self.port = port
        var continuation: AsyncStream<SceneState>.Continuation!
        sceneUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation = $0 }
        sceneContinuation = continuation
        trust = TrustStore(directory: trustDirectory ?? Self.defaultTrustDirectory,
                           endpoint: "\(host.lowercased()):\(port)")
    }

    /// The first connection uses a fresh display code; later connections resume securely.
    /// On certificateChanged, ask the user, then retry with that exact fingerprint
    /// as approvedCertificate. It is persisted only after code authentication succeeds.
    @discardableResult
    public func connect(pairingCode: String? = nil, approvedCertificate: String? = nil) async throws -> ServerCapabilities {
        let updateContinuation = sceneContinuation
        return try await perform {
            guard self.port != 0 else { throw TorusClientError.message("Port must be nonzero") }
            self.connection?.close()
            self.connection = nil
            let saved = try self.trust.load()
            let expected = approvedCertificate ?? self.sessionFingerprint ?? saved?.fingerprint
            let transport = try TLSConnection(host: self.host, port: self.port, fingerprint: expected)
            transport.onSceneUpdate { fields in
                guard let data = try? JSONSerialization.data(withJSONObject: fields),
                      let scene = try? JSONDecoder().decode(SceneState.self, from: data) else { return }
                updateContinuation.yield(scene)
            }
            do {
                try transport.connect()
                self.sessionFingerprint = transport.fingerprint
                let response: [String: Any]
                if approvedCertificate == nil, let token = saved?.resumeToken {
                    response = try transport.request(["op": "resume", "token": token])
                } else {
                    guard let pairingCode, !pairingCode.isEmpty else {
                        throw TorusClientError.message("Enter the one-time display code to pair this device")
                    }
                    response = try transport.request(["op": "pair", "code": pairingCode])
                }
                guard let fingerprint = transport.fingerprint else {
                    throw TorusClientError.message("Server did not provide a certificate")
                }
                let reply = try self.decode(response)
                let capabilities = try reply.decodeResult(ServerCapabilities.self)
                try self.trust.save(fingerprint, resumeToken: capabilities.resumeToken ?? saved?.resumeToken)
                self.connection = transport
                transport.keepAlive()
                return capabilities
            } catch {
                transport.close()
                throw error
            }
        }
    }

    /// True after this installation has completed a code pairing with this endpoint.
    public func canResume() -> Bool {
        (try? trust.load())?.resumeToken != nil
    }

    public func disconnect() async {
        _ = try? await perform {
            self.connection?.close()
            self.connection = nil
        }
    }

    @discardableResult
    public func setMode(_ mode: DisplayMode) async throws -> SceneState {
        try await send(["op": .string("mode"), "mode": .string(mode.rawValue)]).decodeResult(SceneState.self)
    }

    @discardableResult
    public func put(_ object: DrawingObject) async throws -> SceneState {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(object))
        return try await send(["op": .string("put"), "object": value]).decodeResult(SceneState.self)
    }

    @discardableResult
    public func append(to objectID: String, points: [[Double]]) async throws -> SceneState {
        try await send(["op": .string("append"), "object_id": .string(objectID),
                        "points": .array(points.map { .array($0.map(JSONValue.number)) })]).decodeResult(SceneState.self)
    }

    @discardableResult
    public func delete(_ objectID: String) async throws -> SceneState {
        try await send(["op": .string("delete"), "object_id": .string(objectID)]).decodeResult(SceneState.self)
    }

    @discardableResult
    public func clear() async throws -> SceneState {
        try await send(["op": .string("clear")]).decodeResult(SceneState.self)
    }

    public func state() async throws -> SceneState {
        try await send(["op": .string("state")]).decodeResult(SceneState.self)
    }

    /// Escape hatch for future primitives/operations. v and id are assigned internally.
    @discardableResult
    public func send(_ fields: [String: JSONValue]) async throws -> ServerReply {
        let data = try JSONEncoder().encode(fields)
        return try await perform {
            guard let connection = self.connection else { throw TorusClientError.message("Not connected; pair first") }
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try self.decode(connection.request(payload))
        }
    }

    private func decode(_ fields: [String: Any]) throws -> ServerReply {
        try JSONDecoder().decode(ServerReply.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            work.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    deinit {
        sceneContinuation.finish()
        connection?.close()
    }
}
