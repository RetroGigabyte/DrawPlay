import AppKit
import ApplicationServices
import Foundation

public struct FocusApp: Identifiable, Hashable {
    public let pid: pid_t
    public let name: String
    public var id: pid_t { pid }
}

/// "Focus mode": shows one app full-screen on the tablet's display. The app's main window is moved onto the
/// virtual display and put into macOS full screen, so the tablet shows only that app. Stopping puts the window
/// back where it was. Uses the Accessibility API, so it needs the Accessibility permission.
@MainActor
public final class Focus {
    public private(set) var active: FocusApp?
    public var onLog: (String) -> Void = { _ in }

    private var window: AXUIElement?
    private var savedPosition = CGPoint.zero, savedSize = CGSize.zero
    private var enteredFullScreen = false

    public init() {}

    /// Regular apps that are running and could be focused (not DrawPlay itself).
    public static func runningApps() -> [FocusApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            .compactMap { app in app.localizedName.map { FocusApp(pid: app.processIdentifier, name: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Accessibility helpers

    private func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = copy(el, attr) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = copy(el, attr) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult private func set(_ el: AXUIElement, position p: CGPoint) -> Bool {
        var p = p
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult private func set(_ el: AXUIElement, size s: CGSize) -> Bool {
        var s = s
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) == .success
    }

    private func isFullScreen(_ el: AXUIElement) -> Bool { (copy(el, "AXFullScreen") as? Bool) == true }

    @discardableResult private func setFullScreen(_ el: AXUIElement, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, "AXFullScreen" as CFString, on as CFBoolean) == .success
    }

    private func mainWindow(of app: AXUIElement) -> AXUIElement? {
        for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let w = copy(app, attr as String) { return (w as! AXUIElement) }
        }
        if let list = copy(app, kAXWindowsAttribute as String) as? [AXUIElement], let first = list.first { return first }
        return nil
    }

    private func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    // MARK: start / stop

    public func start(pid: pid_t, onDisplay displayID: CGDirectDisplayID) async throws {
        guard Permissions.accessibility else { throw SessionError("Focus mode needs the Accessibility permission.") }
        if active != nil { await stop() }
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { throw SessionError("That app is not running.") }
        let axApp = AXUIElementCreateApplication(pid)
        guard let w = mainWindow(of: axApp) else { throw SessionError("\(running.localizedName ?? "That app") has no window to show. Open a document or window in it first.") }
        guard let pos = point(w, kAXPositionAttribute as String), let sz = size(w, kAXSizeAttribute as String) else {
            throw SessionError("Could not read the window of \(running.localizedName ?? "that app").")
        }
        window = w; savedPosition = pos; savedSize = sz; enteredFullScreen = false
        active = FocusApp(pid: pid, name: running.localizedName ?? "App")

        if isFullScreen(w) { setFullScreen(w, false); await pause(1.3) }      // leave the app's own full screen first
        let bounds = CGDisplayBounds(displayID)
        set(w, size: bounds.size); set(w, position: bounds.origin); set(w, size: bounds.size)   // size, move, size again (macOS may clamp)
        running.activate(options: [.activateIgnoringOtherApps])
        await pause(0.4)
        if setFullScreen(w, true) {
            await pause(1.3)
            enteredFullScreen = isFullScreen(w)
        }
        onLog(enteredFullScreen ? "Focus mode: \(active!.name) is full screen on the tablet"
                                : "Focus mode: \(active!.name) fills the tablet (this app has no full-screen mode)")
    }

    public func stop() async {
        guard let w = window, let app = active else { return }
        if enteredFullScreen, isFullScreen(w) { setFullScreen(w, false); await pause(1.3) }
        set(w, size: savedSize); set(w, position: savedPosition); set(w, size: savedSize)
        onLog("Focus mode ended: \(app.name) is back where it was")
        window = nil; active = nil; enteredFullScreen = false
    }

    /// For tests: where the focused window is right now.
    func currentFrame() -> (pos: CGPoint, size: CGSize, full: Bool)? {
        guard let w = window, let p = point(w, kAXPositionAttribute as String), let s = size(w, kAXSizeAttribute as String) else { return nil }
        return (p, s, isFullScreen(w))
    }
}

/// `drawplayd --probe-focus "TextEdit"`: puts the app's window on a temporary display and back. Needs Accessibility.
@MainActor
public enum FocusProbe {
    public static func run(appName: String) async -> String {
        var lines: [String] = []
        guard Permissions.accessibility else { return "Accessibility permission is missing for this program." }
        guard let app = Focus.runningApps().first(where: { $0.name.localizedCaseInsensitiveContains(appName) }) else {
            return "No running app named \"\(appName)\". Open it (with a window) and try again."
        }
        guard let (vd, info) = VirtualDisplay.make(pixelWidth: 1600, pixelHeight: 1000, hz: 60, hidpi: false, serial: 9998, log: { lines.append($0) }) else {
            return "Could not create the test display."
        }
        let b = CGDisplayBounds(vd.id)
        lines.append("test display \(vd.id): \(info.description), bounds origin (\(Int(b.minX)), \(Int(b.minY))) size \(Int(b.width))x\(Int(b.height))")
        let f = Focus()
        f.onLog = { lines.append($0) }
        do { try await f.start(pid: app.pid, onDisplay: vd.id) } catch { return (lines + ["start failed: \(error.localizedDescription)"]).joined(separator: "\n") }
        if let c = f.currentFrame() { lines.append("while focused: window at (\(Int(c.pos.x)), \(Int(c.pos.y))) size \(Int(c.size.width))x\(Int(c.size.height)) fullscreen=\(c.full)") }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await f.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        lines.append("after stop, focus active = \(f.active != nil)")
        return lines.joined(separator: "\n")
    }
}
