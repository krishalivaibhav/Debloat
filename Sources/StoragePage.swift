import SwiftUI

enum StorageFilter: String, CaseIterable {
    case all = "All", movable = "Can move", inUse = "In use", stays = "Stays", moved = "Moved"

    func includes(_ item: StorageItem) -> Bool {
        switch (self, item.verdict) {
        case (.all, _), (.movable, .movable), (.movable, .clearable), (.inUse, .inUse), (.stays, .keep), (.moved, .moved): return true
        default: return false
        }
    }
}

struct StoragePage: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let snap = model.storage
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Storage", subtitle: "What fills your disks, what can safely move to another drive, and what would break if it did. Moved things leave a shortcut behind, so they keep opening from the same place.")
                VolumesCard(volumes: snap.volumes)
                if snap.scanned {
                    BreakdownCard(totals: snap.totals)
                    ItemsCard(model: model)
                } else {
                    Card {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Measuring folders and checking what's open… this takes a few seconds.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 72)
            .animation(.easeOutStrong(), value: snap)
        }
        .task { if !model.storage.scanned { await model.scanStorage() } }
    }
}

private struct VolumesCard: View {
    let volumes: [Volume]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Disks", subtitle: volumes.contains { !$0.isRoot } ? nil : "Plug in a drive to move things off this Mac.")
                ForEach(volumes) { v in
                    HStack(spacing: 12) {
                        ItemIcon(appPath: nil, symbol: v.isRoot ? "internaldrive" : "externaldrive", size: 32)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(v.isRoot ? "\(v.name) (this Mac)" : v.name).font(.system(size: 13, weight: .semibold))
                                Pill(text: v.format)
                                if v.readOnly { Pill(text: "Read-only") }
                                Spacer()
                                Text("\(mbText(v.freeMB)) free of \(mbText(v.totalMB))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            GeometryReader { g in
                                let used = v.totalMB > 0 ? CGFloat(v.usedMB) / CGFloat(v.totalMB) : 0
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.track)
                                    Capsule().fill(used > 0.9 ? Color.seriesWired : Color.seriesApp).frame(width: g.size.width * used)
                                }
                            }
                            .frame(height: 6)
                            if v.isFAT {
                                Text("\(v.format) works with Windows too, but can't hold shortcuts or app bundles. Apps and some folders can't move here.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct BreakdownCard: View {
    let totals: [StorageKind: Int]

    var body: some View {
        let kinds = StorageKind.allCases.filter { (totals[$0] ?? 0) > 0 }
        let sum = max(1, kinds.reduce(0) { $0 + (totals[$1] ?? 0) })
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "By type", subtitle: "\(mbText(sum)) in the folders Debloat looks at. macOS itself and other users aren't counted.")
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(kinds) { k in
                            Rectangle().fill(color(k))
                                .frame(width: max(2, (g.size.width - CGFloat(kinds.count) * 2) * CGFloat(totals[k] ?? 0) / CGFloat(sum)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(kinds) { k in
                        HStack(spacing: 6) {
                            Circle().fill(color(k)).frame(width: 8, height: 8)
                            Text(k.title).font(.system(size: 12))
                            Text(mbText(totals[k] ?? 0)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func color(_ k: StorageKind) -> Color { Color.categorical[StorageKind.allCases.firstIndex(of: k)! % Color.categorical.count] }
}

private struct ItemsCard: View {
    @ObservedObject var model: Model

    var body: some View {
        let targets = model.storage.volumes.filter(\.canReceive)
        let shown = model.storage.items.filter { model.storageFilter.includes($0) }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    CardHeader(title: "Large items", subtitle: "Anything over \(StorageReader.minMB) MB.")
                    Spacer(minLength: 12)
                    if !targets.isEmpty {
                        Picker("Move to", selection: $model.destination) {
                            ForEach(targets) { Text("\($0.name) · \(mbText($0.freeMB)) free").tag(Optional($0.path)) }
                        }
                        .fixedSize()
                    }
                }
                Picker("Show", selection: $model.storageFilter.animation(.easeOutStrong())) {
                    ForEach(StorageFilter.allCases, id: \.self) { f in
                        Text("\(f.rawValue) \(model.storage.items.filter { f.includes($0) }.count)").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if shown.isEmpty {
                    Text("Nothing here.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(shown) { item in
                    if item.id != shown.first?.id { Divider() }
                    StorageRow(model: model, item: item)
                }
            }
        }
    }
}

private struct StorageRow: View {
    @ObservedObject var model: Model
    let item: StorageItem
    @StateObject private var confirm = ConfirmState()

    final class ConfirmState: ObservableObject { @Published var shown = false }

    var body: some View {
        let dest = model.destinationVolume
        HStack(alignment: .top, spacing: 12) {
            ItemIcon(appPath: FileManager.default.fileExists(atPath: item.path) ? item.path : nil, symbol: item.kind.symbol, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(item.displayPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Pill(text: item.kind.title)
                    Pill(text: item.mb > 0 ? mbText(item.mb) : "size unknown")
                    VerdictChip(verdict: item.verdict)
                }
                ForEach(reasons(dest), id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            action(dest).fixedSize()
        }
        .confirmationDialog(dialogTitle(dest), isPresented: $confirm.shown) {
            switch item.verdict {
            case .clearable:
                Button("Delete \(mbText(item.mb))", role: .destructive) { Task { await model.clearStorage(item) } }
            case .moved:
                Button("Move back") { Task { await model.moveBack(item) } }
            default:
                Button("Move to \(dest?.name ?? "drive")") { Task { await model.moveStorage(item) } }
            }
        } message: {
            Text(dialogMessage(dest))
        }
    }

    /// Why it can't, or shouldn't casually, move to the chosen drive
    private func reasons(_ dest: Volume?) -> [String] {
        var out = item.notes
        if case .keep(let why) = item.verdict { out.append(why) }
        if case .inUse(let apps) = item.verdict { out.append("Open in \(apps.prefix(3).joined(separator: ", "))\(apps.count > 3 ? " and \(apps.count - 3) more" : ""). Quit \(apps.count == 1 ? "it" : "them") first.") }
        if case .moved(_, false) = item.verdict { out.append("The drive it was moved to isn't plugged in, so this won't open.") }
        if case .movable = item.verdict, let dest {
            if dest.isFAT && item.hasSymlinks { out.append("\(dest.name) is \(dest.format), which can't store the shortcuts inside this.") }
            else if item.mb + 512 > dest.freeMB { out.append("Not enough room on \(dest.name).") }
        }
        return out
    }

    @ViewBuilder
    private func action(_ dest: Volume?) -> some View {
        if model.working.contains(item.path) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.stage[item.path] ?? "Starting…")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
        } else {
            switch item.verdict {
            case .movable:
                Button(dest.map { "Move to \($0.name)" } ?? "Move") { confirm.shown = true }
                    .buttonStyle(.primary)
                    .disabled(dest == nil || (dest!.isFAT && item.hasSymlinks) || item.mb + 512 > dest!.freeMB)
                    .help(dest == nil ? "Plug in a drive first" : "Copies it to \(dest!.name), checks the copy, then leaves a shortcut here")
            case .clearable:
                Button("Delete") { confirm.shown = true }.buttonStyle(.secondary)
                    .help("Caches are rebuilt when an app needs them")
            case .moved(_, let connected):
                Button("Move back") { confirm.shown = true }.buttonStyle(.secondary).disabled(!connected)
            case .inUse, .keep:
                EmptyView()
            }
        }
    }

    private func dialogTitle(_ dest: Volume?) -> String {
        switch item.verdict {
        case .clearable: return "Delete \(item.name)?"
        case .moved: return "Move \(item.name) back to this Mac?"
        default: return "Move \(item.name) to \(dest?.name ?? "the drive")?"
        }
    }

    private func dialogMessage(_ dest: Volume?) -> String {
        switch item.verdict {
        case .clearable:
            return "It's a cache: the app rebuilds what it needs. Frees \(mbText(item.mb))."
        case .moved(let to, _):
            return "Copies it back from \(StorageReader.tilde(to)), then removes it from the drive."
        default:
            let folder = "\(StorageReader.folderOnDrive)/"
            return "Debloat copies it into “\(folder)” on \(dest?.name ?? "the drive"), checks every file's size and checksum against the original, and only then replaces it here with a shortcut. If anything doesn't match, nothing is deleted. Frees \(mbText(item.mb)) on this Mac. It only opens while the drive is plugged in."
        }
    }
}

private struct VerdictChip: View {
    let verdict: StorageItem.Verdict

    var body: some View {
        let (text, color): (String, Color) = {
            switch verdict {
            case .movable: return ("Safe to move", .green)
            case .clearable: return ("Safe to delete", .green)
            case .inUse: return ("In use", .orange)
            case .keep: return ("Keep here", .red)
            case .moved(let to, let connected):
                let drive = to.split(separator: "/").dropFirst().first.map(String.init) ?? "drive"
                return (connected ? "On \(drive)" : "\(drive) not connected", connected ? .accentColor : .orange)
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

private struct Pill: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}
