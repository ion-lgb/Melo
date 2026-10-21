import Foundation

/// 宽松 JSON 值：用于承载原版 LX 的 `meta` 字段、设置项、自定义源脚本事件等
/// 结构不固定的数据，保证读写原版 JSON 时不丢字段。
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v):
            if v.rounded() == v, abs(v) < 9_007_199_254_740_992 {
                try container.encode(Int64(v))
            } else {
                try container.encode(v)
            }
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    // MARK: - 访问器

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        if case .int(let v) = self { return String(v) }
        if case .double(let v) = self { return String(v) }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return Int(v)
        case .double(let v): return Int(v)
        case .bool(let v): return v ? 1 : 0
        case .string(let v): return Int(v)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let v): return Double(v)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .string(let v): return ["true", "1", "yes"].contains(v.lowercased())
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let dict) = self else { return nil }
            return dict[key]
        }
        set {
            guard case .object(var dict) = self else { return }
            dict[key] = newValue
            self = .object(dict)
        }
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }

    // MARK: - 便利构造

    public static func from(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let v as Bool: return .bool(v)
        case let v as Int: return .int(Int64(v))
        case let v as Int64: return .int(v)
        case let v as Double: return .double(v)
        case let v as Float: return .double(Double(v))
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map(JSONValue.from))
        case let v as [String: Any]: return .object(v.mapValues(JSONValue.from))
        default: return .null
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }

    public func jsonData(pretty: Bool = false) -> Data? {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try? encoder.encode(self)
    }

    public func jsonString(pretty: Bool = false) -> String? {
        guard let data = jsonData(pretty: pretty) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = value
    }

    public init?(jsonData: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: jsonData) else { return nil }
        self = value
    }

    public var displayString: String {
        switch self {
        case .string(let v): return v
        case .null: return ""
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        default: return jsonString() ?? ""
        }
    }
}
