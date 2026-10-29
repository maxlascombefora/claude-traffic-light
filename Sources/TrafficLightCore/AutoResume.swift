import Foundation

/// True when a hook payload shows work that will re-invoke the Session without the user:
/// a still-running background task (Bash run_in_background, a background subagent) or a
/// scheduled wakeup (/loop, session crons). Claude Code fires Stop when such a turn ends,
/// which would otherwise read as Your Turn even though the Session resumes on its own.
///
/// The `background_tasks` and `session_crons` arrays ship on Stop payloads from CLI ≥ 2.1.216
/// (verified empirically); payloads without them — older CLIs, other hook events — report no
/// pending work, so this degrades to the previous behaviour.
///
/// A running task only counts when it will actually finish. Claude starts dev servers and log
/// tails as background shell tasks too, and those never exit, so a Session that owns one would
/// read as Working for as long as the server runs. Such tasks are recognised by their command
/// (see `isLongLived`) and skipped.
public func willAutoResume(hookJSON json: [String: Any]) -> Bool {
    if let tasks = json["background_tasks"] as? [[String: Any]] {
        // A task with no status field is assumed running — lenient toward green, matching
        // the observed payloads ({"status":"running"} while a task is pending).
        if tasks.contains(where: {
            ($0["status"] as? String ?? "running") == "running" && !isLongLived(task: $0)
        }) {
            return true
        }
    }
    if let crons = json["session_crons"] as? [Any], !crons.isEmpty {
        return true
    }
    return false
}

/// Commands that run until killed: dev servers, watchers, log tails. Matched case-insensitively
/// against the whole command line of a `shell` background task. A hit means the task will never
/// re-invoke the Session, so it must not hold the Light green.
///
/// Kept narrow on purpose: a CI watch (`gh pr checks --watch`) or a `--wait` script also runs in
/// the background and *does* finish, so generic words like "watch" or "wait" are not here.
public let longLivedCommandPatterns: [String] = [
    #"(^|[\s/;&|])next\s+dev\b"#,                          // next dev -p 3009
    #"(^|[\s/;&|])vite\b(?!\s+(build|preview))"#,          // vite, vite dev, vite serve
    #"(^|[\s/;&|])(yarn|npm|pnpm|bun)\s+(run\s+)?(dev|start|serve|storybook)(?![\w:.-])"#,
    #"(^|[\s/;&|])nodemon\b"#,
    #"(^|[\s/;&|])webpack(-dev-server|\s+serve)\b"#,
    #"\bmanage\.py\s+runserver\b"#,
    #"(^|[\s/;&|])runserver\b"#,
    #"(^|[\s/;&|])docker(\s+|-)compose\s+up\b(?!.*\s-d\b)"#, // compose up without -d stays attached
    #"(^|[\s/;&|])python3?\s+-m\s+http\.server\b"#,
    #"(^|[\s/;&|])tail\s(.*\s)?(-[a-zA-Z]*[fF]|--follow)\b"#, // tail -f, tail -n0 -F, tail --follow
    #"(^|[\s/;&|])(vitest|jest)\b.*\s--watch(All)?\b"#,     // test runners in watch mode
    #"(^|[\s/;&|])tsc\b.*\s(-w|--watch)\b"#,
]

/// Whether a background task entry describes a process that runs until killed. Only `shell`
/// tasks carry a `command`; every other task type (subagent, monitor, workflow, teammate, cloud
/// session, MCP task) has an end and always counts as work that resumes the Session. A `shell`
/// task without a command is kept as well: every doubt keeps the Light green.
public func isLongLived(task: [String: Any]) -> Bool {
    guard let command = task["command"] as? String, !command.isEmpty else { return false }
    return isLongLived(command: command)
}

public func isLongLived(command: String) -> Bool {
    longLivedCommandPatterns.contains { pattern in
        command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
