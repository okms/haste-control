import HasteKit
import SwiftUI

struct MenuPopover: View {
    @Environment(MouseStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch store.connection {
            case .disconnected:
                Placeholder(symbol: "cable.connector.slash",
                            text: "Plug in the HyperX 2.4 GHz dongle or connect the mouse with its USB-C cable.")
            case .connecting:
                ProgressView("Reading settings…").frame(maxWidth: .infinity)
            case .asleep:
                BatteryCard(compact: true)
                Placeholder(symbol: "moon.zzz", text: "The mouse is asleep. Move it to wake it up.")
            case .ready:
                BatteryCard(compact: false)
                Divider()
                DPIQuickPicker()
                PollingQuickPicker()
                ProfileQuickPicker()
            }
            if let err = store.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pulsefire Haste Wireless").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(store.statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var dotColor: Color {
        switch store.connection {
        case .ready: .green
        case .asleep: .yellow
        case .connecting: .blue
        case .disconnected: .gray
        }
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: { Label("Settings…", systemImage: "slider.horizontal.3") }
            Spacer()
            Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read everything from the mouse")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit")
        }
        .buttonStyle(.borderless)
    }
}

struct Placeholder: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BatteryCard: View {
    @Environment(MouseStore.self) private var store
    let compact: Bool

    var body: some View {
        let pct = store.cachedBatteryPercent
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                Circle().trim(from: 0, to: CGFloat(pct ?? 0) / 100)
                    .stroke(color(pct), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(pct.map { "\($0)%" } ?? "—").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    if store.battery?.charge == .charging {
                        Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Battery").font(.subheadline.weight(.semibold))
                if let b = store.battery {
                    Text(b.charge.label).font(.caption)
                    if !compact, b.millivolts > 0 {
                        Text(String(format: "%.2f V", Double(b.millivolts) / 1000)).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(pct == nil ? "Shown once the mouse wakes" : "Last known level")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let t = store.batteryUpdated {
                    Text("Updated \(t, style: .relative) ago").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    private func color(_ pct: Int?) -> Color {
        guard let pct else { return .gray }
        if store.battery?.charge == .charging { return .green }
        return pct <= store.notifyThreshold ? .red : pct <= 30 ? .orange : .green
    }
}

struct DPIQuickPicker: View {
    @Environment(MouseStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DPI").font(.subheadline.weight(.semibold))
            if let d = store.dpi {
                HStack(spacing: 6) {
                    ForEach(Array(d.profiles.enumerated()), id: \.offset) { i, p in
                        if p.enabled {
                            Button { store.selectProfile(i) } label: {
                                VStack(spacing: 3) {
                                    Circle().fill(p.color.color).frame(width: 7, height: 7)
                                    Text("\(p.dpi)").font(.caption.weight(i == d.activeProfile ? .bold : .regular))
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(i == d.activeProfile ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(i == d.activeProfile ? Color.accentColor : .clear, lineWidth: 1.2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct PollingQuickPicker: View {
    @Environment(MouseStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Polling rate").font(.subheadline.weight(.semibold))
            Picker("Polling rate", selection: Binding(get: { store.polling ?? .hz1000 },
                                                      set: { store.setPolling($0) })) {
                ForEach(PollingRate.allCases) { Text("\($0.hertz)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Hz — higher is smoother, lower saves battery").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

extension RGB {
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(UInt8((ns.redComponent * 255).rounded()), UInt8((ns.greenComponent * 255).rounded()),
                  UInt8((ns.blueComponent * 255).rounded()))
    }
}
