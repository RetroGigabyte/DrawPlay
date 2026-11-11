import CoreGraphics
import Foundation
import VDShim

struct DisplayModeInfo {
    var pointsW: Int, pointsH: Int, pixelsW: Int, pixelsH: Int
    var hidpi: Bool
    var note: String
    var description: String { "\(pointsW)×\(pointsH) points, \(pixelsW)×\(pixelsH) pixels\(hidpi ? " (Retina)" : "")" }
}

/// A second (virtual) monitor macOS treats like a real one. It exists while this object lives.
///
/// macOS builds its own mode list from the modes we register and starts the display in an arbitrary
/// one, so after `apply` we pick the wanted mode explicitly. For Retina we try three layouts and
/// fall back step by step: logical mode only, anchor + logical mode, then plain 1x.
final class VirtualDisplay: @unchecked Sendable {
    private let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    private init(display: CGVirtualDisplay) { self.display = display }

    static func make(pixelWidth pw: Int, pixelHeight ph: Int, hz: Double, hidpi: Bool, serial: UInt32 = 1,
                     log: @escaping (String) -> Void) -> (VirtualDisplay, DisplayModeInfo)? {
        let d = CGVirtualDisplayDescriptor()
        d.name = "DrawPlay Tablet"
        d.vendorID = 0x3456; d.productID = 0x1234; d.serialNum = serial
        // Square limit so the same display can switch between landscape and portrait.
        let longEdge = max(pw, ph)
        d.maxPixelsWide = UInt32(longEdge); d.maxPixelsHigh = UInt32(longEdge)
        // macOS only offers Retina on panels it thinks are dense (200+ ppi), so size the panel to match.
        let ppi: Double = hidpi ? 220 : 110
        d.sizeInMillimeters = CGSize(width: Double(pw) / ppi * 25.4, height: Double(ph) / ppi * 25.4)
        d.redPrimary = CGPoint(x: 0.64, y: 0.33)        // sRGB primaries, D65 white
        d.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        d.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        d.queue = DispatchQueue(label: "drawplay.virtualdisplay")
        d.terminationHandler = { _, _ in log("virtual display terminated by the system") }
        guard let v = CGVirtualDisplay(descriptor: d), v.displayID != 0 else { return nil }
        let vd = VirtualDisplay(display: v)
        guard let info = vd.setMode(pixelWidth: pw, pixelHeight: ph, hz: hz, hidpi: hidpi, log: log) else { return nil }
        return (vd, info)
    }

    /// Switches the display to `pw x ph` backing pixels (half that in points when `hidpi`).
    /// For Retina three layouts are tried in turn: logical mode only, anchor + logical mode, then plain 1x.
    func setMode(pixelWidth pw: Int, pixelHeight ph: Int, hz: Double, hidpi: Bool,
                 log: @escaping (String) -> Void) -> DisplayModeInfo? {
        func settings(_ hi: Bool, _ modes: [(Int, Int)]) -> CGVirtualDisplaySettings {
            let s = CGVirtualDisplaySettings()
            s.hiDPI = hi ? 1 : 0
            s.modes = modes.map { CGVirtualDisplayMode(width: UInt($0.0), height: UInt($0.1), refreshRate: hz) }
            return s
        }
        let v = display
        if hidpi {
            let lw = pw / 2, lh = ph / 2
            if v.apply(settings(true, [(lw, lh)])), select(lw, lh, pw, ph, log) {
                return DisplayModeInfo(pointsW: lw, pointsH: lh, pixelsW: pw, pixelsH: ph, hidpi: true, note: "logical mode")
            }
            log("Retina layout A failed, trying anchor + logical mode")
            if v.apply(settings(true, [(pw, ph), (lw, lh)])), select(lw, lh, pw, ph, log) {
                return DisplayModeInfo(pointsW: lw, pointsH: lh, pixelsW: pw, pixelsH: ph, hidpi: true, note: "anchor mode")
            }
            log("Retina is not available on this Mac, using regular resolution")
        }
        if v.apply(settings(false, [(pw, ph)])), select(pw, ph, pw, ph, log) {
            return DisplayModeInfo(pointsW: pw, pointsH: ph, pixelsW: pw, pixelsH: ph, hidpi: false,
                                   note: hidpi ? "Retina unavailable, fell back" : "regular")
        }
        return nil
    }

    private func matches(_ m: CGDisplayMode, _ w: Int, _ h: Int, _ pw: Int, _ ph: Int) -> Bool {
        m.width == w && m.height == h && m.pixelWidth == pw && m.pixelHeight == ph
    }

    private func select(_ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ log: (String) -> Void) -> Bool {
        let id = self.id
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let deadline = Date().addingTimeInterval(3)
        var target: CGDisplayMode?
        while Date() < deadline {
            if let cur = CGDisplayCopyDisplayMode(id), matches(cur, w, h, pw, ph) { return true }
            let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            target = modes.first { $0.isUsableForDesktopGUI() && matches($0, w, h, pw, ph) }
            if target != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let target else {
            let offered = ((CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? [])
                .filter { $0.isUsableForDesktopGUI() }.map { "\($0.width)x\($0.height)@\($0.pixelWidth)x\($0.pixelHeight)" }
            log("mode \(w)x\(h)@\(pw)x\(ph) not offered. Offered: \(offered)")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, target, nil)
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { return false }
        while Date() < deadline {
            if let cur = CGDisplayCopyDisplayMode(id), matches(cur, w, h, pw, ph) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

/// Creates a display, reports the mode macOS actually gave it, and removes it again. No permissions needed.
public enum DisplayProbe {
    public static func run(pixelWidth: Int, pixelHeight: Int, hidpi: Bool, rotate: Bool = false) -> String {
        var lines: [String] = []
        guard let (vd, info) = VirtualDisplay.make(pixelWidth: pixelWidth, pixelHeight: pixelHeight, hz: 60, hidpi: hidpi, serial: 9999,   // different id, so a probe can run next to a live session
                                                   log: { lines.append($0) }) else {
            return (lines + ["FAILED to create the display"]).joined(separator: "\n")
        }
        let cur = CGDisplayCopyDisplayMode(vd.id)
        let b = CGDisplayBounds(vd.id)
        lines.append("OK id=\(vd.id): \(info.description) [\(info.note)]")
        lines.append("macOS reports: \(cur?.width ?? 0)x\(cur?.height ?? 0) points, \(cur?.pixelWidth ?? 0)x\(cur?.pixelHeight ?? 0) pixels, bounds \(Int(b.width))x\(Int(b.height))")
        if rotate {          // switch the same display to the other orientation and back, like Auto mode does
            for (w, h) in [(pixelHeight, pixelWidth), (pixelWidth, pixelHeight)] {
                let t0 = Date()
                guard let i = vd.setMode(pixelWidth: w, pixelHeight: h, hz: 60, hidpi: hidpi, log: { lines.append($0) }) else {
                    lines.append("ROTATE to \(w)x\(h) FAILED"); break
                }
                let b2 = CGDisplayBounds(vd.id)
                lines.append(String(format: "rotated to %@ in %.2fs, bounds %dx%d", i.description, Date().timeIntervalSince(t0), Int(b2.width), Int(b2.height)))
            }
        }
        return lines.joined(separator: "\n")
    }
}
