# Contributing

Bug reports with a pasted PortSight report are the most useful thing. The report says what macOS negotiated with your monitor, which is hard to guess otherwise.

To work on the code:

```bash
./build.sh                                              # build/PortSight.app
./build/PortSight.app/Contents/MacOS/PortSight --self-test
./build/PortSight.app/Contents/MacOS/PortSight --render-pages /tmp/pages   # draw each page to PNG
```

Layout of `Sources/`:

| File | What it does |
|---|---|
| `Displays.swift` | Displays, modes, monitor details, switching modes |
| `Connections.swift` | USB-C ports, power, USB devices |
| `KernelLog.swift` | Parses the display driver's log lines, caches history |
| `LiveWatch.swift` | Live `log stream`, power and port polling, notifications |
| `Bandwidth.swift` | Link capacity, bandwidth estimates, the best-setup advisor |
| `Diagnosis.swift` | Findings and the text report |
| `LidProfiles.swift` | Lid-open and lid-closed modes |
| `Framebuffer.swift` | Colour formats (private IOMobileFramebuffer calls) |
| `DDC.swift` | Monitor brightness, contrast, volume (private IOAVService calls) |
| `Views.swift`, `AppModel.swift` | The SwiftUI app |
| `Entry.swift` | Command line |

Private Apple functions are always looked up at runtime with `dlsym`, and the feature hides itself if one is missing. Keep it that way, so a macOS update can't crash the app.
