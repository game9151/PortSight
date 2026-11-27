import Foundation
import IOKit

/// Small wrappers around the IORegistry and command-line tools.
enum IOReg {
    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    /// Properties of every IOService of the given class (subclasses included).
    static func services(matching className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            result.append(properties(entry))
            IOObjectRelease(entry)
        }
        return result
    }

    /// true when the MacBook lid is closed, nil on Macs without a lid.
    static func clamshellClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}

enum Shell {
    /// Runs a tool and returns its standard output ("" if it can't start).
    static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func json(_ path: String, _ args: [String]) -> [String: Any]? {
        let text = run(path, args)
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum Fmt {
    static func pct(_ ratio: Double) -> String { String(format: "%.0f%%", ratio * 100) }
    static func gbps(_ value: Double) -> String { String(format: "%.2f Gbps", value) }
}

enum MacInfo {
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
