import OpenAPIChatKit
import SwiftUI

/// Shows an API response as a table (lists) or a card (single objects), straight from the JSON.
struct ResultView: View {
    let presentation: ResultPresentation
    var pagination: Pagination?
    var onLoadMore: (() async -> Void)?

    var body: some View {
        Group {
            switch presentation {
            case .table(let table): ResultTableView(table: table, pagination: pagination, onLoadMore: onLoadMore)
            case .record(let fields): ResultRecordView(fields: fields)
            }
        }
        .padding(10)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

private struct ResultTableView: View {
    let table: ResultTable
    let pagination: Pagination?
    let onLoadMore: (() async -> Void)?
    @State private var expanded = false
    @State private var loading = false

    private let collapsedCount = 10

    private var visibleRows: ArraySlice<[String: JSONValue]> {
        expanded ? table.rows[...] : table.rows.prefix(collapsedCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        ForEach(table.columns, id: \.self) { column in
                            Text(ResultFormat.header(column))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                                cell(row, column: column, isFirst: index == 0)
                            }
                        }
                    }
                }
                .font(.callout)
            }

            HStack(spacing: 14) {
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if table.rows.count > collapsedCount {
                    Button(expanded ? "Mostrar menos" : "Mostrar los \(table.rows.count)") {
                        withAnimation { expanded.toggle() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                if pagination != nil, let onLoadMore {
                    if loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Cargar más", systemImage: "arrow.down.circle") {
                            loading = true
                            Task {
                                await onLoadMore()
                                loading = false
                                withAnimation { expanded = true }
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var countText: String {
        if let total = pagination?.total, total > table.rows.count {
            return "\(table.rows.count) de \(total) resultados"
        }
        return table.rows.count == 1 ? "1 resultado" : "\(table.rows.count) resultados"
    }

    @ViewBuilder
    private func cell(_ row: [String: JSONValue], column: String, isFirst: Bool) -> some View {
        let text = row[column].map { ResultFormat.text($0, key: column) } ?? "—"
        let width: CGFloat = isFirst ? 280 : 170
        if isFirst, let link = table.linkColumn, let url = row[link]?.stringValue.flatMap(URL.init(string:)) {
            Link(text, destination: url)
                .lineLimit(2)
                .frame(maxWidth: width, alignment: .leading)
        } else {
            Text(text)
                .fontWeight(isFirst ? .medium : .regular)
                .foregroundStyle(ResultFormat.isNegative(row[column], key: column) ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: width, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct ResultRecordView: View {
    let fields: [ResultField]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(fields) { field in
                GridRow {
                    Text(ResultFormat.header(field.key))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    if let url = field.value.stringValue.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                        Link(url.host() ?? url.absoluteString, destination: url).font(.callout)
                    } else {
                        Text(ResultFormat.text(field.value, key: field.key))
                            .font(.callout)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

enum ResultFormat {
    /// `price.amount` → "Price amount", `createdAt` → "Created at".
    static func header(_ key: String) -> String {
        var words = ""
        var previous: Character = " "
        for c in key {
            if c == "_" || c == "." || c == "-" { words.append(" ") }
            else {
                if c.isUppercase && previous.isLowercase { words.append(" ") }
                words.append(c)
            }
            previous = c
        }
        let lower = words.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    static func text(_ value: JSONValue, key: String) -> String {
        switch value {
        case .bool(let b): return b ? "Sí" : "No"
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { return Int(n).formatted() }
            return n.formatted(.number.precision(.fractionLength(0...2)))
        case .string(let s):
            if let date = parseDate(s) { return date.formatted(date: .abbreviated, time: s.count > 10 ? .shortened : .omitted) }
            // Enum-like values such as `out_of_stock` read better with spaces.
            if !s.contains(" "), s.contains("_"), s.count < 40 { return s.replacingOccurrences(of: "_", with: " ") }
            return s
        default:
            return value.scalarText
        }
    }

    /// Dims values like "out of stock" / `false` so the useful rows stand out.
    static func isNegative(_ value: JSONValue?, key: String) -> Bool {
        switch value {
        case .bool(false): return true
        case .string(let s):
            let lower = s.lowercased()
            return ["out_of_stock", "out of stock", "unavailable", "agotado", "inactive", "disabled", "sold"].contains(lower)
        default: return false
        }
    }

    private static let isoFull = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        guard s.count >= 10, s.count <= 35, s.first?.isNumber == true, s.contains("-") else { return nil }
        if let d = isoFull.date(from: s) ?? isoFractional.date(from: s) { return d }
        if s.count == 10 { return try? Date(s + "T00:00:00Z", strategy: .iso8601) }
        return nil
    }
}
