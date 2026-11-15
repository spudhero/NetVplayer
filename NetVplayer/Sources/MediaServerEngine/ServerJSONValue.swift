import Foundation

/// Media servers vary between string and numeric IDs and attributes.
indirect enum ServerJSONValue: Decodable, Sendable {
    case object([String: ServerJSONValue]), array([ServerJSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode([String: ServerJSONValue].self) { self = .object(value) }
        else if let value = try? c.decode([ServerJSONValue].self) { self = .array(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else { self = .number(try c.decode(Double.self)) }
    }
    subscript(_ key: String) -> ServerJSONValue { if case .object(let values) = self { values[key] ?? .null } else { .null } }
    var string: String? { switch self { case .string(let value): value; case .number(let value) where value.isFinite: String(format: "%.0f", value); default: nil } }
    var integer: Int64? {
        switch self {
        case .string(let value): return Int64(value)
        case .number(let value) where value.isFinite && value >= Double(Int64.min) && value < Double(Int64.max): return Int64(value)
        default: return nil
        }
    }
    var double: Double? { if case .number(let value) = self { value } else { string.flatMap(Double.init) } }
    var array: [ServerJSONValue] { if case .array(let values) = self { values } else { [] } }
    var boolean: Bool? { if case .bool(let value) = self { value } else { nil } }
}
