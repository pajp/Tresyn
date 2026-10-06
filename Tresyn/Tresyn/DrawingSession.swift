import Combine
import Foundation
import SwiftUI
import TorusDrawingClient

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
    private var activeStrokePointCount = 0
    private var maximumStrokePointCount = 1_024
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
    private var editingStartPoint: [Double]?
    private var depthSendTask: Task<Void, Never>?
    private var connectionMonitorTask: Task<Void, Never>?
    private var sceneUpdateTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var sceneRevision = -1

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
        shouldReconnect = true
        reconnectTask?.cancel()
        status = newClient.canResume() ? "Reconnecting securely with \(cleanHost)…" : "Pairing securely with \(cleanHost)…"
        Task {
            do {
                let capabilities = try await newClient.connect(
                    pairingCode: pairingCode.isEmpty ? nil : pairingCode,
                    approvedCertificate: approvedCertificate
                )
                maximumStrokePointCount = max(2, capabilities.limits["points_per_object"] ?? 1_024)
                _ = try await newClient.setMode(.drawing)
                let scene = try await newClient.state()
                sceneRevision = scene.revision
                previewObjects = scene.objects.map(previewObject)
                updateObjectCounter(from: scene.objects)
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
                startSceneUpdates(newClient)
                startConnectionMonitoring(newClient)
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
        shouldReconnect = false
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
        sceneUpdateTask?.cancel()
        sceneUpdateTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        flushTask?.cancel()
        strokeSendTask?.cancel()
        activeStrokeID = nil
        bufferedPoints.removeAll()
        Task { await client?.disconnect() }
        client = nil
        isConnected = false
        status = "Disconnected. The last drawing stays on the display."
    }

    private func startConnectionMonitoring(_ monitoredClient: TorusClient) {
        connectionMonitorTask?.cancel()
        connectionMonitorTask = Task {
            while shouldReconnect, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard shouldReconnect, !Task.isCancelled, client === monitoredClient else { return }
                do {
                    _ = try await monitoredClient.state()
                } catch {
                    connectionMonitorTask = nil
                    connectionWasLost()
                    return
                }
            }
        }
    }

    private func startSceneUpdates(_ monitoredClient: TorusClient) {
        sceneUpdateTask?.cancel()
        sceneUpdateTask = Task {
            for await scene in monitoredClient.sceneUpdates {
                guard !Task.isCancelled, client === monitoredClient else { return }
                applyRemoteScene(scene)
            }
        }
    }

    private func applyRemoteScene(_ scene: SceneState) {
        guard scene.revision > sceneRevision else { return }
        sceneRevision = scene.revision
        previewObjects = scene.objects.map(previewObject)
        updateObjectCounter(from: scene.objects)
        if let selectedObjectID, !scene.objectIDs.contains(selectedObjectID) {
            self.selectedObjectID = nil
        }
        undoStack.removeAll()
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func connectionWasLost() {
        guard shouldReconnect, reconnectTask == nil else { return }
        sceneUpdateTask?.cancel()
        sceneUpdateTask = nil
        client = nil
        isConnecting = true
        status = "Connection lost. Reconnecting…"

        reconnectTask = Task {
            var retryDelay = Duration.seconds(1)
            while shouldReconnect, !Task.isCancelled {
                let cleanHost = host.trimmingCharacters(in: .whitespaces)
                guard let serverPort = UInt16(port), !cleanHost.isEmpty else {
                    finishReconnecting()
                    return
                }

                let newClient = TorusClient(host: cleanHost, port: serverPort)
                do {
                    let capabilities = try await newClient.connect()
                    _ = try await newClient.setMode(.drawing)
                    let scene = try await newClient.state()
                    guard shouldReconnect, !Task.isCancelled else {
                        await newClient.disconnect()
                        return
                    }

                    maximumStrokePointCount = max(2, capabilities.limits["points_per_object"] ?? 1_024)
                    sceneRevision = scene.revision
                    previewObjects = scene.objects.map(previewObject)
                    updateObjectCounter(from: scene.objects)
                    selectedObjectID = nil
                    client = newClient
                    isConnected = true
                    isConnecting = false
                    status = "Reconnected — changes appear on the Looking Glass Go immediately."
                    reconnectTask = nil
                    startSceneUpdates(newClient)
                    startConnectionMonitoring(newClient)
                    return
                } catch let error as TorusClientError {
                    if case .certificateChanged(let fingerprint) = error {
                        pendingCertificate = fingerprint
                        isConnected = false
                        status = "The server identity changed. Confirm it to reconnect."
                        finishReconnecting()
                        return
                    }
                } catch {
                    // Wake-up and network availability errors are expected while retrying.
                }

                status = "Connection lost. Retrying automatically…"
                try? await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, .seconds(15))
            }
            finishReconnecting()
        }
    }

    private func finishReconnecting() {
        isConnecting = false
        reconnectTask = nil
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

    func beginMovingSelectedObject(at location: CGPoint, in size: CGSize) {
        guard editSnapshot == nil,
              let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object else { return }
        editSnapshot = sceneObjects()
        editingObject = object
        editingStartPoint = worldPoint(location, in: size)
    }

    func moveSelectedObject(to location: CGPoint, in size: CGSize) {
        guard let selectedObjectID, let original = editingObject, let editingStartPoint,
              let index = previewObjects.firstIndex(where: { $0.id == selectedObjectID }) else { return }
        let target = worldPoint(location, in: size)
        let offset = [target[0] - editingStartPoint[0], target[1] - editingStartPoint[1], 0]
        let moved = transformed(original, translation: offset)
        previewObjects[index] = previewObject(moved)
    }

    func endMovingSelectedObject() {
        guard let snapshot = editSnapshot, let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object,
              let client else {
            editSnapshot = nil
            editingObject = nil
            editingStartPoint = nil
            return
        }
        recordChange(from: snapshot)
        editSnapshot = nil
        editingObject = nil
        editingStartPoint = nil
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
        let updatedObject = transformed(object, translation: [0, 0, newDepth - currentDepth])
        previewObjects[index] = previewObject(updatedObject)
        sendDepthUpdate(updatedObject)
    }

    func endChangingSelectedDepth() {
        guard let snapshot = editSnapshot else {
            editSnapshot = nil
            return
        }
        recordChange(from: snapshot)
        editSnapshot = nil
    }

    private func sendDepthUpdate(_ object: DrawingObject) {
        guard let client else { return }
        let previous = depthSendTask
        depthSendTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
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
        activeStrokePointCount = 0
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
            activeStrokePointCount = 2
            let stroke = DrawingObject(id: id, type: .polyline, color: rgb, radius: 0.022, points: [last, next])
            previewObjects.append(previewObject(stroke))
            enqueueStrokeStart(stroke, using: client)
            scheduleStrokeFlush()
        } else if activeStrokePointCount >= maximumStrokePointCount {
            flushStroke()
            objectCounter += 1
            let continuationID = "vision-stroke-\(objectCounter)"
            activeStrokeID = continuationID
            activeStrokePointCount = 2
            let continuation = DrawingObject(
                id: continuationID,
                type: .polyline,
                color: rgb,
                radius: 0.022,
                points: [last, next]
            )
            previewObjects.append(previewObject(continuation))
            enqueueStrokeStart(continuation, using: client)
        } else {
            activeStrokePointCount += 1
            bufferedPoints.append(next)
            appendPreviewPoint(next, to: id)
        }
    }

    func endStroke() {
        flushTask?.cancel()
        flushTask = nil
        flushStroke()
        activeStrokeID = nil
        activeStrokePointCount = 0
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
            catch { status = "Couldn’t start stroke: \(errorMessage(error))" }
        }
    }

    private func enqueueStrokeAppend(_ points: [[Double]], to id: String, using client: TorusClient) {
        let previous = strokeSendTask
        strokeSendTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do { _ = try await client.append(to: id, points: points) }
            catch { status = "Stroke interrupted: \(errorMessage(error))" }
        }
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? TorusClientError)?.description ?? error.localizedDescription
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
