import Foundation

/// True when a hook payload shows work that will re-invoke the Session without the user:
/// a still-running background task (Bash run_in_background, a background subagent) or a
/// scheduled wakeup (/loop, session crons). Claude Code fires Stop when such a turn ends,
/// which would otherwise read as Your Turn even though the Session resumes on its own.
///
/// The `background_tasks` and `session_crons` arrays ship on Stop payloads from CLI ≥ 2.1.216
/// (verified empirically); payloads without them — older CLIs, other hook events — report no
/// pending work, so this degrades to the previous behaviour.
public func willAutoResume(hookJSON json: [String: Any]) -> Bool {
    if let tasks = json["background_tasks"] as? [[String: Any]] {
        // A task with no status field is assumed running — lenient toward green, matching
        // the observed payloads ({"status":"running"} while a task is pending).
        if tasks.contains(where: { ($0["status"] as? String ?? "running") == "running" }) {
            return true
        }
    }
    if let crons = json["session_crons"] as? [Any], !crons.isEmpty {
        return true
    }
    return false
}
