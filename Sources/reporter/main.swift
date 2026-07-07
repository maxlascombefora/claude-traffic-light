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

/// Process names (kinfo p_comm) we treat as pass-through wrappers between the hook and the
/// Claude session, and step over when resolving the owning process.
let wrapperNames: Set<String> = [
    "sh", "-sh", "bash", "-bash", "zsh", "-zsh", "dash", "fish", "ksh", "csh", "tcsh",
    "login", "env",
]

/// The Claude session process that owns this hook = the NEAREST ancestor of the reporter
/// that isn't a shell/login wrapper. We can't match by name: Claude Code's own process name
/// (kinfo p_comm) is its CLI *version string* (e.g. "2.1.203"), not "claude". But hooks are
/// always spawned `claude → sh -c → reporter`, so the first non-wrapper ancestor is the
/// session. "Nearest" is load-bearing — it stops below launchers like openclaw's long-lived
/// `node` gateway, which sits ABOVE the session and would otherwise be recorded as a shared,
/// immortal pid that pins every session live forever. The start time is captured alongside
/// to fingerprint the exact process against later pid reuse.
func resolveClaudeProcess() -> (pid: Int32, start: Double?)? {
    var pid = getppid()
    var hops = 0
    while pid > 1, hops < 12 {
        let name = (processName(pid) ?? "").lowercased()
        if !name.isEmpty, !wrapperNames.contains(name) {
            return (pid, processStartTime(pid))
        }
        guard let parent = parentPID(of: pid), parent != pid else { break }
        pid = parent
        hops += 1
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
        cwd: json["cwd"] as? String,
        // A resolved process with no controlling terminal is headless automation (claude -p);
        // exclude it from the Light. Unknown (no pid) stays nil → treated as a real window.
        interactive: proc.map { hasControllingTerminal($0.pid) }
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
