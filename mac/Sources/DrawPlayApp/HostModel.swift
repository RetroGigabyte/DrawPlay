import AppKit
import DrawPlayCore
import ServiceManagement
import SwiftUI

struct SizeChoice: Identifiable, Hashable {
    let width: Int, height: Int, label: String
    var id: String { "\(width)x\(height)" }
}

@MainActor
final class HostModel: ObservableObject {
    static let shared = HostModel()
    static let sizes = [
        SizeChoice(width: 2560, height: 1600, label: "2560 × 1600 (Tab S8 native)"),
        SizeChoice(width: 1920, height: 1200, label: "1920 × 1200 (lighter on Wi-Fi)"),
        SizeChoice(width: 1280, height: 800, label: "1280 × 800 (lowest load)"),
    ]
    private let defaults = UserDefaults.standard
    static let port: UInt16 = 7878

    @Published var mode: LinkMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var size: SizeChoice { didSet { defaults.set(size.id, forKey: "size") } }
    @Published var sharp: Bool { didSet { defaults.set(sharp, forKey: "sharp") } }
    @Published var orientation: OrientationMode { didSet { defaults.set(orientation.rawValue, forKey: "orientation") } }
    @Published var pin: String { didSet { defaults.set(pin, forKey: "pin") } }
    @Published var quality: VideoQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "keepAwake") } }

    @Published var running = false
    @Published var busy = false
    @Published var status = "Stopped"
    @Published var detail = ""
    @Published var stats = Session.Stats()
    @Published var log: [String] = []
    @Published var devices: [Adb.Device] = []
    @Published var adbPath: String? = Adb.path
    @Published var addresses: [(name: String, address: String)] = []
    @Published var screenOK = Permissions.screenRecording
    @Published var accessOK = Permissions.accessibility
    @Published var focusApps: [FocusApp] = Focus.runningApps()
    @Published var focusPick: pid_t?
    @Published var focused: FocusApp?
    @Published var usbReady = false          // adb reverse done for the current session
    private var session: Session?
    private var timer: Timer?

    init() {
        let d = UserDefaults.standard
        let savedSize = d.string(forKey: "size")
        mode = LinkMode(rawValue: d.string(forKey: "mode") ?? "") ?? .usb
        size = Self.sizes.first { $0.id == savedSize } ?? Self.sizes[0]
        sharp = d.object(forKey: "sharp") as? Bool ?? true
        orientation = OrientationMode(rawValue: d.string(forKey: "orientation") ?? "") ?? .auto
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        quality = VideoQuality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        if let p = d.string(forKey: "pin"), p.count == 6 { pin = p } else { let p = Self.randomPin(); pin = p; d.set(p, forKey: "pin") }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Ask once at launch so DrawPlay appears in both System Settings lists straight away.
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        if !Permissions.screenRecording { Permissions.requestScreenRecording() }
        Task { await refresh() }
    }

    /// The chosen resolution as it will be at start (width and height swapped for Portrait).
    var effectiveSize: (width: Int, height: Int) { orientation == .portrait ? (size.height, size.width) : (size.width, size.height) }

    static func randomPin() -> String { String(Int.random(in: 100_000...999_999)) }

    func newPin() { pin = Self.randomPin(); if running { append("New PIN takes effect the next time you press Start.") } }

    func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func refresh() async {
        screenOK = Permissions.screenRecording
        accessOK = Permissions.accessibility
        addresses = NetInfo.ipv4Addresses()
        adbPath = Adb.path
        focusApps = Focus.runningApps()
        if let f = focused, !focusApps.contains(f) { focused = session?.focusedApp }   // the app quit
        if mode == .usb, adbPath != nil { devices = await Adb.devices() }
    }

    // MARK: start / stop

    func toggle() async {
        if running { await stop() } else { await start() }
    }

    func start() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        status = "Starting…"
        let cfg = Session.Config(mode: mode, port: Self.port, pixelWidth: size.width, pixelHeight: size.height,
                                 fps: 60, hidpi: sharp, orientation: orientation, quality: quality, keepAwake: keepAwake, pin: UInt32(pin) ?? 0)
        let s = Session(config: cfg)
        s.onLog = { [weak self] in self?.append($0) }
        s.onStats = { [weak self] st in
            guard let self else { return }
            self.stats = st
            if self.running { self.status = st.tabletConnected ? "Tablet connected" : "Running, waiting for the tablet" }
        }
        s.onDisplay = { [weak self] d in self?.detail = d }
        s.onEnded = { [weak self] reason in
            guard let self else { return }
            self.append(reason); self.running = false; self.status = "Stopped"; self.session = nil; self.focused = nil
        }
        do {
            try await s.start()
            session = s; running = true
            detail = s.displayDescription
            status = "Running, waiting for the tablet"
            if mode == .usb { await setupUSB() }
        } catch {
            append("Could not start: \(error.localizedDescription)")
            status = "Stopped"
            await refresh()
        }
    }

    func stop() async {
        busy = true; defer { busy = false }
        await session?.stop()
        session = nil; running = false; usbReady = false; focused = nil
        status = "Stopped"; stats = Session.Stats()
    }

    // MARK: USB helpers

    func setupUSB() async {
        usbReady = false
        let ready = (await Adb.devices()).filter(\.ready)
        devices = await Adb.devices()
        guard !ready.isEmpty else {
            append(devices.isEmpty ? "No tablet found over USB. Plug it in and allow USB debugging." : "The tablet is connected but not authorised: accept the prompt on its screen.")
            return
        }
        for d in ready {
            let r = await Adb.run(["-s", d.serial, "reverse", "tcp:\(Self.port)", "tcp:\(Self.port)"])
            append(r.code == 0 ? "USB link ready for \(d.model)" : "adb reverse failed for \(d.model): \(r.output)")
            usbReady = usbReady || r.code == 0
        }
    }

    func openOnTablet() async {
        for d in devices.filter(\.ready) {
            let r = await Adb.run(["-s", d.serial, "shell", "am", "start", "-n", "dev.drawplay/.MainActivity", "--es", "host", "127.0.0.1"])
            append(r.code == 0 ? "Opened DrawPlay on \(d.model)" : "Could not open the app (is it installed?): \(r.output)")
        }
    }

    func installOnTablet() async {
        guard let apk = Bundle.main.url(forResource: "DrawPlay", withExtension: "apk") else {
            append("No DrawPlay.apk is bundled in this app. Build with scripts/make-app.sh after building the Android app."); return
        }
        for d in devices.filter(\.ready) {
            append("Installing on \(d.model)…")
            let r = await Adb.run(["-s", d.serial, "install", "-r", apk.path])
            append(r.code == 0 ? "Installed on \(d.model)" : "Install failed: \(r.output)")
        }
    }

    // MARK: focus mode

    func startFocus(_ app: FocusApp) async {
        guard let s = session else { append("Start streaming first, then pick an app."); return }
        do { try await s.startFocus(pid: app.pid); focused = s.focusedApp; focusPick = app.pid }
        catch { append("Focus mode: \(error.localizedDescription)") }
    }

    func stopFocus() async {
        await session?.stopFocus()
        focused = nil
    }

    // MARK: menu bar

    /// Filled pencil while a session runs, outline when stopped.
    var menuSymbol: String { running ? "pencil.circle.fill" : "pencil.circle" }

    var menuStatus: String {
        guard running else { return "DrawPlay: stopped" }
        if stats.tabletConnected { return "Tablet connected · \(stats.fps) fps · ping \(Int(stats.pingMs)) ms" }
        return mode == .usb ? "Waiting for the tablet (USB)" : "Waiting for the tablet (Wi-Fi)"
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { append("Could not change Open at login: \(error.localizedDescription). It works best when DrawPlay is in the Applications folder.") }
            objectWillChange.send()
        }
    }

    // MARK: permissions

    func fixPermissions() {
        let ok = Permissions.resetSavedGrants()
        append(ok ? "Cleared DrawPlay's saved permissions. Allow both again, then quit and reopen DrawPlay."
                  : "Could not clear the saved permissions. Remove DrawPlay from both lists in System Settings with the minus button, then add it again.")
        Permissions.requestAccessibility()
        Permissions.requestScreenRecording()
        openSettings("Privacy_Accessibility")
    }

    // MARK: settings shortcuts

    func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
