# PortSight

A macOS menu bar app that shows what your monitor, dock and cable are actually doing, and fixes the most common clamshell-mode bug.

It reads the same data macOS uses internally: the video link your Mac negotiated (lanes, speed, colour format, how full the cable is), what each USB-C port is carrying, how much power is coming in, and which mode macOS picks when you close the lid.

## The problem that started this

A MacBook Air on a USB-C dock, driving a 3440x1440 monitor at 120Hz. After a restart, closing the lid made the monitor say "no video input". The Mac wasn't asleep, and the cables and dock were fine.

The kernel log showed the real cause. macOS keeps one display setting for lid open and a separate one for lid closed. The lid-closed one had been saved at 144Hz. Through a dock that shares the cable with USB 3, DisplayPort only gets 2 lanes, and 144Hz needed 95% of that link in YCbCr 4:2:2. The monitor couldn't lock onto it.

PortSight finds this automatically and can pin the lid-closed mode to one that works.

## What it does

**Overview**: plain-English findings, for example:
- "Closing the lid switches the monitor to 144Hz" (and what it was with the lid open)
- "Video only gets half the cable on port 2" (DisplayPort sharing a USB-C cable with USB 3 = 2 lanes)
- "The link runs at DP 1.2 speed" (your dock, adapter or cable is the bottleneck)
- "The cable is 95% full"
- "Only 12W of power is coming in" (dock passthrough)

**Displays**: every mode your monitor offers, with an estimate of how much of the link each one needs and which colour format it would have to use. Pick one to try it. If you don't press Keep within 15 seconds it switches back, so a black screen fixes itself.

**Connections**: the measured video link (lanes x Gbps, DP version, colour format, bandwidth used, DSC), each USB-C port's active transports, power source and wattage, and every USB device including hubs and docks.

**Lid Profiles**: choose a mode for lid open and lid closed per monitor. PortSight applies it for 10 seconds after each lid change and leaves your manual changes alone the rest of the time. Off by default.

**Report**: a copyable text report for GitHub issues and forums. Serial numbers are left out.

## Install

1. Download `PortSight.zip` from [Releases](../../releases) and unzip it.
2. Move `PortSight.app` to Applications.
3. The first time, right-click it and choose **Open**. Builds aren't notarised yet, so macOS warns you once.

It runs in the menu bar (cable icon). Requires macOS 14 or later. It works on Apple silicon and Intel, though USB-C port and link details come from Apple silicon drivers.

## Command line

Useful when the screen is black and you can only reach the Mac over SSH or Screen Sharing from another device:

```bash
/Applications/PortSight.app/Contents/MacOS/PortSight --report            # diagnostics (last 2 hours of log)
/Applications/PortSight.app/Contents/MacOS/PortSight --report --hours 24
/Applications/PortSight.app/Contents/MacOS/PortSight --list              # displays and modes
/Applications/PortSight.app/Contents/MacOS/PortSight --set 3440x1440@120 # switch the first external display and save it
```

## How it works

| Data | Source |
|---|---|
| Displays and modes | CoreGraphics (`CGDisplayCopyAllDisplayModes`) |
| Monitor details (maker, native size, HDR, input) | `DisplayAttributes` from the display driver in the IORegistry |
| USB-C port transports | `AppleTCController` entries in the IORegistry |
| Video link: lanes, speed, colour format, bandwidth | Display driver lines in the kernel log (`log show`) |
| Lid open/closed history | Power management lines in the kernel log |
| Power and USB devices | `system_profiler` |

Bandwidth estimates for modes use CVT reduced-blanking v2 timings. They land within a few percent of what macOS actually sends.

## Limits

- Link details only appear in the log when a mode changes. If there's nothing recent, change the refresh rate or replug the monitor, then refresh.
- Reading the kernel log needs an administrator account.
- PortSight can't read a dock's spec sheet. It reports what the link actually negotiated, which is what limits you anyway.
- Colour format (RGB vs 4:2:2) is chosen by macOS. Changing it needs private APIs, which PortSight doesn't use yet.
- Not on the Mac App Store, because the sandbox blocks reading the log and the IORegistry.

## Build from source

```bash
./build.sh
```

This needs the Xcode command line tools. It produces `build/PortSight.app` (universal) and `build/PortSight.zip`, ad-hoc signed. To notarise, replace `--sign -` in `build.sh` with your Developer ID.

`PortSight --render-pages <folder>` draws each window page to PNG, for checking UI changes without screen recording permission.

## Licence

MIT
