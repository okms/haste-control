import Foundation
import IOKit.hid

public enum HasteError: Error, LocalizedError, Equatable {
    case notConnected
    case timeout(UInt8)
    case io(Int32)
    case badReply(UInt8)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Mouse not connected."
        case .timeout(let op): String(format: "No reply from mouse (request 0x%02X). Is it asleep?", op)
        case .io(let code): String(format: "USB I/O error 0x%08X", UInt32(bitPattern: code))
        case .badReply(let op): String(format: "Unexpected reply to request 0x%02X", op)
        }
    }
}

/// Owns the IOHIDManager and the vendor (0xFF00) interface of the dongle or
/// cabled mouse. All callbacks run on the main run loop; all API is main-actor.
@MainActor
public final class HIDTransport {
    public struct Endpoint: Equatable {
        public let productID: Int
        public var isWired: Bool { productID == HasteProtocol.wiredProductID }
    }

    public var onAttach: ((Endpoint) -> Void)?
    public var onDetach: (() -> Void)?
    public var onUnsolicited: (([UInt8]) -> Void)?
    /// Log hook for every packet in/out (hex). Off by default.
    public var trace: ((String) -> Void)?

    public private(set) var endpoint: Endpoint?

    private let manager: IOHIDManager
    private var devices: [Int: IOHIDDevice] = [:]  // productID → device
    private var active: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: HasteProtocol.packetLength)
    private var waiter: (id: Int, match: ([UInt8]) -> Bool, cont: CheckedContinuation<[UInt8], Error>)?
    private var nextWaiterID = 0
    private var queueTail: Task<Void, Never>?
    private var lastWrite = Date.distantPast
    /// Minimum spacing between packets (small safety margin for the radio link).
    public var interPacketGap: TimeInterval = 0.005

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = [HasteProtocol.wirelessProductID, HasteProtocol.wiredProductID].map {
            [kIOHIDVendorIDKey: HasteProtocol.vendorID,
             kIOHIDProductIDKey: $0,
             kIOHIDPrimaryUsagePageKey: HasteProtocol.usagePage] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceAdded(device) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.deviceRemoved(device) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: Hotplug

    private func productID(of device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        devices[productID(of: device)] = device
        selectBestDevice()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        devices = devices.filter { $0.value !== device }
        if active === device {
            failWaiter(HasteError.notConnected)
            active = nil
            endpoint = nil
            onDetach?()
        }
        selectBestDevice()
    }

    /// Prefer the cable (direct) connection over the dongle when both exist.
    private func selectBestDevice() {
        let pid = devices[HasteProtocol.wiredProductID] != nil ? HasteProtocol.wiredProductID
                : devices[HasteProtocol.wirelessProductID] != nil ? HasteProtocol.wirelessProductID : nil
        guard let pid, let dev = devices[pid], dev !== active else { return }
        if active != nil { failWaiter(HasteError.notConnected) }
        active = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, buffer, HasteProtocol.packetLength, { ctx, _, sender, _, _, report, length in
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { me.received(bytes, from: sender) }
        }, ctx)
        endpoint = Endpoint(productID: pid)
        onAttach?(endpoint!)
    }

    // MARK: I/O

    private func received(_ bytes: [UInt8], from sender: UnsafeMutableRawPointer?) {
        trace?("<- " + bytes.hexTrimmed)
        if let w = waiter, w.match(bytes) {
            waiter = nil
            w.cont.resume(returning: bytes)
            return
        }
        onUnsolicited?(bytes)
    }

    private func failWaiter(_ error: Error) {
        if let w = waiter { waiter = nil; w.cont.resume(throwing: error) }
    }

    /// Fire-and-forget write (no reply expected).
    public func write(_ packet: [UInt8]) throws {
        guard let dev = active else { throw HasteError.notConnected }
        trace?("-> " + packet.hexTrimmed)
        let r = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        if r != kIOReturnSuccess { throw HasteError.io(r) }
    }

    /// Send a packet and wait for the reply that echoes its first two bytes.
    /// Requests are strictly serialized.
    public func request(_ packet: [UInt8], timeout: TimeInterval = 1.0,
                        match: (([UInt8]) -> Bool)? = nil) async throws -> [UInt8] {
        let op = packet[0], sub = packet[1]
        let matcher = match ?? { r in r.count > 1 && r[0] == op && r[1] == sub }
        return try await serialized {
            let wait = self.interPacketGap - Date().timeIntervalSince(self.lastWrite)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            defer { self.lastWrite = Date() }
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
                self.nextWaiterID += 1
                let id = self.nextWaiterID
                self.waiter = (id, matcher, cont)
                do { try self.write(packet) } catch {
                    self.waiter = nil
                    cont.resume(throwing: error)
                    return
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if let w = self.waiter, w.id == id {
                        self.waiter = nil
                        w.cont.resume(throwing: HasteError.timeout(op))
                    }
                }
            }
        }
    }

    /// Send several packets in order, each waiting for its acknowledgement.
    public func send(_ packets: [[UInt8]]) async throws {
        for p in packets { _ = try await request(p) }
    }

    private func serialized<T>(_ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            do { return .success(try await op()) } catch { return .failure(error) }
        }
        queueTail = Task { @MainActor in _ = await task.value }
        return try await task.value.get()
    }
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
    /// Hex with trailing zero padding collapsed.
    public var hexTrimmed: String {
        var end = count
        while end > 4, self[end - 1] == 0 { end -= 1 }
        return Array(self[..<end]).hex + (end < count ? " …" : "")
    }
}
