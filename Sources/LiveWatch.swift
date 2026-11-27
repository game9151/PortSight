import Foundation
import IOKit.ps
import UserNotifications

struct WatchEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let level: Finding.Level
    let title: String
    let detail: String
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var liveWatch: Bool { didSet { defaults.set(liveWatch, forKey: "liveWatch"); liveWatch ? LiveWatch.shared.start() : LiveWatch.shared.stop() } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications"); if notifications { Notifier.requestPermission() } } }

    private init() {
        defaults.register(defaults: ["liveWatch": true, "notifications": true])
        liveWatch = defaults.bool(forKey: "liveWatch")
        notifications = defaults.bool(forKey: "notifications")
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ event: WatchEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.detail
        content.sound = event.level == .problem ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
    }
}

/// Follows the kernel log live (`log stream`) and polls power and USB-C ports,
/// turning changes into events and, for problems, notifications.
final class LiveWatch {
    static let shared = LiveWatch()

    /// Called on the main queue.
    var onEvent: ((WatchEvent) -> Void)?
    var onLink: ((LinkSnapshot) -> Void)?
    var onLid: ((LidEvent) -> Void)?
    /// For the command-line `--watch`: print raw events too.
    var verbose = false
    /// Off for the command line, which has no notification permission.
    var allowNotifications = true

    private var process: Process?
    private var stopped = true
    private var buffer = Data()
    private let queue = DispatchQueue(label: "PortSight.livewatch")
    private var parser = LinkLogParser(skipInternalPipe: true)
    private var pollTimer: DispatchSourceTimer?

    private var lastLink: LinkSnapshot?
    private var lastOpenLink: LinkSnapshot?
    private var lastWatts: Int?
    private var lastPorts: [Int: [String]] = [:]
    private var recentTitles: [String: Date] = [:]

    var isRunning: Bool { !stopped }

    func start() {
        queue.async { [self] in
            guard stopped else { return }
            stopped = false
            let hasBuiltin = IOReg.clamshellClosed() != nil
            parser = LinkLogParser(skipInternalPipe: hasBuiltin, lastLidState: IOReg.clamshellClosed())
            lastWatts = LiveWatch.adapterWatts()
            lastPorts = Dictionary(uniqueKeysWithValues: Connections.ports().map { ($0.id, $0.active) })
            launchStream()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            pollTimer = timer
        }
    }

    /// Stops the log reader right away (used when the app quits).
    func stopNow() {
        stopped = true
        process?.terminationHandler = nil
        process?.terminate()
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pollTimer?.cancel(); pollTimer = nil
            process?.terminationHandler = nil
            process?.terminate(); process = nil
        }
    }

    /// Seeds the "lid open" reference from history so the first lid close can be compared.
    func seed(lastOpen: LinkSnapshot?, last: LinkSnapshot?) {
        queue.async { [self] in
            if lastOpenLink == nil { lastOpenLink = lastOpen }
            if lastLink == nil { lastLink = last }
        }
    }

    private func launchStream() {
        // Run `log stream` under a small shell guard that stops it when PortSight exits for any reason,
        // including a crash or being killed, so it never lingers in the background.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let guardScript = """
        parent=$PPID
        /usr/bin/log stream --style compact --predicate "$1" &
        child=$!
        trap 'kill $child 2>/dev/null; exit 0' TERM INT HUP
        while kill -0 "$parent" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 2; done
        kill $child 2>/dev/null
        """
        p.arguments = ["-c", guardScript, "portsight-watch", LinkLogParser.predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.stopped else { return }
                self.launchStream()
            }
        }
        do { try p.run(); process = p } catch { process = nil }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            for event in parser.feed(line) { handle(event) }
        }
        // A link setup ends with its mode line; if that never comes, flush after a short pause.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            for event in self.parser.flush() { self.handle(event) }
        }
    }

    private func handle(_ event: LinkLogParser.Event) {
        KernelLog.append(event)
        switch event {
        case .lid(let lid):
            DispatchQueue.main.async { self.onLid?(lid) }
            emit(.info, "Lid \(lid.closed ? "closed" : "opened")", "", notify: false)
        case .link(let s):
            DispatchQueue.main.async { self.onLink?(s) }
            evaluate(s)
        }
    }

    private func evaluate(_ s: LinkSnapshot) {
        let lidClosed = IOReg.clamshellClosed() == true
        let previous = lastLink
        emit(.info, "Monitor set to \(s.modeLabel)", "\(s.colourLabel), \(s.capacity.summary)\(s.ratio.map { ", \(Fmt.pct($0)) of bandwidth" } ?? "")", notify: false)

        if lidClosed, let open = lastOpenLink, let r = s.refresh, let o = open.refresh, abs(r - o) > 1 {
            emit((s.ratio ?? 0) > 0.9 ? .problem : .warning,
                 "Lid closed: monitor switched to \(DisplayMode.hz(r))",
                 "With the lid open it ran at \(DisplayMode.hz(o)). If the screen went black, set a lid-closed mode in PortSight's Lid Profiles.")
        }
        if let p = previous {
            if s.lanes < p.lanes || s.perLaneGbps < p.perLaneGbps - 0.1 {
                emit(.warning, "The monitor link got slower",
                     "It went from \(p.capacity.summary) to \(s.capacity.summary). A cable, adapter or dock may have renegotiated.")
            }
            if s.isCompressedColour && !p.isCompressedColour {
                emit(.warning, "Colour dropped to \(s.encoding ?? "YCbCr")",
                     "\(s.modeLabel) doesn't fit the link in full RGB, so macOS squeezed the colour.")
            }
        }
        if let ratio = s.ratio, ratio > 0.95 {
            emit(.warning, "The cable is \(Fmt.pct(ratio)) full",
                 "\(s.modeLabel) is right at the limit of this link. If the monitor flickers or drops out, try a lower refresh rate.")
        }
        lastLink = s
        if !lidClosed { lastOpenLink = s }
    }

    static func adapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else { return nil }
        return (details[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
    }

    private func poll() {
        let watts = LiveWatch.adapterWatts()
        if watts != lastWatts {
            if let w = watts, w < 30, (lastWatts ?? 0) >= 30 || lastWatts == nil {
                emit(.warning, "Power dropped to \(w)W", "The Mac is now getting \(w)W. Docks often pass through much less than the charger behind them.")
            } else if watts == nil, lastWatts != nil {
                emit(.info, "Power disconnected", "The Mac is running on battery.", notify: false)
            } else if let w = watts {
                emit(.info, "Power source: \(w)W", "", notify: false)
            }
            lastWatts = watts
        }
        let ports = Dictionary(uniqueKeysWithValues: Connections.ports().map { ($0.id, $0.active) })
        for (id, active) in ports {
            let before = lastPorts[id] ?? []
            if before.contains("DisplayPort") && !active.contains("DisplayPort") {
                emit(.warning, "Monitor link lost on port \(id)", "DisplayPort stopped on this USB-C port. Check the cable or dock.")
            } else if !before.contains("DisplayPort") && active.contains("DisplayPort") {
                emit(.info, "Monitor connected on port \(id)", active.contains("USB3") ? "Sharing the cable with USB 3, so 2 lanes." : "", notify: false)
            }
        }
        lastPorts = ports
    }

    private func emit(_ level: Finding.Level, _ title: String, _ detail: String, notify: Bool = true) {
        let event = WatchEvent(level: level, title: title, detail: detail)
        if verbose {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            print("\(f.string(from: event.date))  \(title)\(detail.isEmpty ? "" : " - \(detail)")")
            fflush(stdout)
        }
        let isRepeat = recentTitles[title].map { Date().timeIntervalSince($0) < 60 } ?? false
        recentTitles[title] = Date()
        let shouldNotify = notify && !isRepeat && level.rawValue <= Finding.Level.warning.rawValue
        DispatchQueue.main.async {
            self.onEvent?(event)
            if shouldNotify && self.allowNotifications && AppSettings.shared.notifications { Notifier.post(event) }
        }
    }
}
