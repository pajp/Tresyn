import Cocoa
import SceneKit
import Quartz
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let archive = try JSONDecoder().decode(SceneArchive.self, from: data)
        guard archive.format == "tresyn-scene" else {
            throw PreviewError.invalidFormat
        }

        let contentSize = CGSize(width: 720, height: 1_280)
        let png = try ScenePreviewRenderer.renderPNG(objects: archive.objects, size: contentSize)
        return QLPreviewReply(
            dataOfContentType: .png,
            contentSize: contentSize
        ) { _ in
            png
        }
    }
}

private struct SceneArchive: Decodable {
    let format: String
    let version: Int
    let objects: [SceneObject]
}

struct SceneObject: Decodable {
    let id: String
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
        case id, type, position, scale, rotation, color, radius, size, points
        case majorRadius = "major_radius"
        case minorRadius = "minor_radius"
    }
}

private enum PreviewError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        "This isn’t a Tresyn scene file."
    }
}

private enum PreviewHTML {
    private static let canvasWidth = 360.0
    private static let canvasHeight = 640.0
    private static let sceneWidth = 2.925
    private static let sceneHeight = 5.2

    static func make(archive: SceneArchive) -> String {
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #07090d; }
            svg { display: block; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <svg viewBox="0 0 \(canvasWidth) \(canvasHeight)" preserveAspectRatio="xMidYMid meet" aria-label="Front view of scene">
            <defs>
                <radialGradient id="glow"><stop stop-color="#183142"/><stop offset="1" stop-color="#07090d"/></radialGradient>
            </defs>
            <rect width="100%" height="100%" fill="url(#glow)"/>
            \(archive.objects.map(svg(for:)).joined())
        </svg>
        </body>
        </html>
        """
    }

    private static func svg(for object: SceneObject) -> String {
        let color = color(for: object)
        let position = object.position ?? [0, 0, 0]
        let x = mapX(position[safe: 0] ?? 0)
        let y = mapY(position[safe: 1] ?? 0)
        let scale = object.scale ?? [1, 1, 1]
        let scaleX = abs(scale[safe: 0] ?? 1)
        let scaleY = abs(scale[safe: 1] ?? 1)

        switch object.type {
        case "line", "polyline":
            guard let points = object.points, !points.isEmpty else { return "" }
            let coordinates = points.map {
                "\(mapX($0[safe: 0] ?? 0)),\(mapY($0[safe: 1] ?? 0))"
            }.joined(separator: " ")
            return "<polyline points=\"\(coordinates)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        case "sphere":
            let radius = max(5, (object.radius ?? 0.12) / sceneWidth * canvasWidth * scaleX)
            return "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"\(radius)\" fill=\"\(color)\" opacity=\".92\"/>"
        case "box":
            let size = object.size ?? [0.25, 0.25, 0.25]
            let width = max(8, (size[safe: 0] ?? 0.25) / sceneWidth * canvasWidth * scaleX)
            let height = max(8, (size[safe: 1] ?? 0.25) / sceneHeight * canvasHeight * scaleY)
            return "<rect x=\"\(x - width / 2)\" y=\"\(y - height / 2)\" width=\"\(width)\" height=\"\(height)\" rx=\"3\" fill=\"\(color)\" opacity=\".92\"/>"
        case "torus":
            let radius = max(8, (object.majorRadius ?? 0.18) / sceneWidth * canvasWidth * scaleX)
            let thickness = max(3, (object.minorRadius ?? 0.05) / sceneWidth * canvasWidth * scaleX * 2)
            return "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"\(radius)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(thickness)\"/>"
        default:
            return "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"6\" fill=\"\(color)\"/>"
        }
    }

    private static func mapX(_ value: Double) -> Double {
        (value + sceneWidth / 2) / sceneWidth * canvasWidth
    }

    private static func mapY(_ value: Double) -> Double {
        canvasHeight - (value + sceneHeight / 2) / sceneHeight * canvasHeight
    }

    private static func color(for object: SceneObject) -> String {
        let components = object.color ?? [0.1, 0.8, 0.7]
        let values = (0..<3).map { index in
            Int((components[safe: index] ?? 0.7).clamped(to: 0...1) * 255)
        }
        return "rgb(\(values[0]),\(values[1]),\(values[2]))"
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
