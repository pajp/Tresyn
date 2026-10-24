import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealityKit
import TorusDrawingClient

struct RealityDrawingPreview: View {
    private static let displayMinimum = SIMD3<Float>(-1.4625, -2.6, -0.65)
    private static let displayMaximum = SIMD3<Float>(1.4625, 2.6, 0.65)
    #if os(macOS)
    private static let macOSSceneScale: Float = 0.24
    private static let displayWorldHeight: Float = 5.2
    #endif

    let objects: [DrawingSession.PreviewObject]
    let selectedObjectID: String?
    let allowsObjectManipulation: Bool
    @Binding var cameraControlsEnabled: Bool
    let resetRequest: Int
    let onObjectSelected: (String) -> Void
    let onObjectDoubleActivated: (String) -> Void
    let onManipulationBegan: (String) -> Void
    let onManipulationChanged: (String, Transform) -> Void
    let onManipulationEnded: (String, Transform) -> Void
    @Binding var isManipulatingObject: Bool
    @State private var root = Entity()
    #if os(visionOS)
    @State private var activelyManipulatedObjectIDs: Set<String> = []
    #endif
    #if os(macOS)
    @State private var camera = Entity()
    #endif

    var body: some View {
        RealityView { content in
            configureRoot()
            content.add(root)
            #if os(visionOS)
            _ = content.subscribe(to: ManipulationEvents.WillBegin.self) { event in
                activelyManipulatedObjectIDs.insert(event.entity.name)
                isManipulatingObject = true
                onObjectSelected(event.entity.name)
                onManipulationBegan(event.entity.name)
            }
            _ = content.subscribe(to: ManipulationEvents.DidUpdateTransform.self) { event in
                constrainToDisplayBounds(event.entity)
                onManipulationChanged(event.entity.name, event.entity.transform)
            }
            _ = content.subscribe(to: ManipulationEvents.WillEnd.self) { event in
                constrainToDisplayBounds(event.entity)
                onManipulationEnded(event.entity.name, event.entity.transform)
                activelyManipulatedObjectIDs.remove(event.entity.name)
                isManipulatingObject = !activelyManipulatedObjectIDs.isEmpty
            }
            #endif
            #if os(macOS)
            content.add(macOSCamera())
            #endif
        } update: { _ in
            updateScene()
        }
        .macOSCameraControls(isEnabled: cameraControlsEnabled)
        #if os(visionOS)
        .simultaneousGesture(
            SpatialTapGesture(count: 2)
                .targetedToAnyEntity()
                .onEnded { value in
                    guard allowsObjectManipulation else { return }
                    onObjectDoubleActivated(value.entity.name)
                }
        )
        #endif
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12), lineWidth: 1))
        #if os(macOS)
        .onChange(of: resetRequest) {
            resetMacOSCamera()
        }
        #endif
    }

    #if os(visionOS)
    @MainActor
    private func constrainToDisplayBounds(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: root)
        var correction = SIMD3<Float>.zero
        for axis in 0..<2 {
            let displaySpan = Self.displayMaximum[axis] - Self.displayMinimum[axis]
            let objectSpan = bounds.max[axis] - bounds.min[axis]
            if objectSpan > displaySpan {
                correction[axis] = (Self.displayMinimum[axis] + Self.displayMaximum[axis]
                                    - bounds.min[axis] - bounds.max[axis]) / 2
            } else if bounds.min[axis] < Self.displayMinimum[axis] {
                correction[axis] = Self.displayMinimum[axis] - bounds.min[axis]
            } else if bounds.max[axis] > Self.displayMaximum[axis] {
                correction[axis] = Self.displayMaximum[axis] - bounds.max[axis]
            }
        }
        correction.z = min(max(entity.position.z, Self.displayMinimum.z), Self.displayMaximum.z)
                     - entity.position.z
        entity.position += correction
    }
    #endif

    @MainActor
    private func configureRoot() {
        #if os(visionOS)
        root.scale = SIMD3(repeating: 0.07)
        // Keep the complete drawing-depth range in front of the window surface.
        // This preserves relative Z depth without allowing negative-Z objects to
        // fall behind the SwiftUI backing layer and become occluded.
        root.position.z = 0.05
        #elseif os(macOS)
        root.scale = SIMD3(repeating: Self.macOSSceneScale)
        #else
        root.scale = SIMD3(repeating: 0.24)
        #endif
        updateScene()
    }

    #if os(macOS)
    @MainActor
    private func macOSCamera() -> Entity {
        var component = OrthographicCameraComponent()
        // Orthographic scale is the vertical half-extent of the view volume.
        component.scale = Self.displayWorldHeight * Self.macOSSceneScale / 2
        camera.components.set(component)
        resetMacOSCamera()
        return camera
    }

    @MainActor
    private func resetMacOSCamera() {
        camera.look(at: .zero, from: [0, 0, 2], relativeTo: nil)
    }

    #endif

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
            let isSelected = preview.id == selectedObjectID
            entity.components.set(OpacityComponent(opacity: isSelected ? 0.72 : 1))
            #if os(visionOS)
            if allowsObjectManipulation {
                if !entity.components.has(InputTargetComponent.self) {
                    var inputTarget = InputTargetComponent()
                    inputTarget.allowedInputTypes = .indirect
                    entity.components.set(inputTarget)
                }
                if !entity.components.has(HoverEffectComponent.self) {
                    entity.components.set(HoverEffectComponent(.highlight(
                        HoverEffectComponent.HighlightHoverEffectStyle(
                            color: .cyan,
                            strength: 2.0
                        )
                    )))
                }
                if !entity.components.has(ManipulationComponent.self) {
                    var manipulation = ManipulationComponent()
                    manipulation.releaseBehavior = .stay
                    entity.components.set(manipulation)
                }
            } else {
                entity.components.remove(InputTargetComponent.self)
                entity.components.remove(HoverEffectComponent.self)
                entity.components.remove(ManipulationComponent.self)
            }
            #endif
        }
    }

    @MainActor
    private func update(_ entity: Entity, with preview: DrawingSession.PreviewObject) {
        let object = preview.object
        if let model = entity as? ModelEntity {
            model.model?.materials = [previewMaterial(preview.color)]
        }
        if (object.type == .polyline || object.type == .line),
           let model = entity as? ModelEntity,
           let mesh = strokeMesh(for: object) {
            model.model?.mesh = mesh
            #if os(visionOS)
            // Replacing a collision component while the system is gazing at it
            // clears RealityKit's native hover state. Geometry only changes while
            // drawing, so keep the target stable throughout Select mode.
            if !allowsObjectManipulation {
                model.components.set(CollisionComponent(shapes: selectionCollisionShapes(for: object)))
            }
            #endif
        }
        #if os(visionOS)
        guard !activelyManipulatedObjectIDs.contains(entity.name) else { return }
        #endif
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
        #if os(visionOS)
        entity.components.set(CollisionComponent(shapes: selectionCollisionShapes(for: object)))
        #endif
        return entity
    }

    #if os(visionOS)
    @MainActor
    private func selectionCollisionShapes(for object: DrawingObject) -> [ShapeResource] {
        // A small invisible margin gives gaze targeting a magnetic, forgiving feel
        // without changing the model's visible size.
        let acquisitionMargin: Float = 0.035
        switch object.type {
        case .sphere:
            return [.generateSphere(radius: Float(object.radius ?? 0.25) + acquisitionMargin)]
        case .box:
            let size = vector(object.size ?? [0.5, 0.5, 0.5])
            return [.generateBox(size: size + SIMD3(repeating: acquisitionMargin * 2))]
        case .torus:
            return torusCollisionShapes(
                majorRadius: Float(object.majorRadius ?? 0.4),
                minorRadius: Float(object.minorRadius ?? 0.12),
                acquisitionMargin: acquisitionMargin
            )
        case .line, .polyline:
            return strokeCollisionShapes(for: object, acquisitionMargin: acquisitionMargin)
        }
    }

    @MainActor
    private func strokeCollisionShapes(
        for object: DrawingObject,
        acquisitionMargin: Float
    ) -> [ShapeResource] {
        let points = (object.points ?? []).map(vector)
        let radius = max(Float(object.radius ?? 0.015) + acquisitionMargin, 0.04)
        let shapes = zip(points, points.dropFirst()).compactMap { start, end -> ShapeResource? in
            let offset = end - start
            let length = simd_length(offset)
            guard length > 0.0001 else { return nil }
            let orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: offset / length)
            return ShapeResource.generateCapsule(height: length + radius * 2, radius: radius)
                .offsetBy(rotation: orientation, translation: (start + end) / 2)
        }
        if !shapes.isEmpty { return shapes }
        return points.first.map {
            [ShapeResource.generateSphere(radius: radius).offsetBy(translation: $0)]
        } ?? []
    }

    @MainActor
    private func torusCollisionShapes(
        majorRadius: Float,
        minorRadius: Float,
        acquisitionMargin: Float,
        segments: Int = 24
    ) -> [ShapeResource] {
        let targetRadius = minorRadius + acquisitionMargin
        return (0..<segments).map { segment in
            let startAngle = Float(segment) / Float(segments) * .pi * 2
            let endAngle = Float(segment + 1) / Float(segments) * .pi * 2
            let start = SIMD3<Float>(cos(startAngle) * majorRadius, sin(startAngle) * majorRadius, 0)
            let end = SIMD3<Float>(cos(endAngle) * majorRadius, sin(endAngle) * majorRadius, 0)
            let offset = end - start
            let length = simd_length(offset)
            let orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: offset / length)
            return ShapeResource.generateCapsule(height: length + targetRadius * 2, radius: targetRadius)
                .offsetBy(rotation: orientation, translation: (start + end) / 2)
        }
    }
    #endif

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

private extension View {
    @ViewBuilder
    func macOSCameraControls(isEnabled: Bool) -> some View {
        #if os(macOS)
        realityViewCameraControls(isEnabled ? .orbit : .none)
        #else
        self
        #endif
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
