import CoreGraphics
import Foundation

/// Turns tablet packets into macOS events.
/// Pen: mouse events marked as tablet points, with proximity events, so drawing apps see a real pen
/// (pressure, tilt, eraser end, barrel button). Touch: click/drag with one finger, scroll with two.
/// All calls happen on the main queue.
final class Injector {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var bounds: CGRect { CGDisplayBounds(displayID) }
    private let src = CGEventSource(stateID: .hidSystemState)
    private static let deviceID: Int64 = 0x4450      // arbitrary, stable id for our virtual pen

    // pen
    private var inProximity = false, penDown = false, penEraser = false
    private var penButton = CGMouseButton.left
    private var lastPenTime = ProcessInfo.processInfo.systemUptime
    private var lastPenLocation = CGPoint.zero

    // touch
    private lazy var touch = TouchRecognizer(output: self)

    // double-click counting, shared by pen and finger
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int)?

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let b = bounds
        return CGPoint(x: min(b.minX + CGFloat(x) * b.width, b.maxX - 0.5),
                       y: min(b.minY + CGFloat(y) * b.height, b.maxY - 0.5))
    }

    func handle(_ p: Packet) {
        switch p.kind {
        case 2: finger(p)
        case 3: key(p)
        case 5: mouse(p)
        case 6: wheel(p)
        case 0, 1: pen(p)
        default: break          // kind 4 (orientation) is handled by the session
        }
    }

    // MARK: keyboard (tablet on-screen keyboard)

    private var keysDown = Set<UInt16>()
    private var modifiersHeld = false
    private static let modifierKeys: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]   // right/left Command, Shift, Option, Control

    private func flags(from bits: UInt8) -> CGEventFlags {
        var f = CGEventFlags()
        if bits & 1 != 0 { f.insert(.maskShift) }
        if bits & 2 != 0 { f.insert(.maskControl) }
        if bits & 4 != 0 { f.insert(.maskAlternate) }
        if bits & 8 != 0 { f.insert(.maskCommand) }
        if bits & 16 != 0 { f.insert(.maskAlphaShift) }       // caps lock
        return f
    }

    /// Key packet: keyCode = macOS virtual key, `buttons` = modifiers now held (1 shift, 2 ctrl, 4 option, 8 command, 16 caps),
    /// `pointer` = 1 for a key-repeat. A modifier key by itself is posted as a flags-changed event, like a real keyboard.
    private func key(_ p: Packet) {
        let down = p.action == 0
        let f = flags(from: p.buttons)
        if Self.modifierKeys.contains(p.keyCode) {
            guard let e = CGEvent(source: src) else { return }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(p.keyCode))
            e.flags = f
            e.post(tap: .cghidEventTap)
            modifiersHeld = !f.subtracting(.maskAlphaShift).isEmpty
            return
        }
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(p.keyCode), keyDown: down) else { return }
        e.flags = f
        if down, p.pointer == 1 { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
        if down { keysDown.insert(p.keyCode) } else { keysDown.remove(p.keyCode) }
    }

    // MARK: mouse / trackpad (tablet keyboard cover)

    private var mouseButtonDown: CGMouseButton?
    private var mouseLocation = CGPoint.zero
    private var lastMousePoint: CGPoint?
    private var remainderX: CGFloat = 0, remainderY: CGFloat = 0     // fractions of a point not yet sent

    private func buttonTypes(_ b: CGMouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch b {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        default: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    /// Mouse packet: action 0 down, 1 up, 2 move, 3 drag. `buttons`: 1 left, 2 right, 4 middle.
    /// `pointer` = 0: x, y are a screen position (0...1). `pointer` = 1 ("relative"): x, y are movement as a fraction of
    /// the screen, applied to wherever the cursor is now. Games that hide the cursor read that movement, not the position,
    /// so every event also carries its movement in the delta fields.
    private func mouse(_ p: Packet) {
        let b = bounds
        let loc: CGPoint
        var dx: Int64 = 0, dy: Int64 = 0
        if p.pointer == 1 {
            let cur = CGEvent(source: nil)?.location ?? mouseLocation        // the game may re-centre the cursor itself
            let fx = CGFloat(p.x) * b.width + remainderX, fy = CGFloat(p.y) * b.height + remainderY
            let ix = fx.rounded(), iy = fy.rounded()                         // nearest whole point; the rest carries over
            remainderX = fx - ix; remainderY = fy - iy
            dx = Int64(ix); dy = Int64(iy)
            loc = CGPoint(x: min(max(cur.x + ix, b.minX), b.maxX - 0.5), y: min(max(cur.y + iy, b.minY), b.maxY - 0.5))
        } else {
            loc = point(p.x, p.y)
            if let last = lastMousePoint { dx = Int64((loc.x - last.x).rounded()); dy = Int64((loc.y - last.y).rounded()) }
            remainderX = 0; remainderY = 0
        }
        lastMousePoint = loc
        mouseLocation = loc
        func post(_ type: CGEventType, _ button: CGMouseButton, clicks: Int = 1) {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: loc, mouseButton: button) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            e.setIntegerValueField(.mouseEventDeltaX, value: dx)
            e.setIntegerValueField(.mouseEventDeltaY, value: dy)
            e.post(tap: .cghidEventTap)
        }
        switch p.action {
        case 0:
            let b: CGMouseButton = p.buttons & 1 != 0 ? .left : (p.buttons & 2 != 0 ? .right : .center)
            mouseButtonDown = b
            post(buttonTypes(b).down, b, clicks: clickCount(at: loc))
        case 3:
            let b = mouseButtonDown ?? .left
            post(buttonTypes(b).drag, b, clicks: lastClick?.count ?? 1)
        case 1:
            let b = mouseButtonDown ?? .left
            post(buttonTypes(b).up, b, clicks: lastClick?.count ?? 1)
            mouseButtonDown = nil
        default:
            post(.mouseMoved, .left)
        }
    }

    /// Scroll packet: x = horizontal and y = vertical wheel amount (Android axis values, positive = up / right).
    private func wheel(_ p: Packet) {
        let px: Float = 40                                    // pixels per wheel step
        let dy = Double(p.y * px), dx = Double(-p.x * px)
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        e.location = mouseLocation
        e.post(tap: .cghidEventTap)
    }

    /// Called a few times a second: lifts a pen that went quiet so it never stays stuck.
    func tick() {
        let idle = ProcessInfo.processInfo.systemUptime - lastPenTime
        if penDown, idle > 2 { postPen(up(penButton), penButton, lastPenLocation, pressure: 0, tx: 0, ty: 0, nx: 0, ny: 0); penDown = false }
        if inProximity, !penDown, idle > 0.6 { proximity(enter: false) }
    }

    /// Releases anything still held (session end or tablet disconnect).
    func reset() {
        if penDown { postPen(up(penButton), penButton, lastPenLocation, pressure: 0, tx: 0, ty: 0, nx: 0, ny: 0); penDown = false }
        if inProximity { proximity(enter: false) }
        touch.reset()
        for k in keysDown { CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: false)?.post(tap: .cghidEventTap) }
        keysDown.removeAll()
        if modifiersHeld, let e = CGEvent(source: src) {            // let go of Shift / Command / ... so none stays stuck
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: 56)
            e.flags = []
            e.post(tap: .cghidEventTap)
            modifiersHeld = false
        }
        if let b = mouseButtonDown, let e = CGEvent(mouseEventSource: src, mouseType: buttonTypes(b).up, mouseCursorPosition: mouseLocation, mouseButton: b) {
            e.post(tap: .cghidEventTap); mouseButtonDown = nil
        }
    }

    // MARK: pen

    private func proximity(enter: Bool) {
        guard let e = CGEvent(source: src) else { return }
        e.type = .tabletProximity
        e.location = lastPenLocation
        e.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
        e.setIntegerValueField(.tabletProximityEventVendorID, value: 0x056A)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: penEraser ? 2 : 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: Self.deviceID)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: penEraser ? 0x080A : 0x0802)
        e.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        // NX_TABLET_CAPABILITY_*: device id, abs x, abs y, buttons, tilt x, tilt y, pressure, rotation.
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0001 | 0x0002 | 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0400 | 0x2000)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: penEraser ? 3 : 1)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        e.post(tap: .cghidEventTap)
        inProximity = enter
    }

    private func pen(_ p: Packet) {
        let eraser = p.kind == 1
        lastPenTime = ProcessInfo.processInfo.systemUptime
        if p.action == 4 {                                   // hover exit
            if penDown { endPenStroke() }
            if inProximity { proximity(enter: false) }
            return
        }
        if inProximity, penEraser != eraser, !penDown { proximity(enter: false) }   // switched tool
        if !inProximity { penEraser = eraser; lastPenLocation = point(p.x, p.y); proximity(enter: true) }

        let loc = point(p.x, p.y)
        lastPenLocation = loc
        let pressure = Double(max(0, min(1, p.pressure)))
        let tx = Double(p.tiltX), ty = Double(p.tiltY)
        let nx = p.x, ny = p.y
        switch p.action {
        case 0:                                              // pen touches the glass
            penButton = (p.buttons & 1) != 0 ? .right : .left   // barrel button held at touch-down = right click
            penDown = true
            postPen(down(penButton), penButton, loc, pressure: pressure, tx: tx, ty: ty, nx: nx, ny: ny, click: clickCount(at: loc))
        case 1:
            if penDown { postPen(drag(penButton), penButton, loc, pressure: pressure, tx: tx, ty: ty, nx: nx, ny: ny) }
            else { postPen(.mouseMoved, .left, loc, pressure: 0, tx: tx, ty: ty, nx: nx, ny: ny) }
        case 2:
            if penDown { endPenStroke(at: loc, tx: tx, ty: ty, nx: nx, ny: ny) }
        default:                                             // hover
            if penDown { endPenStroke(at: loc, tx: tx, ty: ty, nx: nx, ny: ny) }
            postPen(.mouseMoved, .left, loc, pressure: 0, tx: tx, ty: ty, nx: nx, ny: ny)
        }
    }

    private func endPenStroke(at loc: CGPoint? = nil, tx: Double = 0, ty: Double = 0, nx: Float = 0, ny: Float = 0) {
        postPen(up(penButton), penButton, loc ?? lastPenLocation, pressure: 0, tx: tx, ty: ty, nx: nx, ny: ny, click: lastClick?.count ?? 1)
        penDown = false
    }

    private func postPen(_ type: CGEventType, _ button: CGMouseButton, _ loc: CGPoint, pressure: Double,
                         tx: Double, ty: Double, nx: Float, ny: Float, click: Int = 1) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: loc, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        e.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(max(0, min(1, nx)) * 65535))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(max(0, min(1, ny)) * 65535))
        e.setIntegerValueField(.tabletEventPointButtons, value: (penDown ? 1 : 0) | (button == .right ? 2 : 0))
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.tabletEventTiltX, value: tx)
        e.setDoubleValueField(.tabletEventTiltY, value: ty)
        e.setDoubleValueField(.tabletEventRotation, value: 0)
        e.setIntegerValueField(.tabletEventDeviceID, value: Self.deviceID)
        e.post(tap: .cghidEventTap)
    }

    // MARK: touch

    private func finger(_ p: Packet) {
        let pt = point(p.x, p.y)
        switch p.action {
        case 0: touch.down(p.pointer, pt)
        case 1: touch.move(p.pointer, pt)
        default: touch.up(p.pointer, pt)
        }
    }

    // MARK: helpers

    private func mouse(_ type: CGEventType, _ p: CGPoint, click: Int = 1) -> CGEvent? {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        return e
    }

    private func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

    /// 1 for a fresh click, 2 for a quick second click nearby, and so on, so double-click works.
    func clickCount(at p: CGPoint) -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        var n = 1
        if let l = lastClick, now - l.time < 0.4, hypot(l.point.x - p.x, l.point.y - p.y) < 12 { n = l.count + 1 }
        lastClick = (now, p, n)
        return n
    }

    private func down(_ b: CGMouseButton) -> CGEventType { b == .right ? .rightMouseDown : .leftMouseDown }
    private func up(_ b: CGMouseButton) -> CGEventType { b == .right ? .rightMouseUp : .leftMouseUp }
    private func drag(_ b: CGMouseButton) -> CGEventType { b == .right ? .rightMouseDragged : .leftMouseDragged }

}

extension Injector: TouchOutput {
    func moveCursor(to p: CGPoint) {
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func mouse(_ type: CGEventType, at p: CGPoint, clicks: Int) {
        let right = type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }

    func scroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentum: Int64, at p: CGPoint) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
        e.location = p
        e.post(tap: .cghidEventTap)
    }

    /// Gesture events are CGEvents of type 29 (NSEvent "gesture"). Field 110 = kind (8 zoom, 5 rotate),
    /// 113 = magnification, 114 = rotation in degrees, 132 = phase (1 began, 2 changed, 4 ended).
    /// Verified to reach `magnify(with:)` / `rotate(with:)` on macOS 27.
    private func gesture(kind: Int64, valueField: UInt32, value: Double, phase: Int64, at p: CGPoint) {
        guard let e = CGEvent(source: nil), let t = CGEventType(rawValue: 29),
              let fKind = CGEventField(rawValue: 110), let fValue = CGEventField(rawValue: valueField), let fPhase = CGEventField(rawValue: 132) else { return }
        e.type = t
        e.location = p
        e.setIntegerValueField(fKind, value: kind)
        e.setDoubleValueField(fValue, value: value)
        e.setIntegerValueField(fPhase, value: phase)
        e.post(tap: .cghidEventTap)
    }

    func magnify(_ delta: Double, phase: Int64, at p: CGPoint) { gesture(kind: 8, valueField: 113, value: delta, phase: phase, at: p) }
    func rotate(degrees: Double, phase: Int64, at p: CGPoint) { gesture(kind: 5, valueField: 114, value: degrees, phase: phase, at: p) }

    func shortcut(_ key: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }
}
