import AppKit
import TrafficLightCore

/// One on-screen Light: its own borderless panel, with its own position and Lamp Diameter.
///
/// The app can show several — spread across screens, or side by side on one — and they all
/// display the same Aggregate Status, since Status is a property of the Sessions, not of any
/// particular Light. Position and size are per-Light and persisted as a set (see
/// `AppDelegate.saveLights`).
final class Light {
    private let panel: NSPanel
    private let view: LampView
    /// The app owns every Light, so this back-reference is unowned to avoid a cycle.
    private unowned let app: AppDelegate

    private(set) var diameter: CGFloat

    var status: Status {
        get { view.status }
        set { view.status = newValue }
    }

    var frame: NSRect { panel.frame }
    /// The screen the Light currently sits on, falling back to the main one while off-screen.
    var screen: NSScreen? { panel.screen ?? NSScreen.main }

    init(diameter: CGFloat, origin: NSPoint, app: AppDelegate) {
        self.app = app
        self.diameter = LampMetrics.clamp(diameter)

        let size = LampMetrics.panelSize(diameter: self.diameter)
        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        view = LampView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = view

        view.light = self
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    // MARK: - size

    /// Resize while holding one point of the frame still: `anchor` is that point in screen
    /// coordinates, `unit` says which corner of the frame it is (0 = min, 1 = max, per axis).
    /// Clamped to `LampMetrics` bounds; no-op when nothing changes.
    func setDiameter(_ diameter: CGFloat, anchor: NSPoint, unit: CGPoint) {
        let clamped = LampMetrics.clamp(diameter)
        guard clamped != self.diameter else { return }
        self.diameter = clamped
        let size = LampMetrics.panelSize(diameter: clamped)
        panel.setFrame(NSRect(x: anchor.x - unit.x * size.width,
                              y: anchor.y - unit.y * size.height,
                              width: size.width, height: size.height),
                       display: true)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
    }

    /// Top-left of the panel: the anchor for size changes that don't come from a corner drag.
    private var topLeftAnchor: (anchor: NSPoint, unit: CGPoint) {
        (NSPoint(x: panel.frame.minX, y: panel.frame.maxY), CGPoint(x: 0, y: 1))
    }

    func setDiameterFromMenu(_ diameter: CGFloat) {
        let pin = topLeftAnchor
        setDiameter(diameter, anchor: pin.anchor, unit: pin.unit)
        app.saveLights()
    }

    func resetSize() {
        setDiameterFromMenu(LampMetrics.defaultDiameter)
    }

    // MARK: - position

    /// Back to the default spot — the top-right of the screen this Light is on.
    func resetPosition() {
        guard let screen = screen else { return }
        panel.setFrameOrigin(Light.defaultOrigin(on: screen, size: panel.frame.size))
        app.saveLights()
    }

    /// Called when the user finishes dragging the Light.
    func didMove() {
        app.saveLights()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - persistence

    func snapshot() -> [String: Double] {
        ["x": panel.frame.origin.x, "y": panel.frame.origin.y, "d": diameter]
    }

    // MARK: - placement

    static let defaultMargin: CGFloat = 24
    /// How far a duplicate is offset from its source, so it lands visibly beside it.
    static let duplicateOffset: CGFloat = 28

    static func defaultOrigin(on screen: NSScreen, size: NSSize) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - size.width - defaultMargin,
                       y: visible.maxY - size.height - defaultMargin)
    }

    /// Clamp `origin` so a panel of `size` stays fully within `screen`'s visible area.
    static func clamped(origin: NSPoint, size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
    }

    /// Where a duplicate of this Light should go on `screen`: just down-and-right of the original
    /// when duplicating onto the same screen, otherwise that screen's default spot. Nudged along
    /// the diagonal until it isn't sitting exactly on top of an existing Light.
    func duplicateOrigin(on screen: NSScreen, avoiding taken: [NSRect]) -> NSPoint {
        let size = LampMetrics.panelSize(diameter: diameter)
        var candidate = screen == self.screen
            ? NSPoint(x: frame.minX + Light.duplicateOffset, y: frame.minY - Light.duplicateOffset)
            : Light.defaultOrigin(on: screen, size: size)

        for _ in 0..<12 {
            let clamped = Light.clamped(origin: candidate, size: size, on: screen)
            let overlapsExactly = taken.contains { abs($0.minX - clamped.x) < 4 && abs($0.minY - clamped.y) < 4 }
            if !overlapsExactly { return clamped }
            candidate = NSPoint(x: clamped.x - Light.duplicateOffset,
                                y: clamped.y - Light.duplicateOffset)
        }
        return Light.clamped(origin: candidate, size: size, on: screen)
    }
}
