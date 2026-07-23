import AppKit
import TrafficLightCore

/// One row of the Sessions Menu: a live Session with the Status it's contributing, a
/// human-readable label, and whether it's currently Muted.
struct MenuSession {
    let id: String
    let status: Status
    let label: String
    let muted: Bool
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var lampView: LampView!
    private var timer: Timer?

    private let panelSize = NSSize(width: 46, height: 116)
    private let ttl = defaultTTLSeconds

    /// Muted Sessions: session_id → the Status it was muted at. Overlay-local and in-memory
    /// (ADR 0003 keeps the Reporter stateless); pruned every refresh by `applyMutes`.
    private var muteMap: [String: Status] = [:]
    /// Live records from the most recent refresh, reused to build the Sessions Menu on demand.
    private var liveRecords: [SessionRecord] = []
    /// Aggregate Status from the most recent refresh (post-Mute), shown in the menu header.
    private var currentAggregate: Status = .idle

    /// Cached Session Titles (session_id → title), read off the main thread so the Sessions
    /// Menu opens instantly (see ADR 0004 — titles come from Claude's transcript, which can be
    /// large). Main-thread only. Misses fall back to the cwd basename in `menuModel`.
    private var titleCache: [String: String] = [:]
    /// Serial background queue for transcript reads. Keeps disk I/O off the main thread.
    private let titleQueue = DispatchQueue(label: "com.claude-traffic-light.titles", qos: .utility)
    /// Guards against piling up overlapping title warms. Main-thread only.
    private var titleWarmInFlight = false
    /// Refresh counter, used to warm titles on a slower cadence than the 1s status poll.
    private var refreshTick = 0

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
        let (contributing, keptMutes) = applyMutes(live, mutes: muteMap)
        muteMap = keptMutes
        liveRecords = live
        currentAggregate = aggregate(contributing, now: now, ttl: ttl)
        lampView.status = currentAggregate

        // Warm Session Titles off the main thread: immediately at launch (tick 1), then every
        // ~5s. The Sessions Menu reads only the cache, so it never blocks on disk.
        refreshTick += 1
        if refreshTick % 5 == 1 { warmTitles(for: live.map(\.sessionId)) }
    }

    /// Read Session Titles for `ids` on the background queue and swap them into `titleCache`.
    /// Replacing the whole cache also drops entries for Sessions that have ended. No-op while a
    /// previous warm is still running.
    private func warmTitles(for ids: [String]) {
        guard !titleWarmInFlight else { return }
        guard !ids.isEmpty else { titleCache = [:]; return }
        titleWarmInFlight = true
        titleQueue.async { [weak self] in
            var found: [String: String] = [:]
            for id in ids {
                if let title = SessionTitle.read(sessionId: id) { found[id] = title }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.titleWarmInFlight = false
                self.titleCache = found
            }
        }
    }

    // MARK: - Sessions Menu

    /// Toggle the Mute on a Session: unmute if muted, else mute at its current Status. Refreshes
    /// immediately so the Light responds without waiting for the next poll tick.
    func toggleMute(sessionId: String) {
        if muteMap[sessionId] != nil {
            muteMap[sessionId] = nil
        } else if let rec = liveRecords.first(where: { $0.sessionId == sessionId }) {
            muteMap[sessionId] = rec.status
        }
        refresh()
    }

    /// Build the Sessions Menu model from the last refresh's live records: label each Session
    /// (cached Title → cwd basename → id prefix), disambiguate collisions with a short id
    /// suffix, and sort by Status urgency (Blocked → Idle), ties broken by label.
    ///
    /// Reads only `titleCache` — never touches disk — so the menu opens instantly. Any Session
    /// not yet cached (e.g. just appeared) shows its cwd basename now and kicks a background
    /// warm so it's correct on the next open.
    func menuModel() -> (aggregate: Status, sessions: [MenuSession]) {
        if liveRecords.contains(where: { titleCache[$0.sessionId] == nil }) {
            warmTitles(for: liveRecords.map(\.sessionId))
        }

        let labelled: [(rec: SessionRecord, base: String)] = liveRecords.map { r in
            let base: String
            if let title = titleCache[r.sessionId] {
                base = title
            } else if let cwd = r.cwd, !cwd.isEmpty {
                base = (cwd as NSString).lastPathComponent
            } else {
                base = String(r.sessionId.prefix(8))
            }
            return (r, base)
        }

        var counts: [String: Int] = [:]
        for row in labelled { counts[row.base, default: 0] += 1 }

        let sessions = labelled.map { row -> MenuSession in
            let label = counts[row.base, default: 0] > 1
                ? "\(row.base) (#\(row.rec.sessionId.prefix(4)))"
                : row.base
            return MenuSession(id: row.rec.sessionId, status: row.rec.status, label: label,
                               muted: muteMap[row.rec.sessionId] == row.rec.status)
        }
        .sorted {
            $0.status.priority != $1.status.priority
                ? $0.status.priority > $1.status.priority
                : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }

        return (currentAggregate, sessions)
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
