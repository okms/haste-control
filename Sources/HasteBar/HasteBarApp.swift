import AppKit
import HasteKit
import SwiftUI

@MainActor
enum Shared {
    static let store = MouseStore()
    static let profiles = ProfileManager(store: store)
}

@main
struct HasteBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = Shared.store
    private let profiles = Shared.profiles

    var body: some Scene {
        MenuBarExtra {
            MenuPopover()
                .environment(store)
                .environment(profiles)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("HyperX Pulsefire Haste", id: "settings") {
            SettingsView()
                .environment(store)
                .environment(profiles)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 600)
    }
}

/// Status-item label: a mouse glyph whose body fills with charge, plus the %.
struct MenuBarLabel: View {
    let store: MouseStore

    var body: some View {
        let pct = store.cachedBatteryPercent
        let low = (pct ?? 100) <= store.notifyThreshold && store.battery?.charge == .discharging
        HStack(spacing: 3) {
            Image(nsImage: MouseGlyph.image(level: pct.map { Double($0) / 100 },
                                            charging: store.battery?.charge == .charging,
                                            dimmed: store.connection != .ready,
                                            alert: low))
            if store.showPercentInMenuBar, let pct {
                Text("\(pct)%")
                    .monospacedDigit()
            }
        }
        .help(store.statusText)
    }
}

enum MouseGlyph {
    /// Draws a mouse outline filled from the bottom to `level`.
    static func image(level: Double?, charging: Bool, dimmed: Bool, alert: Bool) -> NSImage {
        let size = NSSize(width: 12, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 1.5, y: 1.5, width: 9, height: 15)
            let path = NSBezierPath(roundedRect: body, xRadius: 4.5, yRadius: 4.5)
            let ink = alert ? NSColor.systemRed : NSColor.black
            ink.withAlphaComponent(dimmed ? 0.45 : 1).setStroke()
            path.lineWidth = 1.3
            path.stroke()
            // button split line
            let split = NSBezierPath()
            split.move(to: NSPoint(x: 6, y: 16.5)); split.line(to: NSPoint(x: 6, y: 12))
            split.lineWidth = 1
            split.stroke()
            if let level {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: body.insetBy(dx: 1.6, dy: 1.6), xRadius: 3, yRadius: 3).addClip()
                let h = (body.height - 3.2) * max(0.04, min(1, level))
                (alert ? NSColor.systemRed : NSColor.black).withAlphaComponent(dimmed ? 0.45 : 1).setFill()
                NSRect(x: body.minX, y: body.minY + 1.6, width: body.width, height: h).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if charging {
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 7, y: 11)); bolt.line(to: NSPoint(x: 4, y: 6.5))
                bolt.line(to: NSPoint(x: 6.2, y: 6.5)); bolt.line(to: NSPoint(x: 5, y: 2.5))
                bolt.line(to: NSPoint(x: 8, y: 7.5)); bolt.line(to: NSPoint(x: 5.8, y: 7.5))
                bolt.close()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                bolt.lineWidth = 1.6
                bolt.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                bolt.fill()
            }
            return true
        }
        img.isTemplate = !alert
        return img
    }
}
