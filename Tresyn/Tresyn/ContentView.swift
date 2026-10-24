import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    private static let selectionDragThreshold: CGFloat = 10

    private struct PendingSceneOpen {
        let archive: SceneArchive
        let displayName: String
    }

    @Environment(\.self) private var environment
    @StateObject private var session = DrawingSession()
    @State private var handLocation: CGPoint?
    @State private var isDirectInteractionActive = false
    @State private var isMovingSelection = false
    @State private var isManipulatingObject = false
    @State private var isAdjustingView = false
    @State private var viewResetRequest = 0
    @State private var pendingSceneOpen: PendingSceneOpen?
    @State private var isConfirmingSceneReplacement = false
    #if os(macOS)
    @State private var lastRotationDragTranslation = CGSize.zero
    @State private var lastMagnification = 1.0
    @State private var isScalingWithScrollWheel = false
    @State private var isOptionPressed = false
    #endif

    var body: some View {
        Group {
            if session.isConnected { studio } else { pairing }
        }
        .task {
            session.reconnectToLastServerIfAvailable()
        }
        .focusedSceneObject(session)
        .frame(
            minWidth: 700,
            idealWidth: 860,
            maxWidth: 900,
            minHeight: 520,
            idealHeight: 820,
            maxHeight: 1_100
        )
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
        .alert(
            "Replace Current Scene?",
            isPresented: $isConfirmingSceneReplacement,
            presenting: pendingSceneOpen
        ) { pendingScene in
            Button("Replace", role: .destructive) {
                openPendingScene(pendingScene)
            }
            Button("Cancel", role: .cancel) {
                pendingSceneOpen = nil
            }
        } message: { pendingScene in
            Text("Opening “\(pendingScene.displayName)” will replace the scene currently on the display.")
        }
        .fileImporter(isPresented: $session.isImportingScene, allowedContentTypes: [.tresynScene]) { result in
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
                    _ = try archive.validatedObjects()
                    prepareSceneOpen(archive, displayName: url.lastPathComponent)
                } catch {
                    session.reportSceneTransfer("Couldn’t open scene: \(error.localizedDescription)")
                }
            }
        }
        .onOpenURL { url in
            Task {
                await loadSceneForOpening(from: url)
            }
        }
        .onChange(of: session.isConnected) { _, isConnected in
            guard isConnected else { return }
            presentPendingSceneWhenReady()
        }
        .fileExporter(
            isPresented: $session.isExportingScene,
            document: session.exportDocument,
            contentType: .tresynScene,
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

    private func loadSceneForOpening(from url: URL) async {
        guard url.pathExtension.lowercased() == "tres" else {
            session.reportSceneTransfer("Couldn’t open scene: Unsupported file type.")
            return
        }

        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let archive = try JSONDecoder().decode(SceneArchive.self, from: data)
            _ = try archive.validatedObjects()
            prepareSceneOpen(archive, displayName: url.lastPathComponent)
        } catch {
            session.reportSceneTransfer("Couldn’t open scene: \(error.localizedDescription)")
        }
    }

    private func prepareSceneOpen(_ archive: SceneArchive, displayName: String) {
        pendingSceneOpen = PendingSceneOpen(archive: archive, displayName: displayName)
        if session.isConnected {
            presentPendingSceneWhenReady()
        } else {
            session.reportSceneTransfer("Connect to open “\(displayName)”.")
            session.reconnectToLastServerIfAvailable()
        }
    }

    private func presentPendingSceneWhenReady() {
        guard let pendingSceneOpen, session.isConnected else { return }
        if session.previewObjects.isEmpty {
            openPendingScene(pendingSceneOpen)
        } else {
            isConfirmingSceneReplacement = true
        }
    }

    private func openPendingScene(_ pendingScene: PendingSceneOpen) {
        pendingSceneOpen = nil
        Task {
            do {
                try await session.openScene(pendingScene.archive)
            } catch {
                session.reportSceneTransfer("Couldn’t open scene: \(error.localizedDescription)")
            }
        }
    }

    private var studio: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = 48
            let columnSpacing: CGFloat = geometry.size.width < 760 ? 14 : 24
            let toolsWidth: CGFloat = geometry.size.width < 760 ? 180 : 220
            let availableCanvasWidth = max(
                220,
                geometry.size.width - horizontalPadding - columnSpacing - toolsWidth
            )
            let availableCanvasHeight = max(160, geometry.size.height - 170)
            let canvasWidth = min(520, availableCanvasWidth, availableCanvasHeight * 2.925 / 5.2)

            HStack(alignment: .top, spacing: columnSpacing) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tools").font(.headline)
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 10
                        ) {
                            ForEach(DrawingSession.Tool.allCases) { tool in
                                Button { session.selectedTool = tool } label: {
                                    Label(tool.rawValue, systemImage: tool.symbol)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                .tint(session.selectedTool == tool ? .accentColor : .gray)
                            }
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
                                Button(role: .destructive) {
                                    session.deleteSelectedObject()
                                } label: {
                                    Label("Delete Selected", systemImage: "trash")
                                }
                            }
                            .labelStyle(.iconOnly)
                            .disabled(session.selectedObjectID == nil)
                        }
                        Divider()
                        ColorPicker("Color", selection: colorSelectionBinding, supportsOpacity: false)
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
                            } else {
                                Text("Select an object to change its depth")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Depth \(session.depth, format: .number.precision(.fractionLength(2)))")
                                .font(.headline)
                            Slider(value: $session.depth, in: -0.65...0.65)
                        }
                        sceneActions
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .frame(width: toolsWidth)

                VStack(alignment: .leading, spacing: 10) {
                    #if os(macOS)
                    HStack(spacing: 8) {
                    Button {
                        isAdjustingView.toggle()
                    } label: {
                        Label("Inspect", systemImage: "rotate.3d")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isAdjustingView ? .accentColor : .gray)
                    Button {
                        viewResetRequest += 1
                        isAdjustingView = false
                    } label: {
                        Label("Front", systemImage: "viewfinder")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    }
                    .controlSize(.small)
                    #endif
                    drawingSurface(maxHeight: availableCanvasHeight, maxWidth: canvasWidth)
                    if let errorStatus {
                        Text(errorStatus)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                .frame(width: canvasWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 840, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
    }

    private var sceneActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                #if !os(macOS)
                openSceneButton
                saveSceneButton
                #endif
                clearSceneButton
                disconnectButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    #if !os(macOS)
                    openSceneButton
                    saveSceneButton
                    #endif
                }
                HStack(spacing: 10) {
                    clearSceneButton
                    disconnectButton
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .disabled(session.isTransferringScene)
    }

    private var openSceneButton: some View {
        Button {
            session.requestSceneOpen()
        } label: {
            Label("Open", systemImage: "folder")
        }
    }

    private var saveSceneButton: some View {
        Button {
            session.requestSceneSave()
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
    }

    private var clearSceneButton: some View {
        Button("Clear", systemImage: "trash", role: .destructive) {
            session.clear()
        }
    }

    private var disconnectButton: some View {
        Button("Disconnect", systemImage: "xmark.circle") {
            session.disconnect()
        }
    }

    private var colorSelectionBinding: Binding<Color> {
        Binding(
            get: { session.color },
            set: { color in
                let resolved = color.resolve(in: environment)
                session.setColor(
                    color,
                    rgb: [Double(resolved.red), Double(resolved.green), Double(resolved.blue)]
                )
            }
        )
    }

    private var selectedDepthBinding: Binding<Double> {
        Binding(
            get: { session.selectedObjectDepth ?? 0 },
            set: { session.setSelectedObjectDepth($0) }
        )
    }

    private var errorStatus: String? {
        let errorPrefixes = [
            "Couldn’t", "Opening failed", "Stroke interrupted", "Connection lost",
            "The server identity changed", "This server’s identity changed"
        ]
        return errorPrefixes.contains(where: session.status.hasPrefix) ? session.status : nil
    }

    private func depthDescription(_ value: Double) -> String {
        if value > 0 { return "In front of the display plane" }
        if value < 0 { return "Behind the display plane" }
        return "On the display plane"
    }

    #if os(visionOS)
    private func directDrawingGesture(
        in size: CGSize,
        coordinateSpace3D: some CoordinateSpace3D
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace3D: coordinateSpace3D)
            .onChanged { value in
                guard !isManipulatingObject else { return }
                handLocation = value.location
                isDirectInteractionActive = true
                switch session.selectedTool {
                case .select:
                    // RealityKit entity gestures handle selection and manipulation on visionOS.
                    break
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
                finishDirectDrawingGesture(at: value.location, in: size)
            }
    }
    #else
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
                guard !isOptionPressed else { return }
                if value.translation == .zero {
                    session.selectObject(at: value.location, in: size)
                } else if hypot(value.translation.width, value.translation.height) >= Self.selectionDragThreshold {
                    if !isMovingSelection {
                        session.beginMovingSelectedObject(at: value.startLocation, in: size)
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
            finishDirectDrawingGesture(at: value.location, in: size)
        }
    }
    #endif

    #if os(macOS)
    private var selectedObjectRotationGesture: some Gesture {
        DragGesture(minimumDistance: Self.selectionDragThreshold, coordinateSpace: .local)
            .modifiers(.option)
            .onChanged { value in
                guard session.selectedTool == .select, session.selectedObjectID != nil else { return }
                if lastRotationDragTranslation == .zero {
                    session.beginTransformingSelectedObject()
                }
                let horizontalDelta = value.translation.width - lastRotationDragTranslation.width
                let verticalDelta = value.translation.height - lastRotationDragTranslation.height
                lastRotationDragTranslation = value.translation
                session.rotateSelectedObjectContinuously(
                    horizontal: .radians(Double(horizontalDelta) * 0.012),
                    vertical: .radians(Double(-verticalDelta) * 0.012)
                )
            }
            .onEnded { _ in
                session.endTransformingSelectedObject()
                lastRotationDragTranslation = .zero
            }
    }

    private var selectedObjectMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard session.selectedTool == .select, session.selectedObjectID != nil else { return }
                if lastMagnification == 1 {
                    session.beginTransformingSelectedObject()
                }
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                session.scaleSelectedObject(by: factor)
            }
            .onEnded { _ in
                session.endTransformingSelectedObject()
                lastMagnification = 1
            }
    }

    private func handleScaleScroll(_ phase: MacScrollPhase, deltaY: CGFloat) {
        guard session.selectedTool == .select, session.selectedObjectID != nil else { return }
        switch phase {
        case .began:
            guard !isScalingWithScrollWheel else { return }
            isScalingWithScrollWheel = true
            session.beginTransformingSelectedObject()
        case .changed:
            session.scaleSelectedObject(by: exp(Double(deltaY) * 0.012))
        case .ended:
            guard isScalingWithScrollWheel else { return }
            isScalingWithScrollWheel = false
            session.endTransformingSelectedObject()
        }
    }
    #endif

    private func finishDirectDrawingGesture(at location: CGPoint, in size: CGSize) {
        handLocation = location
        isDirectInteractionActive = false
        switch session.selectedTool {
        case .select:
            if isMovingSelection { session.endMovingSelectedObject() }
            isMovingSelection = false
        case .stroke:
            session.endStroke()
        case .sphere, .box, .torus:
            session.place(location, in: size)
        }
    }

    private func drawingSurface(maxHeight: CGFloat, maxWidth: CGFloat) -> some View {
        let width = min(maxWidth, maxHeight * 2.925 / 5.2)
        let height = min(maxHeight, maxWidth * 5.2 / 2.925)
        #if os(visionOS)
        return GeometryReader3D { spatialGeometry in
            let coordinateSpace = spatialGeometry.coordinateSpace3D()
            GeometryReader { geometry in
                drawingSurfaceContent
                    .simultaneousGesture(
                        directDrawingGesture(
                            in: geometry.size,
                            coordinateSpace3D: coordinateSpace
                        ),
                        isEnabled: !isAdjustingView && session.selectedTool != .select
                    )
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        #else
        return GeometryReader { geometry in
            drawingSurfaceContent
                #if os(macOS)
                .background {
                    MacScrollWheelObserver { phase, deltaY in
                        handleScaleScroll(phase, deltaY: deltaY)
                    }
                }
                .gesture(directDrawingGesture(in: geometry.size), isEnabled: !isAdjustingView)
                .highPriorityGesture(
                    selectedObjectRotationGesture,
                    isEnabled: !isAdjustingView && session.selectedTool == .select
                )
                .simultaneousGesture(
                    selectedObjectMagnifyGesture,
                    isEnabled: !isAdjustingView && session.selectedTool == .select
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2, coordinateSpace: .local)
                        .onEnded { value in
                            session.cloneObject(at: value.location, in: geometry.size)
                        },
                    isEnabled: !isAdjustingView && session.selectedTool == .select
                )
                .onModifierKeysChanged(mask: .option) { _, modifiers in
                    isOptionPressed = modifiers.contains(.option)
                }
                #else
                .gesture(directDrawingGesture(in: geometry.size), isEnabled: !isAdjustingView)
                #endif
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        #endif
    }

    private var drawingSurfaceContent: some View {
        ZStack {
            RealityDrawingPreview(
                objects: session.previewObjects,
                selectedObjectID: session.selectedObjectID,
                allowsObjectManipulation: session.selectedTool == .select,
                cameraControlsEnabled: $isAdjustingView,
                resetRequest: viewResetRequest,
                onObjectSelected: { id in
                    guard session.selectedTool == .select else { return }
                    session.selectObject(id: id)
                },
                onObjectDoubleActivated: { id in
                    guard session.selectedTool == .select else { return }
                    session.cloneObject(id: id)
                },
                onManipulationBegan: session.beginObjectManipulation,
                onManipulationChanged: session.updateObjectTransform,
                onManipulationEnded: session.endObjectManipulation,
                isManipulatingObject: $isManipulatingObject
            )
            if session.selectedTool != .select, let handLocation {
                Circle()
                    .fill(session.color)
                    .frame(width: isDirectInteractionActive ? 18 : 12, height: isDirectInteractionActive ? 18 : 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: session.color.opacity(0.8), radius: 8)
                    .position(handLocation)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .drawingPointerBehavior(isEnabled: session.selectedTool != .select)
        .drawingHoverTracking(isEnabled: session.selectedTool != .select) { phase in
            switch phase {
            case .active(let location):
                handLocation = location
            case .ended:
                if !isDirectInteractionActive { handLocation = nil }
            }
        }
    }
}

#if os(macOS)
private enum MacScrollPhase {
    case began
    case changed
    case ended
}

private struct MacScrollWheelObserver: NSViewRepresentable {
    let action: (MacScrollPhase, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var action: (MacScrollPhase, CGFloat) -> Void
        private var monitor: Any?
        private var endTask: Task<Void, Never>?
        private var isScrolling = false

        init(action: @escaping (MacScrollPhase, CGFloat) -> Void) {
            self.action = action
        }

        func startMonitoring() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopMonitoring() {
            endTask?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let view, let window = view.window, event.window === window else { return }
            let location = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(location) else { return }

            if !isScrolling {
                isScrolling = true
                action(.began, 0)
            }
            action(.changed, event.scrollingDeltaY)

            endTask?.cancel()
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self else { return }
                isScrolling = false
                action(.ended, 0)
            }
        }
    }
}
#endif

private extension View {
    @ViewBuilder
    func drawingPointerBehavior(isEnabled: Bool) -> some View {
        #if os(visionOS)
        if isEnabled {
            handPointerBehavior(.drawing)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func drawingHoverTracking(
        isEnabled: Bool,
        perform action: @escaping (HoverPhase) -> Void
    ) -> some View {
        if isEnabled {
            onContinuousHover(perform: action)
        } else {
            self
        }
    }
}

#Preview { ContentView() }
