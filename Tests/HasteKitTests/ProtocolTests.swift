import Testing
@testable import HasteKit

/// Hex helper: "d3 01 00" → padded 64-byte packet.
func pkt(_ hex: String) -> [UInt8] {
    let clean = hex.replacingOccurrences(of: " ", with: "")
    var out: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out + [UInt8](repeating: 0, count: max(0, 64 - out.count))
}

// MARK: - Parsers (live replies recorded from a real PF002 on 2026-11-17)

@Test func parsesHeartbeat() throws {
    let b = try #require(HasteProtocol.parseHeartbeat(pkt("510000094e000a1b00920f0204")))
    #expect(b.percent == 78)
    #expect(b.charge == .discharging)
    #expect(b.warningThreshold == 10)
    #expect(b.millivolts == 3986)
}

@Test func parsesReceiverAndMouseInfo() throws {
    let dongle = try #require(HasteProtocol.parseInfo(pkt(
        "5000003c8e02f003060001048e03f00303000100" + "48797065725820507573656669726520486173746520576972656c657373")))
    #expect(dongle.productID == 0x028E)
    #expect(dongle.version == "4.1.0.6")
    let mouse = try #require(HasteProtocol.parseInfo(pkt(
        "5005003c8e04f003070001018e05f00304000001" + "48797065725820507573656669726520486173746520576972656c657373")))
    #expect(mouse.productID == 0x048E)
    #expect(mouse.version == "1.1.0.7")
}

@Test func parsesDPI() throws {
    let d = try #require(HasteProtocol.parseDPI(pkt(
        "5300002102 0f 0100 a000 1000 0400 0800 1000 2000 4000 ff0000 0000ff ffff00 00ff00 ffffff 01")))
    #expect(d.activeProfile == 2)
    #expect(d.profiles.map(\.dpi) == [400, 800, 1600, 3200, 6400])
    #expect(d.profiles.map(\.enabled) == [true, true, true, true, false])
    #expect(d.profiles[1].color == .blue)
    #expect(d.liftOff == .low)
    #expect(d.maxDPI == 16_000)
    #expect(d.enabledMask == 0x0f)
}

@Test func parsesSettingsDumpAndButtons() throws {
    let dump = try #require(HasteProtocol.parseSettingsDump(pkt(
        "50030031040004001000 0400080010002000 4000 ff0000 0000ff ffff00 00ff00 ffffff"
        + "010101 010202 010304 010408 010510 070808 02")))
    #expect(dump.pollingRate == .hz500)
    #expect(dump.dpiValues == [400, 800, 1600, 3200, 6400])
    #expect(dump.buttons[.left] == .mouse(.left))
    #expect(dump.buttons[.forward] == .mouse(.forward))
    #expect(dump.buttons[.dpi] == .dpiToggle)
    let b = try #require(HasteProtocol.parseButtons(pkt("5400000c010101010202010304010408010510070808")))
    #expect(b == dump.buttons)
}

@Test func parsesConnectionAndEvents() {
    #expect(HasteProtocol.parseConnection(pkt("4600000101")) == .wireless(awake: true))
    #expect(HasteProtocol.parseConnection(pkt("46000002ecac")) == .wired)
    let e = HasteProtocol.parseEvent(pkt("ff0302000100000100"))
    #expect(e?.activeProfile == 2)
    #expect(e?.awake == true)
    #expect(e?.buttons == 0x01)
    #expect(HasteProtocol.isAck(pkt("d0000002ecac")))
}

// MARK: - Encoders vs NGenuity USB captures

@Test func pollingPackets() {
    #expect(HasteProtocol.setPollingRate(.hz125) == pkt("d000000100"))
    #expect(HasteProtocol.setPollingRate(.hz1000) == pkt("d000000103"))
}

@Test func dpiSequenceMatchesCapture() {
    let s = DPISettings(activeProfile: 1, profiles: [
        .init(enabled: true, dpi: 16000, color: .red),
        .init(enabled: true, dpi: 200, color: .blue),
        .init(enabled: false, dpi: 1600, color: .yellow),
        .init(enabled: false, dpi: 3200, color: .green),
        .init(enabled: false, dpi: 6400, color: .white),
    ], liftOff: .low)
    let p = HasteProtocol.applyDPI(s)
    #expect(p.first == pkt("d301000103"))
    #expect(p[1] == pkt("d3020002a000"))
    #expect(p[2] == pkt("d3030003ff0000"))
    #expect(p[3] == pkt("d30201020200"))
    #expect(p[4] == pkt("d30301030000ff"))
    #expect(p[p.count - 3] == pkt("d30500010101"))
    #expect(p[p.count - 2] == pkt("d300000101"))
    #expect(p.last == pkt("de03"))
}

@Test func buttonPacketsMatchCapture() {
    #expect(HasteProtocol.setButton(.left, .mouse(.left)) == pkt("d400010201"))
    #expect(HasteProtocol.setButton(.middle, .shortcut(.taskManager)) == pkt("d402050201"))
    #expect(HasteProtocol.setButton(.back, .media(.mute)) == pkt("d403030204"))
    #expect(HasteProtocol.setButton(.forward, .keyboard(0x04)) == pkt("d404020204"))
    #expect(HasteProtocol.setButton(.dpi, .dpiToggle) == pkt("d405070208"))
}

@Test func breathingFramesMatchCapture() {
    let c = LightingConfig(effect: .breathing, colors: [.red], brightness: 100, speed: 100)
    let p = LightingEncoder.packets(for: c)
    #expect(p[0] == pkt("d2004008ffffff0000006400"))
    #expect(p[1] == pkt("da0b003c0000004e0000950000ce0000f20000ff0000f20000ce00009500004e0000000000"))
    #expect(p[7] == pkt("d9000003550b23"))
    #expect(p[8] == pkt("db55"))
    #expect(p[9] == pkt("deff"))
    #expect(LightingEncoder.breathingFrameCount(speed: 50) == 0x41)
    #expect(LightingEncoder.breathingFrameCount(speed: 0) == 0x78)
    // 0-speed capture spot checks
    let slow = LightingEncoder.frames(for: LightingConfig(effect: .breathing, colors: [.red], speed: 0))
    #expect(slow[1].r == 0x06)
    #expect(slow[20].r == 0x80)
}

@Test func cycleFramesMatchCapture() {
    let c = LightingConfig(effect: .cycle, colors: [.red, .yellow, .green, .blue, .magenta], brightness: 100, speed: 100)
    let f = LightingEncoder.frames(for: c)
    #expect(f.count == 0x50)
    #expect(f[0] == RGB(0xff, 0, 0))
    #expect(f[1] == RGB(0xff, 0x10, 0))
    #expect(f[8] == RGB(0xff, 0x81, 0))
    #expect(f[15] == RGB(0xff, 0xf2, 0))
    #expect(f[16] == RGB(0xfb, 0xff, 0))
    #expect(LightingEncoder.cycleFrameCount(speed: 50) == 0x64)
}

@Test func fadePacketsMatchCapture() {
    let c = LightingConfig(effect: .fade, colors: [.red], brightness: 50, speed: 50)
    let p = LightingEncoder.packets(for: c)
    #expect(p[0] == pkt("d2003008800000000000641f"))
    #expect(p[1] == pkt("da01003c"))
    #expect(p[7] == pkt("d9000003550123"))
    for (s, b) in [(0, 0x3f), (25, 0x2f), (75, 0x0f), (100, 0x00)] {
        #expect(LightingEncoder.fadeSpeedByte(speed: s) == UInt8(b))
    }
}

@Test func classifiesRoundTrip() {
    for cfg in [LightingConfig(effect: .solid, colors: [.green], brightness: 100),
                LightingConfig(effect: .breathing, colors: [.blue], brightness: 100, speed: 40),
                LightingConfig(effect: .off, colors: [.red])] {
        let back = LightingEncoder.classify(frames: LightingEncoder.frames(for: cfg))
        #expect(back.effect == cfg.effect)
        if cfg.effect != .off { #expect(back.primary == cfg.primary) }
    }
    #expect(LightingEncoder.classify(frames: LightingEncoder.frames(for:
        LightingConfig(effect: .cycle, colors: LightingConfig.defaultPalette, speed: 30))).effect == .cycle)
}

@Test func keyboardMacroMatchesCapture() throws {
    // Capture: one key-down with a,s,d,f,g,h then all-up.
    let m = Macro(steps: [
        .keyDown(0x04), .keyDown(0x16), .keyDown(0x07), .keyDown(0x09), .keyDown(0x0a), .keyDown(0x0b),
    ], repeatMode: .toggle)
    // Collapse the six downs into one snapshot like NGenuity's recorder does.
    let events: [MacroEvent] = [
        .keyboard(modifiers: 0, keys: [0x04, 0x16, 0x07, 0x09, 0x0a, 0x0b], delay: 0x04b3),
        .keyboard(modifiers: 0, keys: [], delay: 0x0290),
    ]
    #expect(events.flatMap(\.bytes) == Array(pkt("1a00041607090a0bb3041a000000000000009002").prefix(20)))
    #expect(MacroEncoder.compile(m).count == 6)
    let p = try MacroEncoder.packets(for: Macro(steps: [.keyDown(4), .keyUp(4)], repeatMode: .toggle), on: .back)
    #expect(p[0] == pkt("d403040203"))
    #expect(p[1][0...3] == [0xd6, 0x03, 0x00, 0x02])
    #expect(p[2] == pkt("d503000502000200"))
}

@Test func mouseMacroChunking() throws {
    var steps: [MacroStep] = []
    for b in [MacroMouseButton.middle, .left, .right] { steps += [.mouseDown(b), .delay(109), .mouseUp(b), .delay(407)] }
    steps += [.scroll(1), .scroll(-1)]
    let m = Macro(steps: steps, repeatMode: .once)
    let ev = MacroEncoder.compile(m)
    #expect(ev.count == 10)
    #expect(ev[0].bytes == [0x25, 0x04, 0x00, 0x6d, 0x00])
    #expect(ev[1].bytes == [0x25, 0x00, 0x00, 0x97, 0x01])
    #expect(ev[6].bytes[0...2] == [0x25, 0x00, 0x01])
    let p = try MacroEncoder.packets(for: m, on: .middle)
    #expect(p[1][0...3] == [0xd6, 0x02, 0x00, 0x06])
    #expect(p[2][0...3] == [0xd6, 0x02, 0x01, 0x84])
    #expect(p[3][0...4] == [0xd5, 0x02, 0x00, 0x05, 0x0a])
}
