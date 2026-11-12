import SwiftUI

struct StartupPage: View {
    @ObservedObject var model: Model

    var body: some View {
        ItemsPage(model: model,
                  title: "Startup & Background",
                  subtitle: "Choose what may start on its own. Blocked apps still open normally when you launch them yourself.",
                  sections: [
                      ("Login items", "Apps that open when you log in.", [.login]),
                      ("Background services", "Helpers, updaters and agents installed by other apps.", [.agent, .daemon]),
                  ]) {
            EnforcerCard(model: model)
        }
    }
}

struct ApplePage: View {
    @ObservedObject var model: Model

    var body: some View {
        ItemsPage(model: model,
                  title: "Apple Services",
                  subtitle: "Built-in macOS features. Only switch off what you never use; changes take effect after a restart.",
                  sections: [
                      ("System features", "Whole features you can switch off.", [.feature]),
                      ("Background services", "macOS helpers for specific apps and features.", [.apple]),
                  ]) {
            Card {
                Label {
                    Text("Items marked with \(Image(systemName: "exclamationmark.triangle.fill")) turn off something you may notice, like Siri, dictation or search. Everything can be switched back on here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Shared layout for the two list pages: header, an optional top card, banners, then grouped rows.
struct ItemsPage<Top: View>: View {
    @ObservedObject var model: Model
    let title: String
    let subtitle: String
    let sections: [(title: String, subtitle: String, kinds: Set<Item.Kind>)]
    @ViewBuilder var top: Top
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: title, subtitle: subtitle)
                top
                if !model.pendingSystem.isEmpty {
                    SystemPendingBanner(model: model)
                        .transition(.rise(reduceMotion: reduceMotion))
                }
                if !model.hasScanned {
                    Card { ProgressView("Scanning…").frame(maxWidth: .infinity, minHeight: 120) }
                } else {
                    let groups = sections.map { ($0, model.items($0.kinds)) }
                    let filtering = !model.query.isEmpty || model.show != .all
                    FilterBar(model: model, kinds: sections.reduce(into: Set()) { $0.formUnion($1.kinds) })
                    if groups.allSatisfy({ $0.1.isEmpty }) && filtering {
                        if model.query.isEmpty {
                            ContentUnavailableView(model.show.emptyTitle, systemImage: model.show.emptySymbol)
                        } else {
                            ContentUnavailableView.search(text: model.query)
                        }
                    }
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        if !group.1.isEmpty || !filtering {
                            ItemSection(model: model, title: group.0.title, subtitle: group.0.subtitle, items: group.1)
                                .opacity(model.revealed ? 1 : 0)
                                .offset(y: model.revealed || reduceMotion ? 0 : 8)
                                .animation(.easeOutStrong(0.3).delay(Double(index) * 0.05), value: model.revealed)
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 80) // room for the floating bar
            .animation(.easeOutStrong(), value: model.pendingSystem)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Filter")
    }
}

struct ItemSection: View {
    @ObservedObject var model: Model
    let title: String
    let subtitle: String
    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                CardHeader(title: title, subtitle: subtitle)
                Spacer()
                let running = items.filter { $0.isRunning && !$0.isBlocked }.count
                if running > 0 {
                    Text("\(running) running").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    if items.isEmpty {
                        Text("Nothing here").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().padding(.leading, 56) }
                        ItemRow(model: model, item: item)
                    }
                }
            }
        }
    }
}

struct ItemRow: View {
    @ObservedObject var model: Model
    let item: Item

    private var changed: Bool { model.choices[item.id] != nil }
    private var willBlock: Bool { model.isBlocked(item) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ItemIcon(appPath: item.appPath, symbol: item.symbol)
                .opacity(willBlock ? 0.55 : 1)
                .saturation(willBlock ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if item.caution {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .help("Blocking this turns off a macOS feature")
                    }
                    if item.needsAdmin {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("System-level: asks for your password when applied")
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    StatusChip(item: item, changed: changed, willBlock: willBlock)
                    if item.title != item.label {
                        Text(item.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 12)
            Toggle("Allowed", isOn: model.allowedBinding(item))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(willBlock ? "Blocked from starting on its own" : "Allowed to start on its own")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(changed ? Color.accentColor.opacity(0.07) : Color.clear)
        .animation(.easeOut(duration: 0.15), value: changed)
    }
}

enum ItemFilter: String, CaseIterable, Hashable {
    case all = "All"
    case running = "Running"
    case blocked = "Blocked"

    func includes(_ item: Item) -> Bool {
        switch self {
        case .all: return true
        case .running: return item.isRunning
        case .blocked: return item.isBlocked
        }
    }

    var emptyTitle: String { self == .running ? "Nothing running" : "Nothing blocked yet" }
    var emptySymbol: String { self == .running ? "moon.zzz" : "hand.raised" }
}

/// Counts for the page plus the All / Running / Blocked filter.
struct FilterBar: View {
    @ObservedObject var model: Model
    let kinds: Set<Item.Kind>

    var body: some View {
        let all = model.items.filter { kinds.contains($0.kind) }
        let running = all.filter(\.isRunning).count
        let blocked = all.filter(\.isBlocked).count
        HStack(spacing: 12) {
            Text("\(all.count) items · \(running) running · \(blocked) blocked")
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 12)
            Picker("Show", selection: $model.show.animation(.easeOutStrong())) {
                ForEach(ItemFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 4)
    }
}

/// Running state + memory, or the pending change, in one small pill.
struct StatusChip: View {
    let item: Item
    let changed: Bool
    let willBlock: Bool

    var body: some View {
        let (text, color): (String, Color) = {
            if changed { return (willBlock ? "Will block" : "Will allow", .accentColor) }
            if item.isBlocked && item.isRunning { return ("Blocked · stops after restart", .orange) }
            if item.isRunning { return (item.memoryMB > 0 ? "Running · \(mbText(item.memoryMB))" : "Running", .green) }
            if item.isBlocked && item.seenMB > 0 { return ("Blocked · saves ~\(mbText(item.seenMB))", .secondary) }
            if item.isBlocked { return ("Blocked", .secondary) }
            return ("Not running", .secondary)
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

struct EnforcerCard: View {
    @ObservedObject var model: Model

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 18)).foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep it this way").font(.system(size: 13, weight: .semibold))
                    Text("Re-applies your choices at login and every 30 minutes, and tells you when a new app adds a startup item. Works with the app closed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Keep it this way", isOn: Binding(get: { model.enforcerOn }, set: { on in Task { await model.setEnforcer(on) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

struct SystemPendingBanner: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 18)).foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some blocks need your password to finish").font(.system(size: 13, weight: .semibold))
                Text(model.pendingSystem.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button("Finish…") { Task { await model.apply() } }
                .buttonStyle(.primary)
                .disabled(model.busy)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}
