import Foundation
import SceneKit
import TorusDrawingClient

#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#else
import UIKit
private typealias PlatformColor = UIColor
#endif

@MainActor
enum USDZExporter {
    enum ExportError: LocalizedError {
        case unableToWrite

        var errorDescription: String? {
            "The scene couldn’t be converted to USDZ."
        }
    }

    static func data(for objects: [DrawingObject]) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tresyn-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Scene.usdz")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scene = SCNScene()
        scene.rootNode.name = "TresynScene"
        objects.map(node).forEach(scene.rootNode.addChildNode)

        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw ExportError.unableToWrite
        }
        return try Data(contentsOf: url)
    }

    private static func node(for object: DrawingObject) -> SCNNode {
        let node: SCNNode
        switch object.type {
        case .sphere:
            node = SCNNode(geometry: SCNSphere(radius: object.radius ?? 0.25))
        case .box:
            let dimensions = object.size ?? [0.5, 0.5, 0.5]
            let width = dimensions[safe: 0] ?? 0.5
            let height = dimensions[safe: 1] ?? 0.5
            let length = dimensions[safe: 2] ?? 0.5
            node = SCNNode(geometry: boxGeometry(
                width: width,
                height: height,
                length: length
            ))
        case .torus:
            node = SCNNode()
            let geometryNode = SCNNode(geometry: SCNTorus(
                ringRadius: object.majorRadius ?? 0.4,
                pipeRadius: object.minorRadius ?? 0.12
            ))
            // RealityDrawingPreview generates tori in the XY plane with their
            // axis along Z. SCNTorus uses Y as its axis, so align the primitive
            // basis before applying the object's stored transform.
            geometryNode.eulerAngles.x = .pi / 2
            node.addChildNode(geometryNode)
        case .line, .polyline:
            node = strokeNode(for: object)
        }

        node.name = sanitizedName(object.id)
        applyTransform(of: object, to: node)
        applyMaterial(color: object.color, to: node)
        return node
    }

    private static func boxGeometry(width: Double, height: Double, length: Double) -> SCNGeometry {
        let halfExtents = SIMD3(Float(width / 2), Float(height / 2), Float(length / 2))
        let cornerRadius = min(halfExtents.x, min(halfExtents.y, halfExtents.z)) * 0.16
        let innerExtents = halfExtents - SIMD3(repeating: cornerRadius)
        let xCoordinates = roundedBoxCoordinates(halfExtent: halfExtents.x, inset: innerExtents.x)
        let yCoordinates = roundedBoxCoordinates(halfExtent: halfExtents.y, inset: innerExtents.y)
        let zCoordinates = roundedBoxCoordinates(halfExtent: halfExtents.z, inset: innerExtents.z)

        let faces: [([Float], [Float], (Float, Float) -> SIMD3<Float>)] = [
            (xCoordinates, yCoordinates, { SIMD3($0, $1, halfExtents.z) }),
            (xCoordinates, yCoordinates, { SIMD3(-$0, $1, -halfExtents.z) }),
            (yCoordinates, zCoordinates, { SIMD3(halfExtents.x, $0, $1) }),
            (yCoordinates, zCoordinates, { SIMD3(-halfExtents.x, $0, -$1) }),
            (zCoordinates, xCoordinates, { SIMD3($1, halfExtents.y, $0) }),
            (zCoordinates, xCoordinates, { SIMD3($1, -halfExtents.y, -$0) })
        ]

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []

        for (uCoordinates, vCoordinates, position) in faces {
            let base = UInt32(vertices.count)
            for v in vCoordinates {
                for u in uCoordinates {
                    let surfacePoint = position(u, v)
                    let innerPoint = simd_clamp(surfacePoint, -innerExtents, innerExtents)
                    let offset = surfacePoint - innerPoint
                    let normal = simd_normalize(offset)
                    let roundedPoint = innerPoint + normal * cornerRadius
                    vertices.append(SCNVector3(roundedPoint))
                    normals.append(SCNVector3(normal))
                }
            }

            for row in 0..<(vCoordinates.count - 1) {
                for column in 0..<(uCoordinates.count - 1) {
                    let lowerLeft = base + UInt32(row * uCoordinates.count + column)
                    let lowerRight = lowerLeft + 1
                    let upperLeft = lowerLeft + UInt32(uCoordinates.count)
                    let upperRight = upperLeft + 1
                    indices.append(contentsOf: [
                        lowerLeft, lowerRight, upperRight,
                        lowerLeft, upperRight, upperLeft
                    ])
                }
            }
        }

        return SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals)
            ],
            elements: [
                SCNGeometryElement(indices: indices, primitiveType: .triangles)
            ]
        )
    }

    private static func roundedBoxCoordinates(halfExtent: Float, inset: Float) -> [Float] {
        let radius = halfExtent - inset
        return [
            -halfExtent,
            -inset - radius * 2 / 3,
            -inset - radius / 3,
            -inset,
            inset,
            inset + radius / 3,
            inset + radius * 2 / 3,
            halfExtent
        ]
    }

    private static func strokeNode(for object: DrawingObject) -> SCNNode {
        let root = SCNNode()
        let points = (object.points ?? []).map(vector)
        let radius = object.radius ?? 0.015

        for (start, end) in zip(points, points.dropFirst()) {
            let offset = SIMD3<Float>(
                Float(end.x - start.x),
                Float(end.y - start.y),
                Float(end.z - start.z)
            )
            let length = simd_length(offset)
            guard length > 0.0001 else { continue }

            let segment = SCNNode(geometry: SCNCylinder(radius: radius, height: CGFloat(length)))
            segment.position = SCNVector3(
                (start.x + end.x) / 2,
                (start.y + end.y) / 2,
                (start.z + end.z) / 2
            )
            segment.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: offset / length)
            root.addChildNode(segment)
        }

        for point in points {
            let joint = SCNNode(geometry: SCNSphere(radius: radius))
            joint.position = point
            root.addChildNode(joint)
        }
        return root
    }

    private static func applyTransform(of object: DrawingObject, to node: SCNNode) {
        node.position = vector(object.position ?? [0, 0, 0])
        let scale = object.scale ?? [1, 1, 1]
        node.scale = SCNVector3(
            scale[safe: 0] ?? 1,
            scale[safe: 1] ?? 1,
            scale[safe: 2] ?? 1
        )
        let rotation = object.rotation ?? [0, 0, 0, 1]
        node.simdOrientation = simd_quatf(
            ix: Float(rotation[safe: 0] ?? 0),
            iy: Float(rotation[safe: 1] ?? 0),
            iz: Float(rotation[safe: 2] ?? 0),
            r: Float(rotation[safe: 3] ?? 1)
        )
    }

    private static func applyMaterial(color components: [Double]?, to node: SCNNode) {
        let values = components ?? [0.1, 0.8, 0.7]
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = PlatformColor(
            red: values[safe: 0]?.clamped(to: 0...1) ?? 0.1,
            green: values[safe: 1]?.clamped(to: 0...1) ?? 0.8,
            blue: values[safe: 2]?.clamped(to: 0...1) ?? 0.7,
            alpha: 1
        )
        // A partially metallic material keeps the authored color readable
        // under Quick Look's environment lighting on both curved and flat meshes.
        material.metalness.contents = 0.65
        material.roughness.contents = 0.3
        apply(material, to: node.geometry)
        node.enumerateChildNodes { child, _ in
            apply(material, to: child.geometry)
        }
    }

    private static func apply(_ material: SCNMaterial, to geometry: SCNGeometry?) {
        guard let geometry else { return }
        // SceneKit's USD converter indexes one material for every geometry
        // element. Supplying only one material can raise NSRangeException for
        // primitives such as boxes and cylinders, which have several elements.
        geometry.materials = Array(
            repeating: material,
            count: max(geometry.elementCount, 1)
        )
    }

    private static func vector(_ values: [Double]) -> SCNVector3 {
        SCNVector3(
            values[safe: 0] ?? 0,
            values[safe: 1] ?? 0,
            values[safe: 2] ?? 0
        )
    }

    private static func sanitizedName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let result = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return result.isEmpty ? "Object" : String(result)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
