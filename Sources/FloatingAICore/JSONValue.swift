import Foundation
import CoreFoundation

/// Recursive JSON structure used at the app-server boundary. Domain UI types do not depend on it.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    public init(any value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let v as String: self = .string(v)
        case let v as NSNumber:
            self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
        case let v as [Any]: self = .array(try v.map { try JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(try v.mapValues { try JSONValue(any: $0) })
        default: throw CodexError.protocolError("Unsupported JSON value.")
        }
    }

    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public subscript(_ index: Int) -> JSONValue {
        guard let a = array, a.indices.contains(index) else { return .null }
        return a[index]
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var stringValue: String? { string }
    public var boolValue: Bool? { bool }
    public var arrayValue: [JSONValue]? { array }
    public var objectValue: [String: JSONValue]? { object }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last })) }
    public init(nilLiteral: ()) { self = .null }
}
