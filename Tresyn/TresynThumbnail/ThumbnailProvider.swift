import CoreGraphics
import Foundation
import QuickLookThumbnailing

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        do {
            let data = try Data(contentsOf: request.fileURL)
            let archive = try JSONDecoder().decode(SceneArchive.self, from: data)
            guard archive.format == "tresyn-scene" else {
                throw ThumbnailError.invalidFormat
            }

            let size = SceneRenderer.thumbnailSize(fitting: request.maximumSize)
            let image = try SceneThumbnailRenderer.render(objects: archive.objects, size: size)
            let reply = QLThumbnailReply(contextSize: size) { context in
                context.interpolationQuality = .high
                context.draw(image, in: context.boundingBoxOfClipPath)
                return true
            }
            reply.extensionBadge = "tres"
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}

private struct SceneArchive: Decodable, Sendable {
    let format: String
    let objects: [SceneObject]
}

struct SceneObject: Decodable, Sendable {
    let type: String
    let position: [Double]?
    let scale: [Double]?
    let rotation: [Double]?
    let color: [Double]?
    let radius: Double?
    let size: [Double]?
    let majorRadius: Double?
    let minorRadius: Double?
    let points: [[Double]]?

    enum CodingKeys: String, CodingKey {
        case type, position, scale, rotation, color, radius, size, points
        case majorRadius = "major_radius"
        case minorRadius = "minor_radius"
    }
}

private enum ThumbnailError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "This isn’t a Tresyn scene file."
    }
}

private enum SceneRenderer {
    private static let sceneWidth = 2.925
    private static let sceneHeight = 5.2

    static func thumbnailSize(fitting maximumSize: CGSize) -> CGSize {
        let aspectRatio = sceneWidth / sceneHeight
        let width = min(maximumSize.width, maximumSize.height * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }

    static func draw(objects: [SceneObject], in context: CGContext, size: CGSize) {
        let canvas = fittedCanvas(in: size)
        drawBackground(in: context, size: size)

        context.saveGState()
        context.clip(to: canvas)
        for object in objects {
            draw(object, in: context, canvas: canvas)
        }
        context.restoreGState()
    }

    private static func fittedCanvas(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size)
    }

    private static func drawBackground(in context: CGContext, size: CGSize) {
        let canvas = CGRect(origin: .zero, size: size)
        context.setFillColor(CGColor(red: 0.027, green: 0.035, blue: 0.051, alpha: 1))
        context.fill(canvas)

        let colors = [
            CGColor(red: 0.09, green: 0.19, blue: 0.26, alpha: 1),
            CGColor(red: 0.027, green: 0.035, blue: 0.051, alpha: 1)
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: canvas.midX, y: canvas.midY),
                startRadius: 0,
                endCenter: CGPoint(x: canvas.midX, y: canvas.midY),
                endRadius: hypot(canvas.width, canvas.height) / 2,
                options: [.drawsAfterEndLocation]
            )
        }
    }

    private static func draw(_ object: SceneObject, in context: CGContext, canvas: CGRect) {
        let position = object.position ?? [0, 0, 0]
        let center = CGPoint(
            x: mapX(position[safe: 0] ?? 0, canvas: canvas),
            y: mapY(position[safe: 1] ?? 0, canvas: canvas)
        )
        let scale = object.scale ?? [1, 1, 1]
        let scaleX = abs(scale[safe: 0] ?? 1)
        let scaleY = abs(scale[safe: 1] ?? 1)
        let color = color(for: object)

        context.saveGState()
        context.setFillColor(color)
        context.setStrokeColor(color)

        switch object.type {
        case "line", "polyline":
            guard let points = object.points, let first = points.first else {
                context.restoreGState()
                return
            }
            context.setLineWidth(max(2, canvas.width * 0.014))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(
                x: mapX(first[safe: 0] ?? 0, canvas: canvas),
                y: mapY(first[safe: 1] ?? 0, canvas: canvas)
            ))
            for point in points.dropFirst() {
                context.addLine(to: CGPoint(
                    x: mapX(point[safe: 0] ?? 0, canvas: canvas),
                    y: mapY(point[safe: 1] ?? 0, canvas: canvas)
                ))
            }
            context.strokePath()
        case "sphere":
            let radius = max(3, (object.radius ?? 0.12) / sceneWidth * canvas.width * scaleX)
            context.fillEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        case "box":
            let objectSize = object.size ?? [0.25, 0.25, 0.25]
            let width = max(5, (objectSize[safe: 0] ?? 0.25) / sceneWidth * canvas.width * scaleX)
            let height = max(5, (objectSize[safe: 1] ?? 0.25) / sceneHeight * canvas.height * scaleY)
            context.fill(CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            ))
        case "torus":
            let radius = max(5, (object.majorRadius ?? 0.18) / sceneWidth * canvas.width * scaleX)
            let thickness = max(2, (object.minorRadius ?? 0.05) / sceneWidth * canvas.width * scaleX * 2)
            context.setLineWidth(thickness)
            context.strokeEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        default:
            context.fillEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        }

        context.restoreGState()
    }

    private static func mapX(_ value: Double, canvas: CGRect) -> Double {
        canvas.minX + (value + sceneWidth / 2) / sceneWidth * canvas.width
    }

    private static func mapY(_ value: Double, canvas: CGRect) -> Double {
        canvas.minY + (value + sceneHeight / 2) / sceneHeight * canvas.height
    }

    private static func color(for object: SceneObject) -> CGColor {
        let components = object.color ?? [0.1, 0.8, 0.7]
        return CGColor(
            red: components[safe: 0]?.clamped(to: 0...1) ?? 0.1,
            green: components[safe: 1]?.clamped(to: 0...1) ?? 0.8,
            blue: components[safe: 2]?.clamped(to: 0...1) ?? 0.7,
            alpha: 1
        )
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
