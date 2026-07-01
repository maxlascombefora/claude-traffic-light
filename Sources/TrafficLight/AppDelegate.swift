import AppKit
import TrafficLightCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var lampView: LampView!
    private var timer: Timer?

    private let panelSize = NSSize(width: 46, height: 116)
    private let ttl = defaultTTLSeconds

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureDir(Paths.sessionsDir)

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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

        lampView = LampView(frame: NSRect(origin: .zero, size: panelSize))
        panel.contentView = lampView

        restorePosition()
        panel.orderFrontRegardless()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970
        let live = pruneDead(now: now, ttl: ttl)
        lampView.status = aggregate(live, now: now, ttl: ttl)
    }

    // MARK: - position

    func restorePosition() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "originX") != nil {
            panel.setFrameOrigin(NSPoint(x: defaults.double(forKey: "originX"),
                                         y: defaults.double(forKey: "originY")))
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panelSize.width - 24,
                                         y: visible.maxY - panelSize.height - 24))
        }
    }

    func savePosition() {
        let origin = panel.frame.origin
        UserDefaults.standard.set(Double(origin.x), forKey: "originX")
        UserDefaults.standard.set(Double(origin.y), forKey: "originY")
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "originX")
        UserDefaults.standard.removeObject(forKey: "originY")
        restorePosition()
    }
}
