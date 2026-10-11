import Foundation

/// How an API response is shown in the UI, built directly from the JSON so the model
/// doesn't have to spend time writing the data out.
public enum ResultPresentation: Sendable, Equatable {
    case table(ResultTable)
    case record([ResultField])

    /// What the model reads instead of the raw JSON when the data is shown to the user.
    public func modelText(maxCharacters: Int) -> String {
        switch self {
        case .table(let table):
            let idKey = table.rows.first?.keys.first { ["id", "uuid", "slug"].contains($0.lowercased()) }
            return table.modelText(maxCharacters: maxCharacters, idKey: idKey)
        case .record(let fields):
            return fields.map { "\($0.key): \($0.value.scalarText.prefix(120))" }.joined(separator: "\n")
        }
    }

    public init?(_ json: JSONValue) {
        if let table = ResultTable(json) {
            self = .table(table)
        } else if let fields = ResultField.fields(of: json), !fields.isEmpty {
            self = .record(fields)
        } else {
            return nil
        }
    }
}

public struct ResultField: Sendable, Equatable, Identifiable {
    public var key: String
    public var value: JSONValue
    public var id: String { key }

    /// Scalar fields of an object (one level of nesting is flattened as `parent.child`).
    static func fields(of json: JSONValue, limit: Int = 14) -> [ResultField]? {
        guard let dict = json.objectValue else { return nil }
        let flat = ResultTable.flatten(dict)
        let keys = ResultTable.order(Array(flat.keys))
        return keys.prefix(limit).map { ResultField(key: $0, value: flat[$0]!) }
    }
}

public struct ResultTable: Sendable, Equatable {
    /// Key of the list inside the response (e.g. `products`), if it wasn't the root.
    public var title: String?
    public var columns: [String]
    public var rows: [[String: JSONValue]]
    /// Column whose URL makes the first column clickable (e.g. `url`), if any.
    public var linkColumn: String?

    public init?(_ json: JSONValue, maxColumns: Int = 5) {
        guard let (title, items) = Self.mainList(in: json, depth: 0), !items.isEmpty else { return nil }
        let flatRows = items.map { Self.flatten($0) }

        // Columns: short scalar fields present in at least half of the rows.
        var frequency: [String: Int] = [:]
        var length: [String: Int] = [:]
        for row in flatRows {
            for (key, value) in row {
                frequency[key, default: 0] += 1
                length[key, default: 0] += value.scalarText.count
            }
        }
        let common = frequency.filter { $0.value * 2 >= flatRows.count }.map(\.key)
        let link = common.first { key in
            ["url", "link", "href", "permalink", "web_url", "html_url"].contains(key.lowercased())
                && flatRows.contains { $0[key]?.stringValue?.hasPrefix("http") == true }
        }
        let readable = common.filter { key in
            guard key != link else { return false }
            let average = (length[key] ?? 0) / max(frequency[key] ?? 1, 1)
            return Self.isLabel(key) || average <= 40
        }
        let columns = Array(Self.order(readable).prefix(maxColumns))
        guard !columns.isEmpty else { return nil }

        self.title = title
        self.columns = columns
        self.rows = flatRows
        self.linkColumn = link
    }

    /// Compact text for the model: the visible columns as `|`-separated rows (plus an `id` column so
    /// follow-up calls can reference items). Much smaller than the JSON, so the on-device model reads it
    /// faster, and it matches exactly what the user sees.
    public func modelText(maxCharacters: Int, idKey: String? = nil) -> String {
        var columns = self.columns
        // IDs and links let the model chain calls (e.g. a product URL needed by a detail endpoint).
        for key in [idKey, linkColumn].compactMap({ $0 }) where !columns.contains(key) && rows.contains(where: { $0[key] != nil }) {
            columns.append(key)
        }
        var lines = [(title.map { "\($0): " } ?? "") + "\(rows.count) rows. Columns: " + columns.joined(separator: " | ")]
        // Precomputed facts: small models miscount, so give them the numbers.
        lines += summaryFacts()
        var used = lines.reduce(0) { $0 + $1.count + 1 }
        for (index, row) in rows.enumerated() {
            // IDs and URLs must reach the model intact (a truncated ID means a 404); other text is clipped.
            let exact = Set([idKey, linkColumn].compactMap { $0 })
            let line = columns.map { column in
                let text = row[column]?.scalarText ?? ""
                return exact.contains(column) || column.lowercased().hasSuffix("id") ? text : String(text.prefix(60))
            }.joined(separator: " | ")
            if used + line.count > maxCharacters {
                lines.append("… \(rows.count - index) more rows not included here (the user sees them in the table)")
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Counts for enum-like columns ("availability: in_stock 12, out_of_stock 18") and ranges for numbers.
    func summaryFacts() -> [String] {
        var facts: [String] = []
        for column in columns {
            let values = rows.compactMap { $0[column] }
            guard values.count >= 2 else { continue }
            let numbers = values.compactMap(\.numberValue)
            if numbers.count == values.count, let low = numbers.min(), let high = numbers.max(), low != high {
                facts.append("\(column): min \(JSONValue.number(low).scalarText), max \(JSONValue.number(high).scalarText)")
                continue
            }
            let texts = values.map(\.scalarText)
            let distinct = Dictionary(grouping: texts, by: { $0 }).mapValues(\.count)
            if distinct.count >= 2, distinct.count <= 6, distinct.count < values.count {
                let counts = distinct.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                facts.append("\(column) counts: \(counts)")
            }
        }
        return facts.isEmpty ? [] : ["Facts for these \(rows.count) rows: " + facts.joined(separator: "; ")]
    }

    /// Adds the rows of another page, keeping this table's columns.
    public mutating func append(_ other: ResultTable) {
        rows += other.rows
    }

    /// The biggest list of objects in the response: the root array, or one nested a few levels down
    /// (e.g. `{ "products": [...], "total": 49 }` or `{ "data": { "items": [...] } }`).
    static func mainList(in json: JSONValue, depth: Int) -> (String?, [[String: JSONValue]])? {
        switch json {
        case .array(let items):
            let objects = items.compactMap(\.objectValue)
            return objects.count * 2 >= items.count && !objects.isEmpty ? (nil, objects) : nil
        case .object(let dict) where depth < 3:
            var best: (String?, [[String: JSONValue]])?
            for (key, value) in dict {
                guard let (nestedTitle, items) = mainList(in: value, depth: depth + 1) else { continue }
                if items.count > (best?.1.count ?? 0) { best = (nestedTitle ?? key, items) }
            }
            return best
        default:
            return nil
        }
    }

    /// Keeps scalar values; flattens one level of nested objects (`price.amount`).
    static func flatten(_ dict: [String: JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            switch value {
            case .null: continue
            case .string, .number, .bool: result[key] = value
            case .object(let nested):
                for (subkey, subvalue) in nested {
                    switch subvalue {
                    case .string, .number, .bool: result["\(key).\(subkey)"] = subvalue
                    default: continue
                    }
                }
            case .array(let items) where !items.isEmpty && items.allSatisfy({ $0.stringValue != nil || $0.numberValue != nil }):
                result[key] = .string(items.map(\.scalarText).joined(separator: ", "))
            default: continue
            }
        }
        return result
    }

    private static let labelKeys = ["name", "title", "label", "display_name", "displayname", "username", "email"]
    private static let importantFragments = ["price", "amount", "total", "status", "state", "availability", "stock",
                                             "quantity", "count", "date", "created", "updated", "type", "category"]

    static func isLabel(_ key: String) -> Bool {
        labelKeys.contains(key.lowercased())
    }

    /// Label-like fields first, then fields that usually matter (prices, statuses, dates…), then the rest.
    /// Opaque identifiers go last since they rarely help a person reading the table.
    static func order(_ keys: [String]) -> [String] {
        func rank(_ key: String) -> Int {
            let lower = key.lowercased()
            if let i = labelKeys.firstIndex(of: lower) { return i }
            if importantFragments.contains(where: lower.contains) { return 20 }
            if lower == "id" || lower.hasSuffix("id") || lower.hasSuffix("_id") || lower.hasSuffix(".id") { return 90 }
            return 50
        }
        return keys.sorted { (rank($0), $0) < (rank($1), $1) }
    }
}

extension JSONValue {
    /// Parses a response body when it is JSON.
    static func parseIfJSON(_ data: Data, contentType: String?) -> JSONValue? {
        let type = contentType?.lowercased() ?? ""
        guard type.contains("json") || type.isEmpty, let json = try? JSONValue.parse(data),
              json.objectValue != nil || json.arrayValue != nil else { return nil }
        return json
    }
}
