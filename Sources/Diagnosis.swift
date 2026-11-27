import Foundation

struct Finding: Identifiable {
    enum Level: Int { case problem = 0, warning = 1, info = 2, ok = 3 }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String
    var fix: String?
}

struct SystemSnapshot {
    var date = Date()
    var displays: [DisplayInfo]
    var ports: [PortInfo]
    var charger: ChargerInfo?
    var usb: [USBDevice]
    var log: KernelLogResult
    var lidClosed: Bool?
    var findings: [Finding] = []

    var externals: [DisplayInfo] { displays.filter { !$0.isBuiltin } }

    /// The link to the external display: measured from the log, else estimated from the port.
    var capacity: LinkCapacity? {
        if let s = log.latest, s.lanes > 0 { return s.capacity }
        if let port = ports.first(where: { $0.carriesDisplayPort }), let lanes = port.displayPortLanes {
            return LinkCapacity(lanes: lanes, perLaneGbps: 8.1, measured: false)
        }
        return nil
    }
}

enum Diagnosis {
    static func gather(logHours: Double) -> SystemSnapshot {
        let displays = Displays.all()
        var snapshot = SystemSnapshot(
            displays: displays,
            ports: Connections.ports(),
            charger: Connections.charger(),
            usb: Connections.usbDevices(),
            log: KernelLog.read(hours: logHours, hasBuiltinDisplay: displays.contains { $0.isBuiltin } || IOReg.clamshellClosed() != nil),
            lidClosed: IOReg.clamshellClosed())
        snapshot.findings = findings(for: snapshot)
        return snapshot
    }

    static func refreshDisplays(_ snapshot: SystemSnapshot) -> SystemSnapshot {
        var s = snapshot
        s.displays = Displays.all()
        s.lidClosed = IOReg.clamshellClosed()
        s.findings = findings(for: s)
        return s
    }

    static func findings(for s: SystemSnapshot) -> [Finding] {
        var out: [Finding] = []
        let log = s.log

        // 1. The lid-closed setting differs from the lid-open one.
        if let closed = log.linkWhileLid(closed: true), let open = log.linkWhileLid(closed: false),
           let cr = closed.refresh, let or = open.refresh,
           abs(cr - or) > 1 || closed.isCompressedColour != open.isCompressedColour {
            var detail = "Lid open: \(open.modeLabel), \(open.colourLabel). Lid closed: macOS switches to \(closed.modeLabel), \(closed.colourLabel)."
            if let r = closed.ratio { detail += " That uses \(Fmt.pct(r)) of the cable's bandwidth." }
            detail += " If the monitor says \"no signal\" when you close the lid, this is the likely cause."
            out.append(Finding(level: (closed.ratio ?? 0) > 0.9 ? .problem : .warning,
                               title: "Closing the lid switches the monitor to \(DisplayMode.hz(cr))",
                               detail: detail,
                               fix: "In Lid Profiles, set the lid-closed mode to \(DisplayMode.hz(or)), the rate that works with the lid open, and turn profiles on."))
        }

        // 2. DisplayPort sharing a USB-C cable with USB 3.
        for port in s.ports where port.carriesDisplayPort && port.carriesUSB3 {
            out.append(Finding(level: .warning,
                               title: "Video only gets half the cable on port \(port.id)",
                               detail: "This port carries USB 3 and DisplayPort together, so DisplayPort is limited to 2 lanes. Docks and hubs usually do this so their USB 3 ports work.",
                               fix: "For more bandwidth, connect the monitor with a direct USB-C to DisplayPort cable, or use a Thunderbolt dock, so video gets all 4 lanes."))
        }

        // 3. Link details from the last mode change.
        if let link = log.latest {
            if link.perLaneGbps > 0 && link.perLaneGbps < 6 {
                out.append(Finding(level: .warning,
                                   title: "The link runs at DP 1.2 speed",
                                   detail: "The monitor link negotiated \(String(format: "%.1f", link.perLaneGbps)) Gbps per lane (\(link.capacity.speedName)). Your dock, adapter or cable may only support DisplayPort 1.2.",
                                   fix: "A DP 1.4 (HBR3) cable or dock gives 50% more bandwidth per lane."))
            }
            if let r = link.ratio, r > 0.9 {
                out.append(Finding(level: .warning,
                                   title: "The cable is \(Fmt.pct(r)) full",
                                   detail: "\(link.modeLabel) needs \(Fmt.gbps(link.videoGbps ?? 0)) of \(Fmt.gbps(link.usableGbps ?? 0)). Links this close to the limit can flicker or drop out.",
                                   fix: "A lower refresh rate or a 4-lane connection gives it headroom."))
            }
            if link.isCompressedColour {
                out.append(Finding(level: .info,
                                   title: "Colour is sent as \(link.encoding ?? "YCbCr")",
                                   detail: "macOS squeezed the colour signal to fit \(link.modeLabel) through the link. Small coloured text can look slightly softer than with full RGB.",
                                   fix: nil))
            }
        } else if !s.externals.isEmpty {
            out.append(Finding(level: .info,
                               title: "No link details in the last \(Int(log.hoursSearched)) hours",
                               detail: log.error ?? "The display driver only logs link details when a mode changes. Change the refresh rate or replug the monitor, then refresh.",
                               fix: nil))
        }

        // 4. Weak power.
        if let c = s.charger, c.connected, let w = c.watts, w > 0, w < 30 {
            out.append(Finding(level: .warning,
                               title: "Only \(w)W of power is coming in",
                               detail: "The Mac sees a \(w)W power source\(c.name.map { " (\($0))" } ?? ""). Docks often pass through less power than the charger behind them. Clamshell mode needs steady power.",
                               fix: "Plug the MacBook's own charger straight into the Mac, or use a dock that passes through at least 30W."))
        }

        if !out.contains(where: { $0.level.rawValue <= Finding.Level.warning.rawValue }) {
            out.append(Finding(level: .ok, title: "No problems found", detail: "Displays, ports and power look fine.", fix: nil))
        }
        return out.sorted { $0.level.rawValue < $1.level.rawValue }
    }

    /// Plain-text report for GitHub issues. Leaves out serial numbers.
    static func report(_ s: SystemSnapshot) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        lines.append("PortSight report, \(df.string(from: s.date))")
        lines.append("\(MacInfo.model), \(MacInfo.osVersion)")
        if let lid = s.lidClosed { lines.append("Lid: \(lid ? "closed" : "open")") }

        lines.append("\nDISPLAYS")
        for d in s.displays {
            lines.append("- \(d.name) [\(d.roleText)]")
            lines.append("  Current: \(d.current?.label ?? "unknown")")
            if let m = d.monitor {
                var parts: [String] = []
                if let maker = m.manufacturer { parts.append(maker) }
                if let year = m.year { parts.append("made \(year)") }
                if let c = m.connection { parts.append("\(c) input") }
                if m.supportsHDR { parts.append("HDR") }
                if !parts.isEmpty { lines.append("  Monitor: " + parts.joined(separator: ", ")) }
            }
            let (w, h) = d.nativeSize
            lines.append("  Native: \(w)x\(h), highest refresh offered: \(DisplayMode.hz(d.highestRefresh)), \(d.modes.count) modes")
        }

        lines.append("\nVIDEO LINK (kernel log, last \(Int(s.log.hoursSearched))h)")
        if let link = s.log.latest {
            lines.append("  \(link.capacity.summary)")
            lines.append("  Last setup: \(link.modeLabel), \(link.colourLabel)\(link.ratio.map { ", \(Fmt.pct($0)) of bandwidth" } ?? "")\(link.dsc == true ? ", DSC on" : "")")
        } else {
            lines.append("  No link details found\(s.log.error.map { ": \($0)" } ?? "")")
        }
        if let open = s.log.linkWhileLid(closed: false) { lines.append("  Lid open: \(open.modeLabel), \(open.colourLabel)") }
        if let closed = s.log.linkWhileLid(closed: true) { lines.append("  Lid closed: \(closed.modeLabel), \(closed.colourLabel)") }

        lines.append("\nUSB-C PORTS")
        if s.ports.isEmpty { lines.append("  (no USB-C port info on this Mac)") }
        for p in s.ports { lines.append("  Port \(p.id): \(p.summary)") }

        lines.append("\nPOWER")
        if let c = s.charger {
            lines.append("  \(c.connected ? "\(c.name ?? "Power source"), \(c.watts.map { "\($0)W" } ?? "? W")" : "On battery")\(c.charging.map { $0 ? ", charging" : ", not charging" } ?? "")")
        } else { lines.append("  No battery (desktop Mac)") }

        lines.append("\nUSB DEVICES")
        for u in s.usb { lines.append("  \(u.name)\(u.isHubOrDock ? " (hub/dock)" : "")\(u.speed.map { ", \($0)" } ?? "")") }

        lines.append("\nFINDINGS")
        for f in s.findings {
            let tag = ["PROBLEM", "WARNING", "INFO", "OK"][f.level.rawValue]
            lines.append("  [\(tag)] \(f.title)")
            lines.append("    \(f.detail)")
            if let fix = f.fix { lines.append("    Fix: \(fix)") }
        }
        return lines.joined(separator: "\n")
    }
}
