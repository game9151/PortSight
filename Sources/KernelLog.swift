import Foundation

/// One video link setup, as the display driver logged it.
struct LinkSnapshot {
    var time: Date
    var pipe: String
    var lanes = 0
    var perLaneGbps = 0.0
    var bpc: Int?
    var encoding: String?
    var range: String?
    var refresh: Double?
    var pixelClock: Double?
    var dsc: Bool?
    var videoGbps: Double?
    var usableGbps: Double?
    var width: Int?
    var height: Int?
    var activeHeight: Int?

    var ratio: Double? {
        guard let v = videoGbps, let u = usableGbps, u > 0 else { return nil }
        return v / u
    }
    var isCompressedColour: Bool { (encoding ?? "").contains("4:2:2") || (encoding ?? "").contains("4:2:0") }
    var capacity: LinkCapacity { LinkCapacity(lanes: lanes, perLaneGbps: perLaneGbps, measured: true) }

    var modeLabel: String {
        var s = ""
        if let w = width, let h = height { s = "\(w)x\(h)" } else if let h = activeHeight { s = "?x\(h)" }
        if let r = refresh { s += " @ \(DisplayMode.hz(r))" }
        return s.isEmpty ? "unknown mode" : s
    }

    var colourLabel: String {
        guard let enc = encoding else { return "unknown colour format" }
        return "\(enc)\(bpc.map { " \($0)-bit" } ?? "")"
    }
}

struct LidEvent {
    let time: Date
    let closed: Bool
}

struct KernelLogResult {
    var snapshots: [LinkSnapshot] = []
    var lidEvents: [LidEvent] = []
    var hoursSearched: Double = 0
    var error: String?

    var latest: LinkSnapshot? { snapshots.last }

    /// The link setup in force after the most recent lid event of this kind.
    func linkWhileLid(closed: Bool) -> LinkSnapshot? {
        guard let event = lidEvents.last(where: { $0.closed == closed }) else { return nil }
        if let after = snapshots.first(where: { $0.time >= event.time && $0.time.timeIntervalSince(event.time) <= 6 }) {
            return after
        }
        return snapshots.last(where: { $0.time < event.time })
    }
}

enum KernelLog {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func read(hours: Double, hasBuiltinDisplay: Bool) -> KernelLogResult {
        var result = KernelLogResult(hoursSearched: hours)
        let predicate = #"process == "kernel" AND (eventMessage CONTAINS "validateVideo" OR eventMessage CONTAINS "mode_set_gated" OR eventMessage CONTAINS "PMRD: clamshell closed")"#
        let minutes = max(1, Int(hours * 60))
        let text = Shell.run("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "compact", "--predicate", predicate])
        if text.isEmpty {
            result.error = "macOS didn't return any kernel log lines. Reading the log needs an administrator account."
            return result
        }
        var current: LinkSnapshot?
        func finish() { if let c = current, c.lanes > 0 { result.snapshots.append(c) }; current = nil }

        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.count > 23, let time = stamp.date(from: String(line.prefix(23))) else { continue }

            if let m = match(#"clamshell closed (\d)"#, line) {
                let closed = m[0] == "1"
                if result.lidEvents.last?.closed != closed { result.lidEvents.append(LidEvent(time: time, closed: closed)) }
                continue
            }
            let pipe = match(#"[\(\[](DCP[A-Z0-9]*)[\):]"#, line)?[0] ?? "?"
            // On laptops, "DCP" drives the built-in panel. Externals use DCPEXT pipes.
            if hasBuiltinDisplay && pipe == "DCP" { continue }

            if let m = match(#"Validating link @ (\d+) lanes and (\d+)"#, line) {
                finish()
                current = LinkSnapshot(time: time, pipe: pipe)
                current?.lanes = Int(m[0]) ?? 0
                current?.perLaneGbps = (Double(m[1]) ?? 0) / 1e9
            } else if current != nil, current?.pipe == pipe {
                if let m = match(#"Color: depth=(\d+)bpc encoding=\d+ \[([^\]]+)\] range=\d+ \[([^\]]+)\]"#, line) {
                    current?.bpc = Int(m[0]); current?.encoding = m[1]; current?.range = m[2]
                } else if let m = match(#"active=(\d+) syncRate=([\d.]+)Hz"#, line) {
                    current?.activeHeight = Int(m[0]); current?.refresh = Double(m[1])
                } else if let m = match(#"pixelClock=(\d+)"#, line) {
                    current?.pixelClock = Double(m[0])
                } else if let m = match(#"dsc=(YES|NO).*videoBandwidth=(\d+)bps usableBandwidth=(\d+)bps"#, line) {
                    current?.dsc = m[0] == "YES"
                    current?.videoGbps = (Double(m[1]) ?? 0) / 1e9
                    current?.usableGbps = (Double(m[2]) ?? 0) / 1e9
                } else if let m = match(#"mode_set_gated\(uint32_t, uint32_t\): (\d+)x(\d+)@(\d+) Hz"#, line) {
                    current?.width = Int(m[0]); current?.height = Int(m[1])
                    if current?.refresh == nil { current?.refresh = Double(m[2]) }
                    finish()
                }
            }
        }
        finish()
        return result
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
