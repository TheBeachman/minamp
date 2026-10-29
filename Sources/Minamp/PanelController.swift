import AppKit
import SwiftUI

/// Owns the window geometry. The strip never moves when the library opens:
/// the window grows to cover the strip plus a library card stacked above it
/// (or below, when the strip sits in the top half of the screen), and the
/// card fades in. Moving and resizing go through here too.
///
/// Polls the mouse instead of using tracking areas, which fire spurious
/// enter/exit events whenever the window's frame changes.
@MainActor
final class PanelController {
    enum Handle { case strip, library }

    static let expandDelay: TimeInterval = 0.5
    static let collapseDelay: TimeInterval = 0.45
    static let gap: CGFloat = 6
    static let minStrip = NSSize(width: 32, height: 24)
    static let minLibrary = NSSize(width: 260, height: 180)

    private let panel: NSPanel
    private let ui: UIState
    private var timer: Timer?
    private var strip: NSRect          // screen coordinates
    private var library: NSRect?       // screen coordinates, while expanded
    private var insideSince: Date?
    private var outsideSince: Date?
    private var pressStrip: NSRect?
    private var waitForExit = false
    private var collapsing = false
    private var moveStart: (mouse: NSPoint, origin: NSPoint)?
    private var resizeStart: (mouse: NSPoint, strip: NSRect, library: NSSize)?

    init(panel: NSPanel, ui: UIState, strip: NSRect) {
        self.panel = panel
        self.ui = ui
        self.strip = strip
        ui.controller = self
        applyLayout()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Hover

    private var hotRects: [NSRect] {
        guard let lib = library else { return [strip] }
        // Include the gap between the cards so crossing it doesn't collapse.
        let x0 = max(strip.minX, lib.minX), x1 = min(strip.maxX, lib.maxX)
        let band = NSRect(x: x0, y: min(strip.maxY, lib.maxY), width: max(0, x1 - x0),
                          height: abs(lib.midY - strip.midY))
        return [strip, lib, band]
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let inside = hotRects.contains { $0.insetBy(dx: -1, dy: -1).contains(mouse) }
        if ui.hovering != inside { ui.hovering = inside }
        guard !collapsing else { return }
        let now = Date()

        if NSEvent.pressedMouseButtons != 0 {
            if pressStrip == nil { pressStrip = strip }
            insideSince = nil
            outsideSince = nil
            return
        }
        if let pressed = pressStrip {
            pressStrip = nil
            // Just moved or resized the strip: don't pop the library open under the cursor.
            if pressed != strip && !ui.expanded { waitForExit = true }
        }

        if !ui.expanded {
            if !inside { insideSince = nil; waitForExit = false; return }
            guard !waitForExit else { return }
            if insideSince == nil { insideSince = now }
            if now.timeIntervalSince(insideSince!) >= Self.expandDelay { expand() }
        } else {
            if inside || ui.pinned { outsideSince = nil; return }
            if outsideSince == nil { outsideSince = now }
            if now.timeIntervalSince(outsideSince!) >= Self.collapseDelay { collapse() }
        }
    }

    func expand() {
        guard !ui.expanded else { return }
        insideSince = nil
        ui.expanded = true
        applyLayout()
        withAnimation(.easeOut(duration: 0.16)) { ui.showLibrary = true }
    }

    private func collapse() {
        outsideSince = nil
        collapsing = true
        panel.makeFirstResponder(nil)
        withAnimation(.easeIn(duration: 0.12)) {
            ui.showLibrary = false
        } completion: { [weak self] in
            guard let self else { return }
            self.collapsing = false
            self.ui.expanded = false
            self.applyLayout()
        }
    }

    // MARK: Layout

    private var visibleFrame: NSRect {
        let center = NSPoint(x: strip.midX, y: strip.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? panel.screen ?? NSScreen.main
        return screen?.visibleFrame ?? strip
    }

    private func layoutLibrary() -> NSRect? {
        guard ui.expanded else { return nil }
        let vf = visibleFrame
        let above = strip.midY < vf.midY
        let alignRight = strip.midX > vf.midX
        let want = Prefs.librarySize
        let w = min(max(want.width, Self.minLibrary.width), vf.width)
        let room = above ? vf.maxY - strip.maxY - Self.gap : strip.minY - vf.minY - Self.gap
        let h = max(min(want.height, room), 120)
        var x = alignRight ? strip.maxX - w : strip.minX
        x = min(max(x, vf.minX), vf.maxX - w)
        let y = above ? strip.maxY + Self.gap : strip.minY - Self.gap - h
        if ui.libraryAbove != above { ui.libraryAbove = above }
        if ui.libraryAlignRight != alignRight { ui.libraryAlignRight = alignRight }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func applyLayout() {
        library = layoutLibrary()
        let frame = library.map { strip.union($0) } ?? strip
        func local(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
        }
        panel.disableScreenUpdatesUntilFlush()
        ui.stripRect = local(strip)
        ui.libraryRect = library.map(local)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    // MARK: Move and resize (called from the views' drag gestures)

    func beginMove(translation: CGSize) {
        let m = NSEvent.mouseLocation
        // The gesture fires after a couple of points of travel; back that out.
        moveStart = (NSPoint(x: m.x - translation.width, y: m.y + translation.height), strip.origin)
    }

    func move() {
        guard let s = moveStart else { return }
        let m = NSEvent.mouseLocation
        strip.origin = NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y)
        applyLayout()
    }

    func endMove() {
        moveStart = nil
        Prefs.compactFrame = strip
    }

    func beginResize() {
        resizeStart = (NSEvent.mouseLocation, strip, library?.size ?? Prefs.librarySize)
    }

    func resize(_ handle: Handle) {
        guard let s = resizeStart else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - s.mouse.x, dy = m.y - s.mouse.y
        switch handle {
        case .strip:
            // Bottom-right grip: the top-left corner stays put.
            let w = max(Self.minStrip.width, s.strip.width + dx)
            let h = max(Self.minStrip.height, s.strip.height - dy)
            strip = NSRect(x: s.strip.minX, y: s.strip.maxY - h, width: w, height: h)
        case .library:
            // The grip sits on the corner away from the strip, so the edge by the strip stays put.
            let w = s.library.width + (ui.libraryAlignRight ? -dx : dx)
            let h = s.library.height + (ui.libraryAbove ? dy : -dy)
            Prefs.librarySize = NSSize(width: max(Self.minLibrary.width, w), height: max(Self.minLibrary.height, h))
        }
        applyLayout()
    }

    func endResize() {
        resizeStart = nil
        Prefs.compactFrame = strip
        if let library { Prefs.librarySize = library.size }
    }
}
