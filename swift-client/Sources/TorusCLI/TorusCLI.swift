import Foundation
import TorusDrawingClient

@main
struct TorusCLI {
    static func main() async {
        do { try await run() }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }

    static func run() async throws {
        var host = "127.0.0.1", port: UInt16 = 8765, code: String?, script: String?
        var trustDirectory = TorusClient.defaultTrustDirectory
        var demo = false
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            if flag == "--demo" { demo = true; continue }
            if flag == "--help" {
                print("torus-client --host HOST --port 8765 [--code CODE] [--demo | --script FILE]")
                print("Server certificates are remembered automatically. Changes require confirmation.")
                print("Without --demo/--script, enter JSON commands or dashboard, drawing, clear, state, quit.")
                return
            }
            guard !arguments.isEmpty else { throw TorusClientError.message("Missing value for \(flag)") }
            let value = arguments.removeFirst()
            switch flag {
            case "--host": host = value
            case "--port":
                guard let parsed = UInt16(value), parsed > 0 else { throw TorusClientError.message("Invalid port") }
                port = parsed
            case "--trust-directory": trustDirectory = URL(fileURLWithPath: value, isDirectory: true)
            case "--code": code = value
            case "--script": script = value
            default: throw TorusClientError.message("Unknown option \(flag)")
            }
        }
        if code == nil { print("One-time code on display: ", terminator: ""); code = readLine() }
        guard var pairingCode = code else { throw TorusClientError.message("No pairing code entered") }
        let client = TorusClient(host: host, port: port, trustDirectory: trustDirectory)
        var approved: String?
        var paired = false
        for attempt in 0..<6 {
            do {
                try await client.connect(pairingCode: pairingCode, approvedCertificate: approved)
                paired = true
                break
            } catch TorusClientError.certificateChanged(let replacement) {
                fputs("WARNING: The certificate for \(host):\(port) has changed. The server may have been reset, or this may be a different device.\n", stderr)
                print("Trust the changed server certificate? [y/N] ", terminator: "")
                guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                    throw TorusClientError.message("Connection cancelled; saved server identity unchanged")
                }
                approved = replacement
            } catch TorusClientError.server(let reason, let message) where [
                "invalid_code", "pairing_expired", "pairing_locked", "client_busy", "authentication_failed"
            ].contains(reason) {
                fputs("Pairing failed: \(message)\n", stderr)
                if reason == "authentication_failed" { fputs("Press P in the server window for a new one-time code.\n", stderr) }
                guard attempt < 5 else { throw TorusClientError.message("Pairing stopped. Try again with a fresh code.") }
                print("New code (Enter to cancel): ", terminator: "")
                guard let replacement = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !replacement.isEmpty else {
                    throw TorusClientError.message("Pairing cancelled")
                }
                pairingCode = replacement
            }
        }
        guard paired else { throw TorusClientError.message("Pairing failed") }
        print("Paired over encrypted TLS. Server identity remembered.")
        do {
            if demo { try await runDemo(client) }
            else if let script = script {
                for line in try String(contentsOfFile: script, encoding: .utf8).split(separator: "\n") {
                    let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
                    print(try await client.send(fields))
                }
            } else {
                print("Enter JSON, dashboard, drawing, clear, state, or quit:")
                while let line = readLine(), line != "quit" {
                    if line.isEmpty { continue }
                    do {
                        if let mode = DisplayMode(rawValue: line) { print(try await client.setMode(mode)) }
                        else if line == "clear" { print(try await client.clear()) }
                        else if line == "state" { print(try await client.state()) }
                        else {
                            let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
                            print(try await client.send(fields))
                        }
                    } catch { print(error) }
                }
            }
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    static func runDemo(_ client: TorusClient) async throws {
        try await client.setMode(.drawing)
        try await client.clear()
        try await client.put(DrawingObject(id: "sphere", type: .sphere, position: [-0.6, 0.7, 0], color: [0.1, 0.8, 0.9], radius: 0.3))
        try await client.put(DrawingObject(id: "box", type: .box, position: [0.6, 0.7, 0], color: [1, 0.35, 0.1]))
        try await client.put(DrawingObject(id: "ring", type: .torus, position: [0, -0.2, 0], color: [0.7, 0.35, 1]))
        try await client.put(DrawingObject(id: "line", type: .line, color: [0.3, 1, 0.4], radius: 0.025,
                                         points: [[-0.9, -1.5, 0], [0.9, -1.5, 0.4]]))
        func point(_ i: Int) -> [Double] {
            let angle = Double(i) * 0.07
            return [0.65 * cos(angle), -0.85 + 0.3 * sin(angle), 0.4 * sin(angle * 0.7)]
        }
        try await client.put(DrawingObject(id: "stroke", type: .polyline, color: [1, 0.8, 0.15], radius: 0.018,
                                         points: [point(0), point(1)]))
        for i in 2..<150 {
            try await client.append(to: "stroke", points: [point(i)])
            let angle = Double(i) * 0.025
            try await client.put(DrawingObject(id: "box", type: .box, position: [0.6, 0.7, 0.15 * sin(angle)],
                rotation: [0, sin(angle/2), 0, cos(angle/2)], color: [1, 0.35, 0.1]))
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        print("Demo complete. Drawing remains on the display.")
    }
}
