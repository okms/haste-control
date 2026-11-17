import Foundation

/// Typed, async API over `HIDTransport`.
@MainActor
public final class HasteMouse {
    public let transport: HIDTransport
    typealias P = HasteProtocol

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    public convenience init() {
        self.init(transport: HIDTransport())
    }

    public var isAttached: Bool { transport.endpoint != nil }

    // MARK: Reads

    public func link() async throws -> LinkState {
        let r = try await transport.request(P.readConnection())
        guard let s = P.parseConnection(r) else { throw HasteError.badReply(P.Op.connection) }
        return s
    }

    public func receiverInfo() async throws -> FirmwareInfo {
        let r = try await transport.request(P.readReceiverInfo())
        guard let i = P.parseInfo(r) else { throw HasteError.badReply(P.Op.info) }
        return i
    }

    /// Info reported by the mouse itself (relayed by the dongle when wireless).
    public func mouseInfo() async throws -> FirmwareInfo? {
        let r = try await transport.request(P.readMouseInfo())
        return P.parseInfo(r)
    }

    public func battery() async throws -> BatteryStatus {
        let r = try await transport.request(P.readHeartbeat())
        guard let b = P.parseHeartbeat(r) else { throw HasteError.badReply(P.Op.heartbeat) }
        return b
    }

    public func dpi() async throws -> DPISettings {
        let r = try await transport.request(P.readDPI())
        guard let d = P.parseDPI(r) else { throw HasteError.badReply(P.Op.dpi) }
        return d
    }

    public func settingsDump() async throws -> HasteProtocol.SettingsDump {
        let r = try await transport.request(P.readSettingsDump())
        guard let d = P.parseSettingsDump(r) else { throw HasteError.badReply(P.Op.info) }
        return d
    }

    public func buttons() async throws -> [PhysicalButton: ButtonAction] {
        let r = try await transport.request(P.readButtons())
        guard let b = P.parseButtons(r) else { throw HasteError.badReply(P.Op.buttons) }
        return b
    }

    /// Reads the onboard LED animation table back.
    public func lightingFrames() async throws -> [RGB] {
        let h = try await transport.request(P.readLEDHeader())
        guard let n = P.parseLEDHeader(h), n > 0 else { return [] }
        var frames: [RGB] = []
        let packets = (n + LightingEncoder.framesPerPacket - 1) / LightingEncoder.framesPerPacket
        for k in 0..<min(packets, LightingEncoder.packetCount) {
            let r = try await transport.request(P.readLEDFrames(frameCount: n, packetIndex: k)) {
                $0.count >= 4 && $0[0] == P.Op.ledFrames && $0[2] == UInt8(k)
            }
            guard r[3] == 0x3C else { break }
            var i = 4
            while i + 2 < 64 && frames.count < n {
                frames.append(RGB(r[i], r[i + 1], r[i + 2])); i += 3
            }
        }
        return frames
    }

    // MARK: Writes

    public func setPollingRate(_ rate: PollingRate) async throws {
        try await transport.send([P.setPollingRate(rate)])
    }

    public func setLowBatteryWarning(_ percent: Int) async throws {
        try await transport.send([P.setLowBatteryWarning(percent: percent)])
    }

    public func selectDPIProfile(_ index: Int) async throws {
        try await transport.send([P.selectDPIProfile(index)])
    }

    public func applyDPI(_ settings: DPISettings) async throws {
        try await transport.send(P.applyDPI(settings))
    }

    public func setButton(_ button: PhysicalButton, _ action: ButtonAction) async throws {
        try await transport.send([P.setButton(button, action)])
    }

    public func uploadMacro(_ macro: Macro, to button: PhysicalButton) async throws {
        try await transport.send(try MacroEncoder.packets(for: macro, on: button, save: false))
    }

    public func applyLighting(_ config: LightingConfig) async throws {
        try await transport.send(LightingEncoder.packets(for: config, save: false))
    }

    /// Temporary colour preview (the mouse reverts after ~2 s).
    public func previewColor(_ color: RGB, brightness: Int) async throws {
        try await transport.send([P.setDirectLED(color, brightness: brightness)])
    }

    public func saveToDevice() async throws {
        try await transport.send([P.saveAll()])
    }

    public func factoryReset() async throws {
        try await transport.send([P.factoryReset()])
    }

    public func raw(_ packet: [UInt8]) async throws -> [UInt8] {
        try await transport.request(P.packet(packet))
    }
}
