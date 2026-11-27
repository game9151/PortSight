import CoreGraphics
import Foundation

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.first?.hasPrefix("-psn") == true || args.first == "-NSDocumentRevisionsDebugMode" {
            PortSightApp.main()
            return
        }
        exit(CLI.run(args))
    }
}

/// Command-line mode: handy when the screen is black and you can only reach the Mac over SSH.
enum CLI {
    static let help = """
    PortSight: display, dock and cable diagnostics for macOS.

    Usage:
      PortSight                         open the menu bar app
      PortSight --report [--hours N]    print a diagnostics report (default: last 2 hours of log)
      PortSight --list                  list displays and their modes
      PortSight --set WxH@HZ [--display ID]
                                        switch a display (default: first external) and save it
      PortSight --watch                 follow display, link, lid and power changes live
      PortSight --advice                best connection for each external monitor
      PortSight --colours [--display ID]          list colour formats for the current mode
      PortSight --set-colour ID [--display ID]    switch colour format (experimental)
      PortSight --ddc [brightness|contrast|volume] [VALUE] [--display ID]
                                        read or set the monitor's own controls
      PortSight --clear-cache           forget saved link history
    """

    static func pick(_ idText: String?) -> DisplayInfo? {
        let displays = Displays.all()
        if let t = idText, let id = UInt32(t) { return displays.first { $0.id == id } }
        return displays.first { !$0.isBuiltin }
    }

    static func run(_ args: [String]) -> Int32 {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        switch args.first {
        case "--report":
            let hours = value(after: "--hours").flatMap(Double.init) ?? 2
            print(Diagnosis.report(Diagnosis.gather(logHours: hours)))
            return 0
        case "--render-pages":
            // Developer check: draws each window page to PNG files without needing screen recording.
            guard let dir = value(after: "--render-pages") else { print("Give a folder"); return 1 }
            return MainActor.assumeIsolated { PageRenderer.run(directory: dir) }
        case "--watch":
            let watch = LiveWatch.shared
            watch.verbose = true
            watch.allowNotifications = false
            print("Watching display, link, lid, power and port changes. Press Ctrl-C to stop.")
            fflush(stdout)
            watch.start()
            dispatchMain()
        case "--advice":
            let snap = Diagnosis.gather(logHours: 2)
            for d in snap.externals {
                guard let a = Advisor.advice(for: d, current: snap.capacity) else { continue }
                print("\(a.display)\n  \(a.summary)")
                for r in a.rows {
                    let rgb = r.bestRGB.map(DisplayMode.hz) ?? "-", y = r.best422.map(DisplayMode.hz) ?? "-"
                    print("  \(r.option.isCurrent ? "*" : " ") \(r.option.name.padding(toLength: 18, withPad: " ", startingAt: 0)) RGB \(rgb.padding(toLength: 6, withPad: " ", startingAt: 0)) 4:2:2 \(y.padding(toLength: 6, withPad: " ", startingAt: 0)) \(r.option.example)")
                }
            }
            return 0
        case "--colours", "--set-colour":
            guard let display = pick(value(after: "--display")) else { print("No external display found"); return 1 }
            guard let state = Framebuffers.state(for: display.id) else { print("Colour formats aren't available for \(display.name) on this Mac."); return 1 }
            if args.first == "--colours" {
                print("\(display.name): current \(state.currentColour?.label ?? "ID \(state.colourID)")")
                for c in state.choices { print("  \(c.id)  \(c.label)\(c.id == state.colourID ? "  (current)" : "")") }
                return 0
            }
            guard let idText = value(after: "--set-colour"), let id = UInt32(idText), state.choices.contains(where: { $0.id == id }) else {
                print("Give one of the IDs from --colours"); return 1
            }
            let r = Framebuffers.setColour(id, for: display.id)
            print(r == KERN_SUCCESS ? "Switched \(display.name) colour format" : "Failed (error \(r))")
            return r == KERN_SUCCESS ? 0 : 1
        case "--ddc":
            guard DDC.available else { print("DDC needs an Apple silicon Mac."); return 1 }
            guard let display = pick(value(after: "--display")) else { print("No external display found"); return 1 }
            let name = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil
            let chosen = VCP.allCases.filter { name == nil || $0.name.lowercased() == name!.lowercased() }
            guard !chosen.isEmpty else { print("Use brightness, contrast or volume"); return 1 }
            if args.count > 2, !args[2].hasPrefix("--"), let v = Int(args[2]), let vcp = chosen.first {
                let ok = DDC.queue.sync { DDC.write(vcp, value: v, display: display.id) }
                print(ok ? "Set \(vcp.name) to \(v)" : "The monitor didn't accept it"); return ok ? 0 : 1
            }
            for vcp in chosen {
                let v = DDC.queue.sync { DDC.read(vcp, display: display.id) }
                print("\(vcp.name): \(v.map { "\($0.current) of \($0.max)" } ?? "not available")")
            }
            return 0
        case "--clear-cache":
            KernelLog.clearCache()
            print("Link history cleared")
            return 0
        case "--list":
            for d in Displays.all() {
                print("\(d.id)  \(d.name)  [\(d.roleText)]  current: \(d.current?.label ?? "?")")
                for m in d.nativeModes { print("      \(m.label)") }
            }
            return 0
        case "--set":
            guard let text = value(after: "--set"), let want = DisplayMode.parse(text) else {
                print("Give a mode like 3440x1440@120"); return 1
            }
            let displays = Displays.all()
            let target: DisplayInfo?
            if let idText = value(after: "--display"), let id = UInt32(idText) {
                target = displays.first { $0.id == id }
            } else {
                target = displays.first { !$0.isBuiltin } ?? displays.first
            }
            guard let display = target else { print("No display found"); return 1 }
            let candidates = display.modes.filter { $0.width == want.width && $0.height == want.height && abs($0.refresh - want.hz) < 0.6 }
            guard let mode = candidates.first(where: { !$0.isHiDPI }) ?? candidates.first else {
                print("\(display.name) has no \(text) mode. Run --list to see the options."); return 1
            }
            let result = Displays.apply(mode, to: display.id, permanently: true)
            print(result == .success ? "Set \(display.name) to \(mode.label)" : "Failed (error \(result.rawValue))")
            return result == .success ? 0 : 1
        default:
            print(help)
            return args.first == "--help" || args.first == "-h" ? 0 : 1
        }
    }
}
