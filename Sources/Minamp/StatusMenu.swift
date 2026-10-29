import AppKit
import ServiceManagement

/// Menu bar icon: the way to find, hide, show and quit Minamp, since it has no Dock icon.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: PanelController
    private let ui: UIState

    init(controller: PanelController, ui: UIState) {
        self.controller = controller
        self.ui = ui
        super.init()
        item.button?.image = Self.icon()
        item.button?.toolTip = "Minamp"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt each time it opens so titles and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, controller.isHidden ? "Show Minamp" : "Hide Minamp", #selector(toggleHidden))
        let keep = add(menu, "Keep Expanded", #selector(toggleKeepExpanded))
        keep.state = ui.pinned ? .on : .off
        keep.isEnabled = !controller.isHidden
        menu.addItem(.separator())
        add(menu, "Open Spotify", #selector(openSpotify))
        let login = add(menu, "Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit Minamp", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleHidden() { controller.setHidden(!controller.isHidden) }
    @objc private func toggleKeepExpanded() { ui.pinned.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyPlayer.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        try? svc.status == .enabled ? svc.unregister() : svc.register()
    }

    /// Three equalizer bars, matching the app icon; a template so it follows the menu bar's colour.
    private static func icon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (i, h) in [7.0, 12.0, 9.0].enumerated() {
                let r = NSRect(x: 3.5 + Double(i) * 4.0, y: 3, width: 3, height: h)
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
