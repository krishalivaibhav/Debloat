import AppKit
import SwiftUI

@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(to: args[i + 1])
        } else {
            DebloatApp.main()
        }
    }
}

struct DebloatApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("Debloat") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 600)
                .task { await model.scan() }
                .task { await model.startMonitoring() }
        }
        .defaultSize(width: 980, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, page in
                    Button(page.title) { model.page = page }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Rescan") { Task { await model.rescan() } }
                    .keyboardShortcut("r")
                    .disabled(model.busy)
            }
        }
    }
}

enum Page: String, CaseIterable, Identifiable, Hashable {
    case memory, claude, storage, startup, apple
    var id: Self { self }

    var title: String {
        switch self {
        case .memory: return "Memory"
        case .claude: return "Claude"
        case .storage: return "Storage"
        case .startup: return "Startup & Background"
        case .apple: return "Apple Services"
        }
    }

    var symbol: String {
        switch self {
        case .memory: return "memorychip"
        case .claude: return "sparkle"
        case .storage: return "internaldrive"
        case .startup: return "power"
        case .apple: return "apple.logo"
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var page: Page = .memory
    @Published var items: [Item] = []
    /// Pending choices keyed by item id: true = block, false = allow. Only differences from the saved state live here.
    @Published var choices: [String: Bool] = [:]
    @Published var pendingSystem: [String] = []
    @Published var busy = false
    @Published var hasScanned = false
    @Published var revealed = false
    @Published var query = ""
    @Published var enforcerOn = Engine.enforcerInstalled
    @Published var toast: ToastMessage?
    @Published var show: ItemFilter = .all
    @Published var chartMode: ChartMode = .apps

    @Published var samples: [MemorySample] = []
    @Published var processes: [ProcessMemory] = []
    @Published var leftovers: [ProcessMemory] = []
    @Published var claude = ClaudeSnapshot()
    @Published var storage = StorageSnapshot()
    @Published var storageFilter: StorageFilter = .all
    /// Drive that "Move" sends things to
    @Published var destination: String?
    /// Items being moved or deleted right now
    @Published var working: Set<String> = []
    /// Per-app memory over time, and the apps currently drawn as lines (with stable color slots)
    @Published var appHistory: [AppSample] = []
    @Published var chartApps: [ChartApp] = []
    private var colorSlots: [String: Int] = [:]
    private var monitoring = false
    private var toastTask: Task<Void, Never>?

    var pendingChanges: [Item] { items.filter { choices[$0.id] != nil } }
    var pendingNeedsAdmin: Bool { pendingChanges.contains { $0.needsAdmin } }

    /// Blocked items that aren't running, with the memory they were last seen using
    var savings: [Item] { items.filter { $0.isBlocked && !$0.isRunning && $0.seenMB > 0 }.sorted { $0.seenMB > $1.seenMB } }

    /// Filters on the saved state, so a row doesn't vanish the moment its switch is flipped
    func items(_ kinds: Set<Item.Kind>) -> [Item] { items.filter { kinds.contains($0.kind) && $0.matches(query) && show.includes($0) } }

    func isBlocked(_ item: Item) -> Bool { choices[item.id] ?? item.isBlocked }

    /// Switch on = allowed to run, matching System Settings' "Allow in the Background"
    func allowedBinding(_ item: Item) -> Binding<Bool> {
        Binding(
            get: { !self.isBlocked(item) },
            set: { allowed in
                withAnimation(.easeOutStrong()) {
                    if !allowed == item.isBlocked { self.choices[item.id] = nil } else { self.choices[item.id] = !allowed }
                }
            }
        )
    }

    func revert() { withAnimation(.exit) { choices = [:] } }

    func showToast(_ text: String, warning: Bool = false) {
        toastTask?.cancel()
        withAnimation(.easeOutStrong(0.25)) { toast = ToastMessage(text: text, warning: warning) }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.exit) { toast = nil }
        }
    }

    func startMonitoring() async {
        guard !monitoring else { return }
        monitoring = true
        var tick = 0
        while !Task.isCancelled {
            if let s = MemoryReader.sample() {
                samples.append(s)
                if samples.count > 150 { samples.removeFirst(samples.count - 150) } // 5 min at 2 s
            }
            let procs = markLeftovers(await Task.detached { MemoryReader.topProcesses() }.value)
            appHistory.append(AppSample(date: Date(), mb: Dictionary(procs.map { ($0.name, $0.mb) }, uniquingKeysWith: +)))
            if appHistory.count > 150 { appHistory.removeFirst(appHistory.count - 150) }
            updateChartApps(Array(procs.prefix(5)).map(\.name))
            if page == .claude || tick % 3 == 0 {
                let c = await Task.detached { ClaudeReader.scan() }.value
                if c != claude { claude = c }
            }
            if page == .storage && storage.scanned {
                let v = StorageReader.volumes()
                if v != storage.volumes { storage.volumes = v; pickDestination() }
            }
            if tick % 3 == 0 {
                processes = Array(procs.prefix(12))
                leftovers = procs.filter { $0.leftover && $0.mb > 0 }
            }
            tick += 1
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// A process belongs to a closed app when its .app bundle isn't among the running applications
    /// (widgets, notification and Siri extensions keep running after you quit an app).
    /// Only apps from the Applications folders count; system services that happen to be packaged
    /// as apps (XProtect, Software Update, iMessage agents…) are never offered for stopping.
    private func markLeftovers(_ procs: [ProcessMemory]) -> [ProcessMemory] {
        let open = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        let me = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders: Set<String> = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                    "/System/Applications/Utilities", "\(home)/Applications"]
        return procs.map { p in
            var p = p
            if let app = p.appPath, app != me, !open.contains(app), p.mb >= 5,
               folders.contains((app as NSString).deletingLastPathComponent) {
                p.leftover = true
            }
            return p
        }
    }

    func stopLeftovers(_ targets: [ProcessMemory]) {
        for p in targets { for pid in p.pids { kill(pid, SIGTERM) } }
        let mb = targets.reduce(0) { $0 + $1.mb }
        withAnimation(.exit) {
            let stopped = Set(targets.map(\.name))
            leftovers.removeAll { stopped.contains($0.name) }
            processes.removeAll { stopped.contains($0.name) }
        }
        showToast(targets.count == 1 ? "Stopped \(targets[0].name)'s leftovers, \(mbText(mb)) freed"
                                     : "Stopped leftovers from \(targets.count) apps, \(mbText(mb)) freed")
    }

    /// Quits an app the normal way (it can save its work); plain processes get SIGTERM.
    func quit(_ p: ProcessMemory) {
        let app = p.appPath.flatMap { path in NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path } }
        if let app { app.terminate() } else { for pid in p.pids { kill(pid, SIGTERM) } }
        withAnimation(.exit) { processes.removeAll { $0.name == p.name } }
        showToast("Quit \(p.name), about \(mbText(p.mb)) freed")
    }

    func stopClaudeTasks(_ tasks: [ClaudeTask]) {
        for t in tasks { for pid in t.pids { kill(pid, SIGTERM) } }
        let ids = Set(tasks.map(\.id))
        withAnimation(.exit) {
            claude.orphans.removeAll { ids.contains($0.id) }
            for i in claude.sessions.indices {
                let s = claude.sessions[i]
                claude.sessions[i] = ClaudeSession(id: s.id, kind: s.kind, args: s.args, cwd: s.cwd, mb: s.mb, elapsed: s.elapsed,
                                                   tasks: s.tasks.filter { !ids.contains($0.id) })
            }
        }
        let mb = tasks.reduce(0) { $0 + $1.mb }
        showToast(tasks.count == 1 ? "Stopped \(tasks[0].command.prefix(40)), \(mbText(mb)) freed" : "Stopped \(tasks.count) tasks, \(mbText(mb)) freed")
    }

    func stopClaudeSession(_ s: ClaudeSession) {
        if s.kind == .desktop {
            NSRunningApplication(processIdentifier: s.id)?.terminate()
        } else {
            for t in s.tasks { for pid in t.pids { kill(pid, SIGTERM) } }
            kill(s.id, SIGTERM)
        }
        withAnimation(.exit) { claude.sessions.removeAll { $0.id == s.id } }
        showToast("Closed \(s.title), about \(mbText(s.totalMB)) freed")
    }

    var destinationVolume: Volume? { storage.volumes.first { $0.path == destination && $0.canReceive } }

    private func pickDestination() {
        if destinationVolume == nil { destination = storage.volumes.first(where: \.canReceive)?.path }
    }

    func rescan() async {
        if page == .storage { await scanStorage() } else { await scan() }
    }

    func scanStorage() async {
        busy = true
        let snap = await Task.detached { StorageReader.scan() }.value
        storage = snap
        pickDestination()
        busy = false
    }

    private func replace(_ item: StorageItem, with new: StorageItem?) {
        withAnimation(.easeOutStrong()) {
            if let new { storage.items = storage.items.map { $0.id == item.id ? new : $0 } }
            else { storage.items.removeAll { $0.id == item.id } }
            storage.volumes = StorageReader.volumes()
        }
    }

    func moveStorage(_ item: StorageItem) async {
        guard let volume = destinationVolume else { return }
        working.insert(item.path)
        let (dest, error) = await Task.detached { StorageReader.move(item, to: volume) }.value
        working.remove(item.path)
        if let dest {
            var moved = item
            moved.verdict = .moved(to: dest, connected: true)
            moved.notes = []
            replace(item, with: moved)
            showToast("Moved \(item.name) to \(volume.name), \(mbText(item.mb)) freed")
        } else {
            showToast(error ?? "Couldn't move \(item.name)", warning: true)
        }
    }

    func moveBack(_ item: StorageItem) async {
        guard case .moved(let source, true) = item.verdict else { return }
        working.insert(item.path)
        let error = await Task.detached { StorageReader.moveBack(item, from: source) }.value
        working.remove(item.path)
        if let error { showToast(error, warning: true); return }
        var back = item
        back.verdict = .movable
        replace(item, with: back)
        showToast("\(item.name) is back on this Mac")
    }

    func clearStorage(_ item: StorageItem) async {
        working.insert(item.path)
        let error = await Task.detached { StorageReader.clear(item) }.value
        working.remove(item.path)
        if let error { showToast(error, warning: true); return }
        replace(item, with: nil)
        showToast("Deleted \(item.name), \(mbText(item.mb)) freed")
    }

    /// Colors follow the app, not its rank: an app keeps its color while it stays on the chart,
    /// and a newcomer takes the lowest color no visible app is using.
    private func updateChartApps(_ top: [String]) {
        var taken = Set<Int>()
        var slots: [String: Int] = [:]
        for name in top {
            if let slot = colorSlots[name], !taken.contains(slot) { slots[name] = slot; taken.insert(slot) }
        }
        for name in top where slots[name] == nil {
            let slot = (0..<Color.categorical.count).first { !taken.contains($0) } ?? 0
            slots[name] = slot
            taken.insert(slot)
            colorSlots[name] = slot
        }
        let result = top.map { ChartApp(name: $0, slot: slots[$0] ?? 0) }
        if result != chartApps { chartApps = result }
    }

    func scan() async {
        busy = true
        do { try Engine.installEngine() } catch { showToast("Couldn't install engine: \(error.localizedDescription)", warning: true) }
        let (found, pending) = await Task.detached { (Engine.scan(), Engine.pendingSystem()) }.value
        items = found
        pendingSystem = pending
        choices = [:]
        enforcerOn = Engine.enforcerInstalled
        busy = false
        hasScanned = true
        if !revealed { withAnimation(.easeOutStrong(0.3)) { revealed = true } }
    }

    func setEnforcer(_ on: Bool) async {
        enforcerOn = on
        _ = await Task.detached { Engine.run([on ? "install" : "uninstall"]) }.value
        showToast(on ? "Debloat will keep your choices applied" : "Automatic enforcement turned off")
    }

    func apply() async {
        busy = true
        let changes = pendingChanges.map { ($0, isBlocked($0)) }
        let needsAdmin = pendingNeedsAdmin || !pendingSystem.isEmpty
        let ok = await Task.detached { () -> Bool in
            for (item, block) in changes {
                Engine.run(["set", item.configKind, item.label, block ? "block" : "keep"])
            }
            Engine.run(["apply"])
            return needsAdmin ? Engine.runSystemAsAdmin() : true
        }.value
        await scan()
        let n = changes.count
        if !ok {
            showToast("Saved. System-level changes need your password to finish.", warning: true)
        } else if n == 0 {
            showToast("System changes finished")
        } else {
            showToast("Applied \(n) change\(n == 1 ? "" : "s")")
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            Group {
                // The sidebar list can't be drawn offscreen, so snapshots get a plain stand-in
                if Snapshot.active { snapshotSidebar } else {
                    List(Page.allCases, selection: $model.page) { page in
                        Label(page.title, systemImage: page.symbol)
                            .badge(badge(for: page))
                            .tag(page)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch model.page {
                case .memory: MemoryPage(model: model)
                case .claude: ClaudePage(model: model)
                case .storage: StoragePage(model: model)
                case .startup: StartupPage(model: model)
                case .apple: ApplePage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { bottomBar }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if model.busy {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        Button { Task { await model.rescan() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Rescan")
                    }
                }
            }
            .navigationTitle("Debloat")
        }
    }

    private var snapshotSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases) { page in
                HStack {
                    Label(page.title, systemImage: page.symbol).font(.system(size: 13))
                    Spacer()
                    if badge(for: page) > 0 { Text("\(badge(for: page))").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(page == model.page ? Color.primary.opacity(0.1) : .clear))
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func badge(for page: Page) -> Int {
        switch page {
        case .memory: return 0
        case .claude: return model.claude.sessions.reduce(0) { $0 + $1.tasks.filter { $0.kind == .command }.count } + model.claude.orphans.count
        case .startup: return model.items.filter { [.login, .agent, .daemon].contains($0.kind) && !$0.isBlocked && $0.isRunning }.count
        case .storage, .apple: return 0
        }
    }

    /// Pending-changes bar and confirmation toast share the bottom edge; only one shows at a time.
    @ViewBuilder
    private var bottomBar: some View {
        ZStack {
            if !model.pendingChanges.isEmpty {
                PendingBar(model: model)
                    .transition(.rise(reduceMotion: reduceMotion))
            } else if let toast = model.toast {
                Toast(message: toast)
                    .transition(.rise(reduceMotion: reduceMotion))
            }
        }
        .padding(16)
        .animation(.easeOutStrong(0.25), value: model.pendingChanges.isEmpty)
    }
}

struct PendingBar: View {
    @ObservedObject var model: Model

    var body: some View {
        let n = model.pendingChanges.count
        HStack(spacing: 12) {
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(n) unsaved change\(n == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
                    .contentTransition(.numericText(value: Double(n)))
                Text(model.pendingNeedsAdmin ? "Some changes need your Mac password." : "Takes effect right away; Apple services after a restart.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Revert") { model.revert() }
                .buttonStyle(.secondary)
            Button {
                Task { await model.apply() }
            } label: {
                Label(model.pendingNeedsAdmin ? "Apply…" : "Apply", systemImage: model.pendingNeedsAdmin ? "lock.fill" : "checkmark")
            }
            .buttonStyle(.primary)
            .keyboardShortcut(.defaultAction)
        }
        .disabled(model.busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

struct ToastMessage: Equatable {
    let text: String
    /// Something didn't finish; shown with a warning icon instead of a checkmark
    var warning = false
}

struct Toast: View {
    let message: ToastMessage

    var body: some View {
        Label(message.text, systemImage: message.warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
