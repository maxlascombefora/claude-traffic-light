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
                let title = "\(Self.dot(s.status))  \(s.label)"
                let item = NSMenuItem(title: title, action: #selector(toggleMute(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.id
                item.isEnabled = true
                if s.muted {
                    item.state = .on
                    item.attributedTitle = NSAttributedString(string: title, attributes: [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue
                    ])
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addAction(to: menu, "Reset Position", #selector(resetPosition))
        menu.addItem(.separator())
        addAction(to: menu, "Quit Traffic Light", #selector(quit), key: "q")
        return menu
    }

    private func addDisabled(to menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
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

    @objc private func resetPosition() {
        (NSApp.delegate as? AppDelegate)?.resetPosition()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
