import AppKit
import DrawPlayCore
import SwiftUI

/// Owns the menu bar icon and keeps DrawPlay running when its window is closed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController(model: HostModel.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@main
struct DrawPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HostModel.shared

    var body: some Scene {
        Window("DrawPlay", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
    }
}
