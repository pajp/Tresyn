import Combine
import Foundation
import RealityKit
import simd
import SwiftUI
import TorusDrawingClient

@MainActor
final class DrawingSession: ObservableObject {
    private static let displayMinimum = SIMD3<Double>(-1.4625, -2.6, -0.65)
    private static let displayMaximum = SIMD3<Double>(1.4625, 2.6, 0.65)

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
    @Published private(set) var color = Color(.sRGB, red: 0.18, green: 0.83, blue: 1)
    @Published private(set) var rgb = [0.18, 0.83, 1.0]
    @Published var depth = 0.15
    @Published var previewObjects: [PreviewObject] = []
    @Published var selectedObjectID: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var pendingCertificate: String?
    @Published var isTransferringScene = false
    @Published var isImportingScene = false
    @Published var isExportingScene = false
    @Published var exportDocument = SceneExportDocument()

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
    private var manipulationSnapshot: [DrawingObject]?
    private var editingObject: DrawingObject?
    private var editingStartPoint: [Double]?
    private var objectUpdateTasks: [String: Task<Void, Never>] = [:]
    private var pendingObjectUpdates: [String: DrawingObject] = [:]
    private var connectionMonitorTask: Task<Void, Never>?
    private var sceneUpdateTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var hasAttemptedAutomaticReconnect = false
    private var sceneRevision = -1
    var selectedObjectDepth: Double? {
        guard let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object else { return nil }
        return objectCenter(object)[2]
    }

    init() {
        host = UserDefaults.standard.string(forKey: "lastDrawingServerHost") ?? "looking-glass.local"
        port = UserDefaults.standard.string(forKey: "lastDrawingServerPort") ?? "8765"
    }

    var canTransferScene: Bool {
        isConnected && !isTransferringScene
    }

    func requestSceneOpen() {
        guard canTransferScene else { return }
        isImportingScene = true
    }

    func requestSceneSave() {
        guard canTransferScene else { return }
        Task {
            do {
                exportDocument = SceneExportDocument(archive: try await captureScene())
                isExportingScene = true
            } catch {
                reportSceneTransfer("Couldn’t save scene: \(error.localizedDescription)")
            }
        }
    }

    func reconnectToLastServerIfAvailable() {
        guard !hasAttemptedAutomaticReconnect else { return }
        hasAttemptedAutomaticReconnect = true

        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        guard let serverPort = UInt16(port),
              !cleanHost.isEmpty,
              UserDefaults.standard.string(forKey: "lastDrawingServerHost") != nil,
              TorusClient(host: cleanHost, port: serverPort).canResume() else { return }

        connect()
    }

    private func previewObject(_ object: DrawingObject) -> PreviewObject {
        let rgb = object.color ?? [0.1, 0.8, 0.7]
        return PreviewObject(object: object, color: Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2]))
    }

    func connect(approvedCertificate: String? = nil) {
        guard !isConnected, !isConnecting else { return }
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
                UserDefaults.standard.set(String(port), forKey: "lastDrawingServerPort")
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
        objectUpdateTasks.values.forEach { $0.cancel() }
        objectUpdateTasks.removeAll()
        pendingObjectUpdates.removeAll()
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

    func moveSelectedObject(to location: CGPoint, depthTranslation: CGFloat = 0, in size: CGSize) {
        guard let selectedObjectID, let original = editingObject, let editingStartPoint,
              let index = previewObjects.firstIndex(where: { $0.id == selectedObjectID }) else { return }
        let target = worldPoint(location, in: size)
        let originalDepth = objectCenter(original)[2]
        let requestedDepth = originalDepth + Double(depthTranslation / max(size.height, 1)) * 5.2
        let offset = [
            target[0] - editingStartPoint[0],
            target[1] - editingStartPoint[1],
            requestedDepth - originalDepth
        ]
        let moved = constrainedToDisplayBounds(transformed(original, translation: offset))
        previewObjects[index] = previewObject(moved)
        enqueueObjectUpdate(moved)
    }

    func endMovingSelectedObject() {
        guard let snapshot = editSnapshot, let selectedObjectID,
              let object = previewObjects.first(where: { $0.id == selectedObjectID })?.object else {
            editSnapshot = nil
            editingObject = nil
            editingStartPoint = nil
            return
        }
        recordChange(from: snapshot)
        editSnapshot = nil
        editingObject = nil
        editingStartPoint = nil
        enqueueObjectUpdate(object)
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
        let updatedObject = constrainedToDisplayBounds(
            transformed(object, translation: [0, 0, newDepth - currentDepth])
        )
        previewObjects[index] = previewObject(updatedObject)
        enqueueObjectUpdate(updatedObject)
    }

    func endChangingSelectedDepth() {
        guard let snapshot = editSnapshot else {
            editSnapshot = nil
            return
        }
        recordChange(from: snapshot)
        editSnapshot = nil
    }

    private func enqueueObjectUpdate(_ object: DrawingObject) {
        pendingObjectUpdates[object.id] = object
        guard objectUpdateTasks[object.id] == nil else { return }
        objectUpdateTasks[object.id] = Task { [weak self] in
            await self?.sendPendingObjectUpdates(for: object.id)
        }
    }

    private func sendPendingObjectUpdates(for objectID: String) async {
        while !Task.isCancelled {
            guard let object = pendingObjectUpdates.removeValue(forKey: objectID) else {
                objectUpdateTasks[objectID] = nil
                return
            }
            guard let client else {
                objectUpdateTasks[objectID] = nil
                return
            }
            do {
                _ = try await client.put(object)
            } catch {
                status = "Couldn’t update object: \(error.localizedDescription)"
            }
        }
        objectUpdateTasks[objectID] = nil
    }

    func selectObject(id: String) {
        guard let object = previewObjects.first(where: { $0.id == id })?.object else { return }
        selectedObjectID = id
        if let objectColor = object.color, objectColor.count >= 3 {
            rgb = Array(objectColor.prefix(3))
            color = Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
        }
    }

    func cloneObject(at location: CGPoint, in size: CGSize) {
        let point = worldPoint(location, in: size)
        guard let id = previewObjects
            .map({ ($0.id, planarSelectionDistance(from: point, to: $0.object)) })
            .filter({ $0.1 < 0.5 })
            .min(by: { $0.1 < $1.1 })?.0 else { return }
        cloneObject(id: id)
    }

    func cloneObject(id: String) {
        guard let source = previewObjects.first(where: { $0.id == id })?.object,
              client != nil,
              !isTransferringScene else { return }

        let snapshot = sceneObjects()
        let horizontalOffset = objectCenter(source)[0] > 0 ? -0.35 : 0.35
        let shifted = constrainedToDisplayBounds(
            transformed(source, translation: [horizontalOffset, 0, 0])
        )
        objectCounter += 1
        let clone = DrawingObject(
            id: "vision-\(source.type.rawValue)-\(objectCounter)",
            type: shifted.type,
            position: shifted.position,
            rotation: shifted.rotation,
            scale: shifted.scale,
            color: shifted.color,
            radius: shifted.radius,
            size: shifted.size,
            majorRadius: shifted.majorRadius,
            minorRadius: shifted.minorRadius,
            points: shifted.points
        )
        previewObjects.append(previewObject(clone))
        selectedObjectID = clone.id
        recordChange(from: snapshot)
        enqueueObjectUpdate(clone)
        status = "Cloned selected object."
    }

    func setColor(_ color: Color, rgb: [Double]) {
        guard rgb.count >= 3 else { return }
        let safeRGB = rgb.prefix(3).map { component in
            min(max(component.isFinite ? component : 0, 0), 1)
        }
        self.color = color
        self.rgb = safeRGB

        guard selectedTool == .select,
              let selectedObjectID,
              let objectIndex = previewObjects.firstIndex(where: { $0.id == selectedObjectID }),
              client != nil else { return }
        let snapshot = sceneObjects()
        let current = previewObjects[objectIndex].object
        let updated = DrawingObject(
            id: current.id,
            type: current.type,
            position: current.position,
            rotation: current.rotation,
            scale: current.scale,
            color: self.rgb,
            radius: current.radius,
            size: current.size,
            majorRadius: current.majorRadius,
            minorRadius: current.minorRadius,
            points: current.points
        )
        previewObjects[objectIndex] = previewObject(updated)
        recordChange(from: snapshot)
        enqueueObjectUpdate(updated)
    }

    func beginObjectManipulation(id: String) {
        guard client != nil, previewObjects.contains(where: { $0.id == id }) else { return }
        selectedObjectID = id
        if manipulationSnapshot == nil {
            manipulationSnapshot = sceneObjects()
        }
    }

    func updateObjectTransform(id: String, transform: Transform) {
        guard let index = previewObjects.firstIndex(where: { $0.id == id }),
              client != nil else { return }
        let updated = constrainedToDisplayBounds(object(previewObjects[index].object, applying: transform))
        previewObjects[index] = previewObject(updated)
        selectedObjectID = id
        enqueueObjectUpdate(updated)
    }

    func endObjectManipulation(id: String, transform: Transform) {
        updateObjectTransform(id: id, transform: transform)
        guard let snapshot = manipulationSnapshot else { return }
        manipulationSnapshot = nil
        recordChange(from: snapshot)
    }

    private func object(_ current: DrawingObject, applying transform: Transform) -> DrawingObject {
        let rotation = transform.rotation.vector
        return DrawingObject(
            id: current.id,
            type: current.type,
            position: [
                Double(transform.translation.x),
                Double(transform.translation.y),
                Double(transform.translation.z)
            ],
            rotation: [Double(rotation.x), Double(rotation.y), Double(rotation.z), Double(rotation.w)],
            scale: [Double(transform.scale.x), Double(transform.scale.y), Double(transform.scale.z)],
            color: current.color,
            radius: current.radius,
            size: current.size,
            majorRadius: current.majorRadius,
            minorRadius: current.minorRadius,
            points: current.points
        )
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
        object = constrainedToDisplayBounds(object)
        previewObjects[index] = previewObject(object)
        recordChange(from: snapshot)
        Task {
            do { _ = try await client.put(object) }
            catch { status = "Couldn’t rotate object: \(error.localizedDescription)" }
        }
    }

    func beginTransformingSelectedObject() {
        guard manipulationSnapshot == nil, selectedObjectID != nil, client != nil else { return }
        manipulationSnapshot = sceneObjects()
    }

    func rotateSelectedObjectContinuously(horizontal: Angle, vertical: Angle) {
        guard manipulationSnapshot != nil else { return }
        updateSelectedObject { object in
            var object = object
            if let points = object.points {
                let center = objectCenter(object)
                let horizontalCosine = cos(horizontal.radians)
                let horizontalSine = sin(horizontal.radians)
                let verticalCosine = cos(vertical.radians)
                let verticalSine = sin(vertical.radians)
                object.points = points.map { point in
                    let x = (point[safe: 0] ?? 0) - center[0]
                    let y = (point[safe: 1] ?? 0) - center[1]
                    let z = (point[safe: 2] ?? 0) - center[2]
                    let rotatedX = x * horizontalCosine - y * horizontalSine
                    let rotatedY = x * horizontalSine + y * horizontalCosine
                    return [
                        center[0] + rotatedX,
                        center[1] + rotatedY * verticalCosine - z * verticalSine,
                        center[2] + rotatedY * verticalSine + z * verticalCosine
                    ]
                }
            } else {
                let current = object.rotation ?? [0, 0, 0, 1]
                let currentRotation = simd_quatd(
                    ix: current[safe: 0] ?? 0,
                    iy: current[safe: 1] ?? 0,
                    iz: current[safe: 2] ?? 0,
                    r: current[safe: 3] ?? 1
                )
                let horizontalRotation = simd_quatd(
                    angle: horizontal.radians,
                    axis: SIMD3<Double>(0, 0, 1)
                )
                let verticalRotation = simd_quatd(
                    angle: vertical.radians,
                    axis: SIMD3<Double>(1, 0, 0)
                )
                let rotation = simd_normalize(verticalRotation * horizontalRotation * currentRotation).vector
                object.rotation = [rotation.x, rotation.y, rotation.z, rotation.w]
            }
            return object
        }
    }

    func scaleSelectedObject(by factor: Double) {
        guard manipulationSnapshot != nil, factor.isFinite else { return }
        let clampedFactor = min(max(factor, 0.5), 2)
        updateSelectedObject { object in
            var object = object
            if let points = object.points {
                let center = objectCenter(object)
                object.points = points.map { point in
                    [
                        center[0] + ((point[safe: 0] ?? center[0]) - center[0]) * clampedFactor,
                        center[1] + ((point[safe: 1] ?? center[1]) - center[1]) * clampedFactor,
                        center[2] + ((point[safe: 2] ?? center[2]) - center[2]) * clampedFactor
                    ]
                }
                if let radius = object.radius { object.radius = radius * clampedFactor }
            } else {
                object.scale = (object.scale ?? [1, 1, 1]).map {
                    min(max($0 * clampedFactor, 0.05), 20)
                }
            }
            return object
        }
    }

    func endTransformingSelectedObject() {
        guard let snapshot = manipulationSnapshot else { return }
        manipulationSnapshot = nil
        recordChange(from: snapshot)
    }

    private func updateSelectedObject(_ transform: (DrawingObject) -> DrawingObject) {
        guard let selectedObjectID,
              let index = previewObjects.firstIndex(where: { $0.id == selectedObjectID }),
              client != nil else { return }
        let object = constrainedToDisplayBounds(transform(previewObjects[index].object))
        previewObjects[index] = previewObject(object)
        enqueueObjectUpdate(object)
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
        let constrainedObject = constrainedToDisplayBounds(object)
        previewObjects.append(previewObject(constrainedObject))
        recordChange(from: snapshot)
        Task {
            do { _ = try await client.put(constrainedObject) }
            catch { status = "Couldn’t place shape: \(error.localizedDescription)" }
        }
    }

    func beginStroke(at location: CGPoint, in size: CGSize) {
        guard isConnected, !isTransferringScene, selectedTool == .stroke else { return }
        objectCounter += 1
        activeStrokeID = "vision-stroke-\(objectCounter)"
        activeStrokePointCount = 0
        strokeInitialized = false
        lastStrokePoint = worldPoint(location, in: size, inset: 0.022)
        bufferedPoints = []
        pendingStrokeSnapshot = sceneObjects()
    }

    func continueStroke(at location: CGPoint, in size: CGSize) {
        guard let last = lastStrokePoint, let id = activeStrokeID, let client else { return }
        let next = worldPoint(location, in: size, inset: 0.022)
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

    private func constrainedToDisplayBounds(_ object: DrawingObject) -> DrawingObject {
        let bounds = worldBounds(of: object)
        var correction = SIMD3<Double>.zero

        for axis in 0..<2 {
            let displaySpan = Self.displayMaximum[axis] - Self.displayMinimum[axis]
            let objectSpan = bounds.maximum[axis] - bounds.minimum[axis]
            if objectSpan > displaySpan {
                correction[axis] = (Self.displayMinimum[axis] + Self.displayMaximum[axis]
                                    - bounds.minimum[axis] - bounds.maximum[axis]) / 2
            } else if bounds.minimum[axis] < Self.displayMinimum[axis] {
                correction[axis] = Self.displayMinimum[axis] - bounds.minimum[axis]
            } else if bounds.maximum[axis] > Self.displayMaximum[axis] {
                correction[axis] = Self.displayMaximum[axis] - bounds.maximum[axis]
            }
        }

        // Depth controls represent the object's position in the Looking Glass
        // volume, so the object's center may use the complete -0.65...0.65 range.
        let objectDepth = objectCenter(object)[2]
        correction.z = min(max(objectDepth, Self.displayMinimum.z), Self.displayMaximum.z) - objectDepth

        guard correction != .zero else { return object }
        var constrained = object
        if let position = constrained.position {
            constrained.position = (0..<3).map { (position[safe: $0] ?? 0) + correction[$0] }
        } else if let points = constrained.points {
            constrained.points = points.map { point in
                (0..<3).map { (point[safe: $0] ?? 0) + correction[$0] }
            }
        }
        return constrained
    }

    private func worldBounds(of object: DrawingObject) -> (minimum: SIMD3<Double>, maximum: SIMD3<Double>) {
        let localBounds = localBounds(of: object)
        let position = vector3(object.position ?? [0, 0, 0])
        let scale = vector3(object.scale ?? [1, 1, 1])
        let rotation = object.rotation ?? [0, 0, 0, 1]
        let orientation = simd_quatd(
            ix: rotation[safe: 0] ?? 0,
            iy: rotation[safe: 1] ?? 0,
            iz: rotation[safe: 2] ?? 0,
            r: rotation[safe: 3] ?? 1
        ).normalized
        var minimum = SIMD3<Double>(repeating: .infinity)
        var maximum = SIMD3<Double>(repeating: -.infinity)

        for x in [localBounds.minimum.x, localBounds.maximum.x] {
            for y in [localBounds.minimum.y, localBounds.maximum.y] {
                for z in [localBounds.minimum.z, localBounds.maximum.z] {
                    let point = position + orientation.act(SIMD3(x, y, z) * scale)
                    minimum = SIMD3(
                        min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z)
                    )
                    maximum = SIMD3(
                        max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z)
                    )
                }
            }
        }
        return (minimum, maximum)
    }

    private func localBounds(of object: DrawingObject) -> (minimum: SIMD3<Double>, maximum: SIMD3<Double>) {
        if let points = object.points, !points.isEmpty {
            let radius = object.radius ?? 0
            var minimum = SIMD3<Double>(repeating: .infinity)
            var maximum = SIMD3<Double>(repeating: -.infinity)
            for values in points {
                let point = vector3(values)
                minimum = SIMD3(
                    min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z)
                )
                maximum = SIMD3(
                    max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z)
                )
            }
            return (minimum - SIMD3(repeating: radius), maximum + SIMD3(repeating: radius))
        }

        let halfExtents: SIMD3<Double>
        switch object.type {
        case .sphere:
            halfExtents = SIMD3(repeating: object.radius ?? 0.25)
        case .box:
            halfExtents = vector3(object.size ?? [0.5, 0.5, 0.5]) / 2
        case .torus:
            let outerRadius = (object.majorRadius ?? 0.4) + (object.minorRadius ?? 0.12)
            halfExtents = SIMD3(outerRadius, outerRadius, object.minorRadius ?? 0.12)
        case .line, .polyline:
            halfExtents = .zero
        }
        return (-halfExtents, halfExtents)
    }

    private func vector3(_ values: [Double]) -> SIMD3<Double> {
        SIMD3(values[safe: 0] ?? 0, values[safe: 1] ?? 0, values[safe: 2] ?? 0)
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? TorusClientError)?.description ?? error.localizedDescription
    }

    // Exact display-plane dimensions documented by the Drawing Server for Looking Glass Go.
    private func worldPoint(_ point: CGPoint, in size: CGSize, inset: Double = 0) -> [Double] {
        let projected = SIMD3(
            (Double(point.x / max(size.width, 1)) - 0.5) * 2.925,
            (0.5 - Double(point.y / max(size.height, 1))) * 5.2,
            depth
        )
        return (0..<3).map { axis in
            min(max(projected[axis], Self.displayMinimum[axis] + inset),
                Self.displayMaximum[axis] - inset)
        }
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }
}
