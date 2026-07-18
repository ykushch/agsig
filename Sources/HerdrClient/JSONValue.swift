import Foundation

/// A dynamic, decode-tolerant JSON value.
///
/// The herdr socket returns richly nested envelopes whose exact shape varies by
/// method (`result.snapshot…`, `result.read.text`, event `{event,data}`, …).
/// `JSONValue` lets the socket client (spec 01) hand back a fully-parsed but
/// untyped value that later layers (spec 02 models) can re-decode into typed
/// structs, while unknown fields never cause a hard failure.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Convenience accessors

    public subscript(_ key: String) -> JSONValue? {
        if case let .object(dict) = self { return dict[key] }
        return nil
    }

    public subscript(_ index: Int) -> JSONValue? {
        if case let .array(arr) = self, arr.indices.contains(index) { return arr[index] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(n) = self { return n }
        return nil
    }

    public var intValue: Int? {
        if case let .number(n) = self { return Int(n) }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(b): try container.encode(b)
        case let .number(n): try container.encode(n)
        case let .string(s): try container.encode(s)
        case let .array(a): try container.encode(a)
        case let .object(o): try container.encode(o)
        }
    }
}

extension JSONValue {
    /// Parse raw bytes (one JSON object) into a `JSONValue`.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Serialize to compact UTF-8 bytes (no trailing newline).
    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Bridge the dynamic value into a typed `Decodable` model.
    ///
    /// The socket client hands back untyped `JSONValue`s; typed models (spec 02)
    /// call this to decode a nested piece — e.g.
    /// `result["snapshot"]?.decode(Snapshot.self)`.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try serialized()
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
