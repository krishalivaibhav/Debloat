import SwiftUI

struct ClaudePage: View {
    @ObservedObject var model: Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let snap = model.claude
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Claude", subtitle: "Claude Code sessions and the Claude app: what each one is running, how much memory it takes, and a way to stop it.")
                ClaudeSummary(snapshot: snap)
                if !snap.orphans.isEmpty {
                    OrphansCard(model: model, tasks: snap.orphans)
                        .transition(.rise(reduceMotion: reduceMotion))
                }
                if snap.sessions.isEmpty {
                    Card {
                        ContentUnavailableView("Claude isn't running", systemImage: "sparkle",
                                               description: Text("Sessions show up here as soon as you start `claude` or open the Claude app."))
                    }
                }
                ForEach(snap.sessions) { s in
                    SessionCard(model: model, session: s)
                        .transition(.rise(reduceMotion: reduceMotion))
                }
            }
            .padding(24)
            .padding(.bottom, 72)
            .animation(.easeOutStrong(), value: snap)
        }
    }
}

private struct ClaudeSummary: View {
    let snapshot: ClaudeSnapshot

    var body: some View {
        let sessions = snapshot.sessions
        let commands = sessions.reduce(0) { $0 + $1.tasks.filter { $0.kind == .command }.count } + snapshot.orphans.count
        let mb = sessions.reduce(0) { $0 + $1.totalMB } + snapshot.orphans.reduce(0) { $0 + $1.mb }
        Card(padding: 20) {
            HStack(spacing: 32) {
                stat(mbText(mb), "memory in total")
                stat("\(sessions.count)", sessions.count == 1 ? "session" : "sessions")
                stat("\(commands)", commands == 1 ? "command running" : "commands running")
                Spacer()
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct SessionCard: View {
    @ObservedObject var model: Model
    let session: ClaudeSession
    @StateObject private var confirm = ConfirmState()

    final class ConfirmState: ObservableObject { @Published var shown = false }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ItemIcon(appPath: session.kind == .desktop ? "/Applications/Claude.app" : nil,
                             symbol: "terminal", size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.system(size: 14, weight: .semibold))
                        if let cwd = session.cwd {
                            Text(cwd.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        HStack(spacing: 6) {
                            chip(session.kind == .desktop ? "Desktop app" : "Claude Code\(session.args.isEmpty ? "" : " · " + session.args)")
                            chip("up \(session.elapsed)")
                            chip(mbText(session.totalMB))
                        }
                    }
                    Spacer(minLength: 12)
                    Button(session.kind == .desktop ? "Quit" : "End session") { confirm.shown = true }
                        .buttonStyle(.secondary)
                        .fixedSize()
                }
                if !session.tasks.isEmpty {
                    Divider()
                    VStack(spacing: 8) {
                        ForEach(session.tasks) { TaskRow(model: model, task: $0) }
                    }
                } else if session.kind == .cli {
                    Text("Idle: nothing running in the background.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("End \(session.title)?", isPresented: $confirm.shown) {
            Button(session.kind == .desktop ? "Quit Claude" : "End session", role: .destructive) { model.stopClaudeSession(session) }
        } message: {
            Text(session.kind == .desktop
                 ? "The Claude app quits. Your chats are saved."
                 : "This stops the Claude Code session and everything it's running. Work in progress in that terminal is interrupted; you can pick it up again with `claude --continue`.")
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

private struct TaskRow: View {
    @ObservedObject var model: Model
    let task: ClaudeTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.command).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    .help(task.command)
                Text("\(task.kind == .mcp ? "MCP server" : task.kind == .command ? "Command" : "Process") · running \(task.elapsed) · \(mbText(task.mb))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            Button("Stop") { model.stopClaudeTasks([task]) }
                .buttonStyle(.secondary)
                .help(task.kind == .mcp ? "Claude loses this tool until the session restarts" : "Stops this command and anything it started")
        }
    }
}

private struct OrphansCard: View {
    @ObservedObject var model: Model
    let tasks: [ClaudeTask]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    CardHeader(title: "Left running by ended sessions",
                               subtitle: "Commands Claude started in the background whose session has closed. Nothing is watching them anymore.")
                    Spacer(minLength: 16)
                    Button("Stop all · \(mbText(tasks.reduce(0) { $0 + $1.mb }))") { model.stopClaudeTasks(tasks) }
                        .buttonStyle(.primary)
                        .fixedSize()
                }
                ForEach(tasks) { TaskRow(model: model, task: $0) }
            }
        }
    }
}
