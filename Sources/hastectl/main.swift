import Foundation
import HasteKit

// hastectl — command-line control for the HyperX Pulsefire Haste Wireless (PF002).

let usage = """
usage: hastectl <command> [args]

  status                     battery, link, DPI and polling summary (default)
  battery [--json]           battery percentage / charge state
  info                       firmware versions
  dpi                        list DPI profiles
  dpi select <1-5>           activate a profile
  dpi set <1-5> <dpi>        change a profile's DPI (saved to the mouse)
  polling <125|250|500|1000> set polling rate
  warn <percent>             set the mouse's low-battery warning threshold
  light off|solid|breathing|cycle|fade [RRGGBB] [brightness] [speed]
  buttons                    list button assignments
  save                       write all settings to onboard memory
  watch                      print unsolicited events (Ctrl-C to stop)
  raw <hex bytes…>           send a raw packet, print the reply
  --trace                    (any position) print every packet
"""

@MainActor
func run() async -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    let trace = args.contains("--trace")
    args.removeAll { $0 == "--trace" }
    if args.first == "-h" || args.first == "--help" { print(usage); return 0 }

    let mouse = HasteMouse()
    if trace { mouse.transport.trace = { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) } }

    for _ in 0..<40 where !mouse.isAttached { try? await Task.sleep(nanoseconds: 50_000_000) }
    guard mouse.isAttached else {
        FileHandle.standardError.write("hastectl: no HyperX Pulsefire Haste Wireless found (03F0:028E / 03F0:048E)\n".data(using: .utf8)!)
        return 2
    }

    func fail(_ msg: String) -> Int32 {
        FileHandle.standardError.write("hastectl: \(msg)\n".data(using: .utf8)!); return 1
    }

    do {
        let cmd = args.first ?? "status"
        let rest = Array(args.dropFirst())
        if !["raw", "watch", "info"].contains(cmd), try await mouse.link() == .wireless(awake: false) {
            return fail("the mouse is asleep (dongle connected) — move or click it to wake it, then retry")
        }
        switch cmd {
        case "status":
            let link = try await mouse.link()
            let b = try await mouse.battery()
            let d = try await mouse.dpi()
            let dump = try await mouse.settingsDump()
            print("Link:     \(link.label)")
            print("Battery:  \(b.percent)% — \(b.charge.label) (\(b.millivolts) mV, warns at \(b.warningThreshold)%)")
            print("DPI:      \(d.profiles[d.activeProfile].dpi) (profile \(d.activeProfile + 1))")
            print("Polling:  \(dump.pollingRate.label)")
            print("Lift-off: \(d.liftOff.label)")
        case "battery":
            let b = try await mouse.battery()
            if rest.first == "--json" {
                print(#"{"percent":\#(b.percent),"charging":\#(b.charge == .charging),"state":"\#(b.charge)","millivolts":\#(b.millivolts)}"#)
            } else {
                print("\(b.percent)% \(b.charge.label)")
            }
        case "info":
            let r = try await mouse.receiverInfo()
            print("Receiver: \(r.name) \(String(format: "%04X:%04X", r.vendorID, r.productID)) fw \(r.version)")
            if try await mouse.link() != .wireless(awake: false), let m = try await mouse.mouseInfo() {
                print("Mouse:    \(m.name) \(String(format: "%04X:%04X", m.vendorID, m.productID)) fw \(m.version)")
            }
            print("Link:     \(try await mouse.link().label)")
        case "dpi":
            var d = try await mouse.dpi()
            switch rest.first {
            case nil:
                for (i, p) in d.profiles.enumerated() {
                    print("\(i == d.activeProfile ? "▶" : " ") \(i + 1): \(p.enabled ? "on " : "off") \(String(p.dpi).padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.color)")
                }
            case "select":
                guard rest.count == 2, let n = Int(rest[1]), (1...5).contains(n) else { return fail("dpi select <1-5>") }
                try await mouse.selectDPIProfile(n - 1)
                print("Profile \(n) active (\(d.profiles[n - 1].dpi) DPI)")
            case "set":
                guard rest.count == 3, let n = Int(rest[1]), (1...5).contains(n), let v = Int(rest[2]) else {
                    return fail("dpi set <1-5> <dpi>")
                }
                d.profiles[n - 1].dpi = DPISettings.clamp(v, max: d.maxDPI)
                d.profiles[n - 1].enabled = true
                try await mouse.applyDPI(d)
                print("Profile \(n) = \(d.profiles[n - 1].dpi) DPI")
            default: return fail("unknown dpi subcommand")
            }
        case "polling":
            guard let hz = rest.first.flatMap(Int.init), let rate = PollingRate(hertz: hz) else {
                return fail("polling <125|250|500|1000>")
            }
            try await mouse.setPollingRate(rate)
            try await mouse.saveToDevice()
            print("Polling rate \(rate.label)")
        case "warn":
            guard let p = rest.first.flatMap(Int.init), (0...100).contains(p) else { return fail("warn <percent>") }
            try await mouse.setLowBatteryWarning(p)
            try await mouse.saveToDevice()
            print("Low-battery warning at \(p)%")
        case "light":
            guard let e = rest.first.flatMap(LightingEffect.init(rawValue:)) else { return fail("light <effect> …") }
            let color = rest.count > 1 ? UInt32(rest[1].trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16).map(RGB.init(hex:)) : nil
            let bri = rest.count > 2 ? Int(rest[2]) ?? 100 : 100
            let speed = rest.count > 3 ? Int(rest[3]) ?? 50 : 50
            let cfg = LightingConfig(effect: e, colors: e == .cycle && color == nil ? LightingConfig.defaultPalette : [color ?? .red],
                                     brightness: bri, speed: speed)
            try await mouse.applyLighting(cfg)
            try await mouse.saveToDevice()
            print("Lighting: \(e.label)")
        case "buttons":
            let b = try await mouse.buttons()
            for btn in PhysicalButton.allCases { print("\(btn.label): \(b[btn]?.label ?? "?")") }
        case "save":
            try await mouse.saveToDevice(); print("Saved.")
        case "watch":
            mouse.transport.onUnsolicited = { r in
                if let e = HasteProtocol.parseEvent(r) {
                    print("event: profile \(e.activeProfile + 1), \(e.charge?.label ?? "?"), \(e.awake ? "awake" : "sleeping"), buttons \(String(e.buttons, radix: 2))")
                } else { print("unsolicited: \(r.hexTrimmed)") }
            }
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        case "raw":
            let bytes = rest.joined(separator: " ").split(separator: " ").compactMap { UInt8($0, radix: 16) }
            guard !bytes.isEmpty else { return fail("raw <hex bytes…>") }
            print(try await mouse.raw(bytes).hexTrimmed)
        default:
            print(usage); return 64
        }
    } catch {
        return fail(error.localizedDescription)
    }
    return 0
}

// IOKit delivers HID input reports via the main CFRunLoop, so spin it
// instead of relying on top-level `await` (which uses dispatch_main).
Task { @MainActor in exit(await run()) }
RunLoop.main.run()
