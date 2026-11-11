import AppKit
import DrawPlayCore
import SwiftUI

/// The main window, built from standard SwiftUI components so it picks up the system's Liquid Glass look by itself:
/// a standard title bar with a toolbar (Start / Stop and status) over a grouped form.
struct ContentView: View {
    @EnvironmentObject var m: HostModel

    var body: some View {
        Form {
            header
            connection
            screen
            focusMode
            if m.running { live }
            permissions
            logSection
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .status) { statusLabel }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await m.toggle() }
                } label: {
                    Text(m.running ? "Stop" : (m.mode == .usb ? "Start USB" : "Start Wi-Fi"))
                }
                .buttonStyle(.borderedProminent)
                .tint(m.running ? .red : nil)              // otherwise the system accent, like every other control
                .disabled(m.busy)
            }
        }
        .frame(minWidth: 540, minHeight: 640)
    }

    // MARK: toolbar

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle().fill(m.stats.tabletConnected ? .green : (m.running ? .orange : .secondary)).frame(width: 8, height: 8)
            Text(m.status)
        }
    }

    // MARK: sections

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DrawPlay").font(.title.bold())
                    Text("Your Android tablet as a second screen, with pen and touch.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connection: some View {
        Section {
            Picker("Mode", selection: $m.mode) {
                Text("USB cable").tag(LinkMode.usb)
                Text("Wi-Fi").tag(LinkMode.wifi)
            }
            .pickerStyle(.segmented).disabled(m.running)

            if m.mode == .usb { usbRows } else { wifiRows }
        } header: {
            Text("Connection")
        } footer: {
            Text(m.mode == .usb
                 ? "Lowest delay. Plug the tablet in with USB debugging on."
                 : "No cable. The tablet and this Mac must be on the same network. In the tablet app, open Settings, enter the address and PIN, then Connect. The PIN stops other people on your network from controlling this Mac.")
        }
    }

    @ViewBuilder private var usbRows: some View {
        if m.adbPath == nil {
            Label("adb was not found. Install it with: brew install android-platform-tools", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if m.devices.isEmpty {
            Label("No tablet detected yet.", systemImage: "cable.connector").foregroundStyle(.secondary)
        } else {
            ForEach(m.devices) { d in
                Label("\(d.model)  (\(d.ready ? "ready" : d.state == "unauthorized" ? "accept the prompt on the tablet" : d.state))",
                      systemImage: d.ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(d.ready ? .green : .orange)
            }
        }
        HStack {
            Button("Install app on tablet") { Task { await m.installOnTablet() } }
                .disabled(m.devices.filter(\.ready).isEmpty)
            Button("Open app on tablet") { Task { await m.openOnTablet() } }
                .disabled(m.devices.filter(\.ready).isEmpty || !m.running)
            if m.running { Button("Redo USB link") { Task { await m.setupUSB() } } }
        }
        if m.running && m.usbReady {
            Label("USB link is ready. Open DrawPlay on the tablet.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var wifiRows: some View {
        LabeledContent("Mac address") {
            VStack(alignment: .trailing) {
                if m.addresses.isEmpty { Text("not connected to a network").foregroundStyle(.secondary) }
                ForEach(m.addresses, id: \.address) { a in
                    HStack(spacing: 6) {
                        Text(a.address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text(a.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        LabeledContent("PIN") {
            HStack {
                Text(m.pin).font(.system(.title3, design: .monospaced).bold()).textSelection(.enabled)
                Button("New PIN") { m.newPin() }.disabled(m.running)
            }
        }
    }

    private var screen: some View {
        Section {
            Picker("Resolution", selection: $m.size) {
                ForEach(HostModel.sizes) { Text($0.label).tag($0) }
            }
            .disabled(m.running)
            Picker("Orientation", selection: $m.orientation) {
                Text("Auto").tag(OrientationMode.auto)
                Text("Landscape").tag(OrientationMode.landscape)
                Text("Portrait").tag(OrientationMode.portrait)
            }
            .pickerStyle(.segmented).disabled(m.running)
            Picker("Video quality", selection: $m.quality) {
                ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).disabled(m.running)
            Toggle("Sharp text (Retina)", isOn: $m.sharp).disabled(m.running)
            Toggle("Keep this Mac awake while streaming", isOn: $m.keepAwake).disabled(m.running)
            if m.running, !m.detail.isEmpty {
                LabeledContent("Now") { Text(m.detail).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Screen")
        } footer: {
            Text("Auto orientation follows the tablet when you turn it. Higher quality uses more bandwidth (about \(Int(Double(m.effectiveSize.width * m.effectiveSize.height * 60) * m.quality.bitsPerPixelForUI / 1_000_000)) Mbit/s at this size). USB handles any setting; on Wi-Fi it backs off by itself if the network struggles.")
        }
    }

    private var focusMode: some View {
        Section {
            HStack {
                Picker("App", selection: $m.focusPick) {
                    Text("Choose an app").tag(pid_t?.none)
                    ForEach(m.focusApps) { Text($0.name).tag(Optional($0.pid)) }
                }
                .labelsHidden().disabled(m.focused != nil)
                if let f = m.focused {
                    Button("Stop focus on \(f.name)") { Task { await m.stopFocus() } }
                } else {
                    Button("Focus") {
                        if let pid = m.focusPick, let app = m.focusApps.first(where: { $0.pid == pid }) { Task { await m.startFocus(app) } }
                    }
                    .disabled(!m.running || m.focusPick == nil)
                }
            }
        } header: {
            Text("Focus mode")
        } footer: {
            Text("Show one app full-screen on the tablet. DrawPlay moves that app's window onto the tablet's screen and puts it back afterwards.\(m.running ? "" : " Start streaming first.")")
        }
    }

    private var live: some View {
        Section {
            if m.stats.tabletConnected {
                LabeledContent("Picture") { Text("\(m.stats.fps) fps · \(String(format: "%.1f", m.stats.mbps)) Mbit/s (aiming \(Int(m.stats.targetMbps)))").monospacedDigit() }
                LabeledContent("Delay") { Text("ping \(Int(m.stats.pingMs)) ms · encode \(Int(m.stats.encodeMs.rounded())) ms").monospacedDigit() }
            } else {
                Text("Waiting for the tablet…").foregroundStyle(.secondary)
            }
        } header: {
            Text("Live")
        }
    }

    private var permissions: some View {
        Section {
            permissionRow("Screen Recording", "needed to send the screen to the tablet", ok: m.screenOK) {
                Permissions.requestScreenRecording(); m.openSettings("Privacy_ScreenCapture")
            }
            permissionRow("Accessibility", "needed so pen and touch can control the Mac", ok: m.accessOK) {
                Permissions.requestAccessibility(); m.openSettings("Privacy_Accessibility")
            }
            if !m.screenOK || !m.accessOK {
                Button("Fix permissions…") { m.fixPermissions() }
            }
        } header: {
            Text("Permissions")
        } footer: {
            if !m.screenOK || !m.accessOK {
                Text("After allowing, quit and reopen DrawPlay: macOS only applies the change to a fresh start. Already switched on in System Settings but still red here? The switch belongs to an older copy of DrawPlay, so use Fix permissions.")
            }
        }
    }

    private func permissionRow(_ name: String, _ why: String, ok: Bool, fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Allow…", action: fix) }
        }
    }

    private var logSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(m.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }
                }
                .frame(height: 110)
                .onChange(of: m.log.count) { _ in proxy.scrollTo(m.log.count - 1, anchor: .bottom) }
            }
        } header: {
            Text("Log")
        }
    }
}
