import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private static let selectionDragThreshold: CGFloat = 10

    @StateObject private var session = DrawingSession()
    @State private var isImportingScene = false
    @State private var isExportingScene = false
    @State private var exportDocument = SceneExportDocument()
    @State private var handLocation: CGPoint?
    @State private var isDirectInteractionActive = false
    @State private var isMovingSelection = false

    var body: some View {
        Group {
            if session.isConnected { studio } else { pairing }
        }
        .frame(minWidth: 700, minHeight: 520)
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
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 24) {
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
                Picker("Color", selection: $session.selectedColor) {
                    ForEach(session.palette.indices, id: \.self) { index in
                        Text(session.palette[index].name).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .tint(session.color)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .frame(width: 220)

                VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(instructionText)
                        .font(.headline)
                    Spacer()
                    Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                }
                    drawingSurface(maxHeight: max(160, geometry.size.height - 170))
                    Text(session.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    sceneActions
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(24)
        }
    }

    private var sceneActions: some View {
        HStack(spacing: 10) {
            Button {
                isImportingScene = true
            } label: {
                Label("Open", systemImage: "folder")
            }
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
                Label("Save", systemImage: "square.and.arrow.down")
            }
            Spacer()
            Button("Clear", systemImage: "trash", role: .destructive) {
                session.clear()
            }
            Button("Disconnect", systemImage: "xmark.circle") {
                session.disconnect()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .disabled(session.isTransferringScene)
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

    private func drawingSurface(maxHeight: CGFloat) -> some View {
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
            .drawingPointerBehavior()
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
        .frame(
            width: min(400, maxHeight * 2.925 / 5.2),
            height: min(maxHeight, 400 * 5.2 / 2.925)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

private extension View {
    @ViewBuilder
    func drawingPointerBehavior() -> some View {
        #if os(visionOS)
        handPointerBehavior(.drawing)
        #else
        self
        #endif
    }
}

#Preview { ContentView() }
