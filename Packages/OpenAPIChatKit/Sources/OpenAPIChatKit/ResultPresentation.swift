import Foundation

/// How an API response is shown in the UI, built directly from the JSON so the model
/// doesn't have to spend time writing the data out.
public enum ResultPresentation: Sendable, Equatable {
    /// A list (possibly wrapped, e.g. `{ "products": [...], "total": 49 }`).
    case table(ResultTable)
    /// A single object with only scalar fields.
    case record([ResultField])
    /// A single object with its own fields and several lists (e.g. a Pokémon: stats, types, moves…).
    case detail(fields: [ResultField], tables: [ResultTable])

    /// What the model reads instead of the raw JSON when the data is shown to the user.
    public func modelText(maxCharacters: Int) -> String {
        switch self {
        case .table(let table):
            return table.modelText(maxCharacters: maxCharacters, idKey: table.idKey)
        case .record(let fields):
            return Self.text(of: fields)
        case .detail(let fields, let tables):
            // Small lists go first and whole; big ones share what's left of the budget.
            var parts = fields.isEmpty ? [] : [Self.text(of: fields)]
            var remaining = maxCharacters - (parts.first?.count ?? 0)
            let ordered = tables.sorted { $0.rows.count < $1.rows.count }
            for (index, table) in ordered.enumerated() {
                let share = max(remaining / (ordered.count - index), 200)
                let text = table.modelText(maxCharacters: share, idKey: table.idKey)
                parts.append(text)
                remaining -= text.count
            }
            return parts.joined(separator: "\n")
        }
    }

    /// All rows the user can see, for features that look items up (e.g. `PathRepair`).
    public var allRows: [[String: JSONValue]] {
        switch self {
        case .table(let table): table.rows
        case .record(let fields): [Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })]
        case .detail(let fields, let tables):
            [Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })] + tables.flatMap(\.rows)
        }
    }

    private static func text(of fields: [ResultField]) -> String {
        fields.map { "\($0.key): \($0.value.scalarText.prefix(120))" }.joined(separator: "\n")
    }

    /// Keys that describe paging rather than the object itself.
    static let pagingKeys: Set<String> = ["total", "count", "page", "pages", "limit", "offset", "next", "previous", "prev",
                                          "per_page", "perpage", "pagesize", "page_size", "totalcount", "total_count",
                                          "cursor", "has_more", "hasmore", "totalpages", "total_pages"]

    public init?(_ json: JSONValue) {
        if let dict = json.objectValue {
            let lists = ResultTable.objectLists(in: dict)
            let fields = ResultField.fields(of: json) ?? []
            let meaningful = fields.filter { !Self.pagingKeys.contains($0.key.lowercased()) }
            if lists.count >= 2 || (lists.count == 1 && meaningful.count >= 3) {
                let tables = lists.compactMap { ResultTable(title: $0.key, items: $0.items) }
                    // Lists that chart well (numbers per label) are usually the interesting ones.
                    .sorted { ($0.chartable ? 0 : 1, $0.rows.count) < ($1.chartable ? 0 : 1, $1.rows.count) }
                if !tables.isEmpty {
                    self = .detail(fields: meaningful, tables: tables)
                    return
                }
            }
        }
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
    /// Plain values come first; links (images, API URLs…) are capped so they don't bury them.
    static func fields(of json: JSONValue, limit: Int = 12, maxLinks: Int = 3) -> [ResultField]? {
        guard let dict = json.objectValue else { return nil }
        let flat = ResultTable.flatten(dict)
        let isLink = { (key: String) in flat[key]?.stringValue?.hasPrefix("http") == true }
        let keys = ResultTable.order(flat.keys.filter { !isLink($0) }).prefix(limit)
            + ResultTable.order(flat.keys.filter(isLink)).prefix(maxLinks)
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
        guard let (title, items) = Self.mainList(in: json, depth: 0) else { return nil }
        self.init(title: title, items: items, maxColumns: maxColumns)
    }

    init?(title: String?, items: [[String: JSONValue]], maxColumns: Int = 5) {
        guard !items.isEmpty else { return nil }
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
            // `url` or a nested `move.url`.
            ["url", "link", "href", "permalink", "web_url", "html_url"].contains(key.lowercased().split(separator: ".").last.map(String.init) ?? key)
                && flatRows.contains { $0[key]?.stringValue?.hasPrefix("http") == true }
        }
        let readable = common.filter { key in
            guard key != link, !key.hasPrefix("@"), !key.contains(".@") else { return false }
            let average = (length[key] ?? 0) / max(frequency[key] ?? 1, 1)
            return Self.isLabel(key) || average <= 40
        }
        // Columns with the same value in every row (`type: "Feature"`) say little: they only fill
        // the slots left after the ones that vary.
        let isConstant = { (key: String) in flatRows.count >= 3 && Set(flatRows.map { $0[key]?.scalarText ?? "" }).count == 1 }
        let ordered = Self.order(readable.filter { !isConstant($0) && !Self.isIdentifier($0) })
            + Self.order(readable.filter { isConstant($0) && !Self.isIdentifier($0) })
            + Self.order(readable.filter(Self.isIdentifier))
        let columns = Array(ordered.prefix(maxColumns))
        guard !columns.isEmpty else { return nil }

        self.title = title
        self.columns = columns
        self.rows = flatRows
        self.linkColumn = link
    }

    /// The identifier column, if rows have one.
    var idKey: String? {
        rows.first?.keys.first { ["id", "uuid", "slug"].contains($0.lowercased()) }
    }

    var chartable: Bool {
        ResultChart(table: self)?.kind == .bars
    }

    /// Top-level lists of objects in an object (`stats`, `types`…).
    static func objectLists(in dict: [String: JSONValue]) -> [(key: String, items: [[String: JSONValue]])] {
        dict.compactMap { key, value in
            // `@context`, `@graph`… are JSON-LD metadata, not data.
            guard !key.hasPrefix("@"), case .array(let items) = value else { return nil }
            let objects = items.compactMap(\.objectValue)
            guard !objects.isEmpty, objects.count * 2 >= items.count else { return nil }
            return (key, objects)
        }
        .sorted { $0.key < $1.key }
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
            let numbers = values.compactMap(\.numericValue)
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
            if objects.count * 2 >= items.count && !objects.isEmpty { return (nil, objects) }
            // A list of plain values (`["1forge.com", "1password.com", …]`) becomes a one-column table.
            let scalars = items.filter { $0.stringValue != nil || $0.numberValue != nil }
            if scalars.count >= 3, scalars.count * 5 >= items.count * 4 {
                return (nil, scalars.map { ["value": $0] })
            }
            return nil
        case .object(let dict) where depth < 3:
            // A dictionary keyed by name whose values are similar objects
            // (`{"adyen.com": {...}, "amadeus.com": {...}}`) is a list in disguise.
            let objectValues = dict.filter { $0.value.objectValue != nil }
            if dict.count >= 3, objectValues.count * 5 >= dict.count * 4 {
                let items = objectValues.sorted { $0.key < $1.key }.map { key, value in
                    ["key": JSONValue.string(key)].merging(value.objectValue!) { own, _ in own }
                }
                return (nil, items)
            }
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
        for (key, value) in dict where !key.hasPrefix("@") {
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

    private static let labelKeys = ["name", "title", "label", "display_name", "displayname", "username", "email", "key", "value"]
    private static let importantFragments = ["price", "amount", "total", "status", "state", "availability", "stock",
                                             "quantity", "count", "date", "created", "updated", "type", "category"]

    /// `name`, or a nested `stat.name`.
    static func isLabel(_ key: String) -> Bool {
        labelRank(key) != nil
    }

    private static func labelRank(_ key: String) -> Int? {
        let lower = key.lowercased()
        if let i = labelKeys.firstIndex(of: lower) { return i }
        if let last = lower.split(separator: ".").last, let i = labelKeys.firstIndex(of: String(last)) { return i + 1 }
        return nil
    }

    static func isIdentifier(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower == "id" || lower.hasSuffix("id") || lower.hasSuffix("identifier") || lower == "uuid"
    }

    /// Label-like fields first, then fields that usually matter (prices, statuses, dates…), then the rest.
    /// Opaque identifiers go last since they rarely help a person reading the table.
    static func order(_ keys: [String]) -> [String] {
        func rank(_ key: String) -> Int {
            if let i = labelRank(key) { return i }
            if isIdentifier(key) { return 90 }
            if importantFragments.contains(where: key.lowercased().contains) { return 20 }
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
