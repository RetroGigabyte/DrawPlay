import AppKit
import Foundation

/// Sends keyboard / trackpad packets through the real Injector into a small window owned by this test,
/// and checks what that window receives. Nothing is sent to other apps. `drawplayd --selftest-input`.
@MainActor
public enum InputSelfTest {
    private final class Sink: NSView {
        var log: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) { log.append("keyDown\(e.keyCode)\(e.modifierFlags.contains(.shift) ? "+shift" : "")\(e.isARepeat ? " repeat" : "")") }
        override func keyUp(with e: NSEvent) { log.append("keyUp\(e.keyCode)") }
        override func flagsChanged(with e: NSEvent) {
            let f = e.modifierFlags
            log.append("flags[\(f.contains(.command) ? "cmd" : "")\(f.contains(.shift) ? "shift" : "")\(f.contains(.option) ? "opt" : "")\(f.contains(.control) ? "ctrl" : "")] key\(e.keyCode)")
        }
        override func mouseDown(with e: NSEvent) { log.append("leftDown clicks=\(e.clickCount)") }
        override func mouseUp(with e: NSEvent) { log.append("leftUp") }
        override func mouseDragged(with e: NSEvent) { log.append("leftDrag") }
        override func rightMouseDown(with e: NSEvent) { log.append("rightDown") }
        override func rightMouseUp(with e: NSEvent) { log.append("rightUp") }
        override func mouseMoved(with e: NSEvent) { log.append(String(format: "moved %.0f %.0f", e.deltaX, e.deltaY)) }
        override func scrollWheel(with e: NSEvent) { log.append(String(format: "scroll dy=%.0f dx=%.0f", e.scrollingDeltaY, e.scrollingDeltaX)) }
    }

    private static func packet(kind: UInt8, action: UInt8, pointer: UInt8 = 0, buttons: UInt8 = 0, x: Float = 0, y: Float = 0, key: UInt16 = 0) -> Packet {
        var d = Data(count: Packet.size)
        d[0] = kind; d[1] = action; d[2] = pointer; d[3] = buttons
        if kind == 3 { d[4] = UInt8(key & 0xFF); d[5] = UInt8(key >> 8) }
        else {
            for (i, f) in [x, y].enumerated() { withUnsafeBytes(of: f.bitPattern.littleEndian) { for j in 0..<4 { d[4 + i * 4 + j] = $0[j] } } }
        }
        return Packet(d)!
    }

    public static func run() async -> (report: String, passed: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let win = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 360, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        let sink = Sink(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        win.contentView = sink
        win.level = .floating
        win.acceptsMouseMovedEvents = true
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        win.makeFirstResponder(sink)
        app.activate(ignoringOtherApps: true)

        func pump(_ t: Double = 0.12) {
            let end = Date().addingTimeInterval(t)
            while Date() < end {
                while let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { app.sendEvent(e) }
            }
        }
        pump(0.6)

        let inj = Injector()
        let main = CGDisplayBounds(CGMainDisplayID())
        let f = win.frame
        let cx = Float(f.midX / main.width), cy = Float((main.height - f.midY) / main.height)      // window centre, 0...1 on screen
        var lines: [String] = [], ok = true
        func check(_ name: String, _ cond: Bool, _ got: [String]) {
            lines.append("\(cond ? "PASS" : "FAIL")  \(name): \(got.joined(separator: ", "))")
            if !cond { ok = false }
        }
        func scenario(_ steps: [Packet]) -> [String] {
            sink.log.removeAll()
            for s in steps { inj.handle(s); pump(0.08) }
            pump(0.15)
            return sink.log.filter { !$0.hasPrefix("moved") }
        }

        // keyboard (F19 is unmapped, so a stray key does no harm even if something else is listening)
        let k1 = scenario([packet(kind: 3, action: 0, buttons: 1, key: 80), packet(kind: 3, action: 1, buttons: 1, key: 80)])
        check("key with Shift held", k1.first == "keyDown80+shift" && k1.contains("keyUp80"), k1)
        let k2 = scenario([packet(kind: 3, action: 0, buttons: 0, key: 80), packet(kind: 3, action: 0, pointer: 1, key: 80), packet(kind: 3, action: 1, key: 80)])
        check("held key repeats", k2.contains("keyDown80 repeat"), k2)
        let k3 = scenario([packet(kind: 3, action: 0, buttons: 8, key: 55), packet(kind: 3, action: 1, buttons: 0, key: 55)])
        check("Command alone is a modifier change", k3 == ["flags[cmd] key55", "flags[] key55"], k3)

        // trackpad / mouse
        let m1 = scenario([packet(kind: 5, action: 2, x: cx, y: cy), packet(kind: 5, action: 0, buttons: 1, x: cx, y: cy), packet(kind: 5, action: 1, buttons: 1, x: cx, y: cy)])
        check("left click", m1 == ["leftDown clicks=1", "leftUp"], m1)
        let m2 = scenario([packet(kind: 5, action: 0, buttons: 1, x: cx, y: cy), packet(kind: 5, action: 1, buttons: 1, x: cx, y: cy),
                           packet(kind: 5, action: 0, buttons: 1, x: cx, y: cy), packet(kind: 5, action: 1, buttons: 1, x: cx, y: cy)])
        check("double click counts to 2", m2.contains("leftDown clicks=2"), m2)
        Thread.sleep(forTimeInterval: 0.5)
        let m3 = scenario([packet(kind: 5, action: 0, buttons: 2, x: cx, y: cy), packet(kind: 5, action: 1, buttons: 2, x: cx, y: cy)])
        check("right click", m3 == ["rightDown", "rightUp"], m3)
        let m4 = scenario([packet(kind: 5, action: 0, buttons: 1, x: cx, y: cy), packet(kind: 5, action: 3, buttons: 1, x: cx + 0.01, y: cy),
                           packet(kind: 5, action: 3, buttons: 1, x: cx + 0.02, y: cy), packet(kind: 5, action: 1, buttons: 1, x: cx + 0.02, y: cy)])
        check("drag", m4.first?.hasPrefix("leftDown") == true && m4.contains("leftDrag") && m4.last == "leftUp", m4)
        let m5 = scenario([packet(kind: 5, action: 2, x: cx, y: cy), packet(kind: 6, action: 0, x: 0, y: 1)])
        check("wheel up scrolls 40 px", m5.contains { $0.hasPrefix("scroll dy=40") }, m5)
        let m6 = scenario([packet(kind: 6, action: 0, x: 1, y: 0)])
        check("wheel right moves content left", m6.contains { $0.hasPrefix("scroll dy=0 dx=-40") }, m6)

        // relative movement (what a game with a hidden cursor reads)
        func moves(_ steps: [Packet]) -> [String] { sink.log.removeAll(); for s in steps { inj.handle(s); pump(0.08) }; pump(0.15); return sink.log.filter { $0.hasPrefix("moved") } }
        let w = Float(main.width), h = Float(main.height)
        let r1 = moves([packet(kind: 5, action: 2, x: cx, y: cy),
                        packet(kind: 5, action: 2, pointer: 1, x: 10 / w, y: -4 / h), packet(kind: 5, action: 2, pointer: 1, x: -10 / w, y: 25 / h)])
        check("relative moves arrive as deltas", r1.contains("moved 10 -4") && r1.contains("moved -10 25"), r1)
        let r2 = moves([packet(kind: 5, action: 2, pointer: 1, x: 0.4 / w, y: 0), packet(kind: 5, action: 2, pointer: 1, x: 0.4 / w, y: 0), packet(kind: 5, action: 2, pointer: 1, x: 0.4 / w, y: 0)])
        check("fractions add up (3 x 0.4 = 1 point)", r2.filter { $0 == "moved 1 0" }.count == 1, r2)
        let r3 = moves([packet(kind: 5, action: 2, x: cx, y: cy), packet(kind: 5, action: 2, x: cx + 30 / w, y: cy)])
        check("absolute moves carry their movement too", r3.contains("moved 30 0"), r3)

        inj.reset()
        win.close()
        return (lines.joined(separator: "\n"), ok)
    }
}
