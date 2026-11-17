import HasteKit
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case performance, lighting, buttons, macros, power, device
    var id: String { rawValue }
    var title: String {
        switch self {
        case .performance: "Performance"
        case .lighting: "Lighting"
        case .buttons: "Buttons"
        case .macros: "Macros"
        case .power: "Battery & Power"
        case .device: "Device"
        }
    }
    var symbol: String {
        switch self {
        case .performance: "gauge.with.dots.needle.67percent"
        case .lighting: "lightbulb.led"
        case .buttons: "computermouse"
        case .macros: "keyboard"
        case .power: "battery.75percent"
        case .device: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(MouseStore.self) private var store
    @ViewState private var page: SettingsPage

    init(page: SettingsPage = .performance) {
        _page = ViewState(initialValue: page)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            VStack(spacing: 0) {
                if store.connection != .ready {
                    ConnectionBanner()
                }
                ScrollView {
                    Group {
                        switch page {
                        case .performance: PerformancePage()
                        case .lighting: LightingPage()
                        case .buttons: ButtonsPage()
                        case .macros: MacrosPage()
                        case .power: PowerPage()
                        case .device: DevicePage()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(store.connection != .ready && page != .power && page != .device && page != .macros)
                }
                StatusBar()
            }
            .navigationTitle(page.title)
        }
    }
}

struct ConnectionBanner: View {
    @Environment(MouseStore.self) private var store
    var body: some View {
        HStack {
            Image(systemName: store.connection == .asleep ? "moon.zzz.fill" : "cable.connector.slash")
            Text(store.statusText)
            Spacer()
            Button("Retry") { Task { await store.refreshAll() } }
        }
        .padding(10)
        .background(.yellow.opacity(0.18))
    }
}

struct StatusBar: View {
    @Environment(MouseStore.self) private var store
    var body: some View {
        HStack(spacing: 8) {
            if store.isBusy { ProgressView().controlSize(.small); Text("Writing to mouse…") }
            else if let err = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(err).lineLimit(2)
            } else if let t = store.lastSaved {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved to the mouse's onboard memory \(t, style: .relative) ago")
            } else {
                Text("Changes are written to the mouse immediately and stored onboard.")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }
}

struct Section<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .padding(.bottom, 22)
    }
}

// MARK: - Performance

struct PerformancePage: View {
    @Environment(MouseStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading) {
            Section(title: "DPI profiles",
                    subtitle: "Up to five sensitivity levels. The DPI button on the mouse cycles through enabled profiles; the indicator colour flashes when you switch.") {
                if let d = store.dpi {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Active").gridColumnAlignment(.center)
                            Text("On")
                            Text("DPI")
                            Text("")
                            Text("Colour")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(0..<DPISettings.profileCount, id: \.self) { i in
                            DPIRow(index: i, settings: d)
                        }
                    }
                } else { ProgressView() }
            }
            Section(title: "Polling rate", subtitle: "How often the mouse reports its position. 1000 Hz is smoothest; lower rates extend battery life.") {
                Picker("Polling rate", selection: Binding(get: { store.polling ?? .hz1000 }, set: { store.setPolling($0) })) {
                    ForEach(PollingRate.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            }
            Section(title: "Lift-off distance", subtitle: "Height at which the sensor stops tracking when you lift the mouse.") {
                if store.dpi != nil {
                    Picker("Lift-off distance", selection: Binding(
                        get: { store.dpi?.liftOff ?? .low },
                        set: { store.dpi?.liftOff = $0; store.scheduleDPIApply(immediate: true) })) {
                        ForEach(LiftOffDistance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                }
            }
        }
    }
}

struct DPIRow: View {
    @Environment(MouseStore.self) private var store
    let index: Int
    let settings: DPISettings

    var body: some View {
        let p = settings.profiles[index]
        GridRow {
            Button { store.selectProfile(index) } label: {
                Image(systemName: index == settings.activeProfile ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(index == settings.activeProfile ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .gridColumnAlignment(.center)
            .help("Make this the active profile")

            Toggle("", isOn: Binding(get: { p.enabled }, set: { on in
                guard var d = store.dpi else { return }
                if !on && d.profiles.filter(\.enabled).count == 1 { return } // keep at least one
                d.profiles[index].enabled = on
                store.dpi = d
                store.scheduleDPIApply(immediate: true)
            }))
            .labelsHidden()

            Slider(value: Binding(get: { Double(p.dpi) }, set: { v in
                store.dpi?.profiles[index].dpi = DPISettings.clamp(Int(v), max: settings.maxDPI)
                store.scheduleDPIApply()
            }), in: Double(DPISettings.minDPI)...Double(settings.maxDPI), step: Double(DPISettings.dpiStep))
            .frame(minWidth: 220)
            .disabled(!p.enabled)

            TextField("DPI", value: Binding(get: { p.dpi }, set: { v in
                store.dpi?.profiles[index].dpi = DPISettings.clamp(v, max: settings.maxDPI)
                store.scheduleDPIApply(immediate: true)
            }), format: .number.grouping(.never))
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .disabled(!p.enabled)

            ColorPicker("", selection: Binding(get: { p.color.color }, set: { c in
                store.dpi?.profiles[index].color = RGB(c)
                store.scheduleDPIApply()
            }), supportsOpacity: false)
            .labelsHidden()
        }
    }
}

// MARK: - Lighting

struct LightingPage: View {
    @Environment(MouseStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading) {
            Section(title: "Effect", subtitle: "Effects run on the mouse itself and are kept in its onboard memory — no app needs to be running.") {
                Picker("Effect", selection: Binding(get: { store.lighting.effect }, set: { e in
                    store.lighting.effect = e
                    if e == .cycle && store.lighting.colors.count < 2 { store.lighting.colors = LightingConfig.defaultPalette }
                    if e != .cycle && store.lighting.colors.count > 1 { store.lighting.colors = [store.lighting.primary] }
                    store.scheduleLightingApply(immediate: true)
                })) {
                    ForEach(LightingEffect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            if store.lighting.effect != .off {
                Section(title: store.lighting.effect == .cycle ? "Colours" : "Colour") {
                    if store.lighting.effect == .cycle {
                        PaletteEditor()
                    } else {
                        HStack {
                            ColorPicker("Colour", selection: Binding(get: { store.lighting.primary.color }, set: {
                                store.lighting.colors = [RGB($0)]
                                store.scheduleLightingApply()
                            }), supportsOpacity: false)
                            ForEach([RGB.red, .green, .blue, .yellow, .cyan, .magenta, .white], id: \.self) { c in
                                Button { store.lighting.colors = [c]; store.scheduleLightingApply(immediate: true) } label: {
                                    Circle().fill(c.color).frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(.secondary.opacity(0.4)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section(title: "Brightness") {
                    LabeledSlider(value: Binding(get: { store.lighting.brightness }, set: {
                        store.lighting.brightness = $0; store.scheduleLightingApply()
                    }), suffix: "%")
                }
                if store.lighting.effect.usesSpeed {
                    Section(title: "Speed") {
                        LabeledSlider(value: Binding(get: { store.lighting.speed }, set: {
                            store.lighting.speed = $0; store.scheduleLightingApply()
                        }), suffix: "%")
                    }
                }
                Section(title: "Preview") {
                    LightingPreview(config: store.lighting)
                }
            }
        }
    }
}

struct LabeledSlider: View {
    @Binding var value: Int
    var suffix = ""
    var body: some View {
        HStack {
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0) }), in: 0...100, step: 1)
                .frame(maxWidth: 360)
            Text("\(value)\(suffix)").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}

struct PaletteEditor: View {
    @Environment(MouseStore.self) private var store
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(store.lighting.colors.enumerated()), id: \.offset) { i, c in
                VStack(spacing: 2) {
                    ColorPicker("", selection: Binding(get: { c.color }, set: {
                        store.lighting.colors[i] = RGB($0); store.scheduleLightingApply()
                    }), supportsOpacity: false).labelsHidden()
                    if store.lighting.colors.count > 2 {
                        Button { store.lighting.colors.remove(at: i); store.scheduleLightingApply(immediate: true) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            if store.lighting.colors.count < 8 {
                Button { store.lighting.colors.append(.white); store.scheduleLightingApply(immediate: true) } label: {
                    Image(systemName: "plus.circle")
                }.buttonStyle(.borderless)
            }
            Button("Rainbow") { store.lighting.colors = LightingConfig.defaultPalette; store.scheduleLightingApply(immediate: true) }
        }
    }
}

/// Plays the exact frame table that will be sent to the mouse.
struct LightingPreview: View {
    let config: LightingConfig
    var body: some View {
        let frames = LightingEncoder.frames(for: config)
        TimelineView(.animation) { ctx in
            // The firmware's frame period is not known exactly; ~25 ms/frame looks close.
            let idx = frames.count <= 1 ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate / 0.025) % frames.count
            let c = config.effect == .fade ? config.primary.scaled(percent: config.brightness) : frames[idx]
            HStack(spacing: 14) {
                Capsule().fill(c.color).frame(width: 18, height: 34)
                    .overlay(Capsule().stroke(.secondary.opacity(0.4)))
                    .shadow(color: c.color.opacity(0.8), radius: 8)
                Text(config.effect == .fade ? "Lights up on each click, then fades out." :
                        "\(frames.count) frame\(frames.count == 1 ? "" : "s") stored on the mouse")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Buttons

struct ButtonsPage: View {
    @Environment(MouseStore.self) private var store

    var body: some View {
        VStack(alignment: .leading) {
            Section(title: "Button assignments",
                    subtitle: "Remap any of the six buttons. Keyboard keys and macros are sent by the mouse as a USB keyboard, so they work everywhere without this app running.") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    ForEach(PhysicalButton.allCases) { b in
                        GridRow {
                            Text(b.label)
                            ActionPicker(button: b)
                        }
                    }
                }
            }
            Button("Restore default buttons") { store.resetButtons() }
            Text("Windows shortcuts (Task Manager, Win+X …) send Windows key combinations; on macOS prefer a keyboard key or macro.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}

struct ActionPicker: View {
    @Environment(MouseStore.self) private var store
    let button: PhysicalButton

    var body: some View {
        let current = store.buttons[button] ?? button.defaultAction
        HStack {
            Menu(current.label) {
                Menu("Mouse") {
                    ForEach(MouseFunction.allCases) { f in Button(f.label) { store.setButton(button, .mouse(f)) } }
                }
                Menu("Media") {
                    ForEach(MediaFunction.allCases) { f in Button(f.label) { store.setButton(button, .media(f)) } }
                }
                Menu("Keyboard key") {
                    ForEach(HIDKeyboard.allKeys, id: \.usage) { k in
                        Button(k.name) { store.setButton(button, .keyboard(k.usage)) }
                    }
                }
                Button("DPI cycle") { store.setButton(button, .dpiToggle) }
                Button(store.macros[button] != nil ? "Macro: \(store.macros[button]!.name)" : "Macro (create on Macros page)") {
                    store.setButton(button, .macro)
                }
                .disabled(store.macros[button] == nil)
                Menu("Windows shortcut") {
                    ForEach(ShortcutFunction.allCases) { f in Button(f.label) { store.setButton(button, .shortcut(f)) } }
                }
                Divider()
                Button("Disabled") { store.setButton(button, .disabled) }
                Button("Default (\(button.defaultAction.label))") { store.setButton(button, button.defaultAction) }
            }
            .frame(width: 260)
            KeyCaptureButton { usage in store.setButton(button, .keyboard(usage)) }
        }
    }
}

/// Click, then press a key: reports the HID usage of that key.
struct KeyCaptureButton: View {
    var onKey: (UInt8) -> Void
    @ViewState private var capturing = false
    @ViewState private var monitor: Any?

    var body: some View {
        Button(capturing ? "Press a key…" : "Record key") {
            capturing ? stop() : start()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            if let u = HIDKeyboard.fromMacKeyCode[e.keyCode] {
                onKey(u)
                stop()
                return nil
            }
            return e
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        capturing = false
    }
}

// MARK: - Battery & power

struct PowerPage: View {
    @Environment(MouseStore.self) private var store
    @ViewState private var deviceWarn: Double = 10
    @ViewState private var loginItem = SMAppService.mainApp.status == .enabled
    @ViewState private var loginError: String?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading) {
            Section(title: "Battery") {
                BatteryCard(compact: false).frame(maxWidth: 360)
            }
            Section(title: "Mouse charge warning",
                    subtitle: "The mouse's LED blinks to warn you when the battery falls below this level (stored on the mouse).") {
                HStack {
                    Slider(value: $deviceWarn, in: 5...25, step: 1) { editing in
                        if !editing { store.setDeviceLowBatteryWarning(Int(deviceWarn)) }
                    }
                    .frame(maxWidth: 300)
                    Text("\(Int(deviceWarn))%").monospacedDigit().frame(width: 40)
                }
                .disabled(store.connection != .ready)
            }
            Section(title: "macOS notifications") {
                Toggle("Notify when the battery is low", isOn: $store.notifyLowBattery)
                HStack {
                    Text("Threshold")
                    Stepper("\(store.notifyThreshold)%", value: $store.notifyThreshold, in: 5...50, step: 5)
                }
                .disabled(!store.notifyLowBattery)
                Toggle("Notify when fully charged", isOn: $store.notifyFullyCharged)
            }
            Section(title: "Menu bar") {
                Toggle("Show battery percentage next to the icon", isOn: $store.showPercentInMenuBar)
                Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginItem = SMAppService.mainApp.status == .enabled
                        loginError = nil
                    } catch { loginError = error.localizedDescription }
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
        }
        .onAppear { deviceWarn = Double(store.battery?.warningThreshold ?? 10) }
        .onChange(of: store.battery?.warningThreshold) { _, v in if let v { deviceWarn = Double(v) } }
    }
}

// MARK: - Device

struct DevicePage: View {
    @Environment(MouseStore.self) private var store
    @ViewState private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading) {
            Section(title: "Connection") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Status", store.statusText)
                    row("Mouse firmware", store.mouseFirmware?.version ?? "—")
                    row("Receiver firmware", store.isWired ? "— (cable)" : store.receiver?.version ?? "—")
                    row("USB ID", store.isWired ? "03F0:048E (wired)" : "03F0:028E (wireless dongle)")
                    row("Polling rate", store.polling?.label ?? "—")
                    if let b = store.battery { row("Battery voltage", String(format: "%.3f V", Double(b.millivolts) / 1000)) }
                }
            }
            Section(title: "Onboard memory",
                    subtitle: "Every change is saved automatically. Use this if you edited settings with another tool.") {
                HStack {
                    Button("Save all settings to mouse") { store.saveToDevice() }
                    Button("Re-read from mouse") { Task { await store.refreshAll() } }
                }
            }
            Section(title: "Restore defaults",
                    subtitle: "Puts DPI (400/800/1600/3200), 1000 Hz polling, default buttons, red lighting and a 10 % charge warning back on the mouse.") {
                Button("Restore defaults…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Restore default settings on the mouse?", isPresented: $confirmReset) {
                        Button("Restore defaults", role: .destructive) { store.restoreAppDefaults() }
                    } message: {
                        Text("Your DPI profiles, button assignments and lighting will be overwritten. Macros saved in this app are kept.")
                    }
            }
        }
        .disabled(store.connection != .ready)
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}
