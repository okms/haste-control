// hxprobe — send raw 64-byte packets to the HyperX Pulsefire Haste Wireless vendor
// interface (usage page 0xFF00) and dump every input report received.
// Usage: swift tools/hxprobe.swift "51" "50" "50 03" ...   (hex bytes per packet)
import Foundation
import IOKit.hid

let vid = 0x03F0
let pids = [0x028E, 0x048E]

func hex(_ b: UnsafePointer<UInt8>, _ n: Int) -> String {
    (0..<n).map { String(format: "%02x", b[$0]) }.joined(separator: " ")
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matches = pids.map { [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: $0,
                          kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary }
IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("manager open:", String(format: "0x%08x", r))
guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = set.first else {
    print("no device"); exit(1)
}
print("device:", IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString)!)
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { _, _, _, _, _, report, len in
    print(String(format: "  <- [%2d] ", len) + hex(report, len))
}, nil)

let packets = CommandLine.arguments.dropFirst().map { s -> [UInt8] in
    s.split(separator: " ").map { UInt8($0, radix: 16)! }
}
for p in packets {
    var out = [UInt8](repeating: 0, count: 64)
    for (i, b) in p.enumerated() { out[i] = b }
    let res = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, out, 64)
    print("-> " + p.map { String(format: "%02x", $0) }.joined(separator: " "),
          String(format: "(0x%08x)", res))
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.4, false)
}
CFRunLoopRunInMode(CFRunLoopMode.defaultMode, Double(ProcessInfo.processInfo.environment["WAIT"] ?? "0.5")!, false)
