import Foundation
import TrafficLightCore

// The Reporter is invoked by Claude Code hooks. It must be fast and must NEVER disrupt a
// session: every path exits 0, and all errors are swallowed.

/// Read the hook JSON that Claude Code writes to stdin. nil if absent/invalid.
func readHookJSON() -> [String: Any]? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The Claude process that owns this session = the grandparent of the hook process
/// (Claude → sh -c → reporter). We only trust a candidate whose name looks like Claude,
/// otherwise we record no pid and let the TTL backstop handle staleness. The start time is
/// captured alongside the pid to fingerprint the exact process against later pid reuse.
func resolveClaudeProcess() -> (pid: Int32, start: Double?)? {
    let shell = getppid()
    let candidates = [parentPID(of: shell), shell].compactMap { $0 }
    for pid in candidates {
        if let name = processName(pid)?.lowercased(),
           name.contains("claude") || name.contains("node") {
            return (pid, processStartTime(pid))
        }
    }
    return nil
}

func report(_ status: Status) {
    guard let json = readHookJSON(),
          let sid = json["session_id"] as? String, !sid.isEmpty else { return }
    let proc = resolveClaudeProcess()
    let record = SessionRecord(
        sessionId: sid,
        status: status,
        pid: proc?.pid,
        pidStart: proc?.start,
        updatedAt: Date().timeIntervalSince1970,
        cwd: json["cwd"] as? String
    )
    Paths.ensureDir(Paths.sessionsDir)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(record) else { return }
    try? data.write(to: Paths.sessionFile(sid), options: .atomic)
}

func remove() {
    guard let json = readHookJSON(),
          let sid = json["session_id"] as? String, !sid.isEmpty else { return }
    try? FileManager.default.removeItem(at: Paths.sessionFile(sid))
}

/// Debug helper: print the current aggregate and live sessions.
func printAggregate() {
    let now = Date().timeIntervalSince1970
    let live = loadRecords().filter { isLive($0, now: now) }
    let agg = aggregate(live, now: now)
    print("aggregate=\(agg.rawValue)  live=\(live.count)")
    for r in live.sorted(by: { $0.status.priority > $1.status.priority }) {
        let pid = r.pid.map(String.init) ?? "-"
        print("  \(r.status.rawValue)\tpid=\(pid)\t\(r.cwd ?? "-")\t\(r.sessionId)")
    }
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
switch command {
case "working":   report(.working)
case "your-turn": report(.yourTurn)
case "blocked":   report(.blocked)
case "idle":      report(.idle)
case "end":       remove()
case "aggregate": printAggregate()
case "install":   Installer.install()
case "uninstall": Installer.uninstall()
default:
    FileHandle.standardError.write(Data(
        "usage: reporter <working|your-turn|blocked|idle|end|aggregate|install|uninstall>\n".utf8))
}
exit(0)
