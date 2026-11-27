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
