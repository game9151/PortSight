import Foundation

/// A USB-C / Thunderbolt port and what is running over it right now.
struct PortInfo: Identifiable {
    let id: Int
    let connected: Bool
    let active: [String]
    let supported: [String]

    private var dataTransports: [String] { active.filter { $0 != "CC" } }
    var carriesDisplayPort: Bool { active.contains("DisplayPort") }
    var carriesUSB3: Bool { active.contains("USB3") }
    var carriesThunderbolt: Bool { active.contains { $0.contains("CIO") || $0.contains("Thunderbolt") || $0.contains("USB4") } }

    /// DisplayPort over USB-C gets 4 lanes alone, 2 when it shares the cable with USB 3.
    var displayPortLanes: Int? {
        guard carriesDisplayPort else { return nil }
        return carriesUSB3 ? 2 : 4
    }

    var summary: String {
        if !connected { return "Nothing connected" }
        if dataTransports.isEmpty { return active.isEmpty ? "Connected, no data" : "Power only (charger)" }
        var names = dataTransports.map { t -> String in
            switch t {
            case "USB2": return "USB 2"
            case "USB3": return "USB 3"
            case "DisplayPort": return "DisplayPort"
            default: return t.contains("CIO") ? "Thunderbolt/USB4" : t
            }
        }
        if let lanes = displayPortLanes { names = names.map { $0 == "DisplayPort" ? "DisplayPort (\(lanes) lanes)" : $0 } }
        return names.joined(separator: " + ")
    }
}

struct ChargerInfo {
    var connected = false
    var name: String?
    var watts: Int?
    var charging: Bool?
}

struct USBDevice: Identifiable {
    let id = UUID()
    let name: String
    let vendor: String?
    let speed: String?
    var isHubOrDock: Bool {
        let n = name.lowercased()
        return n.contains("hub") || n.contains("dock") || n.contains("multiport") || n.contains("adapter")
    }
}

enum Connections {
    static func ports() -> [PortInfo] {
        var byNumber: [Int: PortInfo] = [:]
        for cls in ["AppleTCController", "AppleTCControllerType10", "AppleTCControllerType11", "AppleHPMInterfaceType10"] {
            for props in IOReg.services(matching: cls) {
                guard let number = (props["PortNumber"] as? NSNumber)?.intValue, byNumber[number] == nil else { continue }
                byNumber[number] = PortInfo(
                    id: number,
                    connected: (props["ConnectionActive"] as? Bool) ?? false,
                    active: (props["TransportsActive"] as? [String]) ?? [],
                    supported: (props["TransportsSupported"] as? [String]) ?? [])
            }
        }
        return byNumber.values.sorted { $0.id < $1.id }
    }

    static func charger() -> ChargerInfo? {
        guard let root = Shell.json("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]),
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        var info = ChargerInfo()
        var sawBattery = false
        for item in items {
            if let w = item["sppower_ac_charger_watts"] as? String { info.watts = Int(w); info.connected = true }
            if let n = item["sppower_ac_charger_name"] as? String { info.name = n }
            if (item["sppower_battery_charger_connected"] as? String)?.uppercased() == "TRUE" { info.connected = true }
            if item["sppower_battery_charge_info"] != nil || item["sppower_battery_health_info"] != nil { sawBattery = true }
            if let charging = findValue(in: item, keyContaining: "is_charging") {
                info.charging = charging.uppercased() == "TRUE" || charging.lowercased() == "yes"
            }
        }
        return (sawBattery || info.connected) ? info : nil
    }

    private static func findValue(in dict: [String: Any], keyContaining needle: String) -> String? {
        for (k, v) in dict {
            if k.contains(needle), let s = v as? String { return s }
            if let nested = v as? [String: Any], let s = findValue(in: nested, keyContaining: needle) { return s }
        }
        return nil
    }

    static func usbDevices() -> [USBDevice] {
        var root = Shell.json("/usr/sbin/system_profiler", ["SPUSBHostDataType", "-json"])?["SPUSBHostDataType"] as? [[String: Any]]
        if root == nil || root?.isEmpty == true {
            root = Shell.json("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"])?["SPUSBDataType"] as? [[String: Any]]
        }
        var out: [USBDevice] = []
        func walk(_ items: [[String: Any]]) {
            for item in items {
                let vendorID = item["USBDeviceKeyVendorID"] ?? item["vendor_id"]
                if vendorID != nil, let name = item["_name"] as? String {
                    out.append(USBDevice(name: name,
                                         vendor: (item["USBDeviceKeyVendorName"] ?? item["manufacturer"]) as? String,
                                         speed: (item["USBDeviceKeyLinkSpeed"] ?? item["device_speed"]) as? String))
                }
                if let children = item["_items"] as? [[String: Any]] { walk(children) }
            }
        }
        walk(root ?? [])
        return out
    }
}
