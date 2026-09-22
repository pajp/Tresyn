import Foundation
import Network
import Security
import CryptoKit

public enum TorusClientError: Error, CustomStringConvertible, Sendable {
    case message(String)
    case certificateChanged(String)
    case server(String, String)
    public var description: String {
        switch self {
        case .message(let text): return text
        case .certificateChanged: return "The server certificate has changed."
        case .server(_, let text): return text
        }
    }
}

struct TrustStore {
    let directory: URL
    let endpoint: String
    var file: URL {
        let key = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    struct Record: Codable {
        let endpoint: String
        let fingerprint: String
        let resumeToken: String?
        enum CodingKeys: String, CodingKey { case endpoint, fingerprint; case resumeToken = "resume_token" }
    }
    func load() throws -> Record? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
        guard record.endpoint == endpoint, record.fingerprint.count == 64,
              record.fingerprint.allSatisfy({ $0.isHexDigit }) else {
            throw TorusClientError.message("Invalid saved server identity at \(file.path)")
        }
        return record
    }
    func save(_ fingerprint: String, resumeToken: String?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Record(endpoint: endpoint, fingerprint: fingerprint, resumeToken: resumeToken))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

final class PeerCertificate {
    private let lock = NSLock()
    private var value: String?
    var fingerprint: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

// Network.framework and these JSON messages can also be used by a visionOS app.
final class TLSConnection {
    let connection: NWConnection
    private let queue = DispatchQueue(label: "torus.network")
    private let requestLock = NSLock()
    private var buffer = Data()
    private var sequence = 0
    private var heartbeat: DispatchSourceTimer?
    private let expectedFingerprint: String?
    private let peer = PeerCertificate()
    var fingerprint: String? { peer.fingerprint }

    init(host: String, port: UInt16, fingerprint: String?) throws {
        expectedFingerprint = fingerprint
        let peer = self.peer
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificates = SecTrustCopyCertificateChain(reference) as? [SecCertificate],
                  let leaf = certificates.first else { complete(false); return }
            let der = SecCertificateCopyData(leaf) as Data
            let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            peer.fingerprint = actual
            complete(fingerprint == nil || actual == fingerprint)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls, tcp: tcp))
    }

    func connect() throws {
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error): failure = error; ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success else {
            connection.cancel()
            if let actual = peer.fingerprint, let expected = expectedFingerprint, actual != expected {
                throw TorusClientError.certificateChanged(actual)
            }
            throw TorusClientError.message("Connection timed out")
        }
        if let actual = peer.fingerprint, let expected = expectedFingerprint, actual != expected {
            connection.cancel()
            throw TorusClientError.certificateChanged(actual)
        }
        if let failure = failure { throw failure }
        connection.stateUpdateHandler = nil
    }

    func keepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            do { _ = try self.request(["op": "ping"]) }
            catch { self.close() }
        }
        heartbeat = timer
        timer.resume()
    }

    func close() {
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
    }

    @discardableResult
    func request(_ fields: [String: Any]) throws -> [String: Any] {
        requestLock.lock()
        defer { requestLock.unlock() }
        sequence += 1
        var message = fields
        let id = String(sequence)
        message["v"] = 1
        message["id"] = id
        var payload = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        payload.append(10)
        guard payload.count <= 262144 else { throw TorusClientError.message("Message too large") }
        let sent = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: payload, completion: .contentProcessed { error in
            sendError = error
            sent.signal()
        })
        guard sent.wait(timeout: .now() + 10) == .success else {
            throw TorusClientError.message("Send timed out")
        }
        if let error = sendError { throw error }
        let reply = try receiveLine()
        guard let response = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
              response["id"] as? String == id, response["v"] as? Int == 1 else {
            throw TorusClientError.message("Invalid server reply")
        }
        guard response["ok"] as? Bool == true else {
            if let error = response["error"] as? [String: Any],
               let code = error["code"] as? String, let text = error["message"] as? String {
                throw TorusClientError.server(code, text)
            }
            throw TorusClientError.message("Server rejected command: \(response["error"] ?? response)")
        }
        return response
    }

    private func receiveLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            let received = DispatchSemaphore(value: 0)
            var chunk: Data?
            var failure: NWError?
            var ended = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                chunk = data
                failure = error
                ended = complete
                received.signal()
            }
            guard received.wait(timeout: .now() + 10) == .success else {
                connection.cancel()
                throw TorusClientError.message("Reply timed out")
            }
            if let failure = failure { throw failure }
            if let chunk = chunk { buffer.append(chunk) }
            guard buffer.count <= 262144 else { throw TorusClientError.message("Reply too large") }
            if ended && !buffer.contains(10) { throw TorusClientError.message("Server disconnected") }
        }
    }

}
