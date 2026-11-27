import Foundation

enum PixelFormat: String, CaseIterable {
    case rgb10 = "RGB 10-bit"
    case rgb8 = "RGB 8-bit"
    case ycc422 = "YCbCr 4:2:2"
    case ycc420 = "YCbCr 4:2:0"

    var bitsPerPixel: Double {
        switch self {
        case .rgb10: return 30
        case .rgb8: return 24
        case .ycc422: return 16
        case .ycc420: return 12
        }
    }
}

/// How much video a DisplayPort link can carry.
struct LinkCapacity {
    var lanes: Int
    var perLaneGbps: Double
    var measured: Bool

    var usableGbps: Double {
        let efficiency = perLaneGbps >= 10 ? 128.0 / 132.0 : 0.8   // 128b/132b for DP 2.x, 8b/10b before
        return Double(lanes) * perLaneGbps * efficiency
    }

    var speedName: String {
        switch perLaneGbps {
        case ..<2.0: return "RBR (DP 1.1)"
        case ..<3.0: return "HBR (DP 1.1)"
        case ..<6.0: return "HBR2 (DP 1.2)"
        case ..<9.0: return "HBR3 (DP 1.3/1.4)"
        default: return "UHBR (DP 2.x)"
        }
    }

    var summary: String {
        "\(lanes) lane\(lanes == 1 ? "" : "s") x \(String(format: "%.1f", perLaneGbps)) Gbps, \(speedName), \(Fmt.gbps(usableGbps)) usable\(measured ? "" : " (estimated)")"
    }
}

enum Fit: String {
    case fits = "Fits"
    case tight = "Tight"
    case tooMuch = "Too much"
}

enum Bandwidth {
    /// Pixel clock estimate using CVT reduced-blanking v2 (80-pixel horizontal blank, 460 µs vertical blank).
    static func pixelClockHz(width: Int, height: Int, refresh: Double) -> Double {
        let hTotal = Double(width + 80)
        let activeFraction = max(0.5, 1 - 460e-6 * refresh)
        let vTotal = (Double(height) / activeFraction).rounded(.up)
        return hTotal * vTotal * refresh
    }

    static func requiredGbps(width: Int, height: Int, refresh: Double, format: PixelFormat) -> Double {
        pixelClockHz(width: width, height: height, refresh: refresh) * format.bitsPerPixel / 1e9
    }

    static func fit(_ required: Double, _ capacity: LinkCapacity) -> (Fit, Double) {
        let ratio = required / max(capacity.usableGbps, 0.001)
        if ratio <= 0.9 { return (.fits, ratio) }
        if ratio <= 1.0 { return (.tight, ratio) }
        return (.tooMuch, ratio)
    }

    /// Best colour format that fits this mode on this link (nil if nothing fits without DSC).
    static func bestFormat(width: Int, height: Int, refresh: Double, capacity: LinkCapacity) -> PixelFormat? {
        for format in [PixelFormat.rgb8, .ycc422, .ycc420] {
            if fit(requiredGbps(width: width, height: height, refresh: refresh, format: format), capacity).0 != .tooMuch { return format }
        }
        return nil
    }
}

/// "What would it take?" advice for one external display.
struct ConnectionOption: Identifiable {
    let id = UUID()
    let name: String
    let example: String
    let capacity: LinkCapacity
    var isCurrent = false
}

struct AdviceRow: Identifiable {
    let id = UUID()
    let option: ConnectionOption
    let bestRGB: Double?        // highest native refresh in full RGB 8-bit
    let best422: Double?        // highest native refresh allowing YCbCr 4:2:2
}

struct Advice {
    let display: String
    let monitorMax: Double
    let rows: [AdviceRow]
    let summary: String
}

enum Advisor {
    static func options(current: LinkCapacity?) -> [ConnectionOption] {
        var list = [
            ConnectionOption(name: "DP 1.2, 2 lanes", example: "Older USB-C hubs with USB 3 ports", capacity: .init(lanes: 2, perLaneGbps: 5.4, measured: false)),
            ConnectionOption(name: "HDMI 2.0", example: "Most hubs' HDMI port", capacity: .init(lanes: 4, perLaneGbps: 4.5, measured: false)),
            ConnectionOption(name: "DP 1.4, 2 lanes", example: "USB-C docks with USB 3 + DisplayPort", capacity: .init(lanes: 2, perLaneGbps: 8.1, measured: false)),
            ConnectionOption(name: "DP 1.2, 4 lanes", example: "Older direct USB-C to DisplayPort cables", capacity: .init(lanes: 4, perLaneGbps: 5.4, measured: false)),
            ConnectionOption(name: "DP 1.4, 4 lanes", example: "Direct USB-C to DisplayPort 1.4 cable, Thunderbolt dock", capacity: .init(lanes: 4, perLaneGbps: 8.1, measured: false)),
        ]
        if let cur = current {
            if let i = list.firstIndex(where: { $0.capacity.lanes == cur.lanes && abs($0.capacity.perLaneGbps - cur.perLaneGbps) < 0.2 }) {
                list[i].isCurrent = true
            } else {
                list.insert(ConnectionOption(name: "Your link", example: cur.summary, capacity: cur, isCurrent: true), at: 0)
            }
        }
        return list
    }

    static func advice(for display: DisplayInfo, current: LinkCapacity?) -> Advice? {
        guard !display.isBuiltin else { return nil }
        let (w, h) = display.nativeSize
        let rates = Array(Set(display.nativeModes.map { ($0.refresh * 100).rounded() / 100 })).sorted(by: >)
        guard w > 0, let top = rates.first else { return nil }

        func best(_ cap: LinkCapacity, _ format: PixelFormat) -> Double? {
            rates.first { Bandwidth.fit(Bandwidth.requiredGbps(width: w, height: h, refresh: $0, format: format), cap).0 != .tooMuch }
        }
        let rows = options(current: current).map { AdviceRow(option: $0, bestRGB: best($0.capacity, .rgb8), best422: best($0.capacity, .ycc422)) }

        var summary = "This monitor goes up to \(DisplayMode.hz(top)) at \(w)x\(h)."
        if let mine = rows.first(where: { $0.option.isCurrent }) {
            let rgb = mine.bestRGB.map(DisplayMode.hz) ?? "nothing"
            summary += " On your current link you get \(rgb) in full RGB"
            if let y = mine.best422, y > (mine.bestRGB ?? 0) { summary += ", or \(DisplayMode.hz(y)) with colour squeezed to 4:2:2" }
            summary += "."
            if (mine.bestRGB ?? 0) < top, let better = rows.first(where: { !$0.option.isCurrent && ($0.bestRGB ?? 0) >= top }) {
                summary += " For \(DisplayMode.hz(top)) in full RGB you need \(better.option.name) (\(better.option.example))."
            } else if (mine.bestRGB ?? 0) >= top {
                summary += " Your connection isn't holding this monitor back."
            } else {
                summary += " No standard connection here reaches \(DisplayMode.hz(top)) in full RGB without compression (DSC)."
            }
        }
        return Advice(display: display.name, monitorMax: top, rows: rows, summary: summary)
    }
}
