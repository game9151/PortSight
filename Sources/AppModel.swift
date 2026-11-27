import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    /// A change on probation: it reverts by itself unless kept.
    struct Trial {
        let title: String
        var secondsLeft: Int
        let keep: () -> Void
        let revert: () -> Void
    }

    @Published var snapshot: SystemSnapshot?
    @Published var loading = false
    @Published var logHours: Double = 2
    @Published var trial: Trial?
    @Published var activity: [String] = []
    @Published var events: [WatchEvent] = []
    @Published var launchAtLoginError: String?
    @Published var colourStates: [CGDirectDisplayID: FramebufferState] = [:]
    @Published var ddcValues: [CGDirectDisplayID: [VCP: DDCValue]] = [:]
    @Published var ddcChecked: Set<CGDirectDisplayID> = []

    private var trialTimer: Timer?
    private var ddcWrites: [String: DispatchWorkItem] = [:]

    /// For rendering previews: no watchers, no log reading.
    init(preloaded: SystemSnapshot) {
        snapshot = preloaded
        loadColourStates()
    }

    init() {
        LidWatcher.shared.onAction = { [weak self] message in
            Task { @MainActor in
                self?.note(message)
                self?.refreshDisplays()
            }
        }
        LidWatcher.shared.start()

        let watch = LiveWatch.shared
        watch.onEvent = { [weak self] event in
            Task { @MainActor in self?.record(event) }
        }
        watch.onLink = { [weak self] link in
            Task { @MainActor in self?.addLink(link) }
        }
        watch.onLid = { [weak self] lid in
            Task { @MainActor in
                self?.snapshot?.log.lidEvents.append(lid)
                self?.snapshot?.lidClosed = lid.closed
            }
        }
        if AppSettings.shared.liveWatch { watch.start() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            LiveWatch.shared.stopNow()
        }
        if AppSettings.shared.notifications { Notifier.requestPermission() }
        refresh()
    }

    var issueCount: Int { snapshot?.findings.filter { $0.level.rawValue <= Finding.Level.warning.rawValue }.count ?? 0 }
    var reportText: String { snapshot.map(Diagnosis.report) ?? "Still checking…" }

    func note(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        activity.insert("\(f.string(from: Date()))  \(message)", at: 0)
        if activity.count > 50 { activity.removeLast() }
    }

    private func record(_ event: WatchEvent) {
        events.insert(event, at: 0)
        if events.count > 200 { events.removeLast() }
    }

    private func addLink(_ link: LinkSnapshot) {
        guard var s = snapshot else { return }
        s.log.snapshots.append(link)
        s.displays = Displays.all()
        s.findings = Diagnosis.findings(for: s)
        snapshot = s
        loadColourStates()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        let hours = logHours
        Task.detached(priority: .userInitiated) {
            let result = Diagnosis.gather(logHours: hours)
            await MainActor.run {
                self.snapshot = result
                self.loading = false
                self.loadColourStates()
                LiveWatch.shared.seed(lastOpen: result.log.linkWhileLid(closed: false), last: result.log.latest)
            }
        }
    }

    func refreshDisplays() {
        guard let s = snapshot else { return }
        snapshot = Diagnosis.refreshDisplays(s)
        loadColourStates()
    }

    func loadColourStates() {
        guard Framebuffers.available, let displays = snapshot?.externals else { return }
        var states: [CGDirectDisplayID: FramebufferState] = [:]
        for d in displays { if let st = Framebuffers.state(for: d.id) { states[d.id] = st } }
        colourStates = states
    }

    // MARK: Trials (auto-revert after 15 seconds unless kept)

    private func startTrial(_ trial: Trial) {
        self.trial = trial
        trialTimer?.invalidate()
        trialTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard var t = trial else { return }
        t.secondsLeft -= 1
        if t.secondsLeft <= 0 { revertTrial() } else { trial = t }
    }

    func keepTrial() {
        guard let t = trial else { return }
        trialTimer?.invalidate()
        t.keep()
        trial = nil
        refreshDisplays()
    }

    func revertTrial() {
        guard let t = trial else { return }
        trialTimer?.invalidate()
        t.revert()
        trial = nil
        refreshDisplays()
    }

    func tryMode(_ mode: DisplayMode, on display: DisplayInfo) {
        guard trial == nil, let previous = display.current, !previous.matches(mode) else { return }
        let result = Displays.apply(mode, to: display.id, permanently: false)
        guard result == .success else {
            note("Couldn't switch \(display.name) to \(mode.label) (error \(result.rawValue))")
            return
        }
        note("Trying \(mode.label) on \(display.name)")
        let id = display.id, name = display.name
        startTrial(Trial(title: "Keep \(mode.label) on \(name)?", secondsLeft: 15,
            keep: { [weak self] in
                Displays.apply(mode, to: id, permanently: true)
                self?.note("Kept \(mode.label) on \(name)")
            },
            revert: { [weak self] in
                Displays.apply(previous, to: id, permanently: false)
                self?.note("Went back to \(previous.label) on \(name)")
            }))
        refreshDisplays()
    }

    func tryColour(_ colour: ColourMode, on display: DisplayInfo) {
        guard trial == nil, let state = colourStates[display.id], state.colourID != colour.id else { return }
        let previousID = state.colourID
        let previousLabel = state.currentColour?.label ?? "the previous format"
        let result = Framebuffers.setColour(colour.id, for: display.id)
        guard result == KERN_SUCCESS else {
            note("Couldn't switch \(display.name) to \(colour.label) (error \(result))")
            return
        }
        note("Trying \(colour.label) on \(display.name)")
        let id = display.id, name = display.name
        startTrial(Trial(title: "Keep \(colour.label) on \(name)?", secondsLeft: 15,
            keep: { [weak self] in self?.note("Kept \(colour.label) on \(name). macOS may pick its own format again after a mode change or replug.") },
            revert: { [weak self] in
                Framebuffers.setColour(previousID, for: id)
                self?.note("Went back to \(previousLabel) on \(name)")
            }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loadColourStates() }
    }

    // MARK: DDC

    func loadDDC(for display: DisplayInfo) {
        guard DDC.available, !display.isBuiltin, !ddcChecked.contains(display.id) else { return }
        ddcChecked.insert(display.id)
        let id = display.id
        DDC.queue.async {
            var values: [VCP: DDCValue] = [:]
            for vcp in VCP.allCases { if let v = DDC.read(vcp, display: id) { values[vcp] = v } }
            DispatchQueue.main.async { self.ddcValues[id] = values }
        }
    }

    /// Updates the slider at once and sends the value to the monitor after a short pause.
    func setDDC(_ vcp: VCP, value: Int, display: CGDirectDisplayID) {
        ddcValues[display]?[vcp]?.current = value
        let key = "\(display)-\(vcp.rawValue)"
        ddcWrites[key]?.cancel()
        let work = DispatchWorkItem { DDC.write(vcp, value: value, display: display) }
        ddcWrites[key] = work
        DDC.queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Misc

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
        note("Report copied to the clipboard")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "Couldn't change this: \(error.localizedDescription). Move PortSight to Applications and try again."
            }
            objectWillChange.send()
        }
    }
}
