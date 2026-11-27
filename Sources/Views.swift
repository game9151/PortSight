import SwiftUI

struct PortSightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("PortSight", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 580)
        }
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.issueCount > 0 ? "cable.connector.slash" : "cable.connector")
        }
    }
}

// MARK: Menu bar

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = LidProfileStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let s = model.snapshot {
            ForEach(s.displays) { d in
                Text("\(d.name): \(d.current?.label ?? "?")")
            }
            Text(model.issueCount == 0 ? "No problems found" : "\(model.issueCount) issue\(model.issueCount == 1 ? "" : "s") found")
            ForEach(s.externals) { d in
                if let cur = d.current {
                    let rates = d.modes.filter { $0.width == cur.width && $0.height == cur.height && $0.pixelWidth == cur.pixelWidth }
                    if rates.count > 1 {
                        Menu("\(d.name) refresh rate") {
                            ForEach(rates, id: \.self) { m in
                                Button((cur.matches(m) ? "✓ " : "    ") + DisplayMode.hz(m.refresh)) {
                                    openWindow(id: "main")
                                    NSApp.activate(ignoringOtherApps: true)
                                    model.tryMode(m, on: d)
                                }
                                .disabled(cur.matches(m) || model.trial != nil)
                            }
                        }
                    }
                }
            }
        } else {
            Text("Checking…")
        }
        if let v = model.updateAvailable {
            Button("Update available: \(v)") { NSWorkspace.shared.open(Updates.releasesPage) }
        }
        Divider()
        Button("Open PortSight") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if let s = model.snapshot, DDC.available {
            ForEach(s.externals) { d in
                Menu("\(d.name) brightness") {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { pct in
                        Button("\(pct)%") {
                            let max = model.ddcValues[d.id]?[.brightness]?.max ?? 100
                            DDC.queue.async { DDC.write(.brightness, value: max * pct / 100, display: d.id) }
                            model.ddcValues[d.id]?[.brightness]?.current = max * pct / 100
                        }
                    }
                }
            }
        }
        Toggle("Apply lid profiles", isOn: $store.enabled)
        Button("Refresh") { model.refresh() }
        Button("Copy report") { model.copyReport() }
        Divider()
        Button("Quit PortSight") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

// MARK: Window

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", displays = "Displays", connections = "Connections", lid = "Lid Profiles", alerts = "Alerts", report = "Report"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "stethoscope"
        case .displays: return "display.2"
        case .connections: return "cable.connector.horizontal"
        case .lid: return "laptopcomputer"
        case .alerts: return "bell"
        case .report: return "doc.plaintext"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page? = .overview

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180)
        } detail: {
            Group {
                if let s = model.snapshot {
                    PageContent(page: page ?? .overview, snapshot: s)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading displays, ports and the kernel log…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .top) { if model.trial != nil { TrialBanner() } }
            .toolbar {
                ToolbarItem {
                    if model.loading { ProgressView().controlSize(.small) }
                }
                ToolbarItem {
                    Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(model.loading)
                }
            }
        }
    }
}

struct PageContent: View {
    let page: Page
    let snapshot: SystemSnapshot
    var body: some View {
        switch page {
        case .overview: OverviewPage(snapshot: snapshot)
        case .displays: DisplaysPage(snapshot: snapshot)
        case .connections: ConnectionsPage(snapshot: snapshot)
        case .lid: LidPage(snapshot: snapshot)
        case .alerts: AlertsPage()
        case .report: ReportPage()
        }
    }
}

struct TrialBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let t = model.trial {
            HStack {
                Image(systemName: "timer")
                Text("\(t.title) Going back in \(t.secondsLeft)s.")
                    .fontWeight(.medium)
                Spacer()
                Button("Go back") { model.revertTrial() }
                Button("Keep") { model.keepTrial() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            .background(.yellow.opacity(0.25))
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

struct Row: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Overview

struct OverviewPage: View {
    @EnvironmentObject var model: AppModel
    let snapshot: SystemSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("What's going on with your displays").font(.title2.bold())
                ForEach(snapshot.findings) { FindingRow(finding: $0) }
                ForEach(snapshot.externals) { d in
                    if let advice = Advisor.advice(for: d, current: snapshot.capacity(for: d)) { AdviceCard(advice: advice) }
                }
                if !model.activity.isEmpty {
                    Card(title: "Activity") {
                        ForEach(model.activity, id: \.self) { Text($0).font(.callout.monospaced()) }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct FindingRow: View {
    @EnvironmentObject var model: AppModel
    let finding: Finding
    var colour: Color { [Color.red, .orange, .blue, .green][finding.level.rawValue] }
    var icon: String { ["exclamationmark.octagon.fill", "exclamationmark.triangle.fill", "info.circle.fill", "checkmark.circle.fill"][finding.level.rawValue] }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(colour).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).font(.headline)
                Text(finding.detail).fixedSize(horizontal: false, vertical: true)
                if let fix = finding.fix {
                    Text("Fix: \(fix)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let action = finding.action, let title = finding.actionTitle {
                    Button(title) { model.perform(action) }.padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(colour.opacity(0.08)))
    }
}

// MARK: Displays

struct DisplaysPage: View {
    @EnvironmentObject var model: AppModel
    let snapshot: SystemSnapshot
    @State private var showAllModes = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Displays").font(.title2.bold())
                    Spacer()
                    Toggle("Show scaled and low-res modes", isOn: $showAllModes)
                }
                Text("Pick a mode to try it. If you don't press Keep within 15 seconds, it goes back, so a black screen fixes itself.")
                    .foregroundStyle(.secondary)
                ForEach(snapshot.displays) { d in
                    DisplayCard(display: d, capacity: snapshot.capacity(for: d), showAll: showAllModes)
                }
            }
            .padding(20)
        }
    }
}

struct DisplayCard: View {
    @EnvironmentObject var model: AppModel
    let display: DisplayInfo
    let capacity: LinkCapacity?
    let showAll: Bool

    var body: some View {
        Card(title: display.name) {
            Row(label: "Role", value: display.roleText)
            Row(label: "Current mode", value: display.current?.label ?? "unknown")
            let (w, h) = display.nativeSize
            Row(label: "Native resolution", value: "\(w)x\(h)")
            Row(label: "Highest refresh", value: DisplayMode.hz(display.highestRefresh))
            if let m = display.monitor {
                if let c = m.connection { Row(label: "Input", value: c) }
                Row(label: "HDR", value: m.supportsHDR ? "Supported" : "No")
                if let y = m.year { Row(label: "Made", value: String(y)) }
            }
            if let cap = capacity { Row(label: "Link", value: cap.summary) }
            if !display.isBuiltin {
                ColourSection(display: display)
                MonitorControls(display: display)
            }
            Divider().padding(.vertical, 4)
            let modes = showAll ? display.modes : display.nativeModes
            ForEach(modes, id: \.self) { mode in ModeRow(display: display, mode: mode, capacity: capacity) }
        }
    }
}

struct ModeRow: View {
    @EnvironmentObject var model: AppModel
    let display: DisplayInfo
    let mode: DisplayMode
    let capacity: LinkCapacity?

    var isCurrent: Bool { display.current?.matches(mode) == true }

    var body: some View {
        HStack {
            Text(mode.label).fontWeight(isCurrent ? .semibold : .regular)
            if isCurrent { Text("current").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.blue.opacity(0.15))) }
            Spacer()
            if let cap = capacity {
                let (w, h) = display.signalSize(for: mode)
                if let best = Bandwidth.bestFormat(width: w, height: h, refresh: mode.refresh, capacity: cap) {
                    let need = Bandwidth.requiredGbps(width: w, height: h, refresh: mode.refresh, format: best)
                    let (fit, ratio) = Bandwidth.fit(need, cap)
                    Text("\(best.rawValue), ~\(Fmt.pct(ratio)) of link")
                        .font(.caption)
                        .foregroundStyle(fit == .fits ? Color.secondary : Color.orange)
                } else {
                    Text("Won't fit this link").font(.caption).foregroundStyle(.red)
                }
            }
            Button("Try") { model.tryMode(mode, on: display) }
                .disabled(isCurrent || model.trial != nil)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Connections

struct ConnectionsPage: View {
    let snapshot: SystemSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connections").font(.title2.bold())
                Card(title: "Video link") {
                    if let link = snapshot.log.latest {
                        Row(label: "Lanes and speed", value: link.capacity.summary)
                        Row(label: "Last setup", value: link.modeLabel)
                        Row(label: "Colour format", value: link.colourLabel + (link.range.map { ", \($0) range" } ?? ""))
                        if let r = link.ratio { Row(label: "Bandwidth used", value: "\(Fmt.gbps(link.videoGbps ?? 0)) of \(Fmt.gbps(link.usableGbps ?? 0)) (\(Fmt.pct(r)))") }
                        Row(label: "Compression (DSC)", value: link.dsc == true ? "On" : "Off")
                        if let open = snapshot.log.linkWhileLid(closed: false) { Row(label: "With lid open", value: "\(open.modeLabel), \(open.colourLabel)") }
                        if let closed = snapshot.log.linkWhileLid(closed: true) { Row(label: "With lid closed", value: "\(closed.modeLabel), \(closed.colourLabel)") }
                    } else {
                        Text(snapshot.log.error ?? "No link details in the kernel log yet. They're logged when a display mode changes. Try changing the refresh rate, then refresh.")
                            .foregroundStyle(.secondary)
                    }
                }
                Card(title: "USB-C ports") {
                    if snapshot.ports.isEmpty { Text("This Mac doesn't report USB-C port details.").foregroundStyle(.secondary) }
                    ForEach(snapshot.ports) { p in Row(label: "Port \(p.id)", value: p.summary) }
                }
                Card(title: "Power") {
                    if let c = snapshot.charger {
                        Row(label: "Source", value: c.connected ? (c.name ?? "Connected") : "On battery")
                        if let w = c.watts { Row(label: "Power", value: "\(w)W") }
                        if let charging = c.charging { Row(label: "Charging", value: charging ? "Yes" : "No") }
                    } else {
                        Text("No battery (desktop Mac).").foregroundStyle(.secondary)
                    }
                }
                Card(title: "USB devices") {
                    ForEach(snapshot.usb) { u in
                        Row(label: u.isHubOrDock ? "Hub / dock" : "Device", value: u.name + (u.speed.map { ", \($0)" } ?? ""))
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: Lid profiles

struct LidPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store = LidProfileStore.shared
    let snapshot: SystemSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Lid Profiles").font(.title2.bold())
                Text("macOS remembers a separate mode for when the lid is closed. If that mode doesn't work with your monitor or dock, the screen goes black in clamshell mode. Pick the mode for each case here. PortSight applies it each time the lid opens or closes and leaves your manual changes alone the rest of the time.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Apply lid profiles automatically", isOn: $store.enabled)
                Toggle("Open PortSight at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                if let err = model.launchAtLoginError { Text(err).foregroundStyle(.red) }
                if snapshot.externals.isEmpty {
                    Card(title: "No external display") { Text("Connect a monitor to set up its profile.").foregroundStyle(.secondary) }
                }
                ForEach(snapshot.externals) { d in
                    Card(title: d.name) {
                        ProfilePicker(display: d, lidClosed: false)
                        ProfilePicker(display: d, lidClosed: true)
                        if let closed = snapshot.log.linkWhileLid(closed: true) {
                            Text("Last time the lid closed, macOS used \(closed.modeLabel).").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct ProfilePicker: View {
    @ObservedObject var store = LidProfileStore.shared
    let display: DisplayInfo
    let lidClosed: Bool

    var selection: Binding<DisplayMode?> {
        Binding(
            get: { lidClosed ? store.profiles[display.key]?.closed : store.profiles[display.key]?.open },
            set: { store.setMode($0, forKey: display.key, lidClosed: lidClosed) })
    }

    var body: some View {
        HStack {
            Text(lidClosed ? "Lid closed" : "Lid open").frame(width: 90, alignment: .leading)
            Picker(lidClosed ? "Lid closed" : "Lid open", selection: selection) {
                Text("Don't change").tag(DisplayMode?.none)
                ForEach(display.nativeModes, id: \.self) { m in Text(m.label).tag(DisplayMode?.some(m)) }
            }
            .labelsHidden()
            .frame(width: 260)
            if let current = display.current {
                Button("Use current (\(DisplayMode.hz(current.refresh)))") { selection.wrappedValue = current }
            }
        }
    }
}

// MARK: Report

struct ReportPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Report").font(.title2.bold())
                Spacer()
                Picker("Search log", selection: $model.logHours) {
                    Text("Last hour").tag(1.0)
                    Text("Last 2 hours").tag(2.0)
                    Text("Last 6 hours").tag(6.0)
                    Text("Last 24 hours").tag(24.0)
                }
                .frame(width: 220)
                .onChange(of: model.logHours) { model.refresh() }
                Button("Copy") { model.copyReport() }
            }
            Text("Paste this into a GitHub issue. Serial numbers are left out.").foregroundStyle(.secondary)
            ScrollView {
                Text(model.reportText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(20)
    }
}


// MARK: Advisor

struct AdviceCard: View {
    let advice: Advice

    var body: some View {
        Card(title: "Best setup for \(advice.display)") {
            Text(advice.summary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Connection").foregroundStyle(.secondary)
                    Text("Full RGB").foregroundStyle(.secondary)
                    Text("With 4:2:2").foregroundStyle(.secondary)
                    Text("Typical hardware").foregroundStyle(.secondary)
                }
                ForEach(advice.rows) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Text(row.option.name).fontWeight(row.option.isCurrent ? .semibold : .regular)
                            if row.option.isCurrent {
                                Text("you").font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.blue.opacity(0.15)))
                            }
                        }
                        Text(row.bestRGB.map(DisplayMode.hz) ?? "-")
                            .foregroundStyle((row.bestRGB ?? 0) >= advice.monitorMax ? Color.green : Color.primary)
                        Text(row.best422.map(DisplayMode.hz) ?? "-")
                        Text(row.option.example).foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            Text("Highest refresh at native resolution. Estimates, without display compression (DSC).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Colour format and monitor controls

struct ColourSection: View {
    @EnvironmentObject var model: AppModel
    let display: DisplayInfo
    @State private var choice: UInt32?

    var body: some View {
        if let state = model.colourStates[display.id] {
            Row(label: "Colour format", value: state.currentColour?.label ?? "ID \(state.colourID)")
            if Framebuffers.canSetColour && state.choices.count > 1 {
                HStack {
                    Text("Change colour").foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    Picker("Colour format", selection: Binding(get: { choice ?? state.colourID }, set: { choice = $0 })) {
                        ForEach(state.choices) { c in Text(c.label).tag(c.id) }
                    }
                    .labelsHidden()
                    .frame(width: 300)
                    Button("Try") {
                        if let id = choice, let c = state.choices.first(where: { $0.id == id }) { model.tryColour(c, on: display) }
                    }
                    .disabled(choice == nil || choice == state.colourID || model.trial != nil)
                    Text("Experimental").font(.caption).foregroundStyle(.orange)
                }
            } else if state.choices.count <= 1 {
                Text("This refresh rate only fits the link in one colour format. Lower the refresh rate for more choices.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct MonitorControls: View {
    @EnvironmentObject var model: AppModel
    let display: DisplayInfo

    var body: some View {
        Group {
            if !DDC.available {
                EmptyView()
            } else if let values = model.ddcValues[display.id] {
                if values.isEmpty {
                    Row(label: "Monitor controls", value: "Not available. The monitor or dock doesn't pass DDC/CI through.")
                }
                ForEach(VCP.allCases) { vcp in
                    if let v = values[vcp] {
                        HStack {
                            Text(vcp.name).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                            Slider(value: Binding(get: { Double(v.current) },
                                                  set: { model.setDDC(vcp, value: Int($0.rounded()), display: display.id) }),
                                   in: 0...Double(v.max))
                                .frame(width: 300)
                            Text("\(v.current)").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } else {
                Row(label: "Monitor controls", value: "Checking…")
            }
        }
        .onAppear { model.loadDDC(for: display) }
    }
}

// MARK: Alerts

struct AlertsPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Alerts").font(.title2.bold())
                Text("PortSight follows the display driver live and checks power and USB-C ports every 5 seconds. It tells you when the link gets slower, colour drops to 4:2:2, the cable is nearly full, the lid changes the monitor's refresh rate, power drops, or the monitor link is lost.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Watch live", isOn: $settings.liveWatch)
                Toggle("Send notifications for problems", isOn: $settings.notifications)
                    .disabled(!settings.liveWatch)
                HStack {
                    Text("Notifications: \(model.notificationStatus)").foregroundStyle(.secondary)
                    if model.notificationStatus.hasPrefix("Blocked") {
                        Button("Open notification settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    } else {
                        Button("Send a test notification") { model.sendTestNotification() }
                    }
                }
                Toggle("Check GitHub for new versions once a day", isOn: $settings.checkUpdates)
                if let v = model.updateAvailable {
                    Button("Version \(v) is out. Download it") { NSWorkspace.shared.open(Updates.releasesPage) }
                }
                Card(title: "Recent events") {
                    if model.events.isEmpty {
                        Text(settings.liveWatch ? "Nothing yet. Events appear here when something changes." : "Live watching is off.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.events) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Text(e.date, style: .time).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            Image(systemName: ["exclamationmark.octagon.fill", "exclamationmark.triangle.fill", "info.circle", "checkmark.circle"][e.level.rawValue])
                                .foregroundStyle([Color.red, .orange, .secondary, .green][e.level.rawValue])
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title)
                                if !e.detail.isEmpty { Text(e.detail).font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { model.refreshNotificationStatus() }
    }
}
