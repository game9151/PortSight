import Foundation

/// One video link setup, as the display driver logged it.
struct LinkSnapshot: Codable {
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

struct LidEvent: Codable {
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

/// Turns display-driver log lines into link snapshots and lid events. Used for history and live watching.
final class LinkLogParser {
    enum Event {
        case link(LinkSnapshot)
        case lid(LidEvent)
    }

    static let predicate = #"process == "kernel" AND (eventMessage CONTAINS "validateVideo" OR eventMessage CONTAINS "mode_set_gated" OR eventMessage CONTAINS "PMRD: clamshell closed")"#

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private let skipInternalPipe: Bool
    private var current: LinkSnapshot?
    private var lastLidState: Bool?

    init(skipInternalPipe: Bool, lastLidState: Bool? = nil) {
        self.skipInternalPipe = skipInternalPipe
        self.lastLidState = lastLidState
    }

    func feed(_ line: String) -> [Event] {
        guard line.count > 23, let time = LinkLogParser.stamp.date(from: String(line.prefix(23))) else { return [] }
        var out: [Event] = []

        if let m = match(#"clamshell closed (\d)"#, line) {
            let closed = m[0] == "1"
            if lastLidState != closed {
                lastLidState = closed
                out.append(.lid(LidEvent(time: time, closed: closed)))
            }
            return out
        }
        let pipe = match(#"[\(\[](DCP[A-Z0-9]*)[\):]"#, line)?[0] ?? "?"
        // On laptops, "DCP" drives the built-in panel. Externals use DCPEXT pipes.
        if skipInternalPipe && pipe == "DCP" { return out }

        if let m = match(#"Validating link @ (\d+) lanes and (\d+)"#, line) {
            out += flush()
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
                out += flush()
            }
        }
        return out
    }

    func flush() -> [Event] {
        defer { current = nil }
        if let c = current, c.lanes > 0 { return [.link(c)] }
        return []
    }

    private func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// Reads link history from the kernel log. Results are cached on disk, so only the
/// time since the last read gets scanned again (the slow part of `log show`).
enum KernelLog {
    private struct Cache: Codable {
        var start: Date
        var end: Date
        var snapshots: [LinkSnapshot]
        var lidEvents: [LidEvent]
    }

    private static let lock = NSLock()
    private static let keepDays = 7.0

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortSight", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("link-history.json")
    }

    private static func loadCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Cache.self, from: data)
    }

    private static func saveCache(_ cache: Cache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// Scans one time range. Returns nil if the log can't be read at all.
    private static func scan(from: Date, to: Date, skipInternalPipe: Bool) -> ([LinkSnapshot], [LidEvent])? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = Shell.run("/usr/bin/log", ["show", "--start", f.string(from: from), "--end", f.string(from: to),
                                              "--style", "compact", "--predicate", LinkLogParser.predicate])
        guard text.contains("Timestamp") else { return nil }
        let parser = LinkLogParser(skipInternalPipe: skipInternalPipe)
        var snaps: [LinkSnapshot] = []
        var lids: [LidEvent] = []
        for line in text.split(separator: "\n") {
            for event in parser.feed(String(line)) {
                switch event {
                case .link(let s): snaps.append(s)
                case .lid(let l): lids.append(l)
                }
            }
        }
        for case .link(let s) in parser.flush() { snaps.append(s) }
        return (snaps, lids)
    }

    private static func dedupeLid(_ events: [LidEvent]) -> [LidEvent] {
        var out: [LidEvent] = []
        for e in events.sorted(by: { $0.time < $1.time }) where out.last?.closed != e.closed { out.append(e) }
        return out
    }

    static func read(hours: Double, hasBuiltinDisplay: Bool) -> KernelLogResult {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let want = now.addingTimeInterval(-hours * 3600)
        var result = KernelLogResult(hoursSearched: hours)
        var cache = loadCache() ?? Cache(start: now, end: now, snapshots: [], lidEvents: [])

        if want < cache.start {
            guard let (s, l) = scan(from: want, to: cache.start, skipInternalPipe: hasBuiltinDisplay) else {
                result.error = "macOS didn't let PortSight read the kernel log. Reading the log needs an administrator account."
                return result
            }
            cache.snapshots = s + cache.snapshots
            cache.lidEvents = l + cache.lidEvents
            cache.start = want
        }
        if cache.end < now, let (s, l) = scan(from: cache.end, to: now, skipInternalPipe: hasBuiltinDisplay) {
            cache.snapshots += s
            cache.lidEvents += l
            cache.end = now
        }
        let cutoff = now.addingTimeInterval(-keepDays * 86400)
        cache.snapshots = cache.snapshots.filter { $0.time >= cutoff }.sorted { $0.time < $1.time }
        cache.lidEvents = dedupeLid(cache.lidEvents.filter { $0.time >= cutoff })
        cache.start = max(cache.start, cutoff)
        saveCache(cache)

        result.snapshots = cache.snapshots.filter { $0.time >= want }
        result.lidEvents = cache.lidEvents.filter { $0.time >= want }
        // Keep the lid state from just before the window, so "lid closed" still resolves.
        if let before = cache.lidEvents.last(where: { $0.time < want }) { result.lidEvents.insert(before, at: 0) }
        if result.snapshots.isEmpty, let before = cache.snapshots.last(where: { $0.time < want }) { result.snapshots = [before] }
        return result
    }

    /// Adds live events to the cache so the next history read doesn't rescan them.
    static func append(_ event: LinkLogParser.Event) {
        lock.lock(); defer { lock.unlock() }
        guard var cache = loadCache() else { return }
        switch event {
        case .link(let s): cache.snapshots.append(s)
        case .lid(let l): cache.lidEvents = dedupeLid(cache.lidEvents + [l])
        }
        cache.end = Date()
        saveCache(cache)
    }

    static func clearCache() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
