import SwiftUI
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealityKit
import TorusDrawingClient
import UniformTypeIdentifiers

nonisolated struct SceneArchive: Codable, Sendable {
    static let currentVersion = 1

    let format: String
    let version: Int
    let objects: [DrawingObject]

    init(objects: [DrawingObject]) {
        format = "tresyn-scene"
        version = Self.currentVersion
        self.objects = objects
    }

    func validatedObjects() throws -> [DrawingObject] {
        guard format == "tresyn-scene" else {
            throw SceneArchiveError.invalidFormat
        }
        guard version == Self.currentVersion else {
            throw SceneArchiveError.unsupportedVersion(version)
        }
        guard Set(objects.map(\.id)).count == objects.count else {
            throw SceneArchiveError.duplicateObjectIDs
        }
        return objects
    }
}

nonisolated enum SceneArchiveError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(Int)
    case duplicateObjectIDs
    case notConnected
    case restoreFailed(original: String, restore: String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This isn’t a Tresyn scene file."
        case .unsupportedVersion(let version):
            "This scene uses unsupported format version \(version)."
        case .duplicateObjectIDs:
            "The scene contains duplicate object identifiers."
        case .notConnected:
            "Connect to a Drawing Server before opening or saving a scene."
        case .restoreFailed(let original, let restore):
            "Opening failed (\(original)), and the previous scene couldn’t be restored (\(restore))."
        }
    }
}

@MainActor
final class SceneExportDocument: WritableDocument {
    static let writableContentTypes: [UTType] = [.json]

    let archive: SceneArchive

    init(archive: SceneArchive = SceneArchive(objects: [])) {
        self.archive = archive
    }

    nonisolated func writer(
        configuration: sending WriteConfiguration
    ) -> sending FileWrapperDocumentWriter<SceneArchive> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
        }
    }

    func snapshot(contentType: UTType) async throws -> sending SceneArchive {
        archive
    }
}

@MainActor
final class DrawingSession: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select = "Select", stroke = "Stroke", sphere = "Sphere", box = "Box", torus = "Torus"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: "hand.draw"
            case .stroke: "pencil.and.scribble"
            case .sphere: "circle.fill"
            case .box: "cube.fill"
            case .torus: "circle.dotted"
            }
        }
    }

    struct PreviewObject: Identifiable {
        let object: DrawingObject
        let color: Color
        var id: String { object.id }
    }

    @Published var host: String
    @Published var port = "8765"
    @Published var pairingCode = ""
    @Published var status = "Enter the server address and the code shown on Looking Glass."
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var selectedTool: Tool = .stroke
    @Published var selectedColor = 0
    @Published var depth = 0.15
    @Published var previewObjects: [PreviewObject] = []
    @Published var selectedObjectID: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var pendingCertificate: String?
    @Published var isTransferringScene = false

    let palette: [(name: String, color: Color, rgb: [Double])] = [
        ("Cyan", .cyan, [0.18, 0.83, 1]),
        ("Coral", .orange, [1, 0.38, 0.25]),
        ("Lime", .green, [0.45, 0.95, 0.42]),
        ("Violet", .purple, [0.66, 0.42, 1]),
        ("White", .white, [0.95, 0.97, 1])
    ]

    private var client: TorusClient?
    private var objectCounter = 0
    private var activeStrokeID: String?
    private var strokeInitialized = false
    private var lastStrokePoint: [Double]?
    private var bufferedPoints: [[Double]] = []
    private var flushTask: Task<Void, Never>?
    private var strokeSendTask: Task<Void, Never>?
    private var undoStack: [[DrawingObject]] = []
    private var redoStack: [[DrawingObject]] = []
    private var pendingStrokeSnapshot: [DrawingObject]?
    private var editSnapshot: [DrawingObject]?
    private var editingObject: DrawingObject?

    var color: Color { palette[selectedColor].color }
    var rgb: [Double] { palette[selectedColor].rgb }
    var selectedColorName: String { palette[selectedColor].name }
    var selectedObjectDepth: Double? {
        guard let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object else { return nil }
        return objectCenter(object)[2]
    }

    init() {
        host = UserDefaults.standard.string(forKey: "lastDrawingServerHost") ?? "looking-glass.local"
    }

    private func previewObject(_ object: DrawingObject) -> PreviewObject {
        let rgb = object.color ?? [0.1, 0.8, 0.7]
        return PreviewObject(object: object, color: Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2]))
    }

    func connect(approvedCertificate: String? = nil) {
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(port), !cleanHost.isEmpty else {
            status = "Use a server address and port."
            return
        }
        isConnecting = true
        let newClient = TorusClient(host: cleanHost, port: port)
        guard newClient.canResume() || pairingCode.count == 6 else {
            isConnecting = false
            status = "Enter the six-digit display code to pair this device."
            return
        }
        status = newClient.canResume() ? "Reconnecting securely with \(cleanHost)…" : "Pairing securely with \(cleanHost)…"
        Task {
            do {
                _ = try await newClient.connect(pairingCode: pairingCode.isEmpty ? nil : pairingCode, approvedCertificate: approvedCertificate)
                _ = try await newClient.setMode(.drawing)
                let scene = try await newClient.state()
                previewObjects = scene.objects.map(previewObject)
                selectedObjectID = nil
                undoStack.removeAll()
                redoStack.removeAll()
                updateHistoryAvailability()
                UserDefaults.standard.set(cleanHost, forKey: "lastDrawingServerHost")
                client = newClient
                isConnected = true
                isConnecting = false
                pendingCertificate = nil
                status = "Connected — changes appear on the Looking Glass Go immediately."
            } catch let error as TorusClientError {
                isConnecting = false
                if case .certificateChanged(let fingerprint) = error {
                    pendingCertificate = fingerprint
                    status = "This server’s identity changed. Confirm it before sending your pairing code."
                } else {
                    status = "Couldn’t connect: \(error.description)"
                }
            } catch {
                isConnecting = false
                status = "Couldn’t connect: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        flushTask?.cancel()
        strokeSendTask?.cancel()
        activeStrokeID = nil
        bufferedPoints.removeAll()
        Task { await client?.disconnect() }
        client = nil
        isConnected = false
        status = "Disconnected. The last drawing stays on the display."
    }

    func clear() {
        guard let client, !isTransferringScene else { return }
        Task {
            do {
                let snapshot = sceneObjects()
                _ = try await client.clear()
                previewObjects = []
                selectedObjectID = nil
                if !snapshot.isEmpty { recordChange(from: snapshot) }
                status = "Canvas cleared."
            } catch {
                status = "Couldn’t clear: \(error.localizedDescription)"
            }
        }
    }

    func captureScene() async throws -> SceneArchive {
        guard let client else { throw SceneArchiveError.notConnected }
        isTransferringScene = true
        defer { isTransferringScene = false }
        await strokeSendTask?.value
        let scene = try await client.state()
        return SceneArchive(objects: scene.objects)
    }

    func openScene(_ archive: SceneArchive) async throws {
        let objects = try archive.validatedObjects()
        guard let client else { throw SceneArchiveError.notConnected }
        isTransferringScene = true
        defer { isTransferringScene = false }

        flushTask?.cancel()
        flushTask = nil
        activeStrokeID = nil
        bufferedPoints.removeAll()
        await strokeSendTask?.value

        let previous = try await client.state()
        do {
            _ = try await client.clear()
            for object in objects {
                _ = try await client.put(object)
            }
            previewObjects = objects.map(previewObject)
            selectedObjectID = nil
            undoStack.removeAll()
            redoStack.removeAll()
            updateHistoryAvailability()
            updateObjectCounter(from: objects)
            status = "Opened scene with \(objects.count) objects."
        } catch {
            let originalDescription = error.localizedDescription
            do {
                _ = try await client.clear()
                for object in previous.objects {
                    _ = try await client.put(object)
                }
                previewObjects = previous.objects.map(previewObject)
                updateObjectCounter(from: previous.objects)
            } catch {
                throw SceneArchiveError.restoreFailed(
                    original: originalDescription,
                    restore: error.localizedDescription
                )
            }
            throw error
        }
    }

    func reportSceneTransfer(_ message: String) {
        status = message
    }

    private func updateObjectCounter(from objects: [DrawingObject]) {
        let maximum = objects.compactMap { object -> Int? in
            guard object.id.hasPrefix("vision-") else { return nil }
            return Int(object.id.split(separator: "-").last ?? "")
        }.max() ?? 0
        objectCounter = max(objectCounter, maximum)
    }

    private func sceneObjects() -> [DrawingObject] {
        previewObjects.map(\.object)
    }

    private func recordChange(from snapshot: [DrawingObject]) {
        undoStack.append(snapshot)
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let snapshot = undoStack.popLast(), let client, !isTransferringScene else { return }
        redoStack.append(sceneObjects())
        updateHistoryAvailability()
        replaceScene(with: snapshot, using: client, successMessage: "Undid last change.")
    }

    func redo() {
        guard let snapshot = redoStack.popLast(), let client, !isTransferringScene else { return }
        undoStack.append(sceneObjects())
        updateHistoryAvailability()
        replaceScene(with: snapshot, using: client, successMessage: "Redid change.")
    }

    private func replaceScene(
        with objects: [DrawingObject],
        using client: TorusClient,
        successMessage: String
    ) {
        isTransferringScene = true
        Task {
            await strokeSendTask?.value
            do {
                _ = try await client.clear()
                for object in objects {
                    _ = try await client.put(object)
                }
                previewObjects = objects.map(previewObject)
                selectedObjectID = nil
                status = successMessage
            } catch {
                status = "Couldn’t update scene: \(error.localizedDescription)"
            }
            isTransferringScene = false
        }
    }

    func selectObject(at location: CGPoint, in size: CGSize) {
        let point = worldPoint(location, in: size)
        selectedObjectID = previewObjects
            .map { ($0.id, planarSelectionDistance(from: point, to: $0.object)) }
            .filter { $0.1 < 0.5 }
            .min { $0.1 < $1.1 }?.0
    }

    func beginMovingSelectedObject() {
        guard editSnapshot == nil,
              let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object else { return }
        editSnapshot = sceneObjects()
        editingObject = object
    }

    func moveSelectedObject(to location: CGPoint, in size: CGSize) {
        guard let selectedObjectID, let original = editingObject,
              let index = previewObjects.firstIndex(where: { $0.id == selectedObjectID }) else { return }
        let target = worldPoint(location, in: size)
        let center = objectCenter(original)
        let offset = [target[0] - center[0], target[1] - center[1], 0]
        let moved = transformed(original, translation: offset)
        previewObjects[index] = previewObject(moved)
    }

    func endMovingSelectedObject() {
        guard let snapshot = editSnapshot, let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object,
              let client else {
            editSnapshot = nil
            editingObject = nil
            return
        }
        recordChange(from: snapshot)
        editSnapshot = nil
        editingObject = nil
        Task {
            do { _ = try await client.put(object) }
            catch { status = "Couldn’t move object: \(error.localizedDescription)" }
        }
    }

    func beginChangingSelectedDepth() {
        guard editSnapshot == nil, selectedObjectID != nil else { return }
        editSnapshot = sceneObjects()
    }

    func setSelectedObjectDepth(_ newDepth: Double) {
        guard let selectedObjectID,
              let index = previewObjects.firstIndex(where: { $0.id == selectedObjectID }) else { return }
        let object = previewObjects[index].object
        let currentDepth = objectCenter(object)[2]
        previewObjects[index] = previewObject(
            transformed(object, translation: [0, 0, newDepth - currentDepth])
        )
    }

    func endChangingSelectedDepth() {
        guard let snapshot = editSnapshot, let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object,
              let client else {
            editSnapshot = nil
            return
        }
        recordChange(from: snapshot)
        editSnapshot = nil
        Task {
            do { _ = try await client.put(object) }
            catch { status = "Couldn’t change object depth: \(error.localizedDescription)" }
        }
    }

    func rotateSelectedObject(by angle: Angle) {
        guard let selectedObjectID,
              let index = previewObjects.firstIndex(where: { $0.id == selectedObjectID }),
              let client else { return }
        let snapshot = sceneObjects()
        var object = previewObjects[index].object
        if let points = object.points {
            let center = objectCenter(object)
            let cosine = cos(angle.radians)
            let sine = sin(angle.radians)
            object.points = points.map { point in
                let x = (point[safe: 0] ?? 0) - center[0]
                let y = (point[safe: 1] ?? 0) - center[1]
                return [
                    center[0] + x * cosine - y * sine,
                    center[1] + x * sine + y * cosine,
                    point[safe: 2] ?? center[2]
                ]
            }
        } else {
            let current = object.rotation ?? [0, 0, 0, 1]
            let halfAngle = angle.radians / 2
            let sine = sin(halfAngle)
            let cosine = cos(halfAngle)
            let x = current[safe: 0] ?? 0
            let y = current[safe: 1] ?? 0
            let z = current[safe: 2] ?? 0
            let w = current[safe: 3] ?? 1
            object.rotation = [-sine * y, sine * x, cosine * z + sine * w, cosine * w - sine * z]
        }
        previewObjects[index] = previewObject(object)
        recordChange(from: snapshot)
        Task {
            do { _ = try await client.put(object) }
            catch { status = "Couldn’t rotate object: \(error.localizedDescription)" }
        }
    }

    func deleteSelectedObject() {
        guard let selectedObjectID, let client,
              previewObjects.contains(where: { $0.id == selectedObjectID }) else { return }
        let snapshot = sceneObjects()
        previewObjects.removeAll { $0.id == selectedObjectID }
        self.selectedObjectID = nil
        recordChange(from: snapshot)
        Task {
            do { _ = try await client.delete(selectedObjectID) }
            catch { status = "Couldn’t delete object: \(error.localizedDescription)" }
        }
    }

    private func planarSelectionDistance(from point: [Double], to object: DrawingObject) -> Double {
        guard let points = object.points, !points.isEmpty else {
            let center = objectCenter(object)
            return hypot(center[0] - point[0], center[1] - point[1])
        }

        if points.count == 1 {
            return hypot((points[0][safe: 0] ?? 0) - point[0],
                         (points[0][safe: 1] ?? 0) - point[1])
        }

        return zip(points, points.dropFirst()).map { start, end in
            let startX = start[safe: 0] ?? 0
            let startY = start[safe: 1] ?? 0
            let deltaX = (end[safe: 0] ?? 0) - startX
            let deltaY = (end[safe: 1] ?? 0) - startY
            let lengthSquared = deltaX * deltaX + deltaY * deltaY
            guard lengthSquared > 0 else { return hypot(point[0] - startX, point[1] - startY) }
            let projection = ((point[0] - startX) * deltaX + (point[1] - startY) * deltaY) / lengthSquared
            let amount = min(max(projection, 0), 1)
            return hypot(point[0] - (startX + amount * deltaX),
                         point[1] - (startY + amount * deltaY))
        }.min() ?? .infinity
    }

    private func objectCenter(_ object: DrawingObject) -> [Double] {
        if let position = object.position {
            return position
        }
        guard let points = object.points, !points.isEmpty else { return [0, 0, depth] }
        return (0..<3).map { axis in
            points.reduce(0) { $0 + ($1[safe: axis] ?? 0) } / Double(points.count)
        }
    }

    private func transformed(_ object: DrawingObject, translation: [Double]) -> DrawingObject {
        let position = object.position.map { point in zip(point, translation).map(+) }
        let points = object.points?.map { point in zip(point, translation).map(+) }
        return DrawingObject(
            id: object.id, type: object.type, position: position, rotation: object.rotation,
            scale: object.scale, color: object.color, radius: object.radius, size: object.size,
            majorRadius: object.majorRadius, minorRadius: object.minorRadius, points: points
        )
    }

    func place(_ location: CGPoint, in size: CGSize) {
        guard isConnected, !isTransferringScene, selectedTool != .stroke, let client else { return }
        let point = worldPoint(location, in: size)
        let snapshot = sceneObjects()
        objectCounter += 1
        let id = "vision-\(selectedTool.rawValue.lowercased())-\(objectCounter)"
        let object: DrawingObject
        switch selectedTool {
        case .select:
            return
        case .sphere:
            object = DrawingObject(id: id, type: .sphere, position: point, color: rgb, radius: 0.18)
        case .box:
            object = DrawingObject(id: id, type: .box, position: point, color: rgb, size: [0.32, 0.32, 0.32])
        case .torus:
            object = DrawingObject(id: id, type: .torus, position: point, color: rgb, majorRadius: 0.22, minorRadius: 0.07)
        case .stroke:
            return
        }
        previewObjects.append(previewObject(object))
        recordChange(from: snapshot)
        Task {
            do { _ = try await client.put(object) }
            catch { status = "Couldn’t place shape: \(error.localizedDescription)" }
        }
    }

    func beginStroke(at location: CGPoint, in size: CGSize) {
        guard isConnected, !isTransferringScene, selectedTool == .stroke else { return }
        objectCounter += 1
        activeStrokeID = "vision-stroke-\(objectCounter)"
        strokeInitialized = false
        lastStrokePoint = worldPoint(location, in: size)
        bufferedPoints = []
        pendingStrokeSnapshot = sceneObjects()
    }

    func continueStroke(at location: CGPoint, in size: CGSize) {
        guard let last = lastStrokePoint, let id = activeStrokeID, let client else { return }
        let next = worldPoint(location, in: size)
        guard distance(last, next) > 0.025 else { return }
        lastStrokePoint = next

        if !strokeInitialized {
            strokeInitialized = true
            let stroke = DrawingObject(id: id, type: .polyline, color: rgb, radius: 0.022, points: [last, next])
            previewObjects.append(previewObject(stroke))
            enqueueStrokeStart(stroke, using: client)
            scheduleStrokeFlush()
        } else {
            bufferedPoints.append(next)
            appendPreviewPoint(next, to: id)
        }
    }

    func endStroke() {
        flushTask?.cancel()
        flushTask = nil
        flushStroke()
        activeStrokeID = nil
        if strokeInitialized, let snapshot = pendingStrokeSnapshot {
            recordChange(from: snapshot)
        }
        pendingStrokeSnapshot = nil
        strokeInitialized = false
        lastStrokePoint = nil
    }

    private func appendPreviewPoint(_ point: [Double], to id: String) {
        guard let index = previewObjects.firstIndex(where: { $0.id == id }) else { return }
        let old = previewObjects[index]
        let drawing = old.object
        previewObjects[index] = PreviewObject(object: DrawingObject(
            id: drawing.id, type: drawing.type, position: drawing.position, rotation: drawing.rotation,
            scale: drawing.scale, color: drawing.color, radius: drawing.radius, size: drawing.size,
            majorRadius: drawing.majorRadius, minorRadius: drawing.minorRadius,
            points: (drawing.points ?? []) + [point]), color: old.color)
    }

    private func scheduleStrokeFlush() {
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(55))
            guard !Task.isCancelled else { return }
            flushStroke()
            if activeStrokeID != nil { scheduleStrokeFlush() }
        }
    }

    private func flushStroke() {
        guard let client, let id = activeStrokeID, !bufferedPoints.isEmpty else { return }
        let points = bufferedPoints
        bufferedPoints.removeAll()
        enqueueStrokeAppend(points, to: id, using: client)
    }

    private func enqueueStrokeStart(_ stroke: DrawingObject, using client: TorusClient) {
        let previous = strokeSendTask
        strokeSendTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do { _ = try await client.put(stroke) }
            catch { status = "Couldn’t start stroke: \(error.localizedDescription)" }
        }
    }

    private func enqueueStrokeAppend(_ points: [[Double]], to id: String, using client: TorusClient) {
        let previous = strokeSendTask
        strokeSendTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do { _ = try await client.append(to: id, points: points) }
            catch { status = "Stroke interrupted: \(error.localizedDescription)" }
        }
    }

    // Exact display-plane dimensions documented by the Drawing Server for Looking Glass Go.
    private func worldPoint(_ point: CGPoint, in size: CGSize) -> [Double] {
        [(Double(point.x / max(size.width, 1)) - 0.5) * 2.925,
         (0.5 - Double(point.y / max(size.height, 1))) * 5.2,
         depth]
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }
}

struct ContentView: View {
    @StateObject private var session = DrawingSession()
    @State private var isImportingScene = false
    @State private var isExportingScene = false
    @State private var exportDocument = SceneExportDocument()
    @State private var handLocation: CGPoint?
    @State private var isDirectInteractionActive = false
    @State private var isMovingSelection = false

    var body: some View {
        NavigationStack {
            Group {
                if session.isConnected { studio } else { pairing }
            }
            .navigationTitle("Tresyn")
        }
        .alert("Server identity changed", isPresented: Binding(
            get: { session.pendingCertificate != nil },
            set: { if !$0 { session.pendingCertificate = nil } }
        )) {
            Button("Trust and pair") {
                if let fingerprint = session.pendingCertificate {
                    session.connect(approvedCertificate: fingerprint)
                }
            }
            Button("Cancel", role: .cancel) { session.pendingCertificate = nil }
        } message: {
            Text("Only continue if you expected this Drawing Server. Its saved certificate no longer matches.")
        }
        .fileImporter(isPresented: $isImportingScene, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result {
                    session.reportSceneTransfer("Couldn’t open scene: \(error.localizedDescription)")
                }
                return
            }
            Task {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let archive = try JSONDecoder().decode(SceneArchive.self, from: data)
                    try await session.openScene(archive)
                } catch {
                    session.reportSceneTransfer("Couldn’t open scene: \(error.localizedDescription)")
                }
            }
        }
        .fileExporter(
            isPresented: $isExportingScene,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Tresyn Scene"
        ) { result in
            switch result {
            case .success:
                session.reportSceneTransfer("Scene saved.")
            case .failure(let error):
                session.reportSceneTransfer("Couldn’t save scene: \(error.localizedDescription)")
            }
        }
    }

    private var pairing: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 58)).foregroundStyle(.cyan)
            Text("Draw beyond the window").font(.largeTitle.bold())
            Text("Pair Tresyn with the Drawing Server running beside your Looking Glass Go.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                TextField("Server address", text: $session.host)
                TextField("Port", text: $session.port)
                TextField("Six-digit display code", text: $session.pairingCode)
            }
            .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
            Button(session.isConnecting ? "Connecting…" : "Pair with Drawing Server") { session.connect() }
                .buttonStyle(.borderedProminent).disabled(session.isConnecting)
            Text(session.status).font(.footnote).multilineTextAlignment(.center)
                .foregroundStyle(.secondary).frame(maxWidth: 480)
        }
        .padding(40)
    }

    private var studio: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tools").font(.headline)
                ForEach(DrawingSession.Tool.allCases) { tool in
                    Button { session.selectedTool = tool } label: {
                        Label(tool.rawValue, systemImage: tool.symbol).frame(width: 118, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(session.selectedTool == tool ? .accentColor : .gray)
                }
                Divider()
                HStack {
                    Button { session.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!session.canUndo)
                    Button { session.redo() } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!session.canRedo)
                }
                if session.selectedTool == .select {
                    HStack {
                        Button { session.rotateSelectedObject(by: .degrees(-15)) } label: {
                            Label("Rotate left", systemImage: "rotate.left")
                        }
                        Button { session.rotateSelectedObject(by: .degrees(15)) } label: {
                            Label("Rotate right", systemImage: "rotate.right")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(session.selectedObjectID == nil)
                    Button(role: .destructive) {
                        session.deleteSelectedObject()
                    } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .disabled(session.selectedObjectID == nil)
                }
                Divider()
                Picker("Color", selection: $session.selectedColor) {
                    ForEach(session.palette.indices, id: \.self) { index in
                        Text(session.palette[index].name).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .tint(session.color)
                Text("Selected: \(session.selectedColorName)")
                    .font(.subheadline.weight(.medium)).foregroundStyle(session.color)
                if session.selectedTool == .select {
                    if let selectedDepth = session.selectedObjectDepth {
                        Text("Object depth \(selectedDepth, format: .number.precision(.fractionLength(2)))")
                            .font(.headline)
                        Slider(value: selectedDepthBinding, in: -0.65...0.65) { isEditing in
                            if isEditing {
                                session.beginChangingSelectedDepth()
                            } else {
                                session.endChangingSelectedDepth()
                            }
                        }
                        Text(depthDescription(selectedDepth))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Select an object to change its depth")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Depth \(session.depth, format: .number.precision(.fractionLength(2)))")
                        .font(.headline)
                    Slider(value: $session.depth, in: -0.65...0.65)
                    Text(depthDescription(session.depth))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isImportingScene = true
                } label: {
                    Label("Open Scene", systemImage: "folder")
                }
                .disabled(session.isTransferringScene)
                Button {
                    Task {
                        do {
                            exportDocument = SceneExportDocument(archive: try await session.captureScene())
                            isExportingScene = true
                        } catch {
                            session.reportSceneTransfer("Couldn’t save scene: \(error.localizedDescription)")
                        }
                    }
                } label: {
                    Label("Save Scene", systemImage: "square.and.arrow.down")
                }
                .disabled(session.isTransferringScene)
                Button("Clear display", role: .destructive) { session.clear() }
                    .disabled(session.isTransferringScene)
                Button("Disconnect") { session.disconnect() }
                    .disabled(session.isTransferringScene)
            }
            .frame(width: 205).padding()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(instructionText)
                        .font(.headline)
                    Spacer()
                    Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                }
                drawingSurface
                Text(session.status).font(.footnote).foregroundStyle(.secondary)
            }
            }
            .padding(26)
        }
    }

    private var selectedDepthBinding: Binding<Double> {
        Binding(
            get: { session.selectedObjectDepth ?? 0 },
            set: { session.setSelectedObjectDepth($0) }
        )
    }

    private func depthDescription(_ value: Double) -> String {
        if value > 0 { return "In front of the display plane" }
        if value < 0 { return "Behind the display plane" }
        return "On the display plane"
    }

    private var instructionText: String {
        switch session.selectedTool {
        case .select:
            "Touch an object to select it, then pinch and drag to move"
        case .stroke:
            "Bring your hand to the canvas, then pinch and hold to draw"
        case .sphere, .box, .torus:
            "Bring your hand to the canvas, then pinch to place a \(session.selectedTool.rawValue.lowercased())"
        }
    }

    private func directDrawingGesture(in size: CGSize) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .local,
            inputKinds: .all
        )
        .onChanged { value in
            handLocation = value.location
            isDirectInteractionActive = true
            switch session.selectedTool {
            case .select:
                if value.translation == .zero {
                    session.selectObject(at: value.location, in: size)
                } else {
                    if !isMovingSelection {
                        session.beginMovingSelectedObject()
                        isMovingSelection = true
                    }
                    session.moveSelectedObject(to: value.location, in: size)
                }
            case .stroke:
                if value.translation == .zero {
                    session.beginStroke(at: value.location, in: size)
                } else {
                    session.continueStroke(at: value.location, in: size)
                }
            case .sphere, .box, .torus:
                break
            }
        }
        .onEnded { value in
            handLocation = value.location
            isDirectInteractionActive = false
            switch session.selectedTool {
            case .select:
                if isMovingSelection { session.endMovingSelectedObject() }
                isMovingSelection = false
            case .stroke:
                session.endStroke()
            case .sphere, .box, .torus:
                session.place(value.location, in: size)
            }
        }
    }

    private var drawingSurface: some View {
        GeometryReader { geometry in
            ZStack {
                RealityDrawingPreview(objects: session.previewObjects, selectedObjectID: session.selectedObjectID)
                if let handLocation {
                    Circle()
                        .fill(session.color)
                        .frame(width: isDirectInteractionActive ? 18 : 12, height: isDirectInteractionActive ? 18 : 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: session.color.opacity(0.8), radius: 8)
                        .position(handLocation)
                        .allowsHitTesting(false)
                }
                VStack {
                    Text("Looking Glass Go • 2.925 × 5.2 display-world units")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }
            .contentShape(Rectangle())
            .handPointerBehavior(.drawing)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    handLocation = location
                case .ended:
                    if !isDirectInteractionActive { handLocation = nil }
                }
            }
            .gesture(directDrawingGesture(in: geometry.size))
        }
        .aspectRatio(2.925 / 5.2, contentMode: .fit)
        .frame(maxWidth: 360, maxHeight: 640)
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

struct RealityDrawingPreview: View {
    let objects: [DrawingSession.PreviewObject]
    let selectedObjectID: String?
    @State private var root = Entity()

    var body: some View {
        RealityView { content in
            configureRoot()
            content.add(root)
        } update: { _ in
            updateScene()
        }
        .padding(8)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    @MainActor
    private func configureRoot() {
        #if os(visionOS)
        root.scale = SIMD3(repeating: 0.07)
        // Keep the complete drawing-depth range in front of the window surface.
        // This preserves relative Z depth without allowing negative-Z objects to
        // fall behind the SwiftUI backing layer and become occluded.
        root.position.z = 0.05
        #else
        root.scale = SIMD3(repeating: 0.24)
        #endif
        updateScene()
    }

    @MainActor
    private func updateScene() {
        let incomingIDs = Set(objects.map(\.id))
        for entity in Array(root.children) where !incomingIDs.contains(entity.name) {
            entity.removeFromParent()
        }

        for preview in objects {
            if let existing = root.findEntity(named: preview.id) {
                update(existing, with: preview)
            } else {
                let entity = entity(for: preview)
                entity.name = preview.id
                root.addChild(entity)
            }
        }
        for preview in objects {
            guard let entity = root.findEntity(named: preview.id) else { continue }
            entity.components.set(OpacityComponent(opacity: preview.id == selectedObjectID ? 0.72 : 1))
        }
    }

    @MainActor
    private func update(_ entity: Entity, with preview: DrawingSession.PreviewObject) {
        let object = preview.object
        if (object.type == .polyline || object.type == .line),
           let model = entity as? ModelEntity,
           let mesh = strokeMesh(for: object) {
            model.model?.mesh = mesh
        }
        entity.position = vector(object.position ?? [0, 0, 0])
        entity.scale = vector(object.scale ?? [1, 1, 1])
        let rotation = object.rotation ?? [0, 0, 0, 1]
        entity.orientation = simd_quatf(
            ix: Float(rotation[safe: 0] ?? 0),
            iy: Float(rotation[safe: 1] ?? 0),
            iz: Float(rotation[safe: 2] ?? 0),
            r: Float(rotation[safe: 3] ?? 1)
        )
    }

    @MainActor
    private func entity(for preview: DrawingSession.PreviewObject) -> Entity {
        let object = preview.object
        let material = previewMaterial(preview.color)
        let entity: ModelEntity
        switch object.type {
        case .sphere:
            entity = ModelEntity(mesh: .generateSphere(radius: Float(object.radius ?? 0.25)),
                                 materials: [material])
        case .box:
            let dimensions = object.size ?? [0.5, 0.5, 0.5]
            let size = vector(dimensions)
            entity = ModelEntity(mesh: .generateBox(size: size,
                                                      cornerRadius: min(size.x, min(size.y, size.z)) * 0.08),
                                 materials: [material])
        case .torus:
            entity = ModelEntity(mesh: torusMesh(majorRadius: Float(object.majorRadius ?? 0.4),
                                                  minorRadius: Float(object.minorRadius ?? 0.12)),
                                 materials: [material])
        case .line, .polyline:
            entity = ModelEntity(mesh: strokeMesh(for: object) ?? .generateSphere(radius: 0.001),
                                 materials: [material])
        }
        entity.position = vector(object.position ?? [0, 0, 0])
        entity.scale = vector(object.scale ?? [1, 1, 1])
        let rotation = object.rotation ?? [0, 0, 0, 1]
        entity.orientation = simd_quatf(ix: Float(rotation[safe: 0] ?? 0),
                                        iy: Float(rotation[safe: 1] ?? 0),
                                        iz: Float(rotation[safe: 2] ?? 0),
                                        r: Float(rotation[safe: 3] ?? 1))
        return entity
    }

    private func strokeMesh(for object: DrawingObject, sides: Int = 8) -> MeshResource? {
        let points = (object.points ?? []).map(vector)
        guard points.count >= 2 else { return nil }
        let radius = Float(object.radius ?? 0.015)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for (segmentIndex, pair) in zip(points, points.dropFirst()).enumerated() {
            let direction = pair.1 - pair.0
            guard simd_length_squared(direction) > 0.000001 else { continue }
            let axis = simd_normalize(direction)
            let reference = abs(axis.z) < 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
            let tangent = simd_normalize(simd_cross(axis, reference))
            let bitangent = simd_cross(axis, tangent)
            let base = UInt32(positions.count)

            for endpoint in [pair.0, pair.1] {
                for side in 0..<sides {
                    let angle = Float(side) / Float(sides) * .pi * 2
                    let normal = tangent * cos(angle) + bitangent * sin(angle)
                    positions.append(endpoint + normal * radius)
                    normals.append(normal)
                }
            }
            for side in 0..<sides {
                let next = (side + 1) % sides
                let a = base + UInt32(side)
                let b = base + UInt32(next)
                let c = base + UInt32(sides + side)
                let d = base + UInt32(sides + next)
                indices += [a, c, b, b, c, d]
            }
            _ = segmentIndex
        }

        guard !indices.isEmpty else { return nil }
        var descriptor = MeshDescriptor()
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private func previewMaterial(_ color: Color) -> SimpleMaterial {
        #if os(macOS)
        SimpleMaterial(color: NSColor(color), roughness: 0.28, isMetallic: true)
        #else
        SimpleMaterial(color: UIColor(color), roughness: 0.28, isMetallic: true)
        #endif
    }

    private func vector(_ values: [Double]) -> SIMD3<Float> {
        SIMD3(Float(values[safe: 0] ?? 0),
              Float(values[safe: 1] ?? 0),
              Float(values[safe: 2] ?? 0))
    }

    private func torusMesh(majorRadius: Float, minorRadius: Float,
                           majorSegments: Int = 36, minorSegments: Int = 14) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for major in 0..<majorSegments {
            let u = Float(major) / Float(majorSegments) * .pi * 2
            for minor in 0..<minorSegments {
                let v = Float(minor) / Float(minorSegments) * .pi * 2
                let normal = SIMD3(cos(u) * cos(v), sin(u) * cos(v), sin(v))
                normals.append(normal)
                positions.append(SIMD3(cos(u) * (majorRadius + minorRadius * cos(v)),
                                      sin(u) * (majorRadius + minorRadius * cos(v)),
                                      minorRadius * sin(v)))
            }
        }
        for major in 0..<majorSegments {
            for minor in 0..<minorSegments {
                let nextMajor = (major + 1) % majorSegments
                let nextMinor = (minor + 1) % minorSegments
                let a = UInt32(major * minorSegments + minor)
                let b = UInt32(nextMajor * minorSegments + minor)
                let c = UInt32(nextMajor * minorSegments + nextMinor)
                let d = UInt32(major * minorSegments + nextMinor)
                indices += [a, b, d, b, c, d]
            }
        }
        var descriptor = MeshDescriptor()
        descriptor.positions = .init(positions)
        descriptor.normals = .init(normals)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: 0.001)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

#Preview { ContentView() }
