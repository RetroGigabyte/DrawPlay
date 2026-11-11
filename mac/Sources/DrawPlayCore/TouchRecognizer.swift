import CoreGraphics
import Foundation

/// What the recognizer asks the Mac to do. `Injector` implements it with CGEvents.
protocol TouchOutput: AnyObject {
    func moveCursor(to p: CGPoint)
    func mouse(_ type: CGEventType, at p: CGPoint, clicks: Int)
    /// phase: 1 began, 2 changed, 4 ended. momentum: 1 begin, 2 continue, 3 end.
    func scroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentum: Int64, at p: CGPoint)
    func magnify(_ delta: Double, phase: Int64, at p: CGPoint)
    func rotate(degrees: Double, phase: Int64, at p: CGPoint)
    func shortcut(_ key: CGKeyCode, flags: CGEventFlags)
    func clickCount(at p: CGPoint) -> Int
}

/// Turns raw finger positions (in screen points) into trackpad-like behaviour:
///   1 finger   tap = click, drag = drag
///   2 fingers  scroll (with momentum), pinch = zoom, twist = rotate, tap = right click
///   3 fingers  swipe left/right = switch Space, up = Mission Control, down = App Exposé
final class TouchRecognizer {
    private unowned let out: TouchOutput
    init(output: TouchOutput) { out = output }

    // thresholds, in points / seconds / degrees
    private let slop: CGFloat = 6, pressDelay = 0.12, tapTime = 0.30
    private let pinchStart: CGFloat = 14, rotateStart: CGFloat = 8, scrollStart: CGFloat = 6, swipeDistance: CGFloat = 70

    private struct Finger { var start: CGPoint; var pos: CGPoint }
    private var fingers: [UInt8: Finger] = [:]
    private enum Mode { case idle, pending, pointer, two, three, dead }
    private var mode = Mode.idle

    // one finger
    private var primary: UInt8 = 0
    private var pendingWork: DispatchWorkItem?
    private var pointerClicks = 1

    // two fingers
    private enum Kind { case undecided, scroll, zoom }
    private var kind = Kind.undecided
    private var c0 = CGPoint.zero, d0: CGFloat = 1, a0: CGFloat = 0
    private var lastC = CGPoint.zero, lastD: CGFloat = 1, lastA: CGFloat = 0
    private var twoStart: TimeInterval = 0, lastMove: TimeInterval = 0
    private var maxTravel: CGFloat = 0
    private var pinching = false, rotating = false
    private var velocity = CGPoint.zero

    // three fingers
    private var threeStart = CGPoint.zero, swipeDone = false

    // momentum
    private var momentumTimer: Timer?
    private var momentumVelocity = CGPoint.zero, momentumFirst = true

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: input

    func down(_ id: UInt8, _ p: CGPoint) {
        stopMomentum()
        fingers[id] = Finger(start: p, pos: p)
        switch fingers.count {
        case 1:
            mode = .pending; primary = id
            let work = DispatchWorkItem { [weak self] in self?.commitPointer() }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pressDelay, execute: work)
        case 2:
            if mode == .pending { cancelPending() }
            else if mode == .pointer, let f = fingers[primary] { out.mouse(.leftMouseUp, at: f.pos, clicks: pointerClicks) }
            if mode == .pending || mode == .pointer || mode == .idle { beginTwo() } else { mode = .dead }
        case 3:
            if mode == .two { endTwoGesture() }
            if mode == .pending { cancelPending() }
            if mode == .pointer, let f = fingers[primary] { out.mouse(.leftMouseUp, at: f.pos, clicks: pointerClicks) }
            mode = .three; threeStart = centroid(); swipeDone = false
        default:
            if mode == .two { endTwoGesture() }
            mode = .dead
        }
    }

    func move(_ id: UInt8, _ p: CGPoint) {
        guard fingers[id] != nil else { return }
        fingers[id]?.pos = p
        switch mode {
        case .pending:
            if let f = fingers[primary], hypot(f.pos.x - f.start.x, f.pos.y - f.start.y) > slop { cancelPending(); commitPointer() }
        case .pointer:
            if id == primary { out.mouse(.leftMouseDragged, at: p, clicks: pointerClicks) }
        case .two: moveTwo()
        case .three: moveThree()
        default: break
        }
    }

    func up(_ id: UInt8, _ p: CGPoint) {
        guard let f = fingers[id] else { return }
        fingers[id]?.pos = p
        switch mode {
        case .pending:
            cancelPending()                                   // a quick tap: click now
            let c = out.clickCount(at: f.start)
            out.mouse(.leftMouseDown, at: f.start, clicks: c)
            out.mouse(.leftMouseUp, at: f.start, clicks: c)
        case .pointer:
            out.mouse(.leftMouseUp, at: p, clicks: pointerClicks)
        case .two:
            finishTwo()
        default: break
        }
        fingers[id] = nil
        if fingers.isEmpty { mode = .idle }
        else if mode == .two || mode == .three || mode == .pointer || mode == .pending { mode = .dead }   // leftover fingers do nothing
    }

    /// Lets go of everything (session end, tablet disconnect).
    func reset() {
        cancelPending(); stopMomentum()
        if mode == .pointer, let f = fingers[primary] { out.mouse(.leftMouseUp, at: f.pos, clicks: pointerClicks) }
        if mode == .two { endTwoGesture() }
        fingers.removeAll(); mode = .idle
    }

    // MARK: one finger

    private func cancelPending() { pendingWork?.cancel(); pendingWork = nil }

    private func commitPointer() {
        guard mode == .pending, let f = fingers[primary] else { return }
        pendingWork = nil
        pointerClicks = out.clickCount(at: f.start)
        out.mouse(.leftMouseDown, at: f.start, clicks: pointerClicks)
        mode = .pointer
        if f.pos != f.start { out.mouse(.leftMouseDragged, at: f.pos, clicks: pointerClicks) }
    }

    // MARK: two fingers

    private func pair() -> (c: CGPoint, d: CGFloat, a: CGFloat)? {
        let ids = fingers.keys.sorted().prefix(2)
        guard ids.count == 2, let p1 = fingers[ids[ids.startIndex]]?.pos, let p2 = fingers[ids[ids.index(after: ids.startIndex)]]?.pos else { return nil }
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        return (CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2), max(hypot(dx, dy), 1), atan2(dy, dx) * 180 / .pi)
    }

    private func angleDiff(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    private func beginTwo() {
        guard let m = pair() else { mode = .dead; return }
        mode = .two; kind = .undecided
        c0 = m.c; lastC = m.c; d0 = m.d; lastD = m.d; a0 = m.a; lastA = m.a
        twoStart = now; lastMove = twoStart; maxTravel = 0
        pinching = false; rotating = false; velocity = .zero
        out.moveCursor(to: m.c)                               // gestures act where the fingers are
    }

    private func moveTwo() {
        guard let m = pair() else { return }
        let t = now
        let travel = hypot(m.c.x - c0.x, m.c.y - c0.y)
        maxTravel = max(maxTravel, travel, abs(m.d - d0))
        if kind == .undecided {
            let zoomScore = max(abs(m.d - d0) / pinchStart, abs(angleDiff(m.a, a0)) / rotateStart)
            let scrollScore = travel / scrollStart
            if zoomScore >= 1 && zoomScore >= scrollScore { kind = .zoom }
            else if scrollScore >= 1 { kind = .scroll; lastC = c0 }
        }
        switch kind {
        case .scroll:
            let dx = m.c.x - lastC.x, dy = m.c.y - lastC.y
            let first = lastC == c0 && lastMove == twoStart
            out.scroll(dx: dx, dy: dy, phase: first ? 1 : 2, momentum: 0, at: m.c)
            let dt = max(t - lastMove, 0.001)
            velocity = CGPoint(x: velocity.x * 0.6 + dx / dt * 0.4, y: velocity.y * 0.6 + dy / dt * 0.4)
            lastC = m.c; lastMove = t
        case .zoom:
            if !pinching, abs(m.d - d0) > pinchStart { pinching = true; lastD = d0; send(magnifyTo: m.d, phase: 1, at: m.c) }
            else if pinching { send(magnifyTo: m.d, phase: 2, at: m.c) }
            if !rotating, abs(angleDiff(m.a, a0)) > rotateStart { rotating = true; lastA = a0; send(rotateTo: m.a, phase: 1, at: m.c) }
            else if rotating { send(rotateTo: m.a, phase: 2, at: m.c) }
            lastC = m.c
        default: break
        }
    }

    private func send(magnifyTo d: CGFloat, phase: Int64, at p: CGPoint) {
        out.magnify(Double(d / lastD - 1), phase: phase, at: p); lastD = d
    }

    private func send(rotateTo a: CGFloat, phase: Int64, at p: CGPoint) {
        out.rotate(degrees: Double(-angleDiff(a, lastA)), phase: phase, at: p); lastA = a     // screen y points down, so flip
    }

    /// A finger lifted: end the gesture, or treat a quick motionless touch as a right click.
    private func finishTwo() {
        switch kind {
        case .scroll:
            out.scroll(dx: 0, dy: 0, phase: 4, momentum: 0, at: lastC)
            if now - lastMove < 0.08, hypot(velocity.x, velocity.y) > 150 { startMomentum(velocity, at: lastC) }
        case .zoom:
            if pinching { out.magnify(0, phase: 4, at: lastC) }
            if rotating { out.rotate(degrees: 0, phase: 4, at: lastC) }
        case .undecided:
            if now - twoStart < tapTime, maxTravel < slop * 2 {
                out.mouse(.rightMouseDown, at: c0, clicks: 1)
                out.mouse(.rightMouseUp, at: c0, clicks: 1)
            }
        }
        kind = .undecided
    }

    /// A third finger arrived mid-gesture: close the two-finger gesture cleanly.
    private func endTwoGesture() {
        if kind == .scroll { out.scroll(dx: 0, dy: 0, phase: 4, momentum: 0, at: lastC) }
        if kind == .zoom {
            if pinching { out.magnify(0, phase: 4, at: lastC) }
            if rotating { out.rotate(degrees: 0, phase: 4, at: lastC) }
        }
        kind = .undecided
    }

    // MARK: three fingers

    private func centroid() -> CGPoint {
        let v = fingers.values.map(\.pos)
        guard !v.isEmpty else { return .zero }
        return CGPoint(x: v.map(\.x).reduce(0, +) / CGFloat(v.count), y: v.map(\.y).reduce(0, +) / CGFloat(v.count))
    }

    private func moveThree() {
        guard !swipeDone else { return }
        let c = centroid(), dx = c.x - threeStart.x, dy = c.y - threeStart.y
        guard max(abs(dx), abs(dy)) > swipeDistance else { return }
        swipeDone = true
        // System shortcuts (Keyboard > Keyboard Shortcuts > Mission Control): Control + arrow keys.
        if abs(dx) > abs(dy) { out.shortcut(dx < 0 ? 124 : 123, flags: .maskControl) }    // swipe left = next Space
        else { out.shortcut(dy < 0 ? 126 : 125, flags: .maskControl) }                    // up = Mission Control, down = App Exposé
    }

    // MARK: momentum (the glide after a flick)

    private func startMomentum(_ v: CGPoint, at p: CGPoint) {
        stopMomentum()
        momentumVelocity = v; momentumFirst = true
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.momentumTick(at: p) }
        }
    }

    private func momentumTick(at p: CGPoint) {
        let dt: CGFloat = 1.0 / 60
        momentumVelocity = CGPoint(x: momentumVelocity.x * 0.95, y: momentumVelocity.y * 0.95)
        if hypot(momentumVelocity.x, momentumVelocity.y) < 25 {
            out.scroll(dx: 0, dy: 0, phase: 0, momentum: 3, at: p)
            momentumTimer?.invalidate(); momentumTimer = nil
            return
        }
        out.scroll(dx: momentumVelocity.x * dt, dy: momentumVelocity.y * dt, phase: 0, momentum: momentumFirst ? 1 : 2, at: p)
        momentumFirst = false
    }

    private func stopMomentum() {
        guard momentumTimer != nil else { return }
        momentumTimer?.invalidate(); momentumTimer = nil
        out.scroll(dx: 0, dy: 0, phase: 0, momentum: 3, at: lastC)
    }
}
