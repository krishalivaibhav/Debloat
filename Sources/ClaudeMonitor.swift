import Foundation

/// A Claude Code session (the `claude` CLI) or the Claude desktop app, with what it has started.
struct ClaudeSession: Identifiable, Equatable {
    let id: Int32 // pid
    let kind: Kind
    let args: String
    /// Working folder of a CLI session; nil for the desktop app
    let cwd: String?
    let mb: Int
    let elapsed: String
    let tasks: [ClaudeTask]

    enum Kind { case cli, desktop }

    var title: String {
        if kind == .desktop { return "Claude app" }
        guard let cwd else { return "Claude Code" }
        return (cwd as NSString).lastPathComponent
    }

    /// Session memory plus everything it started
    var totalMB: Int { mb + tasks.reduce(0) { $0 + $1.mb } }
}

/// A process a Claude session started: a shell command it ran, or an MCP server it talks to.
struct ClaudeTask: Identifiable, Equatable {
    let id: Int32 // pid
    let kind: Kind
    let command: String
    let mb: Int
    let elapsed: String
    /// This pid and everything below it, deepest first, so stopping leaves nothing behind
    let pids: [Int32]

    enum Kind { case command, mcp, other }

    var symbol: String {
        switch kind {
        case .command: return "terminal"
        case .mcp: return "puzzlepiece.extension"
        case .other: return "gearshape"
        }
    }
}

struct ClaudeSnapshot: Equatable {
    var sessions: [ClaudeSession] = []
    /// Commands Claude started whose session has ended but which are still running
    var orphans: [ClaudeTask] = []
}

enum ClaudeReader {
    private struct Proc {
        let pid: Int32
        let ppid: Int32
        let kb: Int
        let elapsed: String
        let command: String
    }

    static func scan() -> ClaudeSnapshot {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Axww", "-o", "pid=,ppid=,rss=,etime=,command="]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return ClaudeSnapshot() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let me = getpid()
        let procs: [Proc] = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let ppid = Int32(f[1]), let kb = Int(f[2]) else { return nil }
            return Proc(pid: pid, ppid: ppid, kb: kb, elapsed: String(f[3]), command: String(f[4]))
        }
        var children: [Int32: [Proc]] = [:]
        for proc in procs { children[proc.ppid, default: []].append(proc) }

        func descendants(_ pid: Int32) -> [Proc] {
            (children[pid] ?? []).flatMap { descendants($0.pid) + [$0] }
        }
        func task(_ proc: Proc) -> ClaudeTask? {
            let below = descendants(proc.pid)
            // Our own `ps`/`lsof` calls show up briefly under whichever session ran Debloat
            if below.contains(where: { $0.pid == me }) || proc.pid == me { return nil }
            let (kind, command) = describe(proc.command)
            return ClaudeTask(id: proc.pid, kind: kind, command: command,
                              mb: (below.reduce(0) { $0 + $1.kb } + proc.kb) / 1024,
                              elapsed: friendlyElapsed(proc.elapsed), pids: below.map(\.pid) + [proc.pid])
        }

        let cliProcs = procs.filter { isCLI($0.command) }
        let desktop = procs.first { $0.command.hasPrefix("/Applications/Claude.app/Contents/MacOS/Claude") }
        let cwds = workingDirectories(cliProcs.map(\.pid))

        var sessions = cliProcs.map { s in
            ClaudeSession(id: s.pid, kind: .cli, args: arguments(s.command), cwd: cwds[s.pid], mb: s.kb / 1024,
                          elapsed: friendlyElapsed(s.elapsed),
                          tasks: (children[s.pid] ?? []).compactMap(task).sorted { $0.mb > $1.mb })
        }
        if let d = desktop {
            // Electron helpers are part of the app itself; only count their memory
            let helpers = descendants(d.pid)
            sessions.append(ClaudeSession(id: d.pid, kind: .desktop, args: "", cwd: nil,
                                          mb: (helpers.reduce(0) { $0 + $1.kb } + d.kb) / 1024,
                                          elapsed: friendlyElapsed(d.elapsed), tasks: []))
        }

        // A Claude shell command whose session is gone gets re-parented to launchd
        let orphans = procs.filter { $0.ppid == 1 && $0.command.contains("/.claude/shell-snapshots/") }.compactMap(task)
        return ClaudeSnapshot(sessions: sessions.sorted { $0.totalMB > $1.totalMB }, orphans: orphans)
    }

    private static func isCLI(_ command: String) -> Bool {
        let exe = String(command.split(separator: " ").first ?? "")
        return (exe as NSString).lastPathComponent == "claude" || command.contains("@anthropic-ai/claude-code/cli")
    }

    private static func arguments(_ command: String) -> String {
        command.split(separator: " ").dropFirst().joined(separator: " ")
    }

    /// Claude Code wraps every command in `zsh -c "source <snapshot> && … eval '<command>' < /dev/null …"`; show just the command.
    private static func describe(_ command: String) -> (ClaudeTask.Kind, String) {
        if command.contains("/.claude/shell-snapshots/"),
           let start = command.range(of: "eval '"),
           let end = command.range(of: "' < /dev/null", options: .backwards, range: start.upperBound..<command.endIndex) {
            return (.command, command[start.upperBound..<end.lowerBound].replacingOccurrences(of: "'\\''", with: "'"))
        }
        let lower = command.lowercased()
        if lower.contains("mcp") || lower.contains("modelcontextprotocol") { return (.mcp, mcpName(command)) }
        if command.hasPrefix("caffeinate") { return (.other, "Keeping your Mac awake while Claude works") }
        return (.other, command)
    }

    /// "npm exec @modelcontextprotocol/server-pdf --stdio" → "server-pdf"
    private static func mcpName(_ command: String) -> String {
        let word = command.split(separator: " ").first {
            $0.lowercased().contains("mcp") || $0.contains("server-") || $0.contains("modelcontextprotocol")
        }
        return word.map { (String($0) as NSString).lastPathComponent } ?? command
    }

    private static func workingDirectories(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var result: [Int32: String] = [:]
        var current: Int32?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            if line.hasPrefix("n"), let pid = current { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    /// ps etime "[[dd-]hh:]mm:ss" → "2 d", "3 h", "14 min", "12 s"
    static func friendlyElapsed(_ etime: String) -> String {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let parts = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        let (h, m, s) = parts.count == 3 ? (parts[0], parts[1], parts[2]) : (0, parts.first ?? 0, parts.last ?? 0)
        if days > 0 { return "\(days) d" }
        if h > 0 { return "\(h) h" }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }
}
