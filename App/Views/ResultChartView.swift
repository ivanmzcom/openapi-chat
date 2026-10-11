import Charts
import OpenAPIChatKit
import SwiftUI

/// Single-series charts: a line over time or horizontal bars per label. One series, so no legend —
/// the title names the measure. Hover (or drag on iOS) shows the exact value.
struct ResultChartView: View {
    let chart: ResultChart

    @State private var selectedDate: Date?
    @State private var selectedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            switch chart.kind {
            case .timeSeries: timeSeries
            case .bars: bars
            }
        }
    }

    private var title: String {
        switch chart.kind {
        case .timeSeries: "\(ResultFormat.header(chart.yKey)) · \(ResultFormat.header(chart.xKey).lowercased())"
        case .bars: chart.yKey.isEmpty ? "Valores" : "\(ResultFormat.header(chart.yKey)) por \(ResultFormat.header(chart.xKey).lowercased())"
        }
    }

    // MARK: Time series

    private var timeSeries: some View {
        Chart {
            ForEach(chart.points) { point in
                LineMark(x: .value("Fecha", point.date!), y: .value(chart.yKey, point.value))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if chart.points.count <= 40 {
                    PointMark(x: .value("Fecha", point.date!), y: .value(chart.yKey, point.value))
                        .symbolSize(64)
                }
            }
            if let selected = nearestPoint(to: selectedDate) {
                RuleMark(x: .value("Fecha", selected.date!))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(title: selected.date!.formatted(date: .abbreviated, time: .shortened),
                                value: ResultFormat.text(.number(selected.value), key: chart.yKey))
                    }
            }
        }
        .foregroundStyle(Color.accentColor)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selectedDate)
        .chartXAxis { recessiveAxis() }
        .chartYAxis { recessiveAxis() }
        .frame(height: 220)
        .padding(.top, 24)
    }

    private func nearestPoint(to date: Date?) -> ResultChart.Point? {
        guard let date else { return nil }
        return chart.points.min { abs($0.date!.timeIntervalSince(date)) < abs($1.date!.timeIntervalSince(date)) }
    }

    // MARK: Bars

    private var bars: some View {
        Chart(chart.points) { point in
            BarMark(x: .value(chart.yKey, point.value), y: .value(chart.xKey, label(point)), height: .fixed(16))
                .clipShape(.rect(cornerRadius: 4))
                .foregroundStyle(Color.accentColor.opacity(selectedLabel == nil || selectedLabel == label(point) ? 1 : 0.4))
                .annotation(position: point.value < 0 ? .leading : .trailing, spacing: 4) {
                    if selectedLabel == label(point) || chart.points.count <= 8 {
                        Text(ResultFormat.text(.number(point.value), key: chart.yKey))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
        }
        .chartYSelection(value: $selectedLabel)
        .chartXAxis { recessiveAxis() }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel(centered: true, collisionResolution: .disabled).foregroundStyle(Color.secondary)
            }
        }
        .frame(height: CGFloat(chart.points.count) * 34 + 30)
    }

    /// Bars need unique category labels; repeated names get a counter.
    private func label(_ point: ResultChart.Point) -> String {
        let duplicates = chart.points.filter { $0.label == point.label }
        guard duplicates.count > 1, let index = duplicates.firstIndex(where: { $0.id == point.id }) else { return point.label }
        return "\(point.label) (\(index + 1))"
    }

    private func recessiveAxis() -> some AxisContent {
        AxisMarks { _ in
            // Explicit neutral colours: hierarchical styles would inherit the series' accent colour.
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.3))
            AxisValueLabel().foregroundStyle(Color.secondary)
        }
    }
}

private struct Tooltip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
    }
}
