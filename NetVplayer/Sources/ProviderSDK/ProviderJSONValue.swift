import Foundation

public enum ProviderJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ProviderJSONValue])
    case object([String: ProviderJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ProviderJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ProviderJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public static func object(_ values: [String: String]) -> ProviderJSONValue {
        .object(values.mapValues(ProviderJSONValue.string))
    }

    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: JSONEncoder.providerCanonical.encode(self))
    }

    public static func encode<T: Encodable>(_ value: T) throws -> ProviderJSONValue {
        try JSONDecoder().decode(ProviderJSONValue.self, from: JSONEncoder.providerCanonical.encode(value))
    }
}

public extension JSONEncoder {
    static var providerCanonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
