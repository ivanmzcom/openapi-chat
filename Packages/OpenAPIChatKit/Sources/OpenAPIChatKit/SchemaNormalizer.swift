import Foundation

/// A JSON Schema flattened into a single concrete shape: `$ref`s followed, `allOf` merged and
/// `oneOf`/`anyOf` collapsed to their first non-null choice. The small on-device model handles
/// a single concrete shape far better than unions.
public indirect enum NormalizedSchema: Sendable {
    case string(enumValues: [String]?)
    case integer(minimum: Double?, maximum: Double?)
    case number(minimum: Double?, maximum: Double?)
    case boolean
    case array(items: NormalizedSchema, minItems: Int?, maxItems: Int?)
    case object(properties: [(name: String, schema: NormalizedSchema, description: String?)], required: Set<String>)
    /// Free-form or recursive values. The model passes them as a JSON string.
    case any
}

public struct SchemaHints: Sendable, Hashable {
    public var description: String?
    public var format: String?
    public var defaultValue: JSONValue?
    public var example: JSONValue?
    public var nonStringEnum: [JSONValue]?

    /// One compact line meant for the model.
    public func text(limit: Int = 160) -> String? {
        var parts: [String] = []
        if let description, !description.isEmpty {
            let clean = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            parts.append(clean.count > limit ? String(clean.prefix(limit)) + "…" : clean)
        }
        if let format { parts.append("format: \(format)") }
        if let nonStringEnum { parts.append("one of: \(nonStringEnum.map(\.scalarText).joined(separator: ", "))") }
        if let defaultValue { parts.append("default: \(defaultValue.scalarText)") }
        if let example, parts.count < 2 { parts.append("e.g. \(example.scalarText.prefix(40))") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

extension APISpec {
    /// Normalizes a raw JSON Schema. `maxDepth` limits how many nested objects are kept before
    /// falling back to `.any`, which keeps tool schemas within the model's small context.
    public func normalize(_ raw: JSONValue, maxDepth: Int = 3, maxProperties: Int = 16) -> (NormalizedSchema, SchemaHints) {
        normalize(raw, depth: 0, maxDepth: maxDepth, maxProperties: maxProperties, visiting: [])
    }

    private func flatten(_ raw: JSONValue, visiting: inout Set<String>) -> [String: JSONValue]? {
        var schema = raw
        if let ref = raw["$ref"]?.stringValue {
            guard !visiting.contains(ref) else { return nil }
            visiting.insert(ref)
            schema = resolve(raw)
            // Sibling keywords next to $ref (allowed in 3.1) win over the referenced ones.
            if var merged = schema.objectValue, let local = raw.objectValue {
                for (k, v) in local where k != "$ref" { merged[k] = v }
                schema = .object(merged)
            }
        }
        guard var dict = schema.objectValue else { return [:] }

        if let all = dict.removeValue(forKey: "allOf")?.arrayValue {
            var properties = dict["properties"]?.objectValue ?? [:]
            var required = dict["required"]?.arrayValue ?? []
            for part in all {
                guard let sub = flatten(part, visiting: &visiting) else { continue }
                for (k, v) in sub["properties"]?.objectValue ?? [:] where properties[k] == nil { properties[k] = v }
                required += sub["required"]?.arrayValue ?? []
                for (k, v) in sub where dict[k] == nil && k != "properties" && k != "required" { dict[k] = v }
            }
            if !properties.isEmpty {
                dict["properties"] = .object(properties)
                dict["type"] = .string("object")
            }
            dict["required"] = .array(required)
        }

        for key in ["oneOf", "anyOf"] {
            guard let choices = dict.removeValue(forKey: key)?.arrayValue else { continue }
            let firstConcrete = choices.first { choice in
                let resolved = resolve(choice)
                return resolved["type"]?.stringValue != "null"
            }
            if let firstConcrete, let sub = flatten(firstConcrete, visiting: &visiting) {
                for (k, v) in sub where dict[k] == nil { dict[k] = v }
            }
        }

        // OpenAPI 3.1 allows `type: [string, null]`.
        if let types = dict["type"]?.arrayValue {
            dict["type"] = types.first { $0.stringValue != "null" } ?? .string("string")
        }
        return dict
    }

    private func normalize(
        _ raw: JSONValue, depth: Int, maxDepth: Int, maxProperties: Int, visiting: Set<String>
    ) -> (NormalizedSchema, SchemaHints) {
        var visiting = visiting
        guard let dict = flatten(raw, visiting: &visiting) else {
            return (.any, SchemaHints(description: "JSON value"))
        }

        var hints = SchemaHints(
            description: dict["description"]?.stringValue ?? dict["title"]?.stringValue,
            format: dict["format"]?.stringValue,
            defaultValue: dict["default"],
            example: dict["example"] ?? dict["examples"]?.arrayValue?.first
        )

        let enumValues = dict["enum"]?.arrayValue?.filter { !$0.isNull }
        var type = dict["type"]?.stringValue
        if type == nil {
            if dict["properties"] != nil { type = "object" }
            else if dict["items"] != nil { type = "array" }
            else if let first = enumValues?.first {
                switch first {
                case .number: type = "number"
                case .bool: type = "boolean"
                default: type = "string"
                }
            }
        }

        switch type {
        case "string":
            let strings = enumValues?.compactMap(\.stringValue)
            return (.string(enumValues: strings?.isEmpty == false ? strings : nil), hints)

        case "integer", "number":
            if let enumValues, !enumValues.isEmpty { hints.nonStringEnum = enumValues }
            let minimum = dict["minimum"]?.numberValue
            let maximum = dict["maximum"]?.numberValue
            return (type == "integer" ? .integer(minimum: minimum, maximum: maximum) : .number(minimum: minimum, maximum: maximum), hints)

        case "boolean":
            return (.boolean, hints)

        case "array":
            if depth >= maxDepth { return (.any, hints) }
            let (items, itemHints) = normalize(dict["items"] ?? .object([:]), depth: depth + 1, maxDepth: maxDepth, maxProperties: maxProperties, visiting: visiting)
            if hints.description == nil { hints.description = itemHints.description.map { "list of: \($0)" } }
            return (.array(items: items, minItems: dict["minItems"]?.numberValue.map(Int.init), maxItems: dict["maxItems"]?.numberValue.map(Int.init)), hints)

        case "object":
            guard let props = dict["properties"]?.objectValue, !props.isEmpty, depth < maxDepth else {
                hints.description = [hints.description, "JSON object"].compactMap { $0 }.joined(separator: " — ")
                return (.any, hints)
            }
            let required = Set(dict["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            // Required first, then alphabetical; skip read-only fields the client cannot send.
            let names = props.keys
                .filter { props[$0]?["readOnly"]?.boolValue != true || required.contains($0) }
                .sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
                .prefix(maxProperties)
            let converted = names.map { name in
                let (schema, h) = normalize(props[name]!, depth: depth + 1, maxDepth: maxDepth, maxProperties: maxProperties, visiting: visiting)
                return (name: name, schema: schema, description: h.text())
            }
            return (.object(properties: converted, required: required.intersection(names)), hints)

        default:
            return (.any, hints)
        }
    }
}

extension NormalizedSchema {
    /// Converts a model-produced value into the shape the API expects
    /// (e.g. parses JSON strings for free-form objects, turns "3" into 3).
    public func coerce(_ value: JSONValue) -> JSONValue {
        switch (self, value) {
        case (.any, .string(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
               let parsed = try? JSONValue.parse(Data(trimmed.utf8)) {
                return parsed
            }
            return value
        case (.integer, .string(let text)):
            return Double(text).map { .number($0.rounded()) } ?? value
        case (.integer, .number(let n)):
            return .number(n.rounded())
        case (.number, .string(let text)):
            return Double(text).map(JSONValue.number) ?? value
        case (.boolean, .string(let text)):
            return .bool(["true", "1", "yes", "sí", "si"].contains(text.lowercased()))
        case (.string, .number), (.string, .bool):
            return .string(value.scalarText)
        case (.array(let items, _, _), .array(let elements)):
            return .array(elements.map(items.coerce))
        case (.array(let items, _, _), .string):
            if case .array(let parsed) = NormalizedSchema.any.coerce(value) { return .array(parsed.map(items.coerce)) }
            return .array([items.coerce(value)])
        case (.object(let properties, _), .object(var dict)):
            for property in properties {
                if let v = dict[property.name] { dict[property.name] = property.schema.coerce(v) }
            }
            return .object(dict.filter { !$0.value.isNull })
        case (.object, .string):
            return NormalizedSchema.any.coerce(value)
        default:
            return value
        }
    }
}
