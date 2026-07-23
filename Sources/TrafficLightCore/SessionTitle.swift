import Foundation

/// Reads the human-readable Session Title from Claude Code's own conversation transcript.
///
/// This is the *one* place the tool reads Claude internals (see ADR 0004). The transcript
/// format is undocumented and unstable, so this is used only for a display label — never for
/// Status or the Light — and every step degrades to nil rather than failing. Callers read this
/// off the main thread into a cache (see `AppDelegate`), not in the 1s poll loop, so the
/// Sessions Menu never blocks on disk.
public enum SessionTitle {
    /// Best-effort title for a `session_id`, or nil if none can be read. Locates the transcript
    /// by scanning the projects dir for `<session_id>.jsonl` (rather than reverse-engineering
    /// the cwd→dirname munging, the most fragile part of the layout) and returns the last
    /// `ai-title` recorded in it.
    public static func read(
        sessionId: String,
        projectsDir: URL = Paths.projectsDir
    ) -> String? {
        guard let file = transcriptFile(sessionId: sessionId, projectsDir: projectsDir),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        let dec = JSONDecoder()
        var latest: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap prefilter: only pay the JSON-decode cost for candidate lines.
            guard line.contains("ai-title"), let data = line.data(using: .utf8),
                  let row = try? dec.decode(TitleLine.self, from: data),
                  row.type == "ai-title", let title = row.aiTitle, !title.isEmpty
            else { continue }
            latest = title
        }
        return latest
    }

    private struct TitleLine: Decodable {
        let type: String
        let aiTitle: String?
    }

    /// The `<session_id>.jsonl` file under some project subdirectory, if it exists.
    private static func transcriptFile(sessionId: String, projectsDir: URL) -> URL? {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return nil }
        // Sanitize before using the id as a path component: the session_id comes from a session
        // file's *contents*, so a crafted value (e.g. "../…") must not escape the projects dir.
        // Legit ids are UUIDs, for which this is a no-op, so real files still match.
        let name = Paths.sanitize(sessionId) + ".jsonl"
        for dir in projects {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
