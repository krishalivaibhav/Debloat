import Darwin
import Foundation

/// One reading of system memory, using the same breakdown as Activity Monitor.
struct MemorySample: Identifiable {
    let id = UUID()
    let date: Date
    let app: Double        // GB
    let wired: Double
    let compressed: Double
    let cached: Double
    let swap: Double
    let freePercent: Int   // macOS's own "memory free" figure; drives the pressure colour

    var used: Double { app + wired + compressed }
}

struct ProcessMemory: Identifiable {
    let id: Int32 // pid
    let name: String
    let mb: Int
    /// Outermost .app bundle, for the icon; nil for plain system processes
    let appPath: String?
    let pids: [Int32]
    /// Its app isn't open, but widgets or extensions from it are still running
    var leftover = false

    /// Only apps from the Applications folders can be quit from here, never macOS itself or Debloat
    var canQuit: Bool {
        guard let appPath, appPath != Bundle.main.bundlePath else { return false }
        return appPath.hasPrefix("/Applications/") || appPath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }
}

enum MemoryReader {
    static let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    static func sample() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Double(vm_kernel_page_size) / 1_073_741_824
        let purgeable = Double(stats.purgeable_count)
        return MemorySample(
            date: Date(),
            app: (Double(stats.internal_page_count) - purgeable) * page,
            wired: Double(stats.wire_count) * page,
            compressed: Double(stats.compressor_page_count) * page,
            cached: (Double(stats.external_page_count) + purgeable) * page,
            swap: swapUsedGB(),
            freePercent: sysctlInt("kern.memorystatus_level") ?? 100
        )
    }

    /// Processes grouped by app, largest first.
    static func topProcesses(limit: Int = .max) -> [ProcessMemory] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Axo", "pid=,rss=,comm="]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        // Group helper processes under their app (e.g. all "Brave Browser Helper" → "Brave Browser")
        var byName: [String: (pids: [Int32], kb: Int, app: String?)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let kb = Int(f[1]) else { continue }
            let path = String(f[2])
            let name = displayName(path)
            let prev = byName[name]
            byName[name] = ((prev?.pids ?? []) + [pid], (prev?.kb ?? 0) + kb, prev?.app ?? appBundle(path))
        }
        return byName.map { ProcessMemory(id: $0.value.pids[0], name: $0.key, mb: $0.value.kb / 1024,
                                          appPath: $0.value.app, pids: $0.value.pids) }
            .sorted { $0.mb > $1.mb }
            .prefix(limit)
            .map { $0 }
    }

    /// Readable names for common system processes whose real names are bundle IDs
    private static let friendlyNames = [
        "com.apple.WebKit.WebContent": "Web pages (WebKit)",
        "com.apple.WebKit.GPU": "Web graphics (WebKit)",
        "com.apple.WebKit.Networking": "Web networking (WebKit)",
        "kernel_task": "macOS kernel",
        "WindowServer": "WindowServer (display)",
        "corespotlightd": "Spotlight",
        "mds_stores": "Spotlight index",
    ]

    /// Name of the outermost .app in the path, so helpers count toward their parent app
    private static func displayName(_ path: String) -> String {
        if let app = path.range(of: ".app/"),
           let slash = path[..<app.lowerBound].range(of: "/", options: .backwards) {
            return String(path[slash.upperBound..<app.lowerBound])
        }
        let name = (path as NSString).lastPathComponent
        return friendlyNames[name] ?? name
    }

    private static func appBundle(_ path: String) -> String? {
        guard let app = path.range(of: ".app/") else { return nil }
        return String(path[..<app.lowerBound]) + ".app"
    }

    private static func swapUsedGB() -> Double {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return Double(swap.xsu_used) / 1_073_741_824
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}
