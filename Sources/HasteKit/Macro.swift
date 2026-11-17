import Foundation

public enum MacroRepeatMode: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case once = 0, toggle = 2, whileHeld = 3
    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .once: "Play once"
        case .toggle: "Repeat until pressed again"
        case .whileHeld: "Repeat while held"
        }
    }
}

/// Mouse buttons usable inside macros (bitmask values in the firmware).
public enum MacroMouseButton: UInt8, CaseIterable, Codable, Sendable, Identifiable {
    case left = 0x01, right = 0x02, middle = 0x04, back = 0x08, forward = 0x10
    public var id: UInt8 { rawValue }
    public var label: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .middle: "Middle"
        case .back: "Back"
        case .forward: "Forward"
        }
    }
}

/// One step in the user-facing macro editor.
public enum MacroStep: Hashable, Codable, Sendable {
    case keyDown(UInt8)          // HID keyboard usage (modifiers 0xE0–0xE7 allowed)
    case keyUp(UInt8)
    case mouseDown(MacroMouseButton)
    case mouseUp(MacroMouseButton)
    case scroll(Int8)            // +1 up / −1 down
    case delay(Int)              // milliseconds

    public var label: String {
        switch self {
        case .keyDown(let u): "↓ \(HIDKeyboard.name(for: u))"
        case .keyUp(let u): "↑ \(HIDKeyboard.name(for: u))"
        case .mouseDown(let b): "↓ Mouse \(b.label)"
        case .mouseUp(let b): "↑ Mouse \(b.label)"
        case .scroll(let d): d > 0 ? "Scroll up" : "Scroll down"
        case .delay(let ms): "Wait \(ms) ms"
        }
    }
}

public struct Macro: Equatable, Codable, Sendable {
    public var name: String
    public var steps: [MacroStep]
    public var repeatMode: MacroRepeatMode
    /// Delay inserted between consecutive events when no explicit delay step is present.
    public var defaultDelay: Int

    public init(name: String = "Macro", steps: [MacroStep] = [], repeatMode: MacroRepeatMode = .once,
                defaultDelay: Int = 20) {
        self.name = name; self.steps = steps; self.repeatMode = repeatMode; self.defaultDelay = defaultDelay
    }
}

/// Firmware-level macro event.
public enum MacroEvent: Equatable, Sendable {
    case keyboard(modifiers: UInt8, keys: [UInt8], delay: Int)
    case mouse(buttons: UInt8, wheel: Int8, delay: Int)

    public var bytes: [UInt8] {
        switch self {
        case let .keyboard(mods, keys, delay):
            let k = Array(keys.prefix(6)) + [UInt8](repeating: 0, count: max(0, 6 - keys.count))
            let d = UInt16(clamping: max(0, delay))
            return [0x1A, mods] + k + [UInt8(d & 0xff), UInt8(d >> 8)]
        case let .mouse(buttons, wheel, delay):
            let d = UInt16(clamping: max(0, delay))
            return [0x25, buttons, UInt8(bitPattern: wheel), UInt8(d & 0xff), UInt8(d >> 8)]
        }
    }

    var withDelay: (Int) -> MacroEvent {
        { d in
            switch self {
            case let .keyboard(m, k, _): .keyboard(modifiers: m, keys: k, delay: d)
            case let .mouse(b, w, _): .mouse(buttons: b, wheel: w, delay: d)
            }
        }
    }
}

public enum MacroEncoder {
    public static let eventsPerPacket = 6
    public static let maxEvents = 108

    public enum EncodeError: Error, LocalizedError {
        case tooManyEvents(Int)
        case empty
        public var errorDescription: String? {
            switch self {
            case .tooManyEvents(let n): "Macro has \(n) events; the mouse supports at most \(MacroEncoder.maxEvents)."
            case .empty: "Macro is empty."
            }
        }
    }

    /// Compile editor steps into firmware events (keyboard state snapshots).
    ///
    /// Each event's delay is the sum of the explicit `.delay` steps that follow
    /// it, or `defaultDelay` when there are none.
    public static func compile(_ macro: Macro) -> [MacroEvent] {
        var events: [MacroEvent] = []
        var explicit: [Int?] = []
        var keys: [UInt8] = []
        var mods: UInt8 = 0
        var mouse: UInt8 = 0

        func emit(_ e: MacroEvent) { events.append(e); explicit.append(nil) }

        for step in macro.steps {
            switch step {
            case .delay(let ms):
                guard !explicit.isEmpty else { continue }
                explicit[explicit.count - 1] = (explicit.last! ?? 0) + max(0, ms)
            case .keyDown(let u):
                if let bit = HIDKeyboard.modifierBit(u) { mods |= bit }
                else if !keys.contains(u) && keys.count < 6 { keys.append(u) }
                emit(.keyboard(modifiers: mods, keys: keys, delay: 0))
            case .keyUp(let u):
                if let bit = HIDKeyboard.modifierBit(u) { mods &= ~bit } else { keys.removeAll { $0 == u } }
                emit(.keyboard(modifiers: mods, keys: keys, delay: 0))
            case .mouseDown(let b):
                mouse |= b.rawValue
                emit(.mouse(buttons: mouse, wheel: 0, delay: 0))
            case .mouseUp(let b):
                mouse &= ~b.rawValue
                emit(.mouse(buttons: mouse, wheel: 0, delay: 0))
            case .scroll(let d):
                // NGenuity sends a wheel tick followed by a neutral event.
                emit(.mouse(buttons: mouse, wheel: d, delay: 0))
                emit(.mouse(buttons: mouse, wheel: 0, delay: 0))
            }
        }
        return zip(events, explicit).map { $0.withDelay($1 ?? macro.defaultDelay) }
    }

    /// Packet sequence: bind button to macro, upload data, set binding.
    public static func packets(for macro: Macro, on button: PhysicalButton, save: Bool = true) throws -> [[UInt8]] {
        let events = compile(macro)
        guard !events.isEmpty else { throw EncodeError.empty }
        guard events.count <= maxEvents else { throw EncodeError.tooManyEvents(events.count) }
        typealias P = HasteProtocol
        let b = button.rawValue
        var out: [[UInt8]] = [P.setButton(button, .macro)]
        var n = 0
        for chunkStart in stride(from: 0, to: events.count, by: eventsPerPacket) {
            let chunk = events[chunkStart..<min(events.count, chunkStart + eventsPerPacket)]
            let seq = UInt8((3 * n) / 2)
            let count = UInt8(chunk.count) | (n % 2 == 1 ? 0x80 : 0)
            out.append(P.packet([P.Op.macroData, b, seq, count] + chunk.flatMap(\.bytes)))
            n += 1
        }
        out.append(P.packet([P.Op.setMacroBinding, b, 0, 5, UInt8(events.count), 0, macro.repeatMode.rawValue, 0, 0]))
        if save { out.append(P.saveAll()) }
        return out
    }
}
