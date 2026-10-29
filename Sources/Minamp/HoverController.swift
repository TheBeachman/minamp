import AppKit
import SwiftUI

/// Grows the compact strip into the full player after the mouse rests on it,
/// and shrinks it back when the mouse leaves.
///
/// Polls the mouse position instead of using tracking areas: tracking areas
/// fire spurious enter/exit events while the window is animating its frame.
@MainActor
final class HoverController {
    static let expandDelay: TimeInterval = 0.5
    static let collapseDelay: TimeInterval = 0.45

    private let panel: NSPanel
    private let ui: UIState
    private var timer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var animating = false
    private var compactFrame: NSRect
    private var anchorRight = false
    private var anchorTop = false
    /// Frame when a mouse button went down on the compact strip; nil when no press is in progress.
    private var pressFrame: NSRect?
    /// After dragging or resizing the strip, don't expand until the mouse has left it once.
    private var waitForExit = false

    init(panel: NSPanel, ui: UIState) {
        self.panel = panel
        self.ui = ui
        compactFrame = panel.frame

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frameChanged() }
            }
        }
        ui.expandNow = { [weak self] in self?.expand() }
    }

    private func tick() {
        guard !animating else { return }
        let inside = panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        let buttonsDown = NSEvent.pressedMouseButtons != 0
        let now = Date()

        if !ui.expanded {
            outsideSince = nil
            if !inside { insideSince = nil; waitForExit = false; pressFrame = nil; return }
            if buttonsDown {
                if pressFrame == nil { pressFrame = panel.frame }
                insideSince = nil
                return
            }
            if let pressed = pressFrame {
                // Mouse released: a plain click expands at once, a drag or resize doesn't.
                pressFrame = nil
                if pressed == panel.frame { expand() } else { waitForExit = true }
                return
            }
            guard !waitForExit else { return }
            if insideSince == nil { insideSince = now }
            if now.timeIntervalSince(insideSince!) >= Self.expandDelay { expand() }
        } else {
            insideSince = nil
            if inside || ui.pinned || buttonsDown { outsideSince = nil; return }
            if outsideSince == nil { outsideSince = now }
            if now.timeIntervalSince(outsideSince!) >= Self.collapseDelay { collapse() }
        }
    }

    private func expand() {
        guard !ui.expanded, !animating else { return }
        insideSince = nil
        compactFrame = panel.frame
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let want = Prefs.expandedSize
        let w = min(max(want.width, compactFrame.width), vf.width)
        let h = min(max(want.height, compactFrame.height), vf.height)

        // Grow away from the nearest screen edges so the player never runs off-screen.
        anchorRight = compactFrame.midX > vf.midX
        anchorTop = compactFrame.midY > vf.midY
        var x = anchorRight ? compactFrame.maxX - w : compactFrame.minX
        var y = anchorTop ? compactFrame.maxY - h : compactFrame.minY
        x = min(max(x, vf.minX), vf.maxX - w)
        y = min(max(y, vf.minY), vf.maxY - h)

        ui.expanded = true
        animate(to: NSRect(x: x, y: y, width: w, height: h))
    }

    private func collapse() {
        outsideSince = nil
        ui.expanded = false
        panel.makeFirstResponder(nil)
        animate(to: compactFrame)
    }

    private func animate(to frame: NSRect) {
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.animating = false
                self?.panel.invalidateShadow()
            }
        })
    }

    /// The user moved or resized the window by hand: remember it.
    private func frameChanged() {
        guard !animating else { return }
        let f = panel.frame
        if ui.expanded {
            Prefs.expandedSize = f.size
            // Keep the strip glued to the same corner of the expanded window.
            compactFrame.origin.x = anchorRight ? f.maxX - compactFrame.width : f.minX
            compactFrame.origin.y = anchorTop ? f.maxY - compactFrame.height : f.minY
        } else {
            compactFrame = f
        }
        Prefs.compactFrame = compactFrame
        panel.invalidateShadow()
    }
}
