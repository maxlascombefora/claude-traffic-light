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
