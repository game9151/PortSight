import CoreGraphics
import Foundation
import IOKit

/// A colour format the display driver offers for the current timing.
struct ColourMode: Identifiable, Hashable {
    let id: UInt32
    let encoding: Int
    let depth: Int
    let limitedRange: Bool
    let eotf: Int
    let isVirtual: Bool

    var encodingName: String { Framebuffers.encodingName(encoding) }
    var isHDR: Bool { eotf != 0 }
    var label: String {
        "\(encodingName), \(depth)-bit, \(limitedRange ? "limited" : "full") range\(isHDR ? ", HDR" : "")"
    }
}

struct FramebufferState {
    let colourID: UInt32
    let timingID: UInt32
    let currentColour: ColourMode?
    /// SDR colour formats the driver allows at the current timing (what fits the link).
    let choices: [ColourMode]
}

/// Talks to Apple silicon's display driver through private IOMobileFramebuffer functions.
/// Everything here is optional: if a function is missing (Intel Macs, future macOS), features hide themselves.
enum Framebuffers {
    private typealias OpenFn = @convention(c) (io_service_t, mach_port_t, UInt32, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> kern_return_t
    private typealias GetModeFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> kern_return_t
    private typealias SetModeFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> kern_return_t
    private typealias GetSupportedFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFArray>?>, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> kern_return_t
    private typealias EncodingStringFn = @convention(c) (UInt32) -> UnsafePointer<CChar>?

    private static let lib = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW)
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }
    private static let open = sym(lib, "IOMobileFramebufferOpen", OpenFn.self)
    private static let getMode = sym(lib, "IOMobileFramebufferGetDigitalOutMode", GetModeFn.self)
    private static let setMode = sym(lib, "IOMobileFramebufferSetDigitalOutMode", SetModeFn.self)
    private static let getSupported = sym(lib, "IOMobileFramebufferGetSupportedDigitalOutModes", GetSupportedFn.self)
    private static let encodingString = sym(iokit, "IOAVVideoPixelEncodingString", EncodingStringFn.self)

    static var available: Bool { open != nil && getMode != nil && getSupported != nil }
    static var canSetColour: Bool { available && setMode != nil }

    private static let lock = NSLock()
    private static var handles: [UInt64: UnsafeMutableRawPointer] = [:]

    static func encodingName(_ value: Int) -> String {
        if let fn = encodingString, let p = fn(UInt32(value)) { return String(cString: p) }
        return ["RGB 4:4:4", "YCbCr 4:2:0", "YCbCr 4:2:2", "YCbCr 4:4:4"].indices.contains(value)
            ? ["RGB 4:4:4", "YCbCr 4:2:0", "YCbCr 4:2:2", "YCbCr 4:4:4"][value] : "Encoding \(value)"
    }

    /// The framebuffer service driving this display (matched by vendor, product and serial).
    private static func service(for display: CGDirectDisplayID) -> (io_service_t, UInt64)? {
        let vendor = CGDisplayVendorNumber(display), model = CGDisplayModelNumber(display), serial = CGDisplaySerialNumber(display)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var fallback: (io_service_t, UInt64)?
        while true {
            let s = IOIteratorNext(iterator)
            if s == 0 { break }
            let props = IOReg.properties(s)
            guard let attrs = props["DisplayAttributes"] as? [String: Any],
                  let p = attrs["ProductAttributes"] as? [String: Any],
                  (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor,
                  (p["ProductID"] as? NSNumber)?.uint32Value == model else { IOObjectRelease(s); continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(s, &entryID)
            if (p["SerialNumber"] as? NSNumber)?.uint32Value == serial {
                if let f = fallback { IOObjectRelease(f.0) }
                return (s, entryID)
            }
            if fallback == nil { fallback = (s, entryID) } else { IOObjectRelease(s) }
        }
        return fallback
    }

    private static func handle(for display: CGDirectDisplayID) -> UnsafeMutableRawPointer? {
        guard let open, let (service, entryID) = service(for: display) else { return nil }
        // The service must stay retained while the handle is in use, or some calls fail. Handles are kept for the app's lifetime.
        lock.lock(); defer { lock.unlock() }
        if let h = handles[entryID] { IOObjectRelease(service); return h }
        var fb: UnsafeMutableRawPointer?
        guard open(service, mach_task_self_, 0, &fb) == KERN_SUCCESS, let fb else { IOObjectRelease(service); return nil }
        handles[entryID] = fb
        return fb
    }

    private static func colourMode(_ d: [String: Any]) -> ColourMode? {
        guard let id = (d["ID"] as? NSNumber)?.uint32Value else { return nil }
        return ColourMode(id: id,
                          encoding: (d["PixelEncoding"] as? NSNumber)?.intValue ?? 0,
                          depth: (d["Depth"] as? NSNumber)?.intValue ?? 8,
                          limitedRange: ((d["DynamicRange"] as? NSNumber)?.intValue ?? 0) == 1,
                          eotf: (d["EOTF"] as? NSNumber)?.intValue ?? 0,
                          isVirtual: ((d["IsVirtual"] as? NSNumber)?.intValue ?? 0) == 1)
    }

    static func state(for display: CGDirectDisplayID) -> FramebufferState? {
        guard CGDisplayIsBuiltin(display) == 0, let getMode, let getSupported, let fb = handle(for: display) else { return nil }
        var colourID: UInt32 = 0, timingID: UInt32 = 0
        guard getMode(fb, &colourID, &timingID) == KERN_SUCCESS else { return nil }
        var colours: Unmanaged<CFArray>?, timings: Unmanaged<CFArray>?
        guard getSupported(fb, &colours, &timings) == KERN_SUCCESS else { return nil }
        let allColours = (colours?.takeUnretainedValue() as? [[String: Any]] ?? []).compactMap(colourMode)
        let timing = (timings?.takeUnretainedValue() as? [[String: Any]] ?? []).first { ($0["ID"] as? NSNumber)?.uint32Value == timingID }
        let allowed = (timing?["ColorModes"] as? [[String: Any]] ?? []).compactMap(colourMode)
        // Formats that differ only in colorimetry look the same to people: keep one per label, preferring the current one.
        var byLabel: [String: ColourMode] = [:]
        for mode in allowed where !mode.isVirtual && !mode.isHDR {
            if byLabel[mode.label] == nil || mode.id == colourID { byLabel[mode.label] = mode }
        }
        let choices = Array(byLabel.values)
            .sorted { ($0.encoding == 0 ? 0 : 1, -$0.depth, $0.limitedRange ? 1 : 0) < ($1.encoding == 0 ? 0 : 1, -$1.depth, $1.limitedRange ? 1 : 0) }
        let current = allColours.first { $0.id == colourID } ?? allowed.first { $0.id == colourID }
        return FramebufferState(colourID: colourID, timingID: timingID, currentColour: current, choices: choices)
    }

    /// Switches the colour format, keeping the current resolution and refresh rate.
    @discardableResult
    static func setColour(_ colourID: UInt32, for display: CGDirectDisplayID) -> kern_return_t {
        guard let setMode, let getMode, let fb = handle(for: display) else { return KERN_FAILURE }
        var current: UInt32 = 0, timing: UInt32 = 0
        guard getMode(fb, &current, &timing) == KERN_SUCCESS else { return KERN_FAILURE }
        return setMode(fb, colourID, timing)
    }
}
