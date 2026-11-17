import Foundation

/// Generates the onboard LED animation tables the firmware plays back.
///
/// The mouse loops over up to 120 RGB frames; frame count encodes speed.
/// Formulas were fitted to NGenuity captures (see docs/PROTOCOL.md).
public enum LightingEncoder {
    public static let maxFrames = 120
    public static let framesPerPacket = 20
    public static let packetCount = 6

    public static func breathingFrameCount(speed: Int) -> Int {
        max(2, Int((120 - 1.09 * Double(clampPct(speed)) + 1e-9).rounded(.down)))
    }

    public static func cycleFrameCount(speed: Int) -> Int {
        max(2, Int((120 - 0.4 * Double(clampPct(speed)) + 1e-9).rounded(.down)))
    }

    /// NGenuity fade speed byte: 0 → 0x3f … 100 → 0x00.
    public static func fadeSpeedByte(speed: Int) -> UInt8 {
        UInt8(max(0, 63 - Int((Double(clampPct(speed)) * 0.64).rounded())))
    }

    public static func frames(for c: LightingConfig) -> [RGB] {
        switch c.effect {
        case .off, .fade:
            return [.black]
        case .solid:
            return [c.primary.scaled(percent: c.brightness)]
        case .breathing:
            let base = c.primary.scaled(percent: c.brightness)
            let n = breathingFrameCount(speed: c.speed)
            return (0..<n).map { i in
                let k = sin(Double.pi * Double(i) / Double(n - 1))
                func f(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * k).rounded(.down)))) }
                return RGB(f(base.r), f(base.g), f(base.b))
            }
        case .cycle:
            let palette = c.colors.isEmpty ? LightingConfig.defaultPalette : c.colors
            let n = cycleFrameCount(speed: c.speed)
            let m = palette.count
            return (0..<n).map { i in
                let t = Double(i) * Double(m) / Double(n - 1)
                let seg = Int(t.rounded(.down)) % m
                let frac = t - t.rounded(.down)
                let a = palette[seg], b = palette[(seg + 1) % m]
                func lerp(_ x: UInt8, _ y: UInt8) -> UInt8 {
                    UInt8(max(0, min(255, (Double(x) + (Double(y) - Double(x)) * frac).rounded(.down))))
                }
                return RGB(lerp(a.r, b.r), lerp(a.g, b.g), lerp(a.b, b.b)).scaled(percent: c.brightness)
            }
        }
    }

    /// The full packet sequence NGenuity sends to store an effect onboard.
    public static func packets(for c: LightingConfig, save: Bool = true) -> [[UInt8]] {
        typealias P = HasteProtocol
        var out: [[UInt8]] = []
        if c.effect == .fade {
            let col = c.primary.scaled(percent: c.brightness)
            out.append(P.packet([P.Op.setLED, 0, 0x30, 8] + col.bytes + [0, 0, 0, 100, fadeSpeedByte(speed: c.speed)]))
        } else {
            out.append(P.packet([P.Op.setLED, 0, 0x40, 8, 0xff, 0xff, 0xff, 0, 0, 0, 100, 0]))
        }
        let f = frames(for: c)
        let n = UInt8(f.count)
        for k in 0..<packetCount {
            var body: [UInt8] = [P.Op.setLEDFrames, n, UInt8(k), 0x3C]
            let slice = f.dropFirst(k * framesPerPacket).prefix(framesPerPacket)
            for col in slice { body += col.bytes }
            out.append(P.packet(body))
        }
        out.append(P.packet([P.Op.setLEDHeader, 0, 0, 3, 0x55, n, 0x23]))
        out.append(P.packet([P.Op.ledCommit, 0x55]))
        if save { out.append(P.saveAll()) }
        return out
    }

    /// Best-effort reconstruction of an effect from the frames stored onboard.
    public static func classify(frames: [RGB]) -> LightingConfig {
        guard let first = frames.first else { return LightingConfig(effect: .off, colors: [.red]) }
        if frames.count == 1 {
            if first.isBlack { return LightingConfig(effect: .off, colors: [.red]) }
            let (col, bri) = normalize(first)
            return LightingConfig(effect: .solid, colors: [col], brightness: bri)
        }
        // Breathing: starts black and every frame is a scalar multiple of the peak.
        let peak = frames.max { Int($0.r) + Int($0.g) + Int($0.b) < Int($1.r) + Int($1.g) + Int($1.b) } ?? first
        let isBreathing = first.isBlack && frames.allSatisfy { f in
            func ratio(_ a: UInt8, _ b: UInt8) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
            let rs = [(f.r, peak.r), (f.g, peak.g), (f.b, peak.b)].filter { $0.1 > 0 }.map { ratio($0.0, $0.1) }
            guard let lo = rs.min(), let hi = rs.max() else { return true }
            return hi - lo < 0.05
        }
        if isBreathing {
            let (col, bri) = normalize(peak)
            let speed = Int(((120 - Double(frames.count)) / 1.09).rounded())
            return LightingConfig(effect: .breathing, colors: [col], brightness: bri, speed: clampPct(speed))
        }
        let speed = Int(((120 - Double(frames.count)) / 0.4).rounded())
        let maxChannel = frames.map { max($0.r, $0.g, $0.b) }.max() ?? 255
        let bri = clampPct(Int((Double(maxChannel) / 255 * 100).rounded()))
        return LightingConfig(effect: .cycle, colors: LightingConfig.defaultPalette,
                              brightness: bri, speed: clampPct(speed))
    }

    static func normalize(_ c: RGB) -> (RGB, Int) {
        let m = max(c.r, c.g, c.b)
        guard m > 0 else { return (.black, 0) }
        let k = 255 / Double(m)
        func s(_ v: UInt8) -> UInt8 { UInt8(min(255, (Double(v) * k).rounded())) }
        return (RGB(s(c.r), s(c.g), s(c.b)), Int((Double(m) / 255 * 100).rounded()))
    }

    static func clampPct(_ v: Int) -> Int { max(0, min(100, v)) }
}
