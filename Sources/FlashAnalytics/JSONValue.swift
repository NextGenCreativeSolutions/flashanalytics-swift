import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    static func normalize(dictionary: [String: Any]) -> [String: Any] {
        dictionary.compactMapValues(normalize(any:))
    }

    static func fromFoundation(dictionary: [String: Any]) -> JSONValue {
        .object(dictionary.mapValues { fromFoundation(any: $0) })
    }

    static func fromFoundation(any value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(Double(int))
        case let double as Double:
            return .number(double)
        case let float as Float:
            return .number(Double(float))
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue)
                : .number(number.doubleValue)
        case let array as [Any]:
            return .array(array.compactMap { normalize(any: $0) }.map(fromFoundation(any:)))
        case let object as [String: Any]:
            return .object(object.compactMapValues { normalize(any: $0) }.mapValues(fromFoundation(any:)))
        case _ as NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }

    func toFoundationObject() -> Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case let .object(value):
            return value.mapValues { $0.toFoundationObject() }
        case let .array(value):
            return value.map { $0.toFoundationObject() }
        case .null:
            return NSNull()
        }
    }

    private static func normalize(any value: Any?) -> Any? {
        switch value {
        case nil:
            return nil
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : number
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let url as URL:
            return url.absoluteString
        case let array as [Any]:
            return array.compactMap(normalize(any:))
        case let object as [String: Any]:
            return normalize(dictionary: object)
        case _ as NSNull:
            return NSNull()
        default:
            return String(describing: value!)
        }
    }
}
