import Foundation

/// Filesystem locations. All overridable via environment variables so tests (and the
/// installer's dry runs) never touch the real ~/.claude or ~/.claude-traffic-light.
public enum Paths {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Base dir for this tool's state. Override: CLAUDE_TRAFFIC_LIGHT_HOME
    public static var baseDir: URL {
        if let o = env["CLAUDE_TRAFFIC_LIGHT_HOME"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return home.appendingPathComponent(".claude-traffic-light", isDirectory: true)
    }

    public static var sessionsDir: URL { baseDir.appendingPathComponent("sessions", isDirectory: true) }
    public static var binDir: URL { baseDir.appendingPathComponent("bin", isDirectory: true) }

    /// Claude Code's per-project conversation transcripts, read only for Session Titles
    /// (see ADR 0004). Override: CLAUDE_TRAFFIC_LIGHT_PROJECTS
    public static var projectsDir: URL {
        if let o = env["CLAUDE_TRAFFIC_LIGHT_PROJECTS"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude Code's settings.json. Override: CLAUDE_TRAFFIC_LIGHT_SETTINGS
    public static var settingsPath: URL {
        if let o = env["CLAUDE_TRAFFIC_LIGHT_SETTINGS"], !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        return home.appendingPathComponent(".claude/settings.json")
    }

    public static func sessionFile(_ sessionId: String) -> URL {
        sessionsDir.appendingPathComponent(sanitize(sessionId) + ".json")
    }

    /// Keep filenames tame regardless of what a session_id contains.
    public static func sanitize(_ id: String) -> String {
        let mapped = id.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_"
        }
        let s = String(mapped)
        return s.isEmpty ? "unknown" : s
    }

    public static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
