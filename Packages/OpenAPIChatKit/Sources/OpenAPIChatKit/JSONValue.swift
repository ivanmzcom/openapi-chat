import Foundation
import Yams

/// A minimal, order-insensitive JSON tree used to walk OpenAPI documents and API payloads.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Conversion from Foundation / Yams values

extension JSONValue {
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .number(Double(int))
        case let double as Double:
            self = .number(double)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let date as Date:
            self = .string(ISO8601DateFormatter().string(from: date))
        case let data as Data:
            self = .string(data.base64EncodedString())
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(any: $0) })
        case let dict as [AnyHashable: Any]:
            var result: [String: JSONValue] = [:]
            for (key, value) in dict { result["\(key.base)"] = JSONValue(any: value) }
            self = .object(result)
        default:
            self = .string("\(value!)")
        }
    }

    /// Parses JSON first and falls back to YAML (a superset that covers most OpenAPI files).
    public static func parse(_ data: Data) throws -> JSONValue {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return JSONValue(any: json)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenAPIError.invalidDocument("El archivo no es texto UTF-8.")
        }
        let yaml: Any?
        do {
            yaml = try Yams.load(yaml: text)
        } catch {
            throw OpenAPIError.invalidDocument("No es JSON ni YAML válido: \(error.localizedDescription)")
        }
        return JSONValue(any: yaml)
    }

    public var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n.isWholeNumber ? Int(n) as Any : n
        case .string(let s): s
        case .array(let a): a.map(\.foundationValue)
        case .object(let o): o.mapValues(\.foundationValue)
        }
    }

    public func jsonData(pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: foundationValue, options: options)) ?? Data("null".utf8)
    }

    public func jsonString(pretty: Bool = false) -> String {
        String(decoding: jsonData(pretty: pretty), as: UTF8.self)
    }

    /// Plain textual form used for query strings, headers and path segments.
    public var scalarText: String {
        switch self {
        case .null: ""
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n.isWholeNumber ? String(Int(n)) : String(n)
        case .string(let s): s
        case .array, .object: jsonString()
        }
    }
}

extension Double {
    var isWholeNumber: Bool {
        isFinite && rounded() == self && abs(self) < 9.0e15
    }
}

// MARK: - Codable (used to persist credentials and settings)

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}
