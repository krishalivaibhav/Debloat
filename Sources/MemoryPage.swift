import Charts
import SwiftUI

struct MemoryPage: View {
    @ObservedObject var model: Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Memory", subtitle: "Live view of your \(Int(MemoryReader.totalGB.rounded())) GB of memory. Updates every 2 seconds.")
                if let now = model.samples.last {
                    OverviewCard(sample: now)
                    HistoryCard(model: model)
                } else {
                    Card { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
                }
                if !model.leftovers.isEmpty {
                    LeftoversCard(model: model)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ProcessesCard(processes: model.processes)
                        SavingsCard(model: model)
                    }
                    .frame(minWidth: 700)
                    VStack(spacing: 16) {
                        ProcessesCard(processes: model.processes)
                        SavingsCard(model: model)
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 72) // room for the floating bar
        }
    }
}

// MARK: - Overview

private struct Segment: Identifiable {
    let id: String
    let gb: Double
    let color: Color
    let note: String
}

struct OverviewCard: View {
    let sample: MemorySample

    private var segments: [Segment] {
        let free = max(MemoryReader.totalGB - sample.used - sample.cached, 0)
        return [
            Segment(id: "App", gb: sample.app, color: .seriesApp, note: "used by apps"),
            Segment(id: "Wired", gb: sample.wired, color: .seriesWired, note: "macOS itself"),
            Segment(id: "Compressed", gb: sample.compressed, color: .seriesCompressed, note: "squeezed to fit"),
            Segment(id: "Cached files", gb: sample.cached, color: .seriesCached, note: "freed instantly when needed"),
            Segment(id: "Free", gb: free, color: .track, note: "unused"),
        ]
    }

    var body: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(gbText(sample.used))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: sample.used))
                    Text("of \(Int(MemoryReader.totalGB.rounded())) GB in use")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                    PressureBadge(freePercent: sample.freePercent)
                }
                MemoryBar(segments: segments, total: MemoryReader.totalGB)
                    .frame(height: 14)
                    .animation(.easeInOut(duration: 0.6), value: sample.used)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    ForEach(segments) { s in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(s.color).frame(width: 10, height: 10)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(s.id == "Free" ? 0.25 : 0)))
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.id).font(.system(size: 12, weight: .medium))
                                Text(gbText(s.gb)).font(.system(size: 12)).monospacedDigit()
                                    .contentTransition(.numericText(value: s.gb))
                                Text(s.note).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "externaldrive").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 10).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Swap").font(.system(size: 12, weight: .medium))
                            Text(gbText(sample.swap)).font(.system(size: 12)).monospacedDigit()
                            Text(sample.swap < 0.05 ? "none, good" : "on disk, slower").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// One horizontal stacked bar with 2pt gaps between segments.
struct MemoryBar: View {
    fileprivate let segments: [Segment]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            let visible = segments.filter { $0.gb > 0.01 }
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { s in
                    Rectangle().fill(s.color)
                        .frame(width: max((geo.size.width - gaps) * s.gb / total, 2))
                        .help("\(s.id): \(gbText(s.gb))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

struct PressureBadge: View {
    let freePercent: Int

    var body: some View {
        let (label, icon, color): (String, String, Color) =
            freePercent >= 50 ? ("Pressure normal", "checkmark.circle.fill", .green)
            : freePercent >= 25 ? ("Pressure elevated", "exclamationmark.triangle.fill", .orange)
            : ("Pressure high", "xmark.octagon.fill", .red)
        Label(label, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .symbolRenderingMode(.palette)
            .foregroundStyle(color, .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
            .help("\(freePercent)% of memory is available to apps")
    }
}

// MARK: - History

enum ChartMode: String, CaseIterable, Hashable {
    case apps = "Apps"
    case total = "Total"
    case breakdown = "Breakdown"
}

struct AppSample: Identifiable {
    let id = UUID()
    let date: Date
    let mb: [String: Int]
}

struct ChartApp: Identifiable, Equatable {
    let name: String
    let slot: Int
    var id: String { name }
    var color: Color { Color.categorical[slot] }
}

struct HistoryCard: View {
    @ObservedObject var model: Model
    @StateObject private var hover = HoverState()

    final class HoverState: ObservableObject { @Published var date: Date? }

    private var samples: [MemorySample] { model.samples }

    private static let layers = ["App", "Wired", "Compressed", "Cached files", "Free"]
    private static let layerColors: [Color] = [.seriesApp, .seriesWired, .seriesCompressed, .seriesCached, .track]

    private var subtitle: String {
        switch model.chartMode {
        case .apps: return "The 5 apps using the most memory right now. Each keeps its color while it stays on the chart."
        case .total: return "Memory apps and macOS are actually using, against your total."
        case .breakdown: return "How all of your memory is split up. Cached files fill spare memory on purpose and are freed instantly."
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    CardHeader(title: "Last 5 minutes", subtitle: subtitle)
                    Spacer(minLength: 16)
                    Picker("Chart", selection: $model.chartMode) {
                        ForEach(ChartMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if samples.count < 2 {
                    Text("Collecting…").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 230)
                } else {
                    switch model.chartMode {
                    case .apps:
                        appsChart.frame(height: 210)
                        ValueLegend(entries: model.chartApps.map { app in
                            (app.name, app.color, mbText(model.appHistory.last?.mb[app.name] ?? 0), true)
                        })
                    case .total:
                        totalChart.frame(height: 230)
                    case .breakdown:
                        breakdownChart.frame(height: 210)
                        if let last = samples.last {
                            ValueLegend(entries: zip(Self.layers, Self.layerColors).enumerated().map { i, layer in
                                (layer.0, layer.1, gbText(layerValues(last)[i]), false)
                            })
                        }
                    }
                }
            }
        }
    }

    // MARK: Apps — one line per app

    private var appsChart: some View {
        let peak = model.appHistory.flatMap { s in model.chartApps.compactMap { s.mb[$0.name] } }.max() ?? 100
        return Chart {
            ForEach(model.chartApps) { app in
                ForEach(model.appHistory) { s in
                    if let mb = s.mb[app.name] {
                        LineMark(x: .value("Time", s.date), y: .value("MB", mb), series: .value("App", app.name))
                            .foregroundStyle(app.color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                }
                if hover.date == nil, let last = model.appHistory.last, let mb = last.mb[app.name] {
                    PointMark(x: .value("Time", last.date), y: .value("MB", mb))
                        .symbolSize(30)
                        .foregroundStyle(app.color)
                }
            }
            hoverRule
        }
        .chartYScale(domain: 0...Double(peak) * 1.15)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Color.track)
                AxisValueLabel { if let mb = v.as(Double.self) { Text(mbText(Int(mb))).font(.system(size: 10)) } }
            }
        }
        .chartXAxis { xAxis }
        .chartOverlay { hoverOverlay($0) }
    }

    // MARK: Total — one line against the total

    private var totalChart: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.date), y: .value("GB", s.used))
                    .foregroundStyle(LinearGradient(colors: [Color.seriesApp.opacity(0.28), Color.seriesApp.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.date), y: .value("GB", s.used))
                    .foregroundStyle(Color.seriesApp)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Total", MemoryReader.totalGB))
                .foregroundStyle(Color.primary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .bottom, alignment: .leading, spacing: 4) {
                    Text("\(Int(MemoryReader.totalGB.rounded())) GB total").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            if let last = samples.last, hover.date == nil {
                PointMark(x: .value("Time", last.date), y: .value("GB", last.used))
                    .symbolSize(36)
                    .foregroundStyle(Color.seriesApp)
                    .annotation(position: .top, alignment: .trailing, spacing: 6) {
                        Text(gbText(last.used)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
            }
            hoverRule
        }
        .chartYScale(domain: 0...MemoryReader.totalGB)
        .chartYAxis { gbAxis }
        .chartXAxis { xAxis }
        .chartOverlay { hoverOverlay($0) }
    }

    // MARK: Breakdown — the whole 16 GB, stacked, with a thin gap between layers

    private func layerValues(_ s: MemorySample) -> [Double] {
        [s.app, s.wired, s.compressed, s.cached, max(MemoryReader.totalGB - s.used - s.cached, 0)]
    }

    private struct LayerPoint: Identifiable {
        let id: String
        let date: Date
        let layer: String
        let gb: Double
    }

    private var breakdownChart: some View {
        let points = samples.flatMap { s in
            zip(Self.layers, layerValues(s)).map { LayerPoint(id: "\(s.id)-\($0.0)", date: s.date, layer: $0.0, gb: $0.1) }
        }
        // Running totals for the boundary lines between layers
        let edges = samples.flatMap { s -> [LayerPoint] in
            var sum = 0.0
            return layerValues(s).dropLast().enumerated().map { i, v in
                sum += v
                return LayerPoint(id: "\(s.id)-edge\(i)", date: s.date, layer: "edge\(i)", gb: sum)
            }
        }
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value("GB", p.gb), stacking: .standard)
                    .foregroundStyle(by: .value("Type", p.layer))
            }
            ForEach(edges) { e in
                LineMark(x: .value("Time", e.date), y: .value("GB", e.gb), series: .value("Edge", e.layer))
                    .foregroundStyle(Color.card)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            hoverRule
        }
        .chartForegroundStyleScale(domain: Self.layers, range: Self.layerColors)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...MemoryReader.totalGB)
        .chartYAxis { gbAxis }
        .chartXAxis { xAxis }
        .chartOverlay { hoverOverlay($0) }
    }

    // MARK: Shared pieces

    @ChartContentBuilder
    private var hoverRule: some ChartContent {
        if let d = hover.date {
            RuleMark(x: .value("Time", d))
                .foregroundStyle(Color.primary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .leading, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                    readout(at: d)
                }
        }
    }

    private var gbAxis: some AxisContent {
        AxisMarks(position: .leading, values: .stride(by: 4)) { v in
            AxisGridLine().foregroundStyle(Color.track)
            AxisValueLabel { if let g = v.as(Double.self) { Text("\(Int(g)) GB").font(.system(size: 10)) } }
        }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: .stride(by: .minute)) { _ in
            AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 10))
        }
    }

    private func hoverOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        guard let frame = proxy.plotFrame else { return }
                        hover.date = proxy.value(atX: loc.x - geo[frame].origin.x, as: Date.self)
                    case .ended:
                        hover.date = nil
                    }
                }
        }
    }

    private func readout(at d: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch model.chartMode {
            case .apps:
                if let n = model.appHistory.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) {
                    Text(n.date, format: .dateTime.hour().minute().second()).font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(model.chartApps.sorted { (n.mb[$0.name] ?? 0) > (n.mb[$1.name] ?? 0) }) { app in
                        readoutRow(app.name, mbText(n.mb[app.name] ?? 0), app.color)
                    }
                }
            case .total, .breakdown:
                if let n = samples.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) {
                    Text(n.date, format: .dateTime.hour().minute().second()).font(.system(size: 10)).foregroundStyle(.secondary)
                    if model.chartMode == .total {
                        readoutRow("In use", gbText(n.used), .seriesApp, bold: true)
                        readoutRow("Cached files", gbText(n.cached), nil)
                        readoutRow("Swap", gbText(n.swap), nil)
                    } else {
                        ForEach(Array(zip(Self.layers, layerValues(n)).enumerated()), id: \.offset) { i, row in
                            readoutRow(row.0, gbText(row.1), Self.layerColors[i])
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 196)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.hairline))
    }

    private func readoutRow(_ name: String, _ value: String, _ color: Color?, bold: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color ?? .clear).frame(width: 8, height: 8)
            Text(name).font(.system(size: 11, weight: bold ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 10)
            Text(value).font(.system(size: 11, weight: bold ? .semibold : .regular)).monospacedDigit()
        }
    }
}

/// Legend that also shows each series' current value. Line swatches for line charts, squares for areas.
struct ValueLegend: View {
    let entries: [(name: String, color: Color, value: String, line: Bool)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                HStack(spacing: 8) {
                    Group {
                        if e.line {
                            Capsule().fill(e.color).frame(width: 14, height: 3)
                        } else {
                            RoundedRectangle(cornerRadius: 3).fill(e.color).frame(width: 10, height: 10)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(e.name == "Free" ? 0.25 : 0)))
                        }
                    }
                    .frame(width: 14)
                    Text(e.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(e.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

// MARK: - Processes & savings

/// A labelled row with a proportional bar on a track.
struct BarRow: View {
    let icon: AnyView
    let title: String
    let value: String
    let fraction: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(value).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.track)
                        Capsule().fill(color).frame(width: max(geo.size.width * fraction, 3))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

struct ProcessesCard: View {
    let processes: [ProcessMemory]

    var body: some View {
        let top = processes.first?.mb ?? 1

        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Using memory now", subtitle: "Helpers are counted under their app.")
                if processes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                }
                ForEach(processes) { p in
                    BarRow(icon: AnyView(ItemIcon(appPath: p.appPath, symbol: "gearshape", size: 20)),
                           title: p.leftover ? "\(p.name) (closed, extensions only)" : p.name, value: mbText(p.mb),
                           fraction: Double(p.mb) / Double(max(top, 1)), color: .seriesApp)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

struct LeftoversCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let items = model.leftovers
        let total = items.reduce(0) { $0 + $1.mb }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    CardHeader(title: "Still running from closed apps",
                               subtitle: "Widgets, notification and Siri extensions keep running after you quit an app. Stopping them is safe: macOS restarts one when it's needed, like for a new notification or a widget on screen.")
                    Spacer(minLength: 16)
                    Button("Stop all · \(mbText(total))") { model.stopLeftovers(items) }
                        .buttonStyle(.primary)
                        .fixedSize()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 10) {
                    ForEach(items) { p in
                        HStack(spacing: 10) {
                            ItemIcon(appPath: p.appPath, symbol: "app.dashed", size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("\(p.pids.count) process\(p.pids.count == 1 ? "" : "es") · \(mbText(p.mb))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            Button("Stop") { model.stopLeftovers([p]) }
                                .buttonStyle(.secondary)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

struct SavingsCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let saved = model.savings
        let total = saved.reduce(0) { $0 + $1.seenMB }
        let top = saved.first?.seenMB ?? 1
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Kept free by your blocks", subtitle: "What blocked items would be using, based on the most each was seen using.")
                if saved.isEmpty {
                    Text("Block something under Startup & Background and its memory shows up here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("~" + mbText(total)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("across \(saved.count) item\(saved.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(saved) { item in
                        BarRow(icon: AnyView(ItemIcon(appPath: item.appPath, symbol: item.symbol, size: 20)),
                               title: item.title, value: "~" + mbText(item.seenMB),
                               fraction: Double(item.seenMB) / Double(max(top, 1)), color: .seriesCompressed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
