import AppKit
import Combine
import SwiftUI

/// Borderless floating panel. Non-activating, so clicking it never pulls focus
/// away from the app you're working in, but it can still take keyboard input
/// for the search field.
final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an inactive panel hit the button under it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PanelController!
    private var statusMenu: StatusMenu!
    let player = SpotifyPlayer()
    let api = SpotifyAPI()
    let ui = UIState()
    let folders = FolderStore()
    private var watchers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        player.api = api
        let strip = Self.startFrame()
        // Two windows, each with its own shadow: the strip, and the library card
        // that appears beside it. The strip window never resizes to make room.
        let stripPanel = makePanel(frame: strip, root: StripView())
        let libraryPanel = makePanel(frame: strip, root: LibraryCard())
        controller = PanelController(strip: stripPanel, library: libraryPanel, ui: ui, frame: strip)
        stripPanel.orderFrontRegardless()
        statusMenu = StatusMenu(controller: controller, ui: ui)

        // When the song changes, ask Spotify what it's playing from.
        player.$trackURI
            .removeDuplicates()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [api] _ in Task { await api.refreshContext() } }
            .store(in: &watchers)

        // `open Minamp.app --args --expanded` starts open and pinned (handy for screenshots).
        if CommandLine.arguments.contains("--expanded") {
            ui.pinned = true
            controller.expand()
        }
    }

    /// Opening Minamp again (Spotlight, Finder) while it's running brings the strip back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.setHidden(false)
        return false
    }

    private func makePanel<V: View>(frame: NSRect, root: V) -> PlayerPanel {
        let panel = PlayerPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Only take keyboard focus when a text field is clicked, never just by appearing.
        panel.becomesKeyOnlyIfNeeded = true
        let host = FirstMouseHostingView(rootView: root
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
            .environmentObject(player)
            .environmentObject(api)
            .environmentObject(ui)
            .environmentObject(folders))
        host.sizingOptions = []  // the window decides the size, not SwiftUI
        panel.contentView = host
        return panel
    }

    /// Menu-bar-less apps still route ⌘C/⌘V/⌘A through the main menu; without
    /// an Edit menu those keys just beep in text fields.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Minamp", action: nil, keyEquivalent: ""))
        main.addItem(item)
        return main
    }

    /// Last strip frame, if it is still on a connected screen; otherwise bottom-right of the main screen.
    private static func startFrame() -> NSRect {
        if let saved = Prefs.compactFrame,
           NSScreen.screens.contains(where: { $0.frame.intersects(saved) }) {
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

    static var librarySize: NSSize {
        get { defaults.string(forKey: "librarySize").map(NSSizeFromString) ?? NSSize(width: 340, height: 440) }
        set { defaults.set(NSStringFromSize(newValue), forKey: "librarySize") }
    }
}
