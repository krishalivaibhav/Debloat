import Foundation

/// A mounted disk: the Mac's own drive or one plugged into it.
struct Volume: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    /// Finder's name for the format, e.g. "APFS", "ExFAT"
    let format: String
    /// statfs name: apfs, hfs, exfat, msdos, ntfs…
    let fsType: String
    let totalMB: Int
    let freeMB: Int
    let isRoot: Bool
    let readOnly: Bool

    var usedMB: Int { max(0, totalMB - freeMB) }
    /// FAT-family drives can't store symlinks or Unix permissions
    var isFAT: Bool { ["exfat", "msdos"].contains(fsType) }
    var canReceive: Bool { !isRoot && !readOnly }
}

enum StorageKind: String, CaseIterable, Identifiable {
    case apps, documents, desktop, downloads, media, developer, caches, appData
    var id: Self { self }

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .documents: return "Documents"
        case .desktop: return "Desktop"
        case .downloads: return "Downloads"
        case .media: return "Photos, music & video"
        case .developer: return "Developer"
        case .caches: return "Caches"
        case .appData: return "App data"
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "app.dashed"
        case .documents: return "doc"
        case .desktop: return "menubar.dock.rectangle"
        case .downloads: return "arrow.down.circle"
        case .media: return "photo.on.rectangle"
        case .developer: return "hammer"
        case .caches: return "clock.arrow.circlepath"
        case .appData: return "shippingbox"
        }
    }
}

/// A large file or folder, and whether it can leave this Mac.
struct StorageItem: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let kind: StorageKind
    let mb: Int
    var verdict: Verdict
    /// Things that point at this item and would notice it moving
    var notes: [String]
    /// Holds symlinks (every .app does), which an ExFAT or FAT drive can't store
    let hasSymlinks: Bool

    enum Verdict: Equatable {
        case movable
        /// Apps that have files inside it open right now
        case inUse([String])
        /// Rebuilt on demand, so deleting beats moving
        case clearable
        case keep(String)
        case moved(to: String, connected: Bool)
    }

    var name: String { (path as NSString).lastPathComponent }
    var displayPath: String { StorageReader.tilde(path) }
    var isApp: Bool { path.hasSuffix(".app") }
}

struct StorageSnapshot: Equatable {
    var volumes: [Volume] = []
    var items: [StorageItem] = []
    /// Everything in each kind's folders, small files included
    var totals: [StorageKind: Int] = [:]
    var scanned = false
}

enum StorageReader {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Smaller items aren't worth a row
    static let minMB = 100
    /// Moved items land here on the drive, mirroring where they came from
    static let folderOnDrive = "Moved from Mac"

    private static let roots: [(String, StorageKind)] = [
        ("/Applications", .apps), ("\(home)/Applications", .apps),
        ("\(home)/Desktop", .desktop), ("\(home)/Documents", .documents), ("\(home)/Downloads", .downloads),
        ("\(home)/Movies", .media), ("\(home)/Music", .media), ("\(home)/Pictures", .media),
        ("\(home)/Library/Developer", .developer), ("\(home)/Library/Caches", .caches),
        ("\(home)/Library/Application Support", .appData),
    ]

    static func tilde(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey,
                                      .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            var fs = statfs()
            let type = statfs(url.path, &fs) == 0 ? withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
            // "Important usage" is APFS-only and reads 0 on ExFAT and other drives
            let important = Int(v.volumeAvailableCapacityForImportantUsage ?? 0)
            let free = important > 0 ? important : v.volumeAvailableCapacity ?? 0
            let root = v.volumeIsRootFileSystem ?? false
            // The sealed system volume and its data twin both show up; keep one "Macintosh HD"
            if !root && url.path.hasPrefix("/System/Volumes") { return nil }
            return Volume(path: url.path, name: v.volumeName ?? url.lastPathComponent,
                          format: (v.volumeLocalizedFormatDescription ?? type.uppercased()).replacingOccurrences(of: " (Case-sensitive)", with: ""),
                          fsType: type, totalMB: total / 1_048_576, freeMB: free / 1_048_576,
                          isRoot: root, readOnly: v.volumeIsReadOnly ?? false)
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }

    static func scan() -> StorageSnapshot {
        let fm = FileManager.default
        let open = openFiles()
        let references = referencingFiles()
        let me = Bundle.main.bundlePath
        var items: [StorageItem] = []
        var totals: [StorageKind: Int] = [:]

        for (root, kind) in roots where fm.fileExists(atPath: root) {
            // `du -a` doesn't follow symlinks, so things already moved need their own pass
            for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let path = "\(root)/\(name)"
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { continue }
                let target = dest.hasPrefix("/") ? dest : "\(root)/\(dest)"
                guard target.hasPrefix("/Volumes/") else { continue }
                let connected = fm.fileExists(atPath: target)
                items.append(StorageItem(path: path, kind: kind, mb: connected ? diskUsage(target) : 0,
                                         verdict: .moved(to: target, connected: connected), notes: [], hasSymlinks: false))
            }
            for (path, mb) in du(root) {
                if path == root { totals[kind, default: 0] += mb; continue }
                let name = (path as NSString).lastPathComponent
                guard mb >= minMB, !name.hasPrefix("."), path != me else { continue }
                var verdict = rule(path: path, kind: kind)
                let users = open.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map(\.process)
                if !users.isEmpty, verdict == .movable || verdict == .clearable {
                    // "Code Helper (Renderer)" and friends are the same app as "Code"
                    let names = Set(users.map { $0.components(separatedBy: " Helper").first ?? $0 })
                    verdict = .inUse(names.sorted())
                }
                let notes = references.compactMap { ref in ref.mentions(path) ? ref.describe(path) : nil }
                var symlinks = false
                if case .movable = verdict { symlinks = containsSymlink(path) }
                if case .inUse = verdict { symlinks = containsSymlink(path) }
                var item = StorageItem(path: path, kind: kind, mb: mb, verdict: verdict, notes: notes, hasSymlinks: symlinks)
                if item.isApp, case .movable = verdict { item.notes.insert("Opens only while the drive is plugged in", at: 0) }
                items.append(item)
            }
        }
        return StorageSnapshot(volumes: volumes(), items: items.sorted { $0.mb > $1.mb }, totals: totals, scanned: true)
    }

    /// What may leave the Mac, judged by where it lives
    private static func rule(path: String, kind: StorageKind) -> StorageItem.Verdict {
        let name = (path as NSString).lastPathComponent
        switch kind {
        case .caches:
            return .clearable
        case .appData:
            return .keep("\(name) looks for its data in exactly this place, so it would break or start over.")
        case .developer:
            if name == "CoreSimulator" { return .keep("Simulators. Remove old ones in Xcode ▸ Settings ▸ Components.") }
            return .keep("Xcode manages this. Clear DerivedData from Xcode ▸ Settings ▸ Locations.")
        case .apps:
            let info = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist")
            if (info?["CFBundleIdentifier"] as? String)?.hasPrefix("com.apple.") == true { return .keep("Comes with macOS.") }
            if FileManager.default.fileExists(atPath: "\(path)/Contents/_MASReceipt") {
                return .keep("From the App Store, which only updates apps in Applications.")
            }
            return .movable
        default:
            return .movable
        }
    }

    // MARK: - Moving

    /// Copies to the drive, checks the copy, then swaps the original for a shortcut so paths keep working.
    /// Returns nil on success, or why it stopped (nothing is lost on any failure path).
    static func move(_ item: StorageItem, to volume: Volume) -> (dest: String?, error: String?) {
        let fm = FileManager.default
        let relative = item.path.hasPrefix(home) ? String(item.path.dropFirst(home.count + 1)) : String(item.path.dropFirst())
        let dest = "\(volume.path)/\(folderOnDrive)/\(relative)"
        if fm.fileExists(atPath: dest) { return (nil, "\(volume.name) already has \(tilde(dest)). Rename or remove it first.") }
        if item.mb + 512 > volume.freeMB { return (nil, "\(volume.name) has \(mbText(volume.freeMB)) free; this needs \(mbText(item.mb)).") }
        do { try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
        catch { return (nil, "Couldn't write to \(volume.name): \(error.localizedDescription)") }

        // FAT drives turn extended attributes into ._ clutter files; leave them behind
        let flags = volume.isFAT ? ["--norsrc", "--noextattr", "--noacl", "--noqtn"] : []
        guard run("/usr/bin/ditto", flags + [item.path, dest]) == 0, entryCount(item.path) == entryCount(dest) else {
            try? fm.removeItem(atPath: dest)
            return (nil, "The copy didn't finish, so \(item.name) stayed where it was.")
        }
        // Rename first: if the original can't be taken away we still have one intact copy, not half of each
        let parked = item.path + ".debloat-moving"
        do { try fm.moveItem(atPath: item.path, toPath: parked) } catch {
            try? fm.removeItem(atPath: dest)
            return (nil, "macOS wouldn't let Debloat remove the original (\(error.localizedDescription)). Nothing changed.")
        }
        do { try fm.createSymbolicLink(atPath: item.path, withDestinationPath: dest) } catch {
            try? fm.moveItem(atPath: parked, toPath: item.path)
            try? fm.removeItem(atPath: dest)
            return (nil, "Couldn't leave a shortcut behind, so nothing was moved.")
        }
        try? fm.removeItem(atPath: parked)
        return (dest, nil)
    }

    /// Brings a moved item back from the drive and removes it there.
    static func moveBack(_ item: StorageItem, from source: String) -> String? {
        let fm = FileManager.default
        let free = volumes().first(where: \.isRoot)?.freeMB ?? 0
        if item.mb + 2048 > free { return "This Mac has \(mbText(free)) free; \(item.name) needs \(mbText(item.mb))." }
        let incoming = item.path + ".debloat-moving"
        guard run("/usr/bin/ditto", [source, incoming]) == 0, entryCount(source) == entryCount(incoming) else {
            try? fm.removeItem(atPath: incoming)
            return "The copy didn't finish, so \(item.name) stayed on the drive."
        }
        do {
            try fm.removeItem(atPath: item.path) // the shortcut
            try fm.moveItem(atPath: incoming, toPath: item.path)
        } catch {
            try? fm.removeItem(atPath: incoming)
            return "Couldn't put \(item.name) back: \(error.localizedDescription)"
        }
        try? fm.removeItem(atPath: source)
        // Tidy the now-empty folders above it, up to and including "Moved from Mac"
        var dir = (source as NSString).deletingLastPathComponent
        while dir.contains("/\(folderOnDrive)"), (try? fm.contentsOfDirectory(atPath: dir))?.allSatisfy({ $0.hasPrefix("._") || $0 == ".DS_Store" }) == true {
            try? fm.removeItem(atPath: dir)
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func clear(_ item: StorageItem) -> String? {
        do { try FileManager.default.removeItem(atPath: item.path); return nil }
        catch { return "Couldn't delete \(item.name): \(error.localizedDescription)" }
    }

    // MARK: - Helpers

    private struct OpenFile { let path: String; let process: String }

    /// Files and working folders held open by any of this user's processes
    private static func openFiles() -> [OpenFile] {
        let ignored: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "Debloat", "lsof", "du", "fseventsd", "Finder", "QuickLookUIService"]
        var result: [OpenFile] = []
        var process = ""
        for line in output("/usr/sbin/lsof", ["-n", "-w", "-F", "cn"]).split(separator: "\n") {
            if line.hasPrefix("c") { process = String(line.dropFirst()) }
            else if line.hasPrefix("n/"), !ignored.contains(process) {
                let path = String(line.dropFirst())
                if path.hasPrefix(home) || path.hasPrefix("/Applications/") { result.append(OpenFile(path: path, process: process)) }
            }
        }
        return result
    }

    private struct Reference {
        let file: String
        let text: String
        let isLoginItem: Bool

        func mentions(_ path: String) -> Bool {
            [path, "~" + path.dropFirst(StorageReader.home.count), "$HOME" + path.dropFirst(StorageReader.home.count)]
                .contains { candidate in
                    guard let r = text.range(of: candidate) else { return false }
                    // "~/Desktop/game" mustn't match "~/Desktop/games"
                    let next = text[r.upperBound...].first
                    return next == nil || "/\"' \n:<".contains(next!)
                }
        }

        func describe(_ path: String) -> String {
            isLoginItem ? "A login item (\(StorageReader.tilde(file))) runs from here"
                        : "\(StorageReader.tilde(file)) points here"
        }
    }

    /// Shell configs, login items and shortcuts that refer to paths by name
    private static func referencingFiles() -> [Reference] {
        let fm = FileManager.default
        var refs: [Reference] = []
        for name in [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", ".profile", ".gitconfig"] {
            let file = "\(home)/\(name)"
            if let text = try? String(contentsOfFile: file, encoding: .utf8) { refs.append(Reference(file: file, text: text, isLoginItem: false)) }
        }
        for dir in ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".plist") {
                let file = "\(dir)/\(name)"
                guard let plist = NSDictionary(contentsOfFile: file) else { continue }
                refs.append(Reference(file: file, text: "\(plist)", isLoginItem: true))
            }
        }
        // Shortcuts (symlinks) in the usual places that point at something else on this Mac
        for dir in [home, "\(home)/Desktop", "\(home)/Documents", "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let link = "\(dir)/\(name)"
                guard let dest = try? fm.destinationOfSymbolicLink(atPath: link), !dest.hasPrefix("/Volumes/") else { continue }
                refs.append(Reference(file: link, text: dest.hasPrefix("/") ? dest : "\(dir)/\(dest)", isLoginItem: false))
            }
        }
        return refs
    }

    /// Path → size in MB of the folder and each thing directly inside it
    private static func du(_ root: String) -> [(String, Int)] {
        // macOS du can't combine -a with -d, so measure each child and add them up for the folder
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).map { "\(root)/\($0)" }
        guard !children.isEmpty else { return [] }
        var kbTotal = 0
        var result: [(String, Int)] = output("/usr/bin/du", ["-sk", "-x"] + children).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int(parts[0]) else { return nil }
            kbTotal += kb
            return (String(parts[1]), kb / 1024)
        }
        result.append((root, kbTotal / 1024))
        return result
    }

    private static func diskUsage(_ path: String) -> Int {
        Int(output("/usr/bin/du", ["-sk", path]).split(separator: "\t").first ?? "").map { $0 / 1024 } ?? 0
    }

    private static func containsSymlink(_ path: String) -> Bool {
        !output("/usr/bin/find", [path, "-type", "l", "-print", "-quit"]).isEmpty
    }

    /// Entries excluding the clutter macOS adds on its own, so a copy and its original compare equal
    private static func entryCount(_ path: String) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return -1 }
        guard isDir.boolValue, let e = FileManager.default.enumerator(atPath: path) else { return 1 }
        var n = 0
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            if !name.hasPrefix("._") && name != ".DS_Store" { n += 1 }
        }
        return n
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func output(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
