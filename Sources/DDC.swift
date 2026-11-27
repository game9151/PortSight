import CoreGraphics
import Foundation
import IOKit

/// Monitor settings over DDC/CI (the monitor's own brightness, contrast and volume).
/// Works on Apple silicon through the IOAVService functions in IOKit. Some docks and adapters block DDC.
enum VCP: UInt8, CaseIterable, Identifiable {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    var id: UInt8 { rawValue }
    var name: String {
        switch self {
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .volume: return "Volume"
        }
    }
}

struct DDCValue: Equatable {
    var current: Int
    var max: Int
}

enum DDC {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias I2CFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create: CreateFn? = iokit.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: CreateFn.self) }
    private static let readI2C: I2CFn? = iokit.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: I2CFn.self) }
    private static let writeI2C: I2CFn? = iokit.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: I2CFn.self) }

    static var available: Bool { create != nil && readI2C != nil && writeI2C != nil }

    /// DDC traffic must not overlap, and monitors are slow, so everything runs on one queue.
    static let queue = DispatchQueue(label: "PortSight.ddc")
    private static var services: [CGDirectDisplayID: AnyObject] = [:]

    private static func registryPath(_ s: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        IORegistryEntryGetPath(s, kIOServicePlane, &buf)
        return String(cString: buf)
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// Finds the external AV service for a display. With several monitors, pairs each one with
    /// the framebuffer that shares the most of its registry path (same DCP pipe).
    private static func service(for display: CGDirectDisplayID) -> AnyObject? {
        if let s = services[display] { return s }
        guard let create else { return nil }
        var avServices: [(io_service_t, String)] = []
        var it: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS {
            while true {
                let s = IOIteratorNext(it)
                if s == 0 { break }
                if (IOReg.properties(s)["Location"] as? String) == "External" { avServices.append((s, registryPath(s))) } else { IOObjectRelease(s) }
            }
            IOObjectRelease(it)
        }
        defer { avServices.forEach { IOObjectRelease($0.0) } }
        guard !avServices.isEmpty else { return nil }

        var chosen = avServices[0].0
        if avServices.count > 1 {
            // Path of this display's framebuffer.
            let vendor = CGDisplayVendorNumber(display), model = CGDisplayModelNumber(display)
            var fbPath = ""
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &it) == KERN_SUCCESS {
                while true {
                    let s = IOIteratorNext(it)
                    if s == 0 { break }
                    if let p = (IOReg.properties(s)["DisplayAttributes"] as? [String: Any])?["ProductAttributes"] as? [String: Any],
                       (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor,
                       (p["ProductID"] as? NSNumber)?.uint32Value == model { fbPath = registryPath(s) }
                    IOObjectRelease(s)
                }
                IOObjectRelease(it)
            }
            chosen = avServices.max { commonPrefix($0.1, fbPath) < commonPrefix($1.1, fbPath) }!.0
        }
        guard let av = create(kCFAllocatorDefault, chosen)?.takeRetainedValue() else { return nil }
        services[display] = av
        return av
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E ^ 0x51) { $0 ^ $1 }
    }

    /// Reads a VCP value. Call on `DDC.queue`.
    static func read(_ vcp: VCP, display: CGDirectDisplayID) -> DDCValue? {
        guard let readI2C, let writeI2C, let av = service(for: display) else { return nil }
        var request: [UInt8] = [0x82, 0x01, vcp.rawValue]
        request.append(checksum(request))
        for attempt in 0..<4 {
            let w = request.withUnsafeMutableBytes { writeI2C(av, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            usleep(useconds_t(50_000 + attempt * 30_000))
            var reply = [UInt8](repeating: 0, count: 12)
            let r = reply.withUnsafeMutableBytes { readI2C(av, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            // Reply: 6E 88 02 result vcp type maxHi maxLo curHi curLo chk
            if w == kIOReturnSuccess, r == kIOReturnSuccess, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp.rawValue {
                let max = Int(reply[6]) << 8 | Int(reply[7])
                let cur = Int(reply[8]) << 8 | Int(reply[9])
                if max > 0 { return DDCValue(current: cur, max: max) }
            }
            usleep(40_000)
        }
        return nil
    }

    /// Forgets cached services, e.g. after a monitor is replugged. Call on `DDC.queue`.
    static func reset() { services.removeAll() }

    /// Writes a VCP value. Call on `DDC.queue`.
    @discardableResult
    static func write(_ vcp: VCP, value: Int, display: CGDirectDisplayID) -> Bool {
        if writeOnce(vcp, value: value, display: display) { return true }
        services[display] = nil
        return writeOnce(vcp, value: value, display: display)
    }

    private static func writeOnce(_ vcp: VCP, value: Int, display: CGDirectDisplayID) -> Bool {
        guard let writeI2C, let av = service(for: display) else { return false }
        var packet: [UInt8] = [0x84, 0x03, vcp.rawValue, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        packet.append(checksum(packet))
        var ok = false
        for _ in 0..<2 {
            let r = packet.withUnsafeMutableBytes { writeI2C(av, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            if r == kIOReturnSuccess { ok = true }
            usleep(20_000)
        }
        return ok
    }
}
