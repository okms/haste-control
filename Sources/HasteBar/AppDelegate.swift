import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["HASTE_SNAPSHOT"] {
            Task { @MainActor in await Snapshotter.run(into: dir) }
        }
    }
}

/// Debug aid: `HASTE_SNAPSHOT=/some/dir HasteBar` renders the popover and every
/// settings page to PNG files (offscreen, no screen-recording permission needed)
/// once the mouse has been read, then quits.
@MainActor
enum Snapshotter {
    static func run(into dir: String) async {
        let store = Shared.store
        for _ in 0..<40 where store.connection == .connecting || store.connection == .disconnected {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        render(MenuPopover().environment(store), size: nil, to: "\(dir)/popover.png")
        for page in SettingsPage.allCases {
            render(SettingsView(page: page).environment(store), size: NSSize(width: 860, height: 640),
                   to: "\(dir)/settings-\(page.rawValue).png")
        }
        render(MenuBarLabel(store: store).padding(4).background(Color(white: 0.92)), size: nil, to: "\(dir)/menubar-label.png")
        print("snapshots written to \(dir) (connection: \(store.connection))")
        NSApp.terminate(nil)
    }

    private static func render<V: View>(_ view: V, size: NSSize?, to path: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let fitting = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
