import AppKit
import CoreGraphics

/// One resolution + refresh rate a display can run.
struct DisplayMode: Hashable, Codable {
    var width: Int          // "looks like" size
    var height: Int
    var pixelWidth: Int     // backing pixels
    var pixelHeight: Int
    var refresh: Double

    init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refresh: Double) {
        self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.refresh = refresh
    }

    init(_ mode: CGDisplayMode) {
        self.init(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                  pixelHeight: mode.pixelHeight, refresh: mode.refreshRate)
    }

    var isHiDPI: Bool { pixelWidth > width }
    var label: String { "\(width)x\(height)\(isHiDPI ? " HiDPI" : "") @ \(DisplayMode.hz(refresh))" }

    static func hz(_ r: Double) -> String {
        if r == 0 { return "?Hz" }
        return abs(r - r.rounded()) < 0.05 ? "\(Int(r.rounded()))Hz" : String(format: "%.2fHz", r)
    }

    func matches(_ other: DisplayMode) -> Bool {
        width == other.width && height == other.height &&
        pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight &&
        abs(refresh - other.refresh) < 0.6
    }

    /// Parses "3440x1440@120".
    static func parse(_ text: String) -> (width: Int, height: Int, hz: Double)? {
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "@")
        guard parts.count == 2, let hz = Double(parts[1].replacingOccurrences(of: "hz", with: "")) else { return nil }
        let size = parts[0].split(separator: "x")
        guard size.count == 2, let w = Int(size[0]), let h = Int(size[1]) else { return nil }
        return (w, h, hz)
    }
}

/// What the monitor reports about itself (EDID, as macOS parsed it).
struct MonitorInfo {
    var productName: String?
    var manufacturer: String?
    var year: Int?
    var maxRefresh: Double?
    var nativeWidth: Int?
    var nativeHeight: Int?
    var supportsHDR = false
    var connection: String?
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let isActive: Bool
    let isAsleep: Bool
    let mirrorsDisplay: CGDirectDisplayID?
    let inMirrorSet: Bool
    let key: String
    let current: DisplayMode?
    let modes: [DisplayMode]
    let monitor: MonitorInfo?

    var highestRefresh: Double { modes.map(\.refresh).max() ?? 0 }

    /// Native panel size: from EDID, or the largest mode offered.
    var nativeSize: (Int, Int) {
        if let w = monitor?.nativeWidth, let h = monitor?.nativeHeight, w > 0, h > 0 { return (w, h) }
        let biggest = modes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        return (biggest?.pixelWidth ?? 0, biggest?.pixelHeight ?? 0)
    }

    /// Modes at the panel's native resolution (sharpest, and the ones people usually want).
    var nativeModes: [DisplayMode] {
        let (w, h) = nativeSize
        let native = modes.filter { ($0.pixelWidth == w && $0.pixelHeight == h) || ($0.width == w && $0.height == h) }
        return native.isEmpty ? modes : native
    }

    /// Size of the video signal on the cable for a mode. Scaled modes are sent at native size.
    func signalSize(for mode: DisplayMode) -> (Int, Int) {
        let (w, h) = nativeSize
        if w > 0 && mode.pixelWidth >= w { return (w, h) }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    var roleText: String {
        var parts: [String] = [isBuiltin ? "built-in" : "external"]
        if isMain { parts.append("main") }
        if inMirrorSet { parts.append(mirrorsDisplay == nil ? "mirroring (source)" : "mirroring") }
        if !isActive { parts.append("inactive") }
        if isAsleep { parts.append("asleep") }
        return parts.joined(separator: ", ")
    }
}

enum Displays {
    static func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func key(for id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    static func cgModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    static func modes(_ id: CGDirectDisplayID) -> [DisplayMode] {
        var seen = Set<String>()
        var result: [DisplayMode] = []
        for cg in cgModes(id) where cg.isUsableForDesktopGUI() {
            let mode = DisplayMode(cg)
            let tag = "\(mode.width)x\(mode.height)/\(mode.pixelWidth)x\(mode.pixelHeight)@\(Int((mode.refresh * 10).rounded()))"
            if seen.insert(tag).inserted { result.append(mode) }
        }
        return result.sorted {
            ($0.pixelWidth * $0.pixelHeight, $0.width, $0.refresh) > ($1.pixelWidth * $1.pixelHeight, $1.width, $1.refresh)
        }
    }

    /// DisplayAttributes dictionaries from the display drivers in the IORegistry.
    static func monitorRecords() -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for cls in ["IOMobileFramebufferShim", "AppleCLCD2", "IOMobileFramebuffer"] {
            for props in IOReg.services(matching: cls) {
                guard var attrs = props["DisplayAttributes"] as? [String: Any],
                      let product = attrs["ProductAttributes"] as? [String: Any] else { continue }
                let tag = "\(product["LegacyManufacturerID"] ?? "")-\(product["ProductID"] ?? "")-\(product["SerialNumber"] ?? "")"
                guard seen.insert(tag).inserted else { continue }
                attrs["_transport"] = props["Transport"]
                out.append(attrs)
            }
        }
        return out
    }

    static func monitor(for id: CGDirectDisplayID, records: [[String: Any]]) -> MonitorInfo? {
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
        let candidates = records.filter {
            guard let p = $0["ProductAttributes"] as? [String: Any] else { return false }
            return (p["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor && (p["ProductID"] as? NSNumber)?.uint32Value == model
        }
        let record = candidates.first {
            (($0["ProductAttributes"] as? [String: Any])?["SerialNumber"] as? NSNumber)?.uint32Value == serial
        } ?? candidates.first
        guard let attrs = record, let product = attrs["ProductAttributes"] as? [String: Any] else { return nil }
        var info = MonitorInfo()
        info.productName = product["ProductName"] as? String
        info.manufacturer = product["ManufacturerID"] as? String
        info.year = (product["YearOfManufacture"] as? NSNumber)?.intValue
        info.maxRefresh = (attrs["MaximumRefreshRate"] as? NSNumber)?.doubleValue
        info.nativeWidth = (attrs["NativeFormatHorizontalPixels"] as? NSNumber)?.intValue
        info.nativeHeight = (attrs["NativeFormatVerticalPixels"] as? NSNumber)?.intValue
        info.supportsHDR = (attrs["SupportsPQEOTF"] as? Bool) ?? (attrs["SupportsHDRStaticMetadataType1"] as? Bool) ?? false
        if let transport = attrs["_transport"] as? [String: Any] {
            info.connection = (transport["Downstream"] as? String) ?? (transport["Upstream"] as? String)
        }
        return info
    }

    static func screenName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }

    static func all() -> [DisplayInfo] {
        let records = monitorRecords()
        return onlineIDs().map { id in
            let builtin = CGDisplayIsBuiltin(id) != 0
            let monitor = monitor(for: id, records: records)
            let mirrorOf = CGDisplayMirrorsDisplay(id)
            let name = screenName(id) ?? monitor?.productName ?? (builtin ? "Built-in Display" : "Display \(id)")
            return DisplayInfo(
                id: id, name: name, isBuiltin: builtin,
                isMain: CGDisplayIsMain(id) != 0, isActive: CGDisplayIsActive(id) != 0,
                isAsleep: CGDisplayIsAsleep(id) != 0,
                mirrorsDisplay: mirrorOf == kCGNullDirectDisplay ? nil : mirrorOf,
                inMirrorSet: CGDisplayIsInMirrorSet(id) != 0,
                key: key(for: id),
                current: CGDisplayCopyDisplayMode(id).map(DisplayMode.init),
                modes: modes(id), monitor: monitor)
        }
        .sorted { (!$0.isBuiltin ? 0 : 1, $0.id) < (!$1.isBuiltin ? 0 : 1, $1.id) }
    }

    static func cgMode(for target: DisplayMode, on id: CGDirectDisplayID) -> CGDisplayMode? {
        cgModes(id).first { $0.isUsableForDesktopGUI() && DisplayMode($0).matches(target) }
    }

    /// Switches a display's mode. `permanently` saves it in macOS's display settings.
    @discardableResult
    static func apply(_ target: DisplayMode, to id: CGDirectDisplayID, permanently: Bool) -> CGError {
        guard let mode = cgMode(for: target, on: id) else { return .illegalArgument }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return .failure }
        CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
        return CGCompleteDisplayConfiguration(cfg, permanently ? .permanently : .forSession)
    }
}
