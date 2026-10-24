import Foundation
import SwiftUI
import TorusDrawingClient
import UniformTypeIdentifiers

extension UTType {
    static let tresynScene = UTType(exportedAs: "nu.dll.tresyn.scene", conformingTo: .json)
}

nonisolated struct SceneArchive: Codable, Sendable {
    static let currentVersion = 1

    let format: String
    let version: Int
    let objects: [DrawingObject]

    init(objects: [DrawingObject]) {
        format = "tresyn-scene"
        version = Self.currentVersion
        self.objects = objects
    }

    func validatedObjects() throws -> [DrawingObject] {
        guard format == "tresyn-scene" else {
            throw SceneArchiveError.invalidFormat
        }
        guard version == Self.currentVersion else {
            throw SceneArchiveError.unsupportedVersion(version)
        }
        guard Set(objects.map(\.id)).count == objects.count else {
            throw SceneArchiveError.duplicateObjectIDs
        }
        return objects
    }
}

nonisolated enum SceneArchiveError: LocalizedError {
    case invalidFormat
    case unsupportedVersion(Int)
    case duplicateObjectIDs
    case notConnected
    case restoreFailed(original: String, restore: String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This isn’t a Tresyn scene file."
        case .unsupportedVersion(let version):
            "This scene uses unsupported format version \(version)."
        case .duplicateObjectIDs:
            "The scene contains duplicate object identifiers."
        case .notConnected:
            "Connect to a Drawing Server before opening or saving a scene."
        case .restoreFailed(let original, let restore):
            "Opening failed (\(original)), and the previous scene couldn’t be restored (\(restore))."
        }
    }
}

@MainActor
final class SceneExportDocument: WritableDocument {
    static let writableContentTypes: [UTType] = [.tresynScene]

    let archive: SceneArchive

    init(archive: SceneArchive = SceneArchive(objects: [])) {
        self.archive = archive
    }

    nonisolated func writer(
        configuration: sending WriteConfiguration
    ) -> sending FileWrapperDocumentWriter<SceneArchive> {
        FileWrapperDocumentWriter(configuration) { snapshot, _ in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
        }
    }

    func snapshot(contentType: UTType) async throws -> sending SceneArchive {
        archive
    }
}
