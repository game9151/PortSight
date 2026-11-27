import Foundation

/// `PortSight --self-test`: checks the parts that don't need hardware. Runs in CI.
enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }

    static func run() -> Int32 {
        // Real display-driver lines from a MacBook Air on a USB-C dock (lid close at 144Hz).
        let log = """
        2026-11-19 17:13:00.262 Df kernel[0:7f] PMRD: clamshell closed 1, disabled 0/2, desktopMode 0, ac 1
        2026-11-19 17:13:00.324 E  kernel[0:178] (DCP)  [AppleDCPDPTXController.cpp::5607] DCPAV[1] AppleDCPDPTXController::validateVideo Validating link @ 4 lanes and 5400000000Gbps
        2026-11-19 17:13:00.552 E  kernel[0:2b2] (DCPEXT)  [AppleDCPDPTXController.cpp::5607] DCPAV[4146] AppleDCPDPTXController::validateVideo Validating link @ 2 lanes and 8100000000Gbps
        2026-11-19 17:13:00.552 E  kernel[0:2b2] (DCPEXT)  [AppleDCPDPTXController.cpp::5612] DCPAV[4147] AppleDCPDPTXController::validateVideo Color: depth=8bpc encoding=2 [YCbCr 4:2:2] range=1 [Limited] colorimetry=1 [BT.709]
        2026-11-19 17:13:00.552 E  kernel[0:2b2] (DCPEXT)  [AppleDCPDPTXController.cpp::5614] DCPAV[4149] AppleDCPDPTXController::validateVideo Vertical: total=1490 frontPorch=3 syncWidth=10 backPorch=37 active=1440 syncRate=144.0007Hz
        2026-11-19 17:13:00.552 E  kernel[0:2b2] (DCPEXT)  [AppleDCPDPTXController.cpp::5615] DCPAV[4150] AppleDCPDPTXController::validateVideo Timing: pixelClock=772420000 interlaced=0 split=0
        2026-11-19 17:13:00.552 E  kernel[0:2b2] (DCPEXT)  [AppleDCPDPTXController.cpp::5675] DCPAV[4152] AppleDCPDPTXController::validateVideo Link: dsc=NO dsc.bpp=0.0000 videoBandwidth=12358720000bps usableBandwidth=12960000000bps
        2026-11-19 17:13:00.555 Df kernel[0:2b2] (RTBuddy) [DCPEXT:ifiedPipeline.cpp:10310] IOMFBStatus UnifiedPipeline::mode_set_gated(uint32_t, uint32_t): 3440x1440@144 Hz DSC=NO VRR=NO link: 1
        2026-11-19 17:13:05.350 Df kernel[0:7f] PMRD: clamshell closed 0, disabled 0/2, desktopMode 0, ac 1
        2026-11-19 17:13:05.350 Df kernel[0:7f] PMRD: clamshell closed 0, disabled 0/2, desktopMode 0, ac 1
        2026-11-19 17:13:05.617 E  kernel[0:2b2] (DCPEXT)  [AppleDCPDPTXController.cpp::5607] DCPAV[1] AppleDCPDPTXController::validateVideo Validating link @ 2 lanes and 8100000000Gbps
        2026-11-19 17:13:05.617 E  kernel[0:2b2] (DCPEXT)  [AppleDCPDPTXController.cpp::5614] DCPAV[2] AppleDCPDPTXController::validateVideo Vertical: total=1510 frontPorch=3 syncWidth=10 backPorch=57 active=1440 syncRate=120.0000Hz
        2026-11-19 17:13:05.620 Df kernel[0:2b2] (RTBuddy) [DCPEXT:ifiedPipeline.cpp:10310] IOMFBStatus UnifiedPipeline::mode_set_gated(uint32_t, uint32_t): 3440x1440@120 Hz DSC=NO VRR=NO link: 1
        """
        let parser = LinkLogParser(skipInternalPipe: true)
        var result = KernelLogResult()
        for line in log.split(separator: "\n") {
            for e in parser.feed(String(line).trimmingCharacters(in: .whitespaces)) {
                if case .link(let s) = e { result.snapshots.append(s) }
                if case .lid(let l) = e { result.lidEvents.append(l) }
            }
        }
        for case .link(let s) in parser.flush() { result.snapshots.append(s) }

        check(result.snapshots.count == 2, "parses two external link setups and skips the built-in panel")
        check(result.lidEvents.count == 2, "parses lid close and open, dropping the repeat")
        if let s = result.snapshots.first {
            check(s.lanes == 2 && abs(s.perLaneGbps - 8.1) < 0.01, "lanes and per-lane speed")
            check(s.capacity.speedName.contains("HBR3"), "8.1 Gbps per lane is HBR3")
            check(s.encoding == "YCbCr 4:2:2" && s.bpc == 8 && s.isCompressedColour, "colour format")
            check(s.width == 3440 && s.height == 1440 && abs((s.refresh ?? 0) - 144) < 0.01, "mode from the mode-set line")
            check(abs((s.ratio ?? 0) - 0.9536) < 0.001, "bandwidth ratio")
        }
        check(result.linkWhileLid(closed: true)?.refresh.map { abs($0 - 144) < 0.01 } == true, "mode while lid closed")
        check(result.linkWhileLid(closed: false)?.refresh.map { abs($0 - 120) < 0.01 } == true, "mode while lid open")

        let est = Bandwidth.requiredGbps(width: 3440, height: 1440, refresh: 144, format: .ycc422)
        check(abs(est - 12.36) / 12.36 < 0.05, "bandwidth estimate within 5% of the driver (\(String(format: "%.2f", est)) vs 12.36 Gbps)")
        let link = LinkCapacity(lanes: 2, perLaneGbps: 8.1, measured: true)
        check(abs(link.usableGbps - 12.96) < 0.01, "usable bandwidth of 2 lanes HBR3")
        check(Bandwidth.bestFormat(width: 3440, height: 1440, refresh: 120, capacity: link) == .ycc422, "120Hz needs 4:2:2 on 2 lanes")
        check(Bandwidth.bestFormat(width: 3440, height: 1440, refresh: 100, capacity: link) == .rgb8, "100Hz fits full RGB on 2 lanes")
        check(Bandwidth.bestFormat(width: 3440, height: 1440, refresh: 144, capacity: LinkCapacity(lanes: 4, perLaneGbps: 8.1, measured: false)) == .rgb8, "144Hz fits RGB on 4 lanes")

        check(DisplayMode.parse("3440x1440@120")?.hz == 120, "parse WxH@Hz")
        check(DisplayMode.parse("garbage") == nil, "reject bad mode text")
        check(Updates.isNewer("1.0.1", than: "1.0.0") && !Updates.isNewer("1.0.0", than: "1.0") && Updates.isNewer("2.0", than: "1.9.9"), "version comparison")

        print(failures == 0 ? "\nAll checks passed" : "\n\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
