import AppKit
import SwiftUI

/// `Debloat --snapshot <dir>` renders every page offscreen to PNGs (dark and light),
/// so the UI can be checked without screen-recording permission.
enum Snapshot {
    static var active = false

    static func run(to dir: String) {
        active = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let model = Model()
            let monitor = Task { await model.startMonitoring() }
            await model.scan()
            try? await Task.sleep(nanoseconds: 20_000_000_000)

            let shots: [(Page, ChartMode)] = [(.memory, .apps), (.memory, .total), (.memory, .breakdown), (.startup, .apps), (.apple, .apps)]
            for (page, mode) in shots {
                for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    model.page = page
                    model.chartMode = mode
                    let size = NSSize(width: 980, height: 1500)
                    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: 0), size: size),
                                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = NSHostingView(rootView: ContentView(model: model).frame(width: size.width, height: size.height))
                    window.orderFrontRegardless()
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let view = window.contentView?.superview ?? window.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: "\(dir)/\(page.rawValue)\(page == .memory ? "-" + mode.rawValue.lowercased() : "")-\(name).png"))
                    }
                    window.orderOut(nil)
                }
            }
            monitor.cancel()
            exit(0)
        }
        app.run()
    }
}
