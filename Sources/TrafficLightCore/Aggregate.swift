import Foundation

/// Default staleness backstop when a session has no resolvable pid: 12 hours.
public let defaultTTLSeconds: Double = 12 * 60 * 60

/// A record is "live" (contributes to the Light) if its process is alive; or, when we
/// couldn't resolve a pid, if it hasn't gone past the inactivity TTL.
public func isLive(
    _ r: SessionRecord,
    now: Double,
    ttl: Double = defaultTTLSeconds,
    alive: (Int32) -> Bool = processAlive
) -> Bool {
    if let pid = r.pid {
        return alive(pid)
    }
    return (now - r.updatedAt) <= ttl
}

/// Worst-wins aggregate Status across live records; `.idle` when nothing is live.
public func aggregate(
    _ records: [SessionRecord],
    now: Double,
    ttl: Double = defaultTTLSeconds,
    alive: (Int32) -> Bool = processAlive
) -> Status {
    let live = records.filter { isLive($0, now: now, ttl: ttl, alive: alive) }
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
    alive: (Int32) -> Bool = processAlive
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
        if isLive(r, now: now, ttl: ttl, alive: alive) {
            live.append(r)
        } else {
            try? fm.removeItem(at: url)
        }
    }
    return live
}
