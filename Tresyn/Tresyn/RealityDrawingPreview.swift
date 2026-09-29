import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealityKit
import TorusDrawingClient

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

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
