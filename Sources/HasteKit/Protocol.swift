import Foundation

/// Packet builders and parsers for the PF002 vendor channel.
/// See docs/PROTOCOL.md for the byte-level description.
public enum HasteProtocol {
    public static let vendorID = 0x03F0
    public static let wirelessProductID = 0x028E
    public static let wiredProductID = 0x048E
    public static let usagePage = 0xFF00
    public static let packetLength = 64

    public enum Op {
        public static let connection: UInt8 = 0x46
        public static let info: UInt8 = 0x50
        public static let heartbeat: UInt8 = 0x51
        public static let ledDirect: UInt8 = 0x52
        public static let dpi: UInt8 = 0x53
        public static let buttons: UInt8 = 0x54
        public static let ledHeader: UInt8 = 0x59
        public static let ledFrames: UInt8 = 0x5A
        public static let setPolling: UInt8 = 0xD0
        public static let setLowBattery: UInt8 = 0xD1
        public static let setLED: UInt8 = 0xD2
        public static let setDPI: UInt8 = 0xD3
        public static let setButton: UInt8 = 0xD4
        public static let setMacroBinding: UInt8 = 0xD5
        public static let macroData: UInt8 = 0xD6
        public static let setLEDHeader: UInt8 = 0xD9
        public static let setLEDFrames: UInt8 = 0xDA
        public static let ledCommit: UInt8 = 0xDB
        public static let save: UInt8 = 0xDE
        public static let factoryReset: UInt8 = 0xDF
        public static let event: UInt8 = 0xFF
    }

    /// Pad to a 64-byte report.
    public static func packet(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count <= packetLength)
        return bytes + [UInt8](repeating: 0, count: packetLength - bytes.count)
    }

    /// `<op> <b1> <b2> 02 ec ac` — the generic "acknowledged / no data" reply.
    public static func isAck(_ r: [UInt8]) -> Bool {
        r.count >= 5 && r[3] == 0x02 && r[4] == 0xEC
    }

    // MARK: - Read requests

    public static func readConnection() -> [UInt8] { packet([Op.connection]) }
    public static func readReceiverInfo() -> [UInt8] { packet([Op.info]) }
    public static func readMouseInfo() -> [UInt8] { packet([Op.info, 0x05]) }
    public static func readSettingsDump() -> [UInt8] { packet([Op.info, 0x03]) }
    public static func readHeartbeat() -> [UInt8] { packet([Op.heartbeat]) }
    public static func readDPI() -> [UInt8] { packet([Op.dpi]) }
    public static func readButtons() -> [UInt8] { packet([Op.buttons]) }
    public static func readLEDHeader() -> [UInt8] { packet([Op.ledHeader]) }
    public static func readLEDFrames(frameCount: Int, packetIndex: Int) -> [UInt8] {
        packet([Op.ledFrames, UInt8(frameCount), UInt8(packetIndex), 0x3C])
    }

    // MARK: - Write requests

    public static func setPollingRate(_ rate: PollingRate) -> [UInt8] {
        packet([Op.setPolling, 0, 0, 1, rate.rawValue])
    }

    public static func setLowBatteryWarning(percent: Int) -> [UInt8] {
        packet([Op.setLowBattery, 0, 0, 1, UInt8(max(0, min(100, percent)))])
    }

    public static func selectDPIProfile(_ index: Int) -> [UInt8] {
        packet([Op.setDPI, 0x00, 0, 1, UInt8(index)])
    }

    public static func setDPIEnabledMask(_ mask: UInt8) -> [UInt8] {
        packet([Op.setDPI, 0x01, 0, 1, mask])
    }

    public static func setDPIValue(profile: Int, dpi: Int) -> [UInt8] {
        let step = UInt16(dpi / DPISettings.dpiStep)
        return packet([Op.setDPI, 0x02, UInt8(profile), 2, UInt8(step & 0xff), UInt8(step >> 8)])
    }

    public static func setDPIColor(profile: Int, color: RGB) -> [UInt8] {
        packet([Op.setDPI, 0x03, UInt8(profile), 3] + color.bytes)
    }

    public static func setLiftOff(_ lod: LiftOffDistance) -> [UInt8] {
        packet([Op.setDPI, 0x05, 0, 1, lod.rawValue, lod.rawValue])
    }

    /// Full DPI apply sequence (as NGenuity sends it), ending with "save DPI".
    public static func applyDPI(_ s: DPISettings, save: Bool = true) -> [[UInt8]] {
        var out: [[UInt8]] = [setDPIEnabledMask(s.enabledMask)]
        for (i, p) in s.profiles.prefix(DPISettings.profileCount).enumerated() {
            out.append(setDPIValue(profile: i, dpi: DPISettings.clamp(p.dpi, max: s.maxDPI)))
            out.append(setDPIColor(profile: i, color: p.color))
        }
        out.append(setLiftOff(s.liftOff))
        out.append(selectDPIProfile(s.activeProfile))
        if save { out.append(saveDPI()) }
        return out
    }

    public static func setButton(_ button: PhysicalButton, _ action: ButtonAction) -> [UInt8] {
        packet([Op.setButton, button.rawValue, action.typeCode, 2, action.code(for: button), 0])
    }

    /// Direct (temporary, ~2 s) LED colour — used for live previews.
    public static func setDirectLED(_ color: RGB, brightness: Int) -> [UInt8] {
        packet([Op.setLED, 0, 0, 8] + color.bytes + color.bytes + [UInt8(clamping: brightness), 0])
    }

    public static func saveDPI() -> [UInt8] { packet([Op.save, 0x03]) }
    public static func saveAll() -> [UInt8] { packet([Op.save, 0xFF]) }
    /// Factory reset handler found in firmware (`DF AA 00`). Untested on hardware.
    public static func factoryReset() -> [UInt8] { packet([Op.factoryReset, 0xAA, 0x00]) }

    // MARK: - Parsers

    public static func parseConnection(_ r: [UInt8]) -> LinkState? {
        guard r.count >= 5, r[0] == Op.connection else { return nil }
        switch r[3] {
        case 0x01: return .wireless(awake: r[4] != 0)
        case 0x02: return .wired
        default: return nil
        }
    }

    public static func parseInfo(_ r: [UInt8]) -> FirmwareInfo? {
        guard r.count >= 21, r[0] == Op.info, r[3] == 0x3C else { return nil }
        let pid = UInt16(r[4]) | UInt16(r[5]) << 8
        let vid = UInt16(r[6]) | UInt16(r[7]) << 8
        let version = [r[11], r[10], r[9], r[8]].map(String.init).joined(separator: ".")
        let nameBytes = r[20...].prefix { $0 != 0 }
        let name = String(decoding: nameBytes, as: UTF8.self)
        return FirmwareInfo(vendorID: vid, productID: pid, version: version, name: name)
    }

    public static func parseHeartbeat(_ r: [UInt8]) -> BatteryStatus? {
        guard r.count >= 11, r[0] == Op.heartbeat, r[3] >= 3 else { return nil }
        let mv = r[3] >= 7 ? Int(r[9]) | Int(r[10]) << 8 : 0
        return BatteryStatus(percent: Int(min(r[4], 100)),
                             charge: ChargeState(rawValue: r[5]) ?? .discharging,
                             warningThreshold: Int(r[6]),
                             millivolts: mv,
                             raw: Array(r.prefix(Int(r[3]) + 4)))
    }

    public static func parseDPI(_ r: [UInt8]) -> DPISettings? {
        guard r.count >= 38, r[0] == Op.dpi, r[3] >= 0x21 else { return nil }
        let mask = r[5]
        let maxStep = Int(r[8]) | Int(r[9]) << 8
        var profiles: [DPIProfile] = []
        for i in 0..<DPISettings.profileCount {
            let step = Int(r[12 + i * 2]) | Int(r[13 + i * 2]) << 8
            let c = 22 + i * 3
            profiles.append(DPIProfile(enabled: mask & (1 << i) != 0,
                                       dpi: step * DPISettings.dpiStep,
                                       color: RGB(r[c], r[c + 1], r[c + 2])))
        }
        return DPISettings(activeProfile: Int(min(r[4], 4)), profiles: profiles,
                           liftOff: LiftOffDistance(rawValue: r[37]) ?? .low,
                           maxDPI: maxStep > 0 ? maxStep * DPISettings.dpiStep : DPISettings.defaultMaxDPI)
    }

    /// Parse 6 consecutive `<type> <code> <mask>` triples.
    public static func parseButtonTriples(_ bytes: ArraySlice<UInt8>) -> [PhysicalButton: ButtonAction] {
        var out: [PhysicalButton: ButtonAction] = [:]
        let b = Array(bytes)
        for btn in PhysicalButton.allCases {
            let o = Int(btn.rawValue) * 3
            guard o + 1 < b.count else { break }
            out[btn] = ButtonAction(type: b[o], code: b[o + 1]) ?? .disabled
        }
        return out
    }

    public static func parseButtons(_ r: [UInt8]) -> [PhysicalButton: ButtonAction]? {
        guard r.count >= 22, r[0] == Op.buttons, !isAck(r) else { return nil }
        return parseButtonTriples(r[4..<22])
    }

    public struct SettingsDump: Equatable, Sendable {
        public var dpiValues: [Int]
        public var dpiColors: [RGB]
        public var buttons: [PhysicalButton: ButtonAction]
        public var pollingRate: PollingRate
    }

    public static func parseSettingsDump(_ r: [UInt8]) -> SettingsDump? {
        guard r.count >= 54, r[0] == Op.info, r[1] == 0x03, r[3] >= 0x31 else { return nil }
        let dpis = (0..<5).map { (Int(r[10 + $0 * 2]) | Int(r[11 + $0 * 2]) << 8) * DPISettings.dpiStep }
        let colors = (0..<5).map { RGB(r[20 + $0 * 3], r[21 + $0 * 3], r[22 + $0 * 3]) }
        return SettingsDump(dpiValues: dpis, dpiColors: colors,
                            buttons: parseButtonTriples(r[35..<53]),
                            pollingRate: PollingRate(rawValue: r[53]) ?? .hz1000)
    }

    public static func parseLEDHeader(_ r: [UInt8]) -> Int? {
        guard r.count >= 7, r[0] == Op.ledHeader, r[3] == 0x03, r[4] == 0x55 else { return nil }
        return Int(r[5])
    }

    public static func parseEvent(_ r: [UInt8]) -> DeviceEvent? {
        guard r.count >= 8, r[0] == Op.event, r[1] == 0x03 else { return nil }
        return DeviceEvent(activeProfile: Int(min(r[2], 4)),
                           charge: ChargeState(rawValue: r[3]),
                           awake: r[4] != 0,
                           buttons: r[7])
    }
}
