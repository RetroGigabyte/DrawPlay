import AppKit
import Combine
import DrawPlayCore

/// The menu bar icon and its menu. Built with AppKit's NSStatusItem; the menu is rebuilt every time it opens.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let model: HostModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var sub: AnyCancellable?

    init(model: HostModel) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "DrawPlay"
        updateIcon()
        sub = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    private func updateIcon() {
        let img = NSImage(systemSymbolName: model.menuSymbol, accessibilityDescription: "DrawPlay")
        img?.isTemplate = true
        item.button?.image = img
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = model

        add(menu, m.menuStatus, enabled: false)
        menu.addItem(.separator())

        add(menu, m.running ? "Stop" : (m.mode == .usb ? "Start USB" : "Start Wi-Fi"), enabled: !m.busy) { Task { await m.toggle() } }

        menu.addItem(.separator())
        add(menu, "USB cable", checked: m.mode == .usb, enabled: !m.running) { m.mode = .usb }
        add(menu, "Wi-Fi", checked: m.mode == .wifi, enabled: !m.running) { m.mode = .wifi }

        let res = NSMenuItem(title: "Resolution: \(m.effectiveSize.width) × \(m.effectiveSize.height)", action: nil, keyEquivalent: "")
        let resMenu = NSMenu()
        for s in HostModel.sizes { add(resMenu, s.label, checked: s == m.size, enabled: !m.running) { m.size = s } }
        res.submenu = resMenu
        res.isEnabled = !m.running
        menu.addItem(res)
        let orient = NSMenuItem(title: "Orientation: \(m.orientation == .auto ? "Auto" : m.orientation.rawValue.capitalized)", action: nil, keyEquivalent: "")
        let orientMenu = NSMenu()
        add(orientMenu, "Auto (follow the tablet)", checked: m.orientation == .auto, enabled: !m.running) { m.orientation = .auto }
        add(orientMenu, "Landscape", checked: m.orientation == .landscape, enabled: !m.running) { m.orientation = .landscape }
        add(orientMenu, "Portrait", checked: m.orientation == .portrait, enabled: !m.running) { m.orientation = .portrait }
        orient.submenu = orientMenu
        orient.isEnabled = !m.running
        menu.addItem(orient)
        let q = NSMenuItem(title: "Quality: \(m.quality.label)", action: nil, keyEquivalent: "")
        let qMenu = NSMenu()
        for opt in VideoQuality.allCases { add(qMenu, opt.label, checked: m.quality == opt, enabled: !m.running) { m.quality = opt } }
        q.submenu = qMenu
        q.isEnabled = !m.running
        menu.addItem(q)
        add(menu, "Sharp text (Retina)", checked: m.sharp, enabled: !m.running) { m.sharp = !m.sharp }

        let focus = NSMenuItem(title: m.focused.map { "Focus mode: \($0.name)" } ?? "Focus on app", action: nil, keyEquivalent: "")
        let focusMenu = NSMenu()
        if let f = m.focused {
            add(focusMenu, "Stop focus on \(f.name)") { Task { await m.stopFocus() } }
        } else if m.focusApps.isEmpty {
            add(focusMenu, "No apps running", enabled: false)
        } else {
            for app in m.focusApps { add(focusMenu, app.name, enabled: m.running) { Task { await m.startFocus(app) } } }
        }
        focus.submenu = focusMenu
        focus.isEnabled = m.running || m.focused != nil
        menu.addItem(focus)

        menu.addItem(.separator())
        if m.mode == .wifi {
            if let a = m.addresses.first { add(menu, "Copy address \(a.address)") { m.copy(a.address) } }
            add(menu, "Copy PIN \(m.pin)") { m.copy(m.pin) }
        } else {
            let ready = !m.devices.filter(\.ready).isEmpty
            add(menu, "Open app on tablet", enabled: ready && m.running) { Task { await m.openOnTablet() } }
            add(menu, "Install app on tablet", enabled: ready) { Task { await m.installOnTablet() } }
            if m.running { add(menu, "Redo USB link") { Task { await m.setupUSB() } } }
        }

        menu.addItem(.separator())
        add(menu, "Open at login", checked: m.openAtLogin) { m.openAtLogin = !m.openAtLogin }
        add(menu, "Show DrawPlay Window") { Self.showWindow() }
        add(menu, "Quit DrawPlay", key: "q") { Task { await m.stop(); NSApp.terminate(nil) } }
    }

    static func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == "DrawPlay" }) { w.makeKeyAndOrderFront(nil) }
        else { NSWorkspace.shared.open(Bundle.main.bundleURL) }   // asks the app to reopen its window
    }

    private func add(_ menu: NSMenu, _ title: String, checked: Bool = false, enabled: Bool = true, key: String = "",
                     action: (@MainActor () -> Void)? = nil) {
        let mi = ActionItem(title: title, key: key, action: action)
        mi.state = checked ? .on : .off
        mi.isEnabled = enabled && action != nil
        menu.addItem(mi)
    }

    private func add(_ menu: NSMenu, _ title: String, enabled: Bool) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = enabled
        menu.addItem(mi)
    }
}

/// A menu item that runs a closure when chosen.
private final class ActionItem: NSMenuItem {
    private let handler: (@MainActor () -> Void)?

    init(title: String, key: String, action: (@MainActor () -> Void)?) {
        handler = action
        super.init(title: title, action: action == nil ? nil : #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler?() } }
}
