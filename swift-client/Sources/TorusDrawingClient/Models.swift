import Foundation

/// Extensible JSON payload for commands not yet represented by a typed API.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum DisplayMode: String, Codable, Sendable { case dashboard, drawing }
public enum Primitive: String, Codable, Sendable {
    case sphere, box, torus, tetrahedron, cylinder, cone, capsule, line, polyline
}

/// Arrays use protocol order: XYZ vectors, XYZW quaternion, RGB color.
public struct DrawingObject: Codable, Sendable {
    public var id: String
    public var type: Primitive
    public var position: [Double]?
    public var rotation: [Double]?
    public var scale: [Double]?
    public var color: [Double]?
    public var radius: Double?
    public var size: [Double]?
    public var majorRadius: Double?
    public var minorRadius: Double?
    public var points: [[Double]]?

    public init(id: String, type: Primitive, position: [Double]? = nil,
                rotation: [Double]? = nil, scale: [Double]? = nil, color: [Double]? = nil,
                radius: Double? = nil, size: [Double]? = nil, majorRadius: Double? = nil,
                minorRadius: Double? = nil, points: [[Double]]? = nil) {
        self.id = id; self.type = type; self.position = position; self.rotation = rotation
        self.scale = scale; self.color = color; self.radius = radius; self.size = size
        self.majorRadius = majorRadius; self.minorRadius = minorRadius; self.points = points
    }

    enum CodingKeys: String, CodingKey {
        case id, type, position, rotation, scale, color, radius, size, points
        case majorRadius = "major_radius", minorRadius = "minor_radius"
    }
}

public struct SceneState: Codable, Sendable {
    public let mode: DisplayMode
    public let objectIDs: [String]
    public let objects: [DrawingObject]
    public let revision: Int
    enum CodingKeys: String, CodingKey { case mode, revision, objects; case objectIDs = "object_ids" }
}

public struct ServerCapabilities: Codable, Sendable {
    public let protocolName: String
    public let primitives: [String]
    public let limits: [String: Int]
    public let resumeToken: String?
    enum CodingKeys: String, CodingKey { case primitives, limits; case protocolName = "protocol"; case resumeToken = "resume_token" }
}

public struct ServerReply: Codable, Sendable {
    public let v: Int
    public let id: String
    public let ok: Bool
    public let result: JSONValue

    public func decodeResult<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(result))
    }
}
