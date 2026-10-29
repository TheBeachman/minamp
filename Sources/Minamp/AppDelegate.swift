import AppKit
import SwiftUI

/// Borderless floating panel. Non-activating, so clicking it never pulls focus
/// away from the app you're working in, but it can still take keyboard input
/// for the search field.
final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PlayerPanel!
    private var hover: HoverController!
    let player = SpotifyPlayer()
    let api = SpotifyAPI()
    let ui = UIState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PlayerPanel(contentRect: Self.startFrame(),
                            styleMask: [.borderless, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 32, height: 24)

        let root = RootView()
            .environmentObject(player)
            .environmentObject(api)
            .environmentObject(ui)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []  // the window decides the size, not SwiftUI
        host.wantsLayer = true
        host.layer?.cornerRadius = 9
        host.layer?.masksToBounds = true
        panel.contentView = host
        panel.orderFrontRegardless()

        hover = HoverController(panel: panel, ui: ui)

        // `open Minamp.app --args --expanded` starts open and pinned (handy for screenshots).
        if CommandLine.arguments.contains("--expanded") {
            ui.pinned = true
            ui.expandNow()
        }
    }

    /// Last compact frame, if it is still on a connected screen; otherwise bottom-right of the main screen.
    private static func startFrame() -> NSRect {
        if let saved = Prefs.compactFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            return saved
        }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: vf.maxX - 300, y: vf.minY + 20, width: 280, height: 52)
    }
}

enum Prefs {
    private static let defaults = UserDefaults.standard

    static var compactFrame: NSRect? {
        get { defaults.string(forKey: "compactFrame").map(NSRectFromString) }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: "compactFrame") }
    }

    static var expandedSize: NSSize {
        get { defaults.string(forKey: "expandedSize").map(NSSizeFromString) ?? NSSize(width: 360, height: 540) }
        set { defaults.set(NSStringFromSize(newValue), forKey: "expandedSize") }
    }
}
