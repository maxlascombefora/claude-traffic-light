import AppKit
import TrafficLightCore

/// Draws the three-lamp traffic light. The lamp for `status` glows; the rest sit dim.
/// Also handles dragging the window and the right-click menu.
final class LampView: NSView {
    var status: Status = .idle {
        didSet { if status != oldValue { needsDisplay = true } }
    }

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero

    private let lamps: [(status: Status, color: NSColor)] = [
        (.blocked, .systemRed),
        (.yourTurn, .systemYellow),
        (.working, .systemGreen),
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let housing = bounds.insetBy(dx: 2, dy: 2)
        NSColor(calibratedWhite: 0.10, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: housing, xRadius: 11, yRadius: 11).fill()

        let diameter: CGFloat = 26
        let gap = (housing.height - CGFloat(lamps.count) * diameter) / CGFloat(lamps.count + 1)
        let centerX = housing.midX
        var top = housing.maxY - gap - diameter

        for lamp in lamps {
            let rect = NSRect(x: centerX - diameter / 2, y: top, width: diameter, height: diameter)
            let isOn = lamp.status == status

            let base = isOn ? lamp.color : (lamp.color.blended(withFraction: 0.82, of: .black) ?? lamp.color)
            base.setFill()
            NSBezierPath(ovalIn: rect).fill()

            if isOn {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 11, color: lamp.color.withAlphaComponent(0.9).cgColor)
                lamp.color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                ctx.restoreGState()
            }

            top -= diameter + gap
        }
    }

    // MARK: - drag to move

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: dragStartOrigin.x + (current.x - dragStartMouse.x),
            y: dragStartOrigin.y + (current.y - dragStartMouse.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        (NSApp.delegate as? AppDelegate)?.savePosition()
    }

    // MARK: - right-click menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Traffic Light", action: #selector(quit), keyEquivalent: "q")
            .target = self
        return menu
    }

    @objc private func resetPosition() {
        (NSApp.delegate as? AppDelegate)?.resetPosition()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
