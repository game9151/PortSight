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
    """

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
