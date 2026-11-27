import CoreGraphics
import Foundation

/// Which mode a display should use with the lid open and with it closed.
struct LidProfile: Codable, Equatable {
    var open: DisplayMode?
    var closed: DisplayMode?
}

final class LidProfileStore: ObservableObject {
    static let shared = LidProfileStore()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "lidProfilesEnabled") } }
    @Published var profiles: [String: LidProfile] { didSet { save() } }

    private init() {
        enabled = defaults.bool(forKey: "lidProfilesEnabled")
        if let data = defaults.data(forKey: "lidProfiles"),
           let decoded = try? JSONDecoder().decode([String: LidProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = [:]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "lidProfiles") }
    }

    func setMode(_ mode: DisplayMode?, forKey key: String, lidClosed: Bool) {
        var profile = profiles[key] ?? LidProfile()
        if lidClosed { profile.closed = mode } else { profile.open = mode }
        profiles[key] = profile
    }
}

/// Watches the lid. For 10 seconds after it opens or closes, makes sure each external display
/// is on the mode its profile asks for. Outside that window it leaves your manual changes alone.
final class LidWatcher {
    static let shared = LidWatcher()
    var onAction: ((String) -> Void)?

    private var lastState: Bool?
    private var enforceUntil = Date.distantPast
    private var lastAttempt: [String: Date] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LidWatcher.shared.check() }
        }, nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in LidWatcher.shared.check() }
        check()
    }

    static func lidClosed() -> Bool {
        if let closed = IOReg.clamshellClosed() { return closed }
        let ids = Displays.onlineIDs()
        let hasBuiltin = ids.contains { CGDisplayIsBuiltin($0) != 0 }
        return hasBuiltin && !ids.contains { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
    }

    func check() {
        let closed = LidWatcher.lidClosed()
        if closed != lastState {
            lastState = closed
            enforceUntil = Date().addingTimeInterval(10)
        }
        let store = LidProfileStore.shared
        guard store.enabled, Date() < enforceUntil else { return }

        for id in Displays.onlineIDs() where CGDisplayIsBuiltin(id) == 0 {
            let key = Displays.key(for: id)
            guard let profile = store.profiles[key], let target = closed ? profile.closed : profile.open,
                  let current = CGDisplayCopyDisplayMode(id).map(DisplayMode.init), !current.matches(target) else { continue }
            if let last = lastAttempt[key], Date().timeIntervalSince(last) < 2 { continue }
            lastAttempt[key] = Date()
            let result = Displays.apply(target, to: id, permanently: true)
            let name = Displays.screenName(id) ?? "External display"
            onAction?("Lid \(closed ? "closed" : "opened"): set \(name) from \(current.label) to \(target.label)\(result == .success ? "" : " (failed, error \(result.rawValue))")")
        }
    }
}
