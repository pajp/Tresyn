import AppKit
import Metal
import SceneKit

enum ScenePreviewRenderer {
    enum RenderError: Error {
        case metalUnavailable
        case imageUnavailable
    }

    static func renderPNG(objects: [SceneObject], size: CGSize) throws -> Data {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.metalUnavailable
        }

        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.027, green: 0.035, blue: 0.051, alpha: 1)
        objects.map(node).forEach(scene.rootNode.addChildNode)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 4.65
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 20
        camera.position = SCNVector3(0, 0, 8)
        scene.rootNode.addChildNode(camera)

        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 1_300
        keyLight.light?.temperature = 6_500
        keyLight.eulerAngles = SCNVector3(-0.55, -0.65, 0)
        scene.rootNode.addChildNode(keyLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .omni
        fillLight.light?.intensity = 650
        fillLight.light?.color = NSColor(calibratedRed: 0.35, green: 0.65, blue: 1, alpha: 1)
        fillLight.position = SCNVector3(-3, 2, 5)
        scene.rootNode.addChildNode(fillLight)

        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 260
        ambientLight.light?.color = NSColor(calibratedWhite: 0.65, alpha: 1)
        scene.rootNode.addChildNode(ambientLight)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.imageUnavailable
        }
        return png
    }

    private static func node(for object: SceneObject) -> SCNNode {
        let node: SCNNode
        switch object.type {
        case "sphere":
            node = SCNNode(geometry: SCNSphere(radius: object.radius ?? 0.25))
        case "box":
            let dimensions = object.size ?? [0.5, 0.5, 0.5]
            let width = dimensions[safe: 0] ?? 0.5
            let height = dimensions[safe: 1] ?? 0.5
            let length = dimensions[safe: 2] ?? 0.5
            node = SCNNode(geometry: SCNBox(
                width: width,
                height: height,
                length: length,
                chamferRadius: min(width, min(height, length)) * 0.08
            ))
        case "torus":
            node = SCNNode(geometry: SCNTorus(
                ringRadius: object.majorRadius ?? 0.4,
                pipeRadius: object.minorRadius ?? 0.12
            ))
        case "line", "polyline":
            node = strokeNode(for: object)
        default:
            node = SCNNode(geometry: SCNSphere(radius: 0.01))
        }

        applyTransform(of: object, to: node)
        applyMaterial(color: object.color, to: node)
        return node
    }

    private static func strokeNode(for object: SceneObject) -> SCNNode {
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

    private static func applyTransform(of object: SceneObject, to node: SCNNode) {
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
        material.diffuse.contents = NSColor(
            calibratedRed: values[safe: 0]?.clamped(to: 0...1) ?? 0.1,
            green: values[safe: 1]?.clamped(to: 0...1) ?? 0.8,
            blue: values[safe: 2]?.clamped(to: 0...1) ?? 0.7,
            alpha: 1
        )
        material.metalness.contents = 1.0
        material.roughness.contents = 0.28
        node.geometry?.materials = [material]
        node.enumerateChildNodes { child, _ in
            child.geometry?.materials = [material]
        }
    }

    private static func vector(_ values: [Double]) -> SCNVector3 {
        SCNVector3(
            values[safe: 0] ?? 0,
            values[safe: 1] ?? 0,
            values[safe: 2] ?? 0
        )
    }
}
