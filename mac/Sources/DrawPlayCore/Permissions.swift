import ApplicationServices
import CoreGraphics
import Foundation

/// The two macOS permissions DrawPlay needs. Both are granted per app in System Settings.
public enum Permissions {
    public static let bundleID = "dev.drawplay.host"

    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }

    public static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    /// Shows the system prompt (and adds the app to the Accessibility list) when not yet trusted.
    public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Forgets this app's saved grants so macOS asks again. Fixes the case where System Settings shows
    /// DrawPlay as allowed but the grant belongs to an older build. Needs no password.
    @discardableResult
    public static func resetSavedGrants() -> Bool {
        var ok = true
        for service in ["Accessibility", "ScreenCapture"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, bundleID]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run(); p.waitUntilExit(); ok = ok && p.terminationStatus == 0 } catch { ok = false }
        }
        return ok
    }
}
