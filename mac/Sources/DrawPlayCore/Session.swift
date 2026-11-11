import CoreGraphics
import CoreVideo
import Foundation
import Network

public enum LinkMode: String, CaseIterable, Identifiable {
    case usb, wifi
    public var id: String { rawValue }
}

/// How the screen is oriented. `auto` follows the tablet: turn the tablet and the Mac display turns with it.
public enum OrientationMode: String, CaseIterable, Identifiable {
    case auto, landscape, portrait
    public var id: String { rawValue }
    var wireByte: UInt8 { self == .auto ? 0 : (self == .landscape ? 1 : 2) }   // sent to the tablet
}

/// How much data the picture may use. Bits per pixel per frame; the bitrate follows from the resolution and frame rate
/// (2560 x 1600 at 60 fps: about 15, 30 and 60 Mbit/s).
public enum VideoQuality: String, CaseIterable, Identifiable {
    case standard, high, maximum
    public var id: String { rawValue }
    public var bitsPerPixelForUI: Double { bitsPerPixel }
    var bitsPerPixel: Double { self == .standard ? 0.06 : (self == .high ? 0.12 : 0.25) }
    public var label: String { self == .standard ? "Standard" : (self == .high ? "High" : "Maximum") }
}

public struct SessionError: LocalizedError {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// One streaming run: virtual display -> capture -> encoder -> tablet, and tablet input -> injector.
/// Everything runs on the main actor.
@MainActor
public final class Session {
    public struct Config {
        public var mode: LinkMode
        public var port: UInt16
        /// Landscape size in pixels (the longer edge is the width); portrait swaps them.
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var fps: Int
        public var hidpi: Bool
        public var orientation: OrientationMode
        public var quality: VideoQuality
        /// Keep the Mac and its displays awake while streaming.
        public var keepAwake: Bool
        /// Wi-Fi mode only: the tablet has to send this PIN. USB mode accepts only local connections instead.
        public var pin: UInt32
        public init(mode: LinkMode = .wifi, port: UInt16 = 7878, pixelWidth: Int = 2560, pixelHeight: Int = 1600,
                    fps: Int = 60, hidpi: Bool = false, orientation: OrientationMode = .landscape, quality: VideoQuality = .high, keepAwake: Bool = true, pin: UInt32 = 0) {
            self.mode = mode; self.port = port; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
            self.fps = fps; self.hidpi = hidpi; self.orientation = orientation; self.quality = quality; self.keepAwake = keepAwake; self.pin = pin
        }
    }

    public struct Stats {
        public var fps = 0
        public var mbps = 0.0
        public var tabletConnected = false
        /// Round trip Mac -> tablet -> Mac in milliseconds (network plus the tablet's own scheduling); 0 until measured.
        public var pingMs = 0.0
        /// The bitrate the encoder is aiming for right now, in Mbit/s (lower than the setting while the network is struggling).
        public var targetMbps = 0.0
        /// Time the encoder takes per frame in milliseconds.
        public var encodeMs = 0.0
        public init() {}
    }

    public let config: Config
    public private(set) var isRunning = false
    public private(set) var displayDescription = ""
    public var onLog: (String) -> Void = { print($0) }
    public var onStats: (Stats) -> Void = { _ in }
    /// Called when the display mode changes (start, or the tablet was turned in Auto mode).
    public var onDisplay: (String) -> Void = { _ in }
    /// Called when the session ends by itself (listener failure). Not called after `stop()`.
    public var onEnded: (String) -> Void = { _ in }

    private let injector = Injector()
    private let streamer = Streamer()
    private var display: VirtualDisplay?
    private var encoder: Encoder?
    private let capture = Capture()
    private let sleepGuard = SleepGuard()
    /// Focus mode: one app full-screen on the tablet.
    public let focus = Focus()
    public var focusedApp: FocusApp? { focus.active }
    private var listener: NWListener?
    private var timer: Timer?
    private var lastFrame: CVPixelBuffer?
    private var needKey = false
    private var frames = 0, lastFrames = 0
    private var lastBytes: UInt64 = 0
    private var tick = 0
    private var failures = 0
    private var lockedUntil = Date.distantPast
    private var currentPortrait = false
    private var ping = 0.0
    private var targetBitrate = 0, currentBitrate = 0      // bits per second: the quality setting, and what the encoder uses now
    private var dropsInWindow = 0, cleanSeconds = 0
    private var lockTimer: Timer?
    private var cursorHidden = false, cursorChangeStreak = 0
    private var wantedPortrait = false
    private var reconfiguring = false

    public init(config: Config) { self.config = config }

    private func pixels(portrait: Bool) -> (w: Int, h: Int) {
        let long = max(config.pixelWidth, config.pixelHeight), short = min(config.pixelWidth, config.pixelHeight)
        return portrait ? (short, long) : (long, short)
    }

    public func start() async throws {
        guard !isRunning else { return }
        // Ask for both up front so both show up in System Settings, whichever is missing first.
        if !Permissions.accessibility { Permissions.requestAccessibility() }
        guard Permissions.screenRecording else {
            Permissions.requestScreenRecording()
            throw SessionError("Screen Recording permission is missing. Allow DrawPlay in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen it.")
        }
        if !Permissions.accessibility {
            onLog("Accessibility permission is missing: the tablet will show the screen but cannot control the Mac.")
        }

        let cfg = config
        let log = onLog
        currentPortrait = cfg.orientation == .portrait
        wantedPortrait = currentPortrait
        let (pw, ph) = pixels(portrait: currentPortrait)
        onLog("Creating the virtual display…")
        let made = await Task.detached { VirtualDisplay.make(pixelWidth: pw, pixelHeight: ph, hz: Double(cfg.fps),
                                                            hidpi: cfg.hidpi, log: log) }.value
        guard let (vd, info) = made else { throw SessionError("Could not create the virtual display.") }
        display = vd
        displayDescription = info.description
        onLog("Virtual display \(vd.id): \(info.description)")
        onDisplay(info.description)
        injector.displayID = vd.id

        streamer.onLog = { [weak self] in self?.onLog($0) }
        streamer.onPacket = { [weak self] p in
            guard let self else { return }
            switch p.kind {
            case 4: self.tabletOrientation(portrait: p.action == 1)
            case 7:                                   // ping reply
                let ms = Double(DispatchTime.now().uptimeNanoseconds &- p.echo) / 1_000_000
                if ms >= 0, ms < 5000 { self.ping = self.ping == 0 ? ms : self.ping * 0.8 + ms * 0.2 }
            default: self.injector.handle(p)
            }
        }
        streamer.onConnect = { [weak self] in
            guard let self else { return }
            self.ping = 0
            self.streamer.send(type: 6, Data([self.cursorHidden ? 1 : 0]))      // is a game holding the mouse right now?
            self.streamer.send(type: 4, Data([self.config.orientation.wireByte]))   // tell the tablet whether to follow or lock
            self.encoder?.requestKeyframe()
            if let f = self.lastFrame { self.encoder?.encode(f) }                   // a still screen produces no new frames
            self.publishStats()
        }
        streamer.onDisconnect = { [weak self] in self?.injector.reset(); self?.publishStats() }

        do { try await startPipeline(info: info) } catch { teardownSync(); throw error }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                       // send small packets at once instead of waiting to batch them
        tcp.enableKeepalive = true               // notice a tablet that vanished (Wi-Fi drop, tablet asleep)
        tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo  // Wi-Fi: use the video queue, which has less waiting
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: cfg.port)!)
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.incoming(c) } }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    await self.stop()
                    self.onEnded("Could not listen on port \(cfg.port): \(e). Is another copy of DrawPlay running?")
                }
            }
        }
        l.start(queue: .main)
        listener = l

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTimer() }
        }
        lockTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCursor() }
        }
        if cfg.keepAwake { sleepGuard.hold(reason: "DrawPlay is streaming to your tablet") }
        focus.onLog = { [weak self] in self?.onLog($0) }
        isRunning = true
        onLog(cfg.mode == .usb ? "Listening on port \(cfg.port) (USB: local connections only)"
                               : "Listening on port \(cfg.port) (Wi-Fi: PIN required)")
        publishStats()
    }

    /// Builds the encoder and starts capturing the display at its current size.
    private func startPipeline(info: DisplayModeInfo) async throws {
        let cfg = config
        let bitrate = Int(Double(info.pixelsW * info.pixelsH * cfg.fps) * cfg.quality.bitsPerPixel)
        targetBitrate = bitrate; currentBitrate = bitrate; dropsInWindow = 0; cleanSeconds = 0
        guard let enc = Encoder(width: info.pixelsW, height: info.pixelsH, fps: cfg.fps, bitrate: bitrate) else {
            throw SessionError("Could not start the video encoder.")
        }
        encoder = enc
        enc.onOutput = { [weak self] type, data in
            DispatchQueue.main.async {
                guard let self else { return }
                if type != 1 { self.frames += 1 }
                if !self.streamer.send(type: type, data) { self.needKey = true; self.dropsInWindow += 1 }   // any drop breaks the reference chain
            }
        }
        capture.onFrame = { [weak self] pb in
            DispatchQueue.main.async {
                guard let self, let enc = self.encoder else { return }
                self.lastFrame = pb
                if self.needKey { enc.requestKeyframe(); self.needKey = false }
                enc.encode(pb)
            }
        }
        guard let vd = display else { throw SessionError("The virtual display is gone.") }
        do {
            try await capture.start(displayID: vd.id, width: info.pixelsW, height: info.pixelsH, fps: cfg.fps)
        } catch {
            throw SessionError("Screen capture failed: \(error.localizedDescription)")
        }
    }

    public func stop() async {
        guard isRunning || display != nil else { return }
        await focus.stop()                  // put the focused app's window back before the display disappears
        isRunning = false
        sleepGuard.release()
        timer?.invalidate(); timer = nil
        lockTimer?.invalidate(); lockTimer = nil
        listener?.cancel(); listener = nil
        streamer.close()
        injector.reset()
        encoder?.onOutput = nil
        await capture.stop()
        encoder?.invalidate(); encoder = nil
        lastFrame = nil
        display = nil                       // releasing the object removes the virtual monitor
        publishStats()
        onLog("Stopped")
    }

    public func startFocus(pid: pid_t) async throws {
        guard isRunning, let vd = display else { throw SessionError("Start streaming first.") }
        try await focus.start(pid: pid, onDisplay: vd.id)
    }

    public func stopFocus() async { await focus.stop() }

    private func teardownSync() {
        encoder?.invalidate(); encoder = nil
        display = nil
    }

    // MARK: rotation (Auto mode)

    private func tabletOrientation(portrait: Bool) {
        wantedPortrait = portrait
        guard config.orientation == .auto else { return }     // fixed orientation: the tablet follows the Mac instead
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard isRunning, !reconfiguring, wantedPortrait != currentPortrait, let vd = display else { return }
        reconfiguring = true
        let target = wantedPortrait
        let cfg = config
        let log = onLog
        let (pw, ph) = pixels(portrait: target)
        Task { @MainActor in
            onLog("Tablet turned \(target ? "upright" : "sideways"): changing the display…")
            capture.onFrame = nil
            await capture.stop()
            encoder?.onOutput = nil
            encoder?.invalidate(); encoder = nil
            let info = await Task.detached { vd.setMode(pixelWidth: pw, pixelHeight: ph, hz: Double(cfg.fps), hidpi: cfg.hidpi, log: log) }.value
            guard let info else {
                reconfiguring = false
                await stop()
                onEnded("Could not change the display for the new orientation.")
                return
            }
            do { try await startPipeline(info: info) } catch {
                reconfiguring = false
                await stop()
                onEnded(error.localizedDescription)
                return
            }
            currentPortrait = target
            displayDescription = info.description
            lastFrame = nil
            encoder?.requestKeyframe()
            onLog("Display is now \(info.description)")
            onDisplay(info.description)
            reconfiguring = false
            rotateIfNeeded()                           // the tablet may have turned again meanwhile
        }
    }

    // MARK: connections

    private func incoming(_ c: NWConnection) {
        if config.mode == .usb, !Session.isLoopback(c.endpoint) {
            onLog("Refused a non-local connection in USB mode")
            c.cancel(); return
        }
        if Date() < lockedUntil { c.cancel(); return }
        streamer.accept(c) { [weak self] pin in
            guard let self else { return false }
            if self.config.mode == .usb { return true }
            if pin == self.config.pin { self.failures = 0; return true }
            self.failures += 1
            self.onLog("Rejected a tablet with the wrong PIN (\(self.failures)/5)")
            if self.failures >= 5 { self.lockedUntil = Date().addingTimeInterval(30); self.failures = 0; self.onLog("Too many wrong PINs: locked for 30 seconds") }
            return false
        }
    }

    nonisolated static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.isIPv4Mapped && a.asIPv4?.isLoopback == true
        default: return false
        }
    }

    // MARK: adaptive bitrate

    /// If frames keep being dropped (Wi-Fi can't carry the bitrate), back off 25%; once it has been clean for 10 s, creep back up.
    private func adaptBitrate() {
        guard let enc = encoder, streamer.isConnected else { dropsInWindow = 0; return }
        if dropsInWindow >= 2 {
            currentBitrate = max(Int(Double(currentBitrate) * 0.75), targetBitrate * 3 / 10)
            enc.setBitrate(currentBitrate); cleanSeconds = 0
            onLog(String(format: "Network is struggling: lowering the video to %.0f Mbit/s", Double(currentBitrate) / 1_000_000))
        } else if dropsInWindow == 0 {
            cleanSeconds += 2
            if cleanSeconds >= 10, currentBitrate < targetBitrate {
                currentBitrate = min(Int(Double(currentBitrate) * 1.15), targetBitrate)
                enc.setBitrate(currentBitrate); cleanSeconds = 0
            }
        }
        dropsInWindow = 0
    }

    // MARK: game mouse lock

    /// A game that hides the cursor wants raw mouse movement. Tell the tablet, so it captures its trackpad the same way.
    private func pollCursor() {
        guard streamer.isConnected else { cursorChangeStreak = 0; return }
        let hidden = CursorWatch.isHidden()
        if hidden == cursorHidden { cursorChangeStreak = 0; return }
        cursorChangeStreak += 1
        guard cursorChangeStreak >= 2 else { return }          // ignore a one-sample blip
        cursorHidden = hidden; cursorChangeStreak = 0
        streamer.send(type: 6, Data([hidden ? 1 : 0]))
    }

    // MARK: stats

    private func onTimer() {
        injector.tick()
        tick += 1
        if tick % 8 == 0 { adaptBitrate() }
        if tick % 4 == 0 {
            if streamer.isConnected {                 // once a second: how long does a round trip to the tablet take?
                var t = DispatchTime.now().uptimeNanoseconds.littleEndian
                streamer.send(type: 5, Data(bytes: &t, count: 8))
            }
            publishStats()
        }
    }

    private func publishStats() {
        var s = Stats()
        s.fps = frames - lastFrames
        s.mbps = Double(streamer.bytesSent &- lastBytes) * 8 / 1_000_000
        lastFrames = frames; lastBytes = streamer.bytesSent
        s.tabletConnected = streamer.isConnected
        s.pingMs = s.tabletConnected ? ping : 0
        s.targetMbps = Double(currentBitrate) / 1_000_000
        s.encodeMs = encoder?.encodeMs ?? 0
        onStats(s)
    }
}
