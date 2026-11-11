import CoreGraphics
import Foundation

/// Feeds scripted finger movements through the real recognizer and checks what it would send to the Mac.
/// Run with `drawplayd --selftest-touch`. Needs no permissions and posts no events.
@MainActor
public enum TouchSelfTest {
    private final class Mock: TouchOutput {
        var log: [String] = []
        var magSum = 1.0, rotSum = 0.0
        func moveCursor(to p: CGPoint) {}
        func mouse(_ type: CGEventType, at p: CGPoint, clicks: Int) {
            let n: String
            switch type {
            case .leftMouseDown: n = "down"
            case .leftMouseUp: n = "up"
            case .leftMouseDragged: n = "drag"
            case .rightMouseDown: n = "rightDown"
            case .rightMouseUp: n = "rightUp"
            default: n = "mouse"
            }
            log.append(n)
        }
        func scroll(dx: CGFloat, dy: CGFloat, phase: Int64, momentum: Int64, at p: CGPoint) {
            log.append(momentum != 0 ? "momentum\(momentum)" : "scroll\(phase)")
        }
        func magnify(_ delta: Double, phase: Int64, at p: CGPoint) { log.append("magnify\(phase)"); magSum *= 1 + delta }
        func rotate(degrees: Double, phase: Int64, at p: CGPoint) { log.append("rotate\(phase)"); rotSum += degrees }
        func shortcut(_ key: CGKeyCode, flags: CGEventFlags) { log.append("shortcut\(key)") }
        func clickCount(at p: CGPoint) -> Int { 1 }
    }

    private static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Compresses repeats: ["scroll2","scroll2"] -> ["scroll2×2"]
    private static func compact(_ l: [String]) -> String {
        var out: [String] = [], i = 0
        while i < l.count {
            var j = i; while j < l.count && l[j] == l[i] { j += 1 }
            out.append(j - i > 1 ? "\(l[i])×\(j - i)" : l[i]); i = j
        }
        return out.joined(separator: " ")
    }

    public static func run() async -> (report: String, passed: Bool) {
        var lines: [String] = [], ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String) {
            lines.append("\(cond ? "PASS" : "FAIL")  \(name): \(detail)")
            if !cond { ok = false }
        }
        func scenario(_ body: (TouchRecognizer, Mock) async -> Void) async -> Mock {
            let m = Mock(); let r = TouchRecognizer(output: m); await body(r, m); r.reset(); return m
        }
        let p0 = CGPoint(x: 500, y: 400)

        let tap = await scenario { r, _ in r.down(0, p0); await wait(0.04); r.up(0, p0) }
        check("one-finger tap clicks", tap.log == ["down", "up"], compact(tap.log))

        let drag = await scenario { r, _ in
            r.down(0, p0); await wait(0.2)
            for i in 1...5 { r.move(0, CGPoint(x: p0.x + CGFloat(i) * 20, y: p0.y)); await wait(0.01) }
            r.up(0, CGPoint(x: p0.x + 100, y: p0.y))
        }
        check("one-finger drag", drag.log.first == "down" && drag.log.last == "up" && drag.log.contains("drag"), compact(drag.log))

        let scroll = await scenario { r, _ in
            r.down(0, CGPoint(x: 480, y: 400)); r.down(1, CGPoint(x: 580, y: 400))
            for i in 1...10 {
                let y = 400 + CGFloat(i) * 12
                r.move(0, CGPoint(x: 480, y: y)); r.move(1, CGPoint(x: 580, y: y)); await wait(0.012)
            }
            r.up(1, CGPoint(x: 580, y: 520)); r.up(0, CGPoint(x: 480, y: 520))
            await wait(1.5)                                  // let the glide run out
        }
        check("two-finger scroll with phases", scroll.log.first == "scroll1" && scroll.log.contains("scroll2") && scroll.log.contains("scroll4"), compact(scroll.log))
        check("flick glides then stops", scroll.log.contains("momentum1") && scroll.log.last == "momentum3", compact(scroll.log))

        let pinch = await scenario { r, _ in
            r.down(0, CGPoint(x: 450, y: 400)); r.down(1, CGPoint(x: 550, y: 400))         // 100 apart
            for i in 1...20 {
                let d = CGFloat(i) * 5                                                       // to 200 apart
                r.move(0, CGPoint(x: 450 - d / 2, y: 400)); r.move(1, CGPoint(x: 550 + d / 2, y: 400)); await wait(0.008)
            }
            r.up(1, CGPoint(x: 600, y: 400)); r.up(0, CGPoint(x: 400, y: 400))
        }
        check("pinch out doubles the size", abs(pinch.magSum - 2.0) < 0.05 && pinch.log.first == "magnify1" && pinch.log.last == "magnify4",
              String(format: "total ×%.2f, ", pinch.magSum) + compact(pinch.log))
        check("pure pinch does not rotate", !pinch.log.contains { $0.hasPrefix("rotate") }, "no rotate events")

        let rotate = await scenario { r, _ in
            let c = CGPoint(x: 500, y: 400), rad: CGFloat = 60
            r.down(0, CGPoint(x: c.x - rad, y: c.y)); r.down(1, CGPoint(x: c.x + rad, y: c.y))
            for i in 1...20 {                                                                // 40 degrees clockwise on screen
                let a = CGFloat(i) * 2 * .pi / 180
                r.move(0, CGPoint(x: c.x - rad * cos(a), y: c.y - rad * sin(a)))
                r.move(1, CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))); await wait(0.008)
            }
            r.up(1, CGPoint(x: 560, y: 440)); r.up(0, CGPoint(x: 440, y: 360))
        }
        check("twist rotates ~40 degrees", abs(abs(rotate.rotSum) - 40) < 3, String(format: "total %.1f°, ", rotate.rotSum) + compact(rotate.log))
        check("pure twist does not zoom", abs(rotate.magSum - 1) < 0.05, String(format: "zoom ×%.2f", rotate.magSum))

        let rightTap = await scenario { r, _ in
            r.down(0, CGPoint(x: 480, y: 400)); r.down(1, CGPoint(x: 560, y: 400)); await wait(0.06)
            r.up(1, CGPoint(x: 560, y: 400)); r.up(0, CGPoint(x: 480, y: 400))
        }
        check("two-finger tap right-clicks", rightTap.log == ["rightDown", "rightUp"], compact(rightTap.log))

        let swipe = await scenario { r, _ in
            for i in 0..<3 { r.down(UInt8(i), CGPoint(x: 600 + CGFloat(i) * 40, y: 400)) }
            for step in 1...10 { for i in 0..<3 { r.move(UInt8(i), CGPoint(x: 600 + CGFloat(i) * 40 - CGFloat(step) * 12, y: 400)) }; await wait(0.01) }
            for i in 0..<3 { r.up(UInt8(i), CGPoint(x: 480, y: 400)) }
        }
        check("three-finger swipe left = next Space (Control+Right)", swipe.log == ["shortcut124"], compact(swipe.log))

        let late = await scenario { r, _ in                       // second finger after the click delay: drag ends, no stray clicks later
            r.down(0, p0); await wait(0.2); r.down(1, CGPoint(x: 560, y: 400)); await wait(0.02)
            r.up(1, CGPoint(x: 560, y: 400)); r.up(0, p0)
        }
        check("second finger after press releases the button once", late.log.filter { $0 == "up" }.count == 1 && late.log.filter { $0 == "down" }.count == 1, compact(late.log))

        return (lines.joined(separator: "\n"), ok)
    }
}
