import Foundation
import HasteKit
import Observation
import UserNotifications

/// App-wide state: talks to the mouse, caches what it read, persists app-side
/// data (macros, lighting choice, notification prefs) in UserDefaults.
@MainActor
@Observable
final class MouseStore {
    enum Connection: Equatable {
        case disconnected
        case asleep
        case connecting
        case ready
    }

    // MARK: Device state
    private(set) var connection: Connection = .disconnected
    private(set) var isWired = false
    private(set) var receiver: FirmwareInfo?
    private(set) var mouseFirmware: FirmwareInfo?
    private(set) var battery: BatteryStatus?
    private(set) var batteryUpdated: Date?
    var dpi: DPISettings?
    private(set) var polling: PollingRate?
    private(set) var buttons: [PhysicalButton: ButtonAction] = [:]
    var lighting: LightingConfig
    private(set) var lightingFromDevice = false

    // MARK: UI state
    private(set) var busy = 0
    var lastError: String?
    private(set) var lastSaved: Date?

    // MARK: App preferences (UserDefaults-backed)
    var showPercentInMenuBar: Bool { didSet { defaults.set(showPercentInMenuBar, forKey: Keys.showPercent) } }
    var notifyLowBattery: Bool { didSet { defaults.set(notifyLowBattery, forKey: Keys.notifyLow); if notifyLowBattery { requestNotificationPermission() } } }
    var notifyThreshold: Int { didSet { defaults.set(notifyThreshold, forKey: Keys.notifyThreshold) } }
    var notifyFullyCharged: Bool { didSet { defaults.set(notifyFullyCharged, forKey: Keys.notifyFull) } }
    var macros: [PhysicalButton: Macro] { didSet { persistMacros() } }

    let mouse: HasteMouse
    private let defaults = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private var dpiApplyTask: Task<Void, Never>?
    private var lightingApplyTask: Task<Void, Never>?
    private var lowBatteryNotified = false
    private var lastCharge: ChargeState?

    private enum Keys {
        static let showPercent = "showPercentInMenuBar"
        static let notifyLow = "notifyLowBattery"
        static let notifyThreshold = "notifyThreshold"
        static let notifyFull = "notifyFullyCharged"
        static let macros = "macros.v1"
        static let lighting = "lighting.v1"
        static let cachedBattery = "cachedBatteryPercent"
    }

    init() {
        mouse = HasteMouse()
        defaults.register(defaults: [Keys.showPercent: true, Keys.notifyLow: true, Keys.notifyThreshold: 15,
                                     Keys.notifyFull: false])
        showPercentInMenuBar = defaults.bool(forKey: Keys.showPercent)
        notifyLowBattery = defaults.bool(forKey: Keys.notifyLow)
        notifyThreshold = defaults.integer(forKey: Keys.notifyThreshold)
        notifyFullyCharged = defaults.bool(forKey: Keys.notifyFull)
        macros = Self.loadMacros(defaults.data(forKey: Keys.macros))
        lighting = (defaults.data(forKey: Keys.lighting)).flatMap { try? JSONDecoder().decode(LightingConfig.self, from: $0) }
            ?? .factoryDefault

        mouse.transport.onAttach = { [weak self] ep in
            guard let self else { return }
            self.isWired = ep.isWired
            self.connection = .connecting
            Task { await self.refreshAll() }
        }
        mouse.transport.onDetach = { [weak self] in
            self?.connection = .disconnected
        }
        mouse.transport.onUnsolicited = { [weak self] bytes in
            guard let self, let e = HasteProtocol.parseEvent(bytes) else { return }
            self.handle(e)
        }
        if notifyLowBattery { requestNotificationPermission() }
        startPolling()
    }

    var isReady: Bool { connection == .ready }
    var isBusy: Bool { busy > 0 }

    var statusText: String {
        switch connection {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .asleep: "Asleep — move the mouse to wake it"
        case .ready: isWired ? "Connected by cable" : "Connected wirelessly"
        }
    }

    // MARK: - Refresh

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.periodicCheck()
            }
        }
    }

    /// Every 15 s: ask the dongle whether the mouse is awake (cheap, answered
    /// locally); re-read the battery at most once a minute.
    private func periodicCheck() async {
        guard mouse.isAttached else { return }
        do {
            let link = try await mouse.link()
            if link == .wireless(awake: false) {
                connection = .asleep
                return
            }
            if connection != .ready {
                await refreshAll()
            } else if (batteryUpdated.map { Date().timeIntervalSince($0) > 55 } ?? true) {
                try await readBattery()
            }
        } catch {
            // transient — keep last known values
        }
    }

    private var refreshInFlight: Task<Void, Never>?

    /// Re-read everything. Concurrent callers share one in-flight refresh.
    func refreshAll() async {
        if let running = refreshInFlight { return await running.value }
        let t = Task { await self.performRefresh() }
        refreshInFlight = t
        await t.value
        refreshInFlight = nil
    }

    private func performRefresh() async {
        guard mouse.isAttached else { connection = .disconnected; return }
        busy += 1
        defer { busy -= 1 }
        do {
            receiver = try await mouse.receiverInfo()
            let link = try await mouse.link()
            if link == .wireless(awake: false) {
                connection = .asleep  // keep showing cached values
                return
            }
            mouseFirmware = try await mouse.mouseInfo()
            try await readBattery()
            dpi = try await mouse.dpi()
            let dump = try await mouse.settingsDump()
            polling = dump.pollingRate
            buttons = try await mouse.buttons()
            let frames = try await mouse.lightingFrames()
            if !frames.isEmpty {
                // Prefer our saved config if it produces exactly what is on the mouse.
                if LightingEncoder.frames(for: lighting) == frames {
                    lightingFromDevice = true
                } else {
                    lighting = LightingEncoder.classify(frames: frames)
                    lightingFromDevice = true
                }
            }
            connection = .ready
            lastError = nil
        } catch HasteError.timeout {
            connection = .asleep
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func readBattery() async throws {
        let b = try await mouse.battery()
        battery = b
        batteryUpdated = Date()
        defaults.set(b.percent, forKey: Keys.cachedBattery)
        evaluateNotifications(b)
    }

    func refreshBatteryNow() {
        Task { try? await readBattery() }
    }

    private func handle(_ e: DeviceEvent) {
        if !e.awake {
            if !isWired { connection = .asleep }
            return
        }
        if connection != .ready {
            Task { await refreshAll() }
            return
        }
        if var d = dpi, d.activeProfile != e.activeProfile {
            d.activeProfile = e.activeProfile
            dpi = d
        }
        if let c = e.charge, c != battery?.charge {
            Task { try? await readBattery() }
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluateNotifications(_ b: BatteryStatus) {
        defer { lastCharge = b.charge }
        if b.charge.isPluggedIn || b.percent > notifyThreshold + 2 { lowBatteryNotified = false }
        if notifyLowBattery, !lowBatteryNotified, b.charge == .discharging, b.percent <= notifyThreshold {
            lowBatteryNotified = true
            notify("HyperX mouse battery low", "\(b.percent)% remaining — plug in the USB-C cable.")
        }
        if notifyFullyCharged, b.charge == .full, let last = lastCharge, last != .full {
            notify("HyperX mouse charged", "Battery is full.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - Actions

    private func perform(_ op: @escaping () async throws -> Void) {
        Task {
            if connection == .asleep {
                // A user action usually means the mouse is being touched — re-check first.
                if let l = try? await mouse.link(), l != .wireless(awake: false) { await refreshAll() }
            }
            guard connection == .ready else {
                lastError = connection == .asleep ? "The mouse is asleep. Move it to wake it, then try again."
                                                  : "The mouse is not connected."
                return
            }
            busy += 1
            defer { busy -= 1 }
            do {
                try await op()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func setPolling(_ rate: PollingRate) {
        let old = polling
        polling = rate
        perform { [self] in
            do {
                try await mouse.setPollingRate(rate)
                try await mouse.saveToDevice()
                lastSaved = Date()
            } catch { polling = old; throw error }
        }
    }

    func selectProfile(_ index: Int) {
        guard var d = dpi, d.profiles.indices.contains(index) else { return }
        d.activeProfile = index
        if !d.profiles[index].enabled {
            d.profiles[index].enabled = true
            dpi = d
            scheduleDPIApply(immediate: true)
            return
        }
        dpi = d
        perform { [self] in try await mouse.selectDPIProfile(index) }
    }

    /// Call after mutating `dpi`; batches rapid edits (sliders) into one write.
    func scheduleDPIApply(immediate: Bool = false) {
        guard var d = dpi else { return }
        if !d.profiles[d.activeProfile].enabled,
           let first = d.profiles.firstIndex(where: \.enabled) {
            d.activeProfile = first
            dpi = d
        }
        dpiApplyTask?.cancel()
        dpiApplyTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled, let self, let settings = self.dpi else { return }
            self.perform { [self] in
                try await self.mouse.applyDPI(settings)
                self.lastSaved = Date()
            }
        }
    }

    func setButton(_ button: PhysicalButton, _ action: ButtonAction) {
        if action == .macro {
            guard let m = macros[button], !m.steps.isEmpty else {
                lastError = "Create a macro for this button on the Macros page first."
                return
            }
            uploadMacro(m, to: button)
            return
        }
        let old = buttons[button]
        buttons[button] = action
        perform { [self] in
            do {
                try await mouse.setButton(button, action)
                try await mouse.saveToDevice()
                lastSaved = Date()
            } catch { buttons[button] = old; throw error }
        }
    }

    func uploadMacro(_ macro: Macro, to button: PhysicalButton) {
        macros[button] = macro
        perform { [self] in
            try await mouse.uploadMacro(macro, to: button)
            try await mouse.saveToDevice()
            buttons[button] = .macro
            lastSaved = Date()
        }
    }

    func resetButtons() {
        perform { [self] in
            for b in PhysicalButton.allCases { try await mouse.setButton(b, b.defaultAction) }
            try await mouse.saveToDevice()
            buttons = Dictionary(uniqueKeysWithValues: PhysicalButton.allCases.map { ($0, $0.defaultAction) })
            lastSaved = Date()
        }
    }

    /// Call after mutating `lighting`.
    func scheduleLightingApply(immediate: Bool = false) {
        if let data = try? JSONEncoder().encode(lighting) { defaults.set(data, forKey: Keys.lighting) }
        lightingApplyTask?.cancel()
        lightingApplyTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard !Task.isCancelled, let self else { return }
            let cfg = self.lighting
            self.perform { [self] in
                try await self.mouse.applyLighting(cfg)
                try await self.mouse.saveToDevice()
                self.lastSaved = Date()
            }
        }
    }

    /// Write a full configuration. `saveToFlash: false` keeps it in RAM only
    /// (used for automatic per-app switching to avoid flash wear).
    func applyProfile(dpi newDPI: DPISettings, polling newPolling: PollingRate, lighting newLighting: LightingConfig,
                      buttons newButtons: [PhysicalButton: ButtonAction], saveToFlash: Bool) {
        dpi = newDPI
        polling = newPolling
        lighting = newLighting
        perform { [self] in
            try await self.mouse.transport.send(HasteProtocol.applyDPI(newDPI, save: saveToFlash))
            try await self.mouse.setPollingRate(newPolling)
            try await self.mouse.transport.send(LightingEncoder.packets(for: newLighting, save: false))
            for (b, a) in newButtons where a != .macro && self.buttons[b] != a {
                try await self.mouse.setButton(b, a)
            }
            for (b, a) in newButtons where a == .macro && self.buttons[b] != .macro {
                if let m = self.macros[b] { try await self.mouse.uploadMacro(m, to: b) }
            }
            self.buttons.merge(newButtons) { _, new in new }
            if saveToFlash {
                try await self.mouse.saveToDevice()
                self.lastSaved = Date()
            }
        }
    }

    func setDeviceLowBatteryWarning(_ pct: Int) {
        perform { [self] in
            try await mouse.setLowBatteryWarning(pct)
            try await mouse.saveToDevice()
            try await readBattery()
            lastSaved = Date()
        }
    }

    func saveToDevice() {
        perform { [self] in
            try await mouse.saveToDevice()
            lastSaved = Date()
        }
    }

    func restoreAppDefaults() {
        dpi = DPISettings.factoryDefault
        lighting = .factoryDefault
        perform { [self] in
            try await mouse.applyDPI(.factoryDefault)
            try await mouse.setPollingRate(.hz1000)
            for b in PhysicalButton.allCases { try await mouse.setButton(b, b.defaultAction) }
            try await mouse.applyLighting(.factoryDefault)
            try await mouse.setLowBatteryWarning(10)
            try await mouse.saveToDevice()
            lastSaved = Date()
        }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await refreshAll() }
    }

    // MARK: - Persistence

    private func persistMacros() {
        let dict = Dictionary(uniqueKeysWithValues: macros.map { (String($0.key.rawValue), $0.value) })
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: Keys.macros) }
    }

    private static func loadMacros(_ data: Data?) -> [PhysicalButton: Macro] {
        guard let data, let dict = try? JSONDecoder().decode([String: Macro].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in
            UInt8(k).flatMap(PhysicalButton.init(rawValue:)).map { ($0, v) }
        })
    }

    var cachedBatteryPercent: Int? {
        battery?.percent ?? (defaults.object(forKey: Keys.cachedBattery) as? Int)
    }
}
