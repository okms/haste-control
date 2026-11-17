import Foundation

// MARK: - Basic types

public struct RGB: Hashable, Codable, Sendable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xff), UInt8((hex >> 8) & 0xff), UInt8(hex & 0xff))
    }

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(255, 255, 255)
    public static let red = RGB(255, 0, 0)
    public static let green = RGB(0, 255, 0)
    public static let blue = RGB(0, 0, 255)
    public static let yellow = RGB(255, 255, 0)
    public static let magenta = RGB(255, 0, 255)
    public static let cyan = RGB(0, 255, 255)

    public var bytes: [UInt8] { [r, g, b] }
    public var isBlack: Bool { r == 0 && g == 0 && b == 0 }
    public var description: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Multiply every channel by `percent / 100`, rounding to nearest (matches NGenuity).
    public func scaled(percent: Int) -> RGB {
        let f = Double(max(0, min(100, percent))) / 100
        func s(_ v: UInt8) -> UInt8 { UInt8(min(255, (Double(v) * f).rounded())) }
        return RGB(s(r), s(g), s(b))
    }
}

public enum PollingRate: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case hz125 = 0, hz250 = 1, hz500 = 2, hz1000 = 3
    public var id: UInt8 { rawValue }
    public var hertz: Int { [125, 250, 500, 1000][Int(rawValue)] }
    public var label: String { "\(hertz) Hz" }
    public init?(hertz: Int) {
        guard let r = Self.allCases.first(where: { $0.hertz == hertz }) else { return nil }
        self = r
    }
}

public enum LiftOffDistance: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case low = 1, high = 2
    public var id: UInt8 { rawValue }
    public var label: String { self == .low ? "Low (1 mm)" : "High (2 mm)" }
}

public enum ChargeState: UInt8, Codable, Sendable {
    case discharging = 0, charging = 1, full = 2
    public var label: String {
        switch self {
        case .discharging: "On battery"
        case .charging: "Charging"
        case .full: "Fully charged"
        }
    }
    public var isPluggedIn: Bool { self != .discharging }
}

// MARK: - Status

public struct BatteryStatus: Equatable, Sendable {
    public var percent: Int
    public var charge: ChargeState
    /// Low-battery warning threshold stored in the mouse (percent).
    public var warningThreshold: Int
    /// Battery voltage in millivolts (inferred from heartbeat bytes 9–10).
    public var millivolts: Int
    public var raw: [UInt8]
}

public struct FirmwareInfo: Equatable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// e.g. "1.1.0.7"
    public var version: String
    public var name: String
}

public enum LinkState: Equatable, Sendable {
    case wireless(awake: Bool)
    case wired
    public var label: String {
        switch self {
        case .wired: "Wired (USB-C)"
        case .wireless(let awake): awake ? "Wireless" : "Wireless — asleep"
        }
    }
}

/// Unsolicited `FF 03 …` report.
public struct DeviceEvent: Equatable, Sendable {
    public var activeProfile: Int
    public var charge: ChargeState?
    public var awake: Bool
    public var buttons: UInt8
}

// MARK: - DPI

public struct DPIProfile: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var dpi: Int
    public var color: RGB
    public init(enabled: Bool, dpi: Int, color: RGB) {
        self.enabled = enabled; self.dpi = dpi; self.color = color
    }
}

public struct DPISettings: Equatable, Codable, Sendable {
    public static let profileCount = 5
    public static let dpiStep = 100
    public static let minDPI = 200
    public static let defaultMaxDPI = 16_000

    public var activeProfile: Int
    public var profiles: [DPIProfile]
    public var liftOff: LiftOffDistance
    public var maxDPI: Int

    public init(activeProfile: Int, profiles: [DPIProfile], liftOff: LiftOffDistance,
                maxDPI: Int = DPISettings.defaultMaxDPI) {
        self.activeProfile = activeProfile; self.profiles = profiles
        self.liftOff = liftOff; self.maxDPI = maxDPI
    }

    public var enabledMask: UInt8 {
        profiles.enumerated().reduce(0) { $0 | ($1.element.enabled ? UInt8(1 << $1.offset) : 0) }
    }

    public static let factoryDefault = DPISettings(
        activeProfile: 1,
        profiles: [
            .init(enabled: true, dpi: 400, color: .red),
            .init(enabled: true, dpi: 800, color: .blue),
            .init(enabled: true, dpi: 1600, color: .yellow),
            .init(enabled: true, dpi: 3200, color: .green),
            .init(enabled: false, dpi: 6400, color: .white),
        ],
        liftOff: .low)

    /// Clamp to the device's legal range and step.
    public static func clamp(_ dpi: Int, max: Int = defaultMaxDPI) -> Int {
        let stepped = Int((Double(dpi) / Double(dpiStep)).rounded()) * dpiStep
        return Swift.min(max, Swift.max(minDPI, stepped))
    }
}

// MARK: - Buttons

public enum PhysicalButton: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case left = 0, right, middle, back, forward, dpi
    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .left: "Left button"
        case .right: "Right button"
        case .middle: "Middle button (wheel)"
        case .back: "Side button — back"
        case .forward: "Side button — forward"
        case .dpi: "DPI button"
        }
    }
    public var defaultAction: ButtonAction {
        switch self {
        case .left: .mouse(.left)
        case .right: .mouse(.right)
        case .middle: .mouse(.middle)
        case .back: .mouse(.back)
        case .forward: .mouse(.forward)
        case .dpi: .dpiToggle
        }
    }
}

public enum MouseFunction: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case left = 1, right, middle, back, forward
    public var id: UInt8 { rawValue }
    public var label: String { ["Left click", "Right click", "Middle click", "Back", "Forward"][Int(rawValue) - 1] }
}

public enum MediaFunction: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case playPause = 0, stop, previous, next, mute, volumeDown, volumeUp
    public var id: UInt8 { rawValue }
    public var label: String {
        ["Play / Pause", "Stop", "Previous track", "Next track", "Mute", "Volume down", "Volume up"][Int(rawValue)]
    }
}

/// Windows-oriented shortcuts built into the firmware. They send Windows key
/// combos, so several are of limited use on macOS (noted in the label).
public enum ShortcutFunction: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case taskManager = 1, systemUtility, showDesktop, cycleApps, closeWindow, cut, copy, paste
    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .taskManager: "Task Manager (Ctrl+Shift+Esc)"
        case .systemUtility: "System utility (Win+X)"
        case .showDesktop: "Show desktop (Win+D)"
        case .cycleApps: "Cycle apps (Win+Tab)"
        case .closeWindow: "Close window (Alt+F4)"
        case .cut: "Cut (Ctrl+X)"
        case .copy: "Copy (Ctrl+C)"
        case .paste: "Paste (Ctrl+V)"
        }
    }
}

public enum ButtonAction: Hashable, Codable, Sendable {
    case disabled
    case mouse(MouseFunction)
    /// USB HID keyboard usage (page 0x07).
    case keyboard(UInt8)
    case media(MediaFunction)
    case macro
    case shortcut(ShortcutFunction)
    case dpiToggle

    public var typeCode: UInt8 {
        switch self {
        case .disabled: 0
        case .mouse: 1
        case .keyboard: 2
        case .media: 3
        case .macro: 4
        case .shortcut: 5
        case .dpiToggle: 7
        }
    }

    public func code(for button: PhysicalButton) -> UInt8 {
        switch self {
        case .disabled: 0
        case .mouse(let f): f.rawValue
        case .keyboard(let u): u
        case .media(let m): m.rawValue
        case .macro: button.rawValue
        case .shortcut(let s): s.rawValue
        case .dpiToggle: 8
        }
    }

    public init?(type: UInt8, code: UInt8) {
        switch type {
        case 0: self = .disabled
        case 1: guard let f = MouseFunction(rawValue: code) else { return nil }; self = .mouse(f)
        case 2: self = .keyboard(code)
        case 3: guard let m = MediaFunction(rawValue: code) else { return nil }; self = .media(m)
        case 4: self = .macro
        case 5: guard let s = ShortcutFunction(rawValue: code) else { return nil }; self = .shortcut(s)
        case 7: self = .dpiToggle
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .disabled: "Disabled"
        case .mouse(let f): f.label
        case .keyboard(let u): "Key: \(HIDKeyboard.name(for: u))"
        case .media(let m): m.label
        case .macro: "Macro"
        case .shortcut(let s): s.label
        case .dpiToggle: "DPI cycle"
        }
    }
}

// MARK: - Lighting

public enum LightingEffect: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, solid, breathing, cycle, fade
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off: "Off"
        case .solid: "Solid"
        case .breathing: "Breathing"
        case .cycle: "Spectrum cycle"
        case .fade: "Trigger fade (on click)"
        }
    }
    public var usesSpeed: Bool { self == .breathing || self == .cycle || self == .fade }
    public var usesPalette: Bool { self == .cycle }
}

public struct LightingConfig: Equatable, Codable, Sendable {
    public var effect: LightingEffect
    /// Main colour (solid / breathing / fade) — first entry; cycle uses all.
    public var colors: [RGB]
    /// 0–100
    public var brightness: Int
    /// 0–100 (100 = fastest)
    public var speed: Int

    public init(effect: LightingEffect, colors: [RGB], brightness: Int = 100, speed: Int = 50) {
        self.effect = effect; self.colors = colors.isEmpty ? [.red] : colors
        self.brightness = brightness; self.speed = speed
    }

    public var primary: RGB { colors.first ?? .red }

    public static let defaultPalette: [RGB] = [.red, .yellow, .green, .cyan, .blue, .magenta]
    public static let factoryDefault = LightingConfig(effect: .solid, colors: [.red], brightness: 100, speed: 50)
}
