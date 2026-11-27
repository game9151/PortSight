import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct ModeTrial {
        let displayID: CGDirectDisplayID
        let displayName: String
        let mode: DisplayMode
        let previous: DisplayMode
        var secondsLeft: Int
    }

    @Published var snapshot: SystemSnapshot?
    @Published var loading = false
    @Published var logHours: Double = 2
    @Published var trial: ModeTrial?
    @Published var activity: [String] = []
    @Published var launchAtLoginError: String?

    private var trialTimer: Timer?

    /// For rendering previews: no lid watcher, no log reading.
    init(preloaded: SystemSnapshot) {
        snapshot = preloaded
    }

    init() {
        LidWatcher.shared.onAction = { [weak self] message in
            Task { @MainActor in
                self?.note(message)
                self?.refreshDisplays()
            }
        }
        LidWatcher.shared.start()
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

    func refresh() {
        guard !loading else { return }
        loading = true
        let hours = logHours
        Task.detached(priority: .userInitiated) {
            let result = Diagnosis.gather(logHours: hours)
            await MainActor.run {
                self.snapshot = result
                self.loading = false
            }
        }
    }

    func refreshDisplays() {
        guard let s = snapshot else { return }
        snapshot = Diagnosis.refreshDisplays(s)
    }

    // MARK: Trying a mode (auto-reverts after 15 seconds unless kept)

    func tryMode(_ mode: DisplayMode, on display: DisplayInfo) {
        guard trial == nil, let previous = display.current, !previous.matches(mode) else { return }
        let result = Displays.apply(mode, to: display.id, permanently: false)
        guard result == .success else {
            note("Couldn't switch \(display.name) to \(mode.label) (error \(result.rawValue))")
            return
        }
        note("Trying \(mode.label) on \(display.name)")
        trial = ModeTrial(displayID: display.id, displayName: display.name, mode: mode, previous: previous, secondsLeft: 15)
        trialTimer?.invalidate()
        trialTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshDisplays()
    }

    private func tick() {
        guard var t = trial else { return }
        t.secondsLeft -= 1
        if t.secondsLeft <= 0 { revertTrial() } else { trial = t }
    }

    func keepTrial() {
        guard let t = trial else { return }
        trialTimer?.invalidate()
        Displays.apply(t.mode, to: t.displayID, permanently: true)
        note("Kept \(t.mode.label) on \(t.displayName)")
        trial = nil
        refreshDisplays()
    }

    func revertTrial() {
        guard let t = trial else { return }
        trialTimer?.invalidate()
        Displays.apply(t.previous, to: t.displayID, permanently: false)
        note("Went back to \(t.previous.label) on \(t.displayName)")
        trial = nil
        refreshDisplays()
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
