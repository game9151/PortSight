import AppKit
import SwiftUI

/// Renders each page of the window to a PNG. Used to check the UI in CI or from a terminal.
enum PageRenderer {
    @MainActor
    static func run(directory: String, height: CGFloat = 1000) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let snapshot = Diagnosis.gather(logHours: 2)
        let model = AppModel(preloaded: snapshot)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let size = NSRect(x: 0, y: 0, width: 900, height: height)
        for page in Page.allCases {
            let view = PageContent(page: page, snapshot: snapshot)
                .environmentObject(model)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.frame = size
            let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = (directory as NSString).appendingPathComponent("\(page.rawValue.replacingOccurrences(of: " ", with: "-")).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("Wrote \(path)")
        }
        return 0
    }
}
