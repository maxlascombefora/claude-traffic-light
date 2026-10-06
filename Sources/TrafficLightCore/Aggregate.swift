import Foundation

/// Default staleness backstop when a session has no resolvable pid: 12 hours.
public let defaultTTLSeconds: Double = 12 * 60 * 60

/// A record is "live" (contributes to the Light) if its process is alive; or, when we
/// couldn't resolve a pid, if it hasn't gone past the inactivity TTL.
///
/// A live pid alone is not trusted: pids get recycled by the OS, so a dead session whose
/// pid was reassigned to an unrelated process would otherwise look live forever. When the
/// record carries a start-time fingerprint (`pidStart`), the process at that pid must still
/// have the same start time; a recycled pid has a newer one and reads as dead.
public func isLive(
    _ r: SessionRecord,
    now: Double,
    ttl: Double = defaultTTLSeconds,
    alive: (Int32) -> Bool = processAlive,
    startTime: (Int32) -> Double? = processStartTime
) -> Bool {
    // Headless automation (no controlling terminal) never drives the Light, even while its
    // process is alive — the Light reflects real windows. nil (unknown) is treated as a window.
    if r.interactive == false { return false }
    if let pid = r.pid {
        guard alive(pid) else { return false }
        // Fingerprinted record: require the pid to still be the same process. If we can't
        // read the current start time, stay lenient (don't prune a possibly-live session).
        if let recorded = r.pidStart, let current = startTime(pid) {
            return abs(current - recorded) < 1.0
        }
        return true
    }
    return (now - r.updatedAt) <= ttl
}

/// Apply Mutes to a set of live records. A Mute maps a `session_id` to the Status the Session
/// held when it was muted; it is *bound to that Status value* (see CONTEXT.md / Mute). This
/// returns the records that still contribute to the Light plus the pruned Mute map: an entry
/// is dropped when its Session has vanished or when its current Status differs from the muted
/// value — so a Mute auto-clears the instant the Session's Status changes, and a later return
/// to that same Status is a fresh Status that nags again.
///
/// Pure and liveness-agnostic: callers pass records they already consider live.
public func applyMutes(
    _ records: [SessionRecord],
    mutes: [String: Status]
) -> (contributing: [SessionRecord], mutes: [String: Status]) {
    var statusById: [String: Status] = [:]
    for r in records { statusById[r.sessionId] = r.status }
    var kept: [String: Status] = [:]
    for (id, mutedStatus) in mutes where statusById[id] == mutedStatus {
        kept[id] = mutedStatus
    }
    let contributing = records.filter { kept[$0.sessionId] == nil }
    return (contributing, kept)
}

/// Worst-wins aggregate Status across live records; `.idle` when nothing is live.
public func aggregate(
    _ records: [SessionRecord],
    now: Double,
    ttl: Double = defaultTTLSeconds,
    alive: (Int32) -> Bool = processAlive,
    startTime: (Int32) -> Double? = processStartTime
) -> Status {
    let live = records.filter { isLive($0, now: now, ttl: ttl, alive: alive, startTime: startTime) }
    return live.map(\.status).max(by: { $0.priority < $1.priority }) ?? .idle
}

/// The Session to jump to when a Light showing `color` is clicked: the oldest — by `changedAt`,
/// falling back to `updatedAt` for records written before that field existed — Session whose
/// Status is `color` among `contributing` (the post-Mute set already used for the aggregate).
/// Filtered to a resolvable `cwd`, since a Session without one can never be matched to a Ghostty
/// terminal (see `GhosttyFocus`); including it would let it permanently block the queue instead
/// of ever reaching a focusable Session behind it. nil when nothing matches. See ADR 0005.
public func focusCandidate(matching color: Status, in contributing: [SessionRecord]) -> SessionRecord? {
    contributing
        .filter { $0.status == color && !($0.cwd ?? "").isEmpty }
        .min { ($0.changedAt ?? $0.updatedAt) < ($1.changedAt ?? $1.updatedAt) }
}

/// Read every session record on disk (skipping unreadable/garbage files).
public func loadRecords(from dir: URL = Paths.sessionsDir) -> [SessionRecord] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return []
    }
    let dec = JSONDecoder()
    return items.filter { $0.pathExtension == "json" }.compactMap { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? dec.decode(SessionRecord.self, from: data)
    }
}

/// Delete session files that are no longer live, returning the survivors.
@discardableResult
public func pruneDead(
    in dir: URL = Paths.sessionsDir,
    now: Double,
    ttl: Double = defaultTTLSeconds,
    alive: (Int32) -> Bool = processAlive,
    startTime: (Int32) -> Double? = processStartTime
) -> [SessionRecord] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return []
    }
    let dec = JSONDecoder()
    var live: [SessionRecord] = []
    for url in items where url.pathExtension == "json" {
        guard let data = try? Data(contentsOf: url),
              let r = try? dec.decode(SessionRecord.self, from: data) else { continue }
        if isLive(r, now: now, ttl: ttl, alive: alive, startTime: startTime) {
            live.append(r)
        } else {
            try? fm.removeItem(at: url)
        }
    }
    return live
}

/// The tty of every open Ghostty terminal, read at `takenAt` (Unix epoch seconds).
public struct GhosttyTTYSnapshot: Sendable {
    public let ttys: Set<String>
    public let takenAt: Double

    public init(ttys: Set<String>, takenAt: Double) {
        self.ttys = ttys
        self.takenAt = takenAt
    }
}

/// Remove Orphaned Sessions: a Session whose process runs under Ghostty, but on a tty that no
/// open Ghostty terminal has. This happens when Ghostty closes a tab but the `claude` process in
/// it keeps running, so the pid check in `isLive` can't see that the Session is gone.
///
/// Every doubt keeps the Session, because hiding a live Session is worse than showing a closed
/// one:
/// - no snapshot (Ghostty not running, or too old to report terminal ttys): keep all;
/// - no pid, or no `pidStart`: keep, since the process start can't be compared to the snapshot;
/// - process started at or after the snapshot: keep, since its terminal may not be listed yet;
/// - process not under Ghostty (another terminal app): keep;
/// - tty unreadable: keep.
public func dropOrphans(
    _ records: [SessionRecord],
    snapshot: GhosttyTTYSnapshot?,
    tty: (Int32) -> String? = ttyPath(of:),
    underGhostty: (Int32) -> Bool = { hasAncestor($0, named: "ghostty") }
) -> [SessionRecord] {
    guard let snapshot else { return records }
    return records.filter { r in
        guard let pid = r.pid, let start = r.pidStart, start < snapshot.takenAt,
              underGhostty(pid), let path = tty(pid) else { return true }
        return snapshot.ttys.contains(path)
    }
}
