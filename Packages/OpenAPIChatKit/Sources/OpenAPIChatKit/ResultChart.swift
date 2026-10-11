import Foundation

/// A chart inferred from an API response: a date + a number becomes a time series,
/// labels + a number become bars. Built from the data, no model involved.
public struct ResultChart: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Values over time (e.g. a price history).
        case timeSeries
        /// One value per label (e.g. products and their price, counts by status).
        case bars
    }

    public struct Point: Sendable, Equatable, Identifiable {
        public var id: Int
        public var label: String
        public var date: Date?
        public var value: Double
    }

    public var kind: Kind
    /// Field names, for axis titles.
    public var xKey: String
    public var yKey: String
    public var points: [Point]

    private static let maxBars = 30
    /// Fields that usually hold the measure worth plotting, most relevant first.
    private static let preferredMeasures = ["price", "amount", "total", "value", "count", "quantity", "score", "rating"]

    /// Time series when some field holds dates; otherwise bars of the label column (≤ 30 rows).
    public init?(table: ResultTable) {
        let rows = table.rows
        guard rows.count >= 2 else { return nil }
        let keys = Set(rows.flatMap(\.keys))

        let dateKey = keys.sorted().first { key in
            let dates = rows.compactMap { $0[key]?.dateValue }
            return dates.count * 5 >= rows.count * 4 && Set(dates).count >= 2
        }
        guard let measure = Self.measure(in: rows, keys: keys.subtracting([dateKey].compactMap { $0 })) else { return nil }

        if let dateKey {
            let points = rows.compactMap { row -> (Date, Double)? in
                guard let date = row[dateKey]?.dateValue, let value = row[measure]?.numericValue else { return nil }
                return (date, value)
            }
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { Point(id: $0.offset, label: "", date: $0.element.0, value: $0.element.1) }
            guard points.count >= 2 else { return nil }
            self.init(kind: .timeSeries, xKey: dateKey, yKey: measure, points: points)
        } else {
            guard rows.count <= Self.maxBars, let labelKey = table.columns.first, labelKey != measure else { return nil }
            let points = rows.enumerated().compactMap { index, row -> Point? in
                guard let value = row[measure]?.numericValue else { return nil }
                return Point(id: index, label: row[labelKey]?.scalarText ?? "—", date: nil, value: value)
            }
            guard points.count >= 2 else { return nil }
            self.init(kind: .bars, xKey: labelKey, yKey: measure, points: points)
        }
    }

    /// Bars for objects whose fields are mostly numbers, e.g. `{"approved": 7, "placed": 19}`.
    public init?(fields: [ResultField]) {
        let numeric = fields.filter { $0.value.numericValue != nil }
        guard numeric.count >= 2, numeric.count * 3 >= fields.count * 2 else { return nil }
        let points = numeric.enumerated().map { Point(id: $0.offset, label: $0.element.key, date: nil, value: $0.element.value.numericValue!) }
        self.init(kind: .bars, xKey: "", yKey: "", points: points)
    }

    private init(kind: Kind, xKey: String, yKey: String, points: [Point]) {
        self.kind = kind
        self.xKey = xKey
        self.yKey = yKey
        self.points = points
    }

    /// The numeric field to plot: present in most rows and actually varying, preferring
    /// names like `price` or `total` and skipping identifiers.
    static func measure(in rows: [[String: JSONValue]], keys: Set<String>) -> String? {
        let candidates = keys.filter { key in
            let lower = key.lowercased()
            guard lower != "id", !lower.hasSuffix("id"), !lower.hasSuffix(".id") else { return false }
            return rows.compactMap { $0[key]?.numericValue }.count * 5 >= rows.count * 4
        }
        // A flat series is still worth plotting (a price that never changed), but varying fields win.
        func rank(_ key: String) -> (Int, Int, String) {
            let lower = key.lowercased()
            let varies = Set(rows.compactMap { $0[key]?.numericValue }).count >= 2 ? 0 : 1
            return (varies, preferredMeasures.firstIndex { lower.contains($0) } ?? preferredMeasures.count, key)
        }
        return candidates.sorted { rank($0) < rank($1) }.first
    }
}

extension ResultPresentation {
    /// A chart for this response, when the data has an obvious one.
    public var chart: ResultChart? {
        switch self {
        case .table(let table): ResultChart(table: table)
        case .record(let fields): ResultChart(fields: fields)
        case .detail: nil   // each list of a detail charts on its own
        }
    }
}

extension JSONValue {
    /// Numbers, and strings that are exactly a decimal number ("29.75"): many APIs send prices as text
    /// to avoid floating-point rounding.
    public var numericValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s):
            guard s.count <= 20, s.wholeMatch(of: /-?\d+(\.\d+)?/) != nil else { return nil }
            return Double(s)
        default: return nil
        }
    }

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// ISO 8601 dates and date-times (`2026-10-02`, `2026-10-02T03:39:00Z`, with or without fractions).
    public var dateValue: Date? {
        guard case .string(let s) = self, s.count >= 10, s.count <= 35, s.first?.isNumber == true, s.contains("-") else { return nil }
        if let date = Self.isoFormatter.date(from: s) ?? Self.isoFractionalFormatter.date(from: s) { return date }
        if s.count == 10 { return Self.isoFormatter.date(from: s + "T00:00:00Z") }
        return nil
    }
}
