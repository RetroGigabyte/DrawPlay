import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac (and its displays) awake while a session runs, so the stream does not drop.
final class SleepGuard {
    private var ids: [IOPMAssertionID] = []
    private var activity: NSObjectProtocol?
    var isHolding: Bool { !ids.isEmpty || activity != nil }

    func hold(reason: String) {
        release()
        // Without this macOS may "App Nap" DrawPlay when its window is hidden or the lid is closed, which delays input and video.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical], reason: reason)
        for type in ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"] {
            var id = IOPMAssertionID(0)
            let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
            if r == kIOReturnSuccess { ids.append(id) }
        }
    }

    func release() {
        for id in ids { IOPMAssertionRelease(id) }
        ids.removeAll()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    deinit { release() }
}

/// `drawplayd --probe-awake`: holds the assertions for a few seconds so `pmset -g assertions` can show them.
public enum SleepProbe {
    public static func hold(seconds: Double) -> Bool {
        let g = SleepGuard()
        g.hold(reason: "DrawPlay is streaming to your tablet")
        let held = g.isHolding
        Thread.sleep(forTimeInterval: seconds)
        g.release()
        return held
    }
}
