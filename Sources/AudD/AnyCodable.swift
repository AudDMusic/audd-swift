// AnyCodable — small inline wrapper that lets us decode/encode JSON values of
// arbitrary shape so unknown fields round-trip through the `extras` accessor.
//
// Spec §5.2: every typed model exposes both typed fields we know about today
// AND an `extras: [String: AnyCodable]` accessor for unknown keys.
import Foundation

/// A type-erased JSON value usable from `Codable`.
public struct AnyCodable: @unchecked Sendable {
    /// The underlying value. May be `NSNull`, `Bool`, `Int`, `Double`, `String`,
    /// `[AnyCodable]`, or `[String: AnyCodable]`.
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }
}

extension AnyCodable: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict
        } else {
            throw DecodingError.typeMismatch(
                AnyCodable.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "AnyCodable: unsupported JSON value"
                )
            )
        }
    }
}

extension AnyCodable: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [AnyCodable]:
            try container.encode(v)
        case let v as [String: AnyCodable]:
            try container.encode(v)
        case let v as [Any]:
            try container.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]:
            var out: [String: AnyCodable] = [:]
            for (k, value) in v {
                out[k] = AnyCodable(value)
            }
            try container.encode(out)
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "AnyCodable: cannot encode \(type(of: value))"
                )
            )
        }
    }
}

extension AnyCodable: Equatable {
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        return _equalAny(lhs.value, rhs.value)
    }
}

private func _equalAny(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case (is NSNull, is NSNull):
        return true
    case let (l as Bool, r as Bool):
        return l == r
    case let (l as Int, r as Int):
        return l == r
    case let (l as Double, r as Double):
        return l == r
    case let (l as String, r as String):
        return l == r
    case let (l as [AnyCodable], r as [AnyCodable]):
        return l == r
    case let (l as [String: AnyCodable], r as [String: AnyCodable]):
        return l == r
    default:
        return false
    }
}

/// Internal coding key for arbitrary string keys when reading unknown fields.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
}
