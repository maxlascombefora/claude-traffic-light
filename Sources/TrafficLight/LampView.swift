import AppKit
import TrafficLightCore

/// Geometry of the overlay, all derived from one number: the Lamp Diameter.
///
/// Resizing is a uniform scale — padding, inset, corner radius and glow all grow with the lamps
/// in the same proportion, so the light looks identical at every size, just bigger or smaller.
/// The `base*` values are the proportions, expressed at `defaultDiameter`.
enum LampMetrics {
    /// Transparent margin between the panel edge and the housing, so the shadow has room.
    static let baseInset: CGFloat = 2
    /// Padding at the default diameter: housing edge → lamp, and lamp → lamp.
    static let basePadding: CGFloat = 8
    static let defaultDiameter: CGFloat = 26
    static let minDiameter: CGFloat = 12
    static let maxDiameter: CGFloat = 96
    static let lampCount = 3

    static func clamp(_ diameter: CGFloat) -> CGFloat {
        min(max(diameter.rounded(), minDiameter), maxDiameter)
    }

    static func scale(diameter: CGFloat) -> CGFloat { clamp(diameter) / defaultDiameter }

    static func inset(diameter: CGFloat) -> CGFloat { baseInset * scale(diameter: diameter) }

    static func padding(diameter: CGFloat) -> CGFloat { basePadding * scale(diameter: diameter) }

    /// Panel size that wraps `diameter` lamps with proportional padding.
    static func panelSize(diameter: CGFloat) -> NSSize {
        let d = clamp(diameter)
        let inset = inset(diameter: d), padding = padding(diameter: d)
        return NSSize(
            width: d + 2 * (inset + padding),
            height: CGFloat(lampCount) * d + CGFloat(lampCount + 1) * padding + 2 * inset
        )
    }

    /// Inverse of `panelSize` — the lamp diameter a panel of this width is showing.
    static func diameter(forPanelWidth width: CGFloat) -> CGFloat {
        clamp(width * defaultDiameter / panelSize(diameter: defaultDiameter).width)
    }

    /// Points of panel width, and of panel height, gained per point of diameter. Lets a resize
    /// drag map cursor travel onto the diameter it implies.
    static var widthPerDiameter: CGFloat {
        panelSize(diameter: defaultDiameter).width / defaultDiameter
    }

    static var heightPerDiameter: CGFloat {
        panelSize(diameter: defaultDiameter).height / defaultDiameter
    }
}

/// Draws the three-lamp traffic light. The lamp for `status` glows; the rest sit dim.
/// Also handles dragging the window, resizing it from any corner, and the right-click menu.
final class LampView: NSView {
    var status: Status = .idle {
        didSet { if status != oldValue { needsDisplay = true } }
    }

    /// The Light this view draws. Weak because the Light owns its panel, which owns this view.
    /// Every geometry action (drag, resize, *Size*, *Duplicate*) applies to this Light alone;
    /// Session/Mute actions are app-wide and go to the AppDelegate.
    weak var light: Light?

    /// Which corner a resize is being dragged from. The diagonally opposite corner stays put,
    /// so the light grows away from the hand instead of sliding out from under it.
    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }

        /// The frame corner held fixed, as a unit fraction of the frame (0 = min, 1 = max).
        var anchorUnit: CGPoint { CGPoint(x: isLeft ? 1 : 0, y: isTop ? 0 : 1) }

        func rect(in bounds: NSRect, side: CGFloat) -> NSRect {
            NSRect(x: isLeft ? bounds.minX : bounds.maxX - side,
                   y: isTop ? bounds.maxY - side : bounds.minY,
                   width: side, height: side)
        }
    }

    private enum Region: Equatable { case move, resize(Corner) }

    private var dragRegion: Region?
    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var dragStartDiameter: CGFloat = LampMetrics.defaultDiameter
    /// Screen point the resize pins, and which frame corner it is.
    private var dragAnchor: NSPoint = .zero
    private var dragAnchorUnit: CGPoint = .zero

    private let lamps: [(status: Status, color: NSColor)] = [
        (.blocked, .systemRed),
        (.yourTurn, .systemYellow),
        (.working, .systemGreen),
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let diameter = LampMetrics.diameter(forPanelWidth: bounds.width)
        let inset = LampMetrics.inset(diameter: diameter)
        let housing = bounds.insetBy(dx: inset, dy: inset)
        // Corner radius tracks the housing width so the pill silhouette survives resizing.
        let radius = housing.width * 0.26
        let housingPath = NSBezierPath(roundedRect: housing, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.10, alpha: 0.92).setFill()
        housingPath.fill()

        let gap = (housing.height - CGFloat(lamps.count) * diameter) / CGFloat(lamps.count + 1)
        let centerX = housing.midX
        var top = housing.maxY - gap - diameter

        // The lit lamp's glow is clipped to the housing, and its blur is capped at the padding,
        // so it fades out before the housing edge instead of bleeding a halo across it.
        ctx.saveGState()
        housingPath.addClip()
        let blur = LampMetrics.padding(diameter: diameter)

        for lamp in lamps {
            let rect = NSRect(x: centerX - diameter / 2, y: top, width: diameter, height: diameter)
            let isOn = lamp.status == status

            let base = isOn ? lamp.color : (lamp.color.blended(withFraction: 0.82, of: .black) ?? lamp.color)
            base.setFill()
            NSBezierPath(ovalIn: rect).fill()

            if isOn {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: blur, color: lamp.color.withAlphaComponent(0.9).cgColor)
                lamp.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                ctx.restoreGState()
            }

            top -= diameter + gap
        }
        ctx.restoreGState()
    }

    // MARK: - hit testing

    /// Corner hit targets, undrawn: the light is small enough that visible handles crowd it, and
    /// the *Size* submenu covers anyone who never finds the corners.
    ///
    /// There is deliberately no hover cursor. macOS hands cursor control to the **active**
    /// application, and this overlay is a non-activating accessory panel that never becomes
    /// active — `NSCursor.set()` updates our own cursor stack but the displayed cursor keeps
    /// whatever the frontmost app wants. (Verified: tracking-area events arrive fine and
    /// `NSCursor.current` changes, while `NSCursor.currentSystem` stays the arrow. AppKit's own
    /// `.resizable` window-frame cursors don't show either.) Cursor feedback would mean making
    /// the panel activating — i.e. clicking the light would steal focus from your terminal.
    private var cornerSide: CGFloat { max(14, bounds.width * 0.3) }

    private func region(at point: NSPoint) -> Region {
        let side = cornerSide
        for corner in Corner.allCases where corner.rect(in: bounds, side: side).contains(point) {
            return .resize(corner)
        }
        return .move
    }

    // MARK: - drag to move / resize

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let region = region(at: local)
        dragRegion = region
        dragStartMouse = NSEvent.mouseLocation
        dragStartDiameter = LampMetrics.diameter(forPanelWidth: bounds.width)

        let frame = window?.frame ?? .zero
        dragStartOrigin = frame.origin
        if case .resize(let corner) = region {
            dragAnchorUnit = corner.anchorUnit
            dragAnchor = NSPoint(x: dragAnchorUnit.x == 1 ? frame.maxX : frame.minX,
                                 y: dragAnchorUnit.y == 1 ? frame.maxY : frame.minY)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragRegion else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouse.x
        let dy = current.y - dragStartMouse.y

        switch dragRegion {
        case .move:
            window?.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
        case .resize(let corner):
            // Follow whichever axis the cursor committed to, converting that axis's travel into
            // the diameter change it implies (the panel grows faster than the lamp it wraps).
            // Away from the anchored corner grows; toward it shrinks.
            let horizontal = (corner.isLeft ? -dx : dx) / LampMetrics.widthPerDiameter
            let vertical = (corner.isTop ? dy : -dy) / LampMetrics.heightPerDiameter
            let delta = abs(horizontal) >= abs(vertical) ? horizontal : vertical
            light?.setDiameter(dragStartDiameter + delta,
                               anchor: dragAnchor,
                               unit: dragAnchorUnit)
        }
    }

    /// Below this much total mouse travel, a mouseDown/mouseUp pair reads as a click rather than
    /// a drag — generous enough to absorb hand tremor, tight enough that no intentional drag is
    /// misread. See ADR 0005.
    private static let clickThreshold: CGFloat = 4

    override func mouseUp(with event: NSEvent) {
        defer { dragRegion = nil }
        let current = NSEvent.mouseLocation
        let moved = hypot(current.x - dragStartMouse.x, current.y - dragStartMouse.y)
        light?.didMove()  // persists position and size for the whole set of Lights
        // Only the body counts as a click target — a stray near-zero-movement tap on a resize
        // corner shouldn't jump to a Session.
        if dragRegion == .move, moved < Self.clickThreshold {
            (NSApp.delegate as? AppDelegate)?.focusOldestMatchingCurrentColor()
        }
    }

    // MARK: - right-click menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let model = (NSApp.delegate as? AppDelegate)?.menuModel()
        let aggregate = model?.aggregate ?? .idle
        let sessions = model?.sessions ?? []

        addDisabled(to: menu, "Light:  \(Self.dot(aggregate))  \(Self.name(aggregate))")
        menu.addItem(.separator())

        if sessions.isEmpty {
            addDisabled(to: menu, "No active sessions")
        } else {
            for s in sessions {
                menu.addItem(sessionMenuItem(for: s))
            }
        }

        menu.addItem(.separator())
        menu.addItem(sizeMenuItem())
        addAction(to: menu, "Reset Position", #selector(resetPosition))
        menu.addItem(.separator())
        menu.addItem(duplicateMenuItem())
        let close = addAction(to: menu, "Close This Light", #selector(closeLight))
        // The last Light can't be closed — there'd be no way back to this menu.
        close.isEnabled = (NSApp.delegate as? AppDelegate)?.canCloseLights ?? false
        menu.addItem(.separator())
        addAction(to: menu, "Quit Traffic Light", #selector(quit), key: "q")
        return menu
    }

    /// One Session's row: a submenu of *Focus* (jump to its terminal) and *Mute* (silence its
    /// color), so the row no longer has to pick a single action for its click — see ADR 0005.
    /// *Focus* is disabled when the Session has no recorded cwd, since it could never be matched
    /// to a Ghostty terminal.
    private func sessionMenuItem(for s: MenuSession) -> NSMenuItem {
        let title = "\(Self.dot(s.status))  \(s.label)"
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.isEnabled = true
        if s.muted {
            row.attributedTitle = NSAttributedString(string: title, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ])
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let focus = NSMenuItem(title: "Focus", action: #selector(focusSession(_:)), keyEquivalent: "")
        focus.target = self
        focus.representedObject = s.id
        focus.isEnabled = !(s.cwd ?? "").isEmpty
        submenu.addItem(focus)

        let mute = NSMenuItem(title: "Mute", action: #selector(toggleMute(_:)), keyEquivalent: "")
        mute.target = self
        mute.representedObject = s.id
        mute.isEnabled = true
        mute.state = s.muted ? .on : .off
        submenu.addItem(mute)

        row.submenu = submenu
        return row
    }

    /// *Duplicate Light* — a plain item with one screen, or a per-screen submenu with several, so
    /// a second Light can be sent straight to another display instead of dragged there.
    private func duplicateMenuItem() -> NSMenuItem {
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            let item = NSMenuItem(title: "Duplicate Light", action: #selector(duplicateLight(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            return item
        }

        let here = light?.screen
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for screen in screens {
            let isHere = screen == here
            let title = isHere ? "This Screen" : screen.localizedName
            let item = NSMenuItem(title: title, action: #selector(duplicateLight(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = screen
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Duplicate Light", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    /// *Size* submenu: presets plus a reset, for when the corner grip is too fiddly. The current
    /// diameter is check-marked, including sizes reached by dragging that land on a preset.
    private func sizeMenuItem() -> NSMenuItem {
        let presets: [(String, CGFloat)] = [
            ("Small", 18), ("Medium", LampMetrics.defaultDiameter), ("Large", 38), ("Huge", 56),
        ]
        let current = LampMetrics.diameter(forPanelWidth: bounds.width)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (name, diameter) in presets {
            let item = NSMenuItem(title: name, action: #selector(applySize(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = diameter
            item.state = diameter == current ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        addAction(to: submenu, "Reset Size", #selector(resetSize))

        let item = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    private func addDisabled(to menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(to menu: NSMenu, _ title: String, _ action: Selector,
                           key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    private static func dot(_ s: Status) -> String {
        switch s {
        case .blocked: return "🔴"
        case .yourTurn: return "🟡"
        case .working: return "🟢"
        case .idle: return "⚪"
        }
    }

    private static func name(_ s: Status) -> String {
        switch s {
        case .blocked: return "Blocked"
        case .yourTurn: return "Your Turn"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.toggleMute(sessionId: id)
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.focusSession(sessionId: id)
    }

    @objc private func applySize(_ sender: NSMenuItem) {
        guard let diameter = sender.representedObject as? CGFloat else { return }
        light?.setDiameterFromMenu(diameter)
    }

    @objc private func resetSize() {
        light?.resetSize()
    }

    @objc private func resetPosition() {
        light?.resetPosition()
    }

    /// `representedObject` carries the target screen when the item came from the per-screen
    /// submenu; nil means "wherever this Light already is".
    @objc private func duplicateLight(_ sender: NSMenuItem) {
        guard let light else { return }
        (NSApp.delegate as? AppDelegate)?.duplicate(light, on: sender.representedObject as? NSScreen)
    }

    @objc private func closeLight() {
        guard let light else { return }
        (NSApp.delegate as? AppDelegate)?.close(light)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
