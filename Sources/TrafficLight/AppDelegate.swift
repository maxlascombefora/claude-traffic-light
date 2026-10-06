import AppKit
import TrafficLightCore

/// One row of the Sessions Menu: a live Session with the Status it's contributing, a
/// human-readable label, and whether it's currently Muted.
struct MenuSession {
    let id: String
    let status: Status
    let label: String
    let muted: Bool
    /// nil/empty when the Session has no recorded cwd — Focus is disabled for that row, since
    /// there's no way to match it to a Ghostty terminal (see `GhosttyFocus`).
    let cwd: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every on-screen Light. Always at least one — the Sessions Menu won't close the last.
    private var lights: [Light] = []
    private var timer: Timer?

    private let ttl = defaultTTLSeconds

    /// Muted Sessions: session_id → the Status it was muted at. Overlay-local and in-memory
    /// (ADR 0003 keeps the Reporter stateless); pruned every refresh by `applyMutes`.
    private var muteMap: [String: Status] = [:]
    /// Live records from the most recent refresh, reused to build the Sessions Menu on demand.
    private var liveRecords: [SessionRecord] = []
    /// `liveRecords` with Muted Sessions removed — the same set the aggregate color is computed
    /// from. Click-to-focus searches this, not `liveRecords`: a Muted Session must never be a
    /// click target, or muting it would stop working the moment another Session shares its color.
    private var contributingRecords: [SessionRecord] = []
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

    /// The ttys of the open Ghostty terminals from the last scan, used to hide Orphaned Sessions
    /// (ADR 0006). nil when unknown, which hides nothing. Main-thread only.
    private var ghosttySnapshot: GhosttyTTYSnapshot?
    /// Serial background queue for the Ghostty AppleScript query.
    private let ghosttyQueue = DispatchQueue(label: "com.claude-traffic-light.ghostty-ttys", qos: .utility)
    /// Guards against piling up overlapping Ghostty scans. Main-thread only.
    private var ghosttyScanInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureDir(Paths.sessionsDir)

        restoreLights()

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970
        let live = dropOrphans(pruneDead(now: now, ttl: ttl), snapshot: ghosttySnapshot)
        let (contributing, keptMutes) = applyMutes(live, mutes: muteMap)
        muteMap = keptMutes
        liveRecords = live
        contributingRecords = contributing
        currentAggregate = aggregate(contributing, now: now, ttl: ttl)
        for light in lights { light.status = currentAggregate }

        // Warm Session Titles off the main thread: immediately at launch (tick 1), then every
        // ~5s. The Sessions Menu reads only the cache, so it never blocks on disk.
        refreshTick += 1
        if refreshTick % 5 == 1 {
            warmTitles(for: live.map(\.sessionId))
            scanGhostty()
        }
    }

    /// Read the open Ghostty terminals' ttys on the background queue into `ghosttySnapshot`, then
    /// refresh so an Orphaned Session leaves the Light at once. No-op while a previous scan is
    /// still running, unless `force` is set. `completion` runs on the main thread after the
    /// refresh (immediately when the scan is skipped).
    private func scanGhostty(force: Bool = false, completion: (() -> Void)? = nil) {
        guard force || !ghosttyScanInFlight else { completion?(); return }
        ghosttyScanInFlight = true
        ghosttyQueue.async { [weak self] in
            let snapshot = GhosttyTerminals.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.ghosttyScanInFlight = false
                self.ghosttySnapshot = snapshot
                self.refresh()
                completion?()
            }
        }
    }

    /// Read Session Titles for `ids` on the background queue and swap them into `titleCache`.
    /// Replacing the whole cache also drops entries for Sessions that have ended. No-op while a
    /// previous warm is still running, unless `force` is set. `completion` runs on the main
    /// thread once the cache holds the result (immediately when the warm is skipped).
    private func warmTitles(for ids: [String], force: Bool = false, completion: (() -> Void)? = nil) {
        guard force || !titleWarmInFlight else { completion?(); return }
        guard !ids.isEmpty else { titleCache = [:]; completion?(); return }
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
                completion?()
            }
        }
    }

    // MARK: - click-to-focus (ADR 0005)

    /// A Light was clicked (not dragged): jump to the oldest live, unmuted Session whose Status
    /// matches the color currently shown, so long as it has a resolvable cwd. No-op if there's no
    /// such Session — every color is eligible, including Working/Idle ("which one's running?").
    func focusOldestMatchingCurrentColor() {
        guard let candidate = focusCandidate(matching: currentAggregate, in: contributingRecords),
              let cwd = candidate.cwd, !cwd.isEmpty else { return }
        GhosttyFocus.focus(cwd: cwd, titleHint: titleCache[candidate.sessionId])
    }

    /// Sessions Menu row → Focus: jump to that one specific Session directly, bypassing the
    /// color queue. Works even when Muted — an explicit pick from the menu, unlike the ambient
    /// click, isn't the ambient nagging Mute exists to silence.
    func focusSession(sessionId: String) {
        guard let record = liveRecords.first(where: { $0.sessionId == sessionId }),
              let cwd = record.cwd, !cwd.isEmpty else { return }
        GhosttyFocus.focus(cwd: cwd, titleHint: titleCache[sessionId])
    }

    // MARK: - Sessions Menu

    /// Sessions Menu → *Refresh Sessions*: rescan the open Ghostty terminals and the sessions
    /// dir now, and reread every Session Title from its transcript, instead of waiting for the
    /// 1s status poll and the ~5s title warm. `completion` runs on the main thread once the
    /// fresh titles are in the cache.
    func refreshSessions(completion: @escaping () -> Void) {
        scanGhostty(force: true) { [weak self] in
            guard let self else { return }
            self.warmTitles(for: self.liveRecords.map(\.sessionId), force: true, completion: completion)
        }
    }

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

    /// Mute every live Session except `sessionId`: mute the rest at their current Status, and
    /// unmute `sessionId` itself if it was muted. Refreshes immediately, like `toggleMute`.
    func muteAllExcept(sessionId: String) {
        for rec in liveRecords where rec.sessionId != sessionId {
            muteMap[rec.sessionId] = rec.status
        }
        muteMap[sessionId] = nil
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
                               muted: muteMap[row.rec.sessionId] == row.rec.status, cwd: row.rec.cwd)
        }
        .sorted {
            $0.status.priority != $1.status.priority
                ? $0.status.priority > $1.status.priority
                : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }

        return (currentAggregate, sessions)
    }

    // MARK: - the set of Lights

    /// More than one Light on screen? Governs whether *Close This Light* is available — the last
    /// one can't be closed, or the app would be running with nothing to right-click.
    var canCloseLights: Bool { lights.count > 1 }

    /// Add another Light showing the same Status, positioned by `source` (beside itself on the
    /// same screen, or at the default spot on another).
    func duplicate(_ source: Light, on screen: NSScreen?) {
        guard let screen = screen ?? source.screen ?? NSScreen.main else { return }
        let origin = source.duplicateOrigin(on: screen, avoiding: lights.map(\.frame))
        let light = Light(diameter: source.diameter, origin: origin, app: self)
        light.status = currentAggregate
        lights.append(light)
        saveLights()
    }

    func close(_ light: Light) {
        guard canCloseLights, let index = lights.firstIndex(where: { $0 === light }) else { return }
        lights.remove(at: index)
        light.close()
        saveLights()
    }

    // MARK: - persistence

    /// Lights are stored as one array of `{x, y, d}` — the whole set, rewritten on any change.
    private static let lightsKey = "lights"

    func saveLights() {
        UserDefaults.standard.set(lights.map { $0.snapshot() }, forKey: Self.lightsKey)
    }

    /// Recreate the saved Lights, or a single default one on first run. Anything saved for a
    /// screen that's since been unplugged is placed on the main screen instead, so a Light can
    /// never come back invisible.
    private func restoreLights() {
        for spec in Self.savedSpecs() {
            let size = LampMetrics.panelSize(diameter: spec.diameter)
            let origin = Self.onscreenOrigin(spec.origin, size: size)
            lights.append(Light(diameter: spec.diameter, origin: origin, app: self))
        }
        if lights.isEmpty, let screen = NSScreen.main {
            let size = LampMetrics.panelSize(diameter: LampMetrics.defaultDiameter)
            lights.append(Light(diameter: LampMetrics.defaultDiameter,
                                origin: Light.defaultOrigin(on: screen, size: size),
                                app: self))
        }
    }

    /// The saved set, falling back to the single-Light keys written by earlier versions.
    private static func savedSpecs() -> [(origin: NSPoint?, diameter: CGFloat)] {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: lightsKey) as? [[String: Double]], !saved.isEmpty {
            return saved.map { entry in
                let origin = entry["x"].flatMap { x in entry["y"].map { NSPoint(x: x, y: $0) } }
                return (origin, LampMetrics.clamp(entry["d"] ?? LampMetrics.defaultDiameter))
            }
        }
        let saved = (defaults.object(forKey: "lampDiameter") as? Double).map { CGFloat($0) }
        let diameter = LampMetrics.clamp(saved ?? LampMetrics.defaultDiameter)
        guard defaults.object(forKey: "originX") != nil else { return [] }
        return [(NSPoint(x: defaults.double(forKey: "originX"),
                         y: defaults.double(forKey: "originY")), diameter)]
    }

    /// Keep a restored origin only if it still lands on a connected screen.
    private static func onscreenOrigin(_ origin: NSPoint?, size: NSSize) -> NSPoint {
        let fallbackScreen = NSScreen.main
        guard let origin else {
            return fallbackScreen.map { Light.defaultOrigin(on: $0, size: size) } ?? .zero
        }
        let frame = NSRect(origin: origin, size: size)
        if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) { return origin }
        return fallbackScreen.map { Light.defaultOrigin(on: $0, size: size) } ?? origin
    }
}
