import AppKit
import Foundation

struct Item: Identifiable, Hashable {
    enum Kind: String { case login, agent, daemon, apple, feature }
    enum Status: String { case kept, blocked, unknown }

    let kind: Kind
    let label: String
    let status: Status
    let state: String // running | loaded | off
    let memoryMB: Int
    /// Most memory this item has been seen using — what a blocked item would take if allowed
    let seenMB: Int
    let title: String
    let detail: String
    let caution: Bool

    var id: String { "\(kind.rawValue):\(label)" }
    var isBlocked: Bool { status == .blocked }
    var isRunning: Bool { state == "running" }
    var needsAdmin: Bool { kind == .daemon || kind == .feature }
    /// The config kind used by `debloat set`; Apple services are ordinary user agents.
    var configKind: String { kind == .apple ? "agent" : kind.rawValue }

    /// App bundle for login items, so rows can show the real app icon
    var appPath: String? {
        guard kind == .login else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/\(label).app", "\(home)/Applications/\(label).app",
                "/Applications/Utilities/\(label).app", "/System/Applications/\(label).app"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    var symbol: String {
        switch kind {
        case .login: return "app.dashed"
        case .agent: return "gearshape"
        case .daemon: return "lock.shield"
        case .apple: return Item.appleSymbols[label] ?? "apple.logo"
        case .feature: return label == "spotlight" ? "magnifyingglass" : "switch.2"
        }
    }

    /// Symbols for the Apple services in the catalog, so the list can be scanned by eye
    private static let appleSymbols = [
        "com.apple.campo": "sparkles",
        "com.apple.Siri.agent": "mic",
        "com.apple.assistantd": "waveform",
        "com.apple.siriknowledged": "brain",
        "com.apple.siriactionsd": "square.stack.3d.up",
        "com.apple.corespeechd": "waveform.and.mic",
        "com.apple.suggestd": "lightbulb",
        "com.apple.parsecd": "globe",
        "com.apple.knowledge-agent": "chart.bar",
        "com.apple.photoanalysisd": "photo",
        "com.apple.mediaanalysisd": "text.viewfinder",
        "com.apple.AMPLibraryAgent": "music.note",
        "com.apple.gamed": "gamecontroller",
        "com.apple.AirPlayUIAgent": "airplayvideo",
        "com.apple.newsd": "newspaper",
        "com.apple.weatherd": "cloud.sun",
        "com.apple.tipsd": "text.bubble",
        "com.apple.helpd": "questionmark.circle",
        "com.apple.familycircled": "person.3",
        "com.apple.ScreenTimeAgent": "hourglass",
    ]

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
            || label.localizedCaseInsensitiveContains(query) || detail.localizedCaseInsensitiveContains(query)
    }
}

/// Thin wrapper around the `debloat` shell engine, which does all the real work.
/// The engine is copied to ~/.debloat so the background enforcer keeps running without the app.
enum Engine {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".debloat")
    static let script = dir.appendingPathComponent("debloat")
    static let enforcerPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.debloat.plist")

    static var catalogURL: URL? { Bundle.main.url(forResource: "catalog", withExtension: "tsv") }

    static var enforcerInstalled: Bool { FileManager.default.fileExists(atPath: enforcerPlist.path) }

    static func installEngine() throws {
        guard let bundled = Bundle.main.url(forResource: "debloat", withExtension: nil) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.contentsEqual(atPath: bundled.path, andPath: script.path) { return }
        if fm.fileExists(atPath: script.path) { try fm.removeItem(at: script) }
        try fm.copyItem(at: bundled, to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    @discardableResult
    static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "failed to run engine: \(error.localizedDescription)" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// System-level changes in the config that still need the admin password
    static func pendingSystem() -> [String] {
        run(["pending"]).split(separator: "\n").map(String.init)
    }

    /// Runs `debloat system` as root via the standard macOS admin password prompt.
    static func runSystemAsAdmin() -> Bool {
        let cmd = "DEBLOAT_DIR=\(shellQuote(dir.path)) /bin/bash \(shellQuote(script.path)) system"
        let source = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    static func scan() -> [Item] {
        let catalog = loadCatalog()
        var args = ["scan", "--tsv"]
        if let url = catalogURL { args += ["--extra", url.path] }
        return run(args).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let kind = Item.Kind(rawValue: f[0]) else { return nil }
            let info = catalog[f[1]]
            return Item(kind: kind, label: f[1], status: Item.Status(rawValue: f[2]) ?? .unknown,
                        state: f[3], memoryMB: Int(f[4]) ?? 0,
                        seenMB: f.count > 5 ? Int(f[5]) ?? 0 : 0,
                        title: info?.title ?? f[1], detail: info?.detail ?? "",
                        caution: info?.caution ?? false)
        }
    }

    private static func loadCatalog() -> [String: (title: String, detail: String, caution: Bool)] {
        guard let url = catalogURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: (String, String, Bool)] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            if f.count == 4 { result[f[0]] = (f[1], f[2], f[3] == "1") }
        }
        return result
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
