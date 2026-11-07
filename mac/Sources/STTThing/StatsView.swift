import Charts
import SwiftUI

/// Translation spend: headline numbers, this conversation over time, cost per
/// day and a table of recent conversations.
struct StatsView: View {
    @ObservedObject var usage: UsageStore
    var onNewConversation: () -> Void

    @State private var hoverTime: Date?
    @State private var hoverDay: Date?

    private let series = Color.blue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                tiles
                conversationChart
                dailyChart
                conversationsTable
                Text("Cost is usage.cost as reported per request by OpenRouter or vertex-proxy. When a response has no cost, it is estimated from the token prices in settings (marked est.).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 640)
    }

    // MARK: tiles

    private var tiles: some View {
        let mine = usage.records.filter { $0.conversation == usage.current.id }
        return HStack(spacing: 12) {
            Tile(
                title: "This conversation",
                value: Money.format(usage.cost(mine)),
                detail: "\(mine.count) requests · started \(usage.current.started.formatted(date: .omitted, time: .shortened))"
            )
            Tile(title: "Today", value: Money.format(usage.todayCost), detail: "\(todayRecords.count) requests")
            Tile(title: "All time", value: Money.format(usage.totalCost), detail: "\(usage.records.count) requests")
            Spacer(minLength: 0)
            Button("New conversation", action: onNewConversation)
                .help("Start counting from zero; the history stays")
        }
    }

    private var todayRecords: [UsageRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return usage.records.filter { $0.date >= start }
    }

    // MARK: this conversation, cumulative

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let total: Double
    }

    private var cumulative: [Point] {
        var total = 0.0
        var points = [Point(id: 0, date: usage.current.started, total: 0)]
        for (i, r) in usage.records.filter({ $0.conversation == usage.current.id }).enumerated() {
            total += r.cost
            points.append(Point(id: i + 1, date: r.date, total: total))
        }
        points.append(Point(id: points.count, date: max(Date(), points.last!.date), total: total))
        return points
    }

    private var conversationChart: some View {
        let points = cumulative
        let hovered = hoverTime.flatMap { t in points.last { $0.date <= t } }
        return VStack(alignment: .leading, spacing: 8) {
            Text("This conversation, total spent").font(.headline)
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("USD", p.total))
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(series)
                }
                if let hovered, let t = hoverTime {
                    RuleMark(x: .value("Time", t))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Callout(lines: [t.formatted(date: .omitted, time: .standard), Money.format(hovered.total)])
                        }
                }
            }
            .overlay {
                if points.count <= 2 && (points.last?.total ?? 0) == 0 {
                    Text("No translations in this conversation yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .chartXSelection(value: $hoverTime)
            .chartYAxis { AxisMarks { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel { if let d = v.as(Double.self) { Text(Money.axis(d, max: points.map(\.total).max() ?? 0)) } }
            } }
            .chartXAxis { AxisMarks { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            } }
            .frame(height: 170)
        }
    }

    // MARK: per day

    private struct Day: Identifiable {
        let date: Date
        let cost: Double
        let requests: Int
        var id: Date { date }
    }

    private var days: [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let grouped = Dictionary(grouping: usage.records) { cal.startOfDay(for: $0.date) }
        return (0..<14).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let list = grouped[day] ?? []
            return Day(date: day, cost: usage.cost(list), requests: list.count)
        }
    }

    private var dailyChart: some View {
        let data = days
        let hovered = hoverDay.flatMap { h in data.first { Calendar.current.isDate($0.date, inSameDayAs: h) } }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Spent per day, last 14 days").font(.headline)
            Chart {
                ForEach(data) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("USD", d.cost), width: .ratio(0.6))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        .foregroundStyle(series.opacity(hovered == nil || hovered?.id == d.id ? 1 : 0.45))
                }
                if let hovered {
                    RuleMark(x: .value("Day", hovered.date, unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Callout(lines: [
                                hovered.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                                "\(Money.format(hovered.cost)) · \(hovered.requests) requests",
                            ])
                        }
                }
            }
            .chartXSelection(value: $hoverDay)
            .chartYAxis { AxisMarks { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel { if let d = v.as(Double.self) { Text(Money.axis(d, max: data.map(\.cost).max() ?? 0)) } }
            } }
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            } }
            .frame(height: 150)
        }
    }

    // MARK: conversations

    private struct Row: Identifiable {
        let id: UUID
        let started: Date
        let requests: Int
        let tokensIn: Int
        let tokensOut: Int
        let avgLatency: Int
        let cost: Double
        let estimated: Bool
    }

    private var rows: [Row] {
        let byConversation = Dictionary(grouping: usage.records) { $0.conversation }
        return usage.conversations.reversed().prefix(30).compactMap { c in
            let list = byConversation[c.id] ?? []
            if list.isEmpty && c.id != usage.current.id { return nil }
            return Row(
                id: c.id, started: c.started, requests: list.count,
                tokensIn: list.reduce(0) { $0 + $1.inputTokens },
                tokensOut: list.reduce(0) { $0 + $1.outputTokens },
                avgLatency: list.isEmpty ? 0 : list.reduce(0) { $0 + $1.latencyMs } / list.count,
                cost: usage.cost(list), estimated: list.contains { $0.costIsEstimate }
            )
        }
    }

    private var conversationsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversations").font(.headline)
            Table(rows) {
                TableColumn("Started") { r in
                    Text(r.started.formatted(date: .abbreviated, time: .shortened))
                        .fontWeight(r.id == usage.current.id ? .semibold : .regular)
                }
                TableColumn("Requests") { r in Text("\(r.requests)").monospacedDigit() }
                    .width(70)
                TableColumn("Tokens in / out") { r in Text("\(r.tokensIn) / \(r.tokensOut)").monospacedDigit() }
                TableColumn("Avg latency") { r in Text(r.requests == 0 ? "–" : "\(r.avgLatency) ms").monospacedDigit() }
                    .width(90)
                TableColumn("Cost") { r in
                    Text(Money.format(r.cost) + (r.estimated ? " est." : "")).monospacedDigit()
                }
                .width(90)
            }
            .frame(height: 200)
        }
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold).monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(minWidth: 140, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

private struct Callout: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
    }
}
