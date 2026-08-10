import AppKit

/// Brings a Ghostty terminal to the front by matching its working directory — see ADR 0005.
///
/// Matching is by `cwd`, not pid: Ghostty's *shipped* AppleScript `terminal` class (verified
/// against the sdef embedded in the installed app, `Ghostty.app/Contents/Resources/Ghostty.sdef`
/// — GitHub's `main` branch is ahead of what's actually released and already carries `pid`/`tty`
/// properties that don't exist yet in the binary) exposes only `id`, `name` (title), and
/// `working directory`. `cwd` is already captured per Session, so no new data is needed — but
/// unlike a pid, a cwd is not unique: two terminals can share one. When more than one terminal
/// matches, `titleHint` (the Session Title already cached from Claude's transcript for the
/// Sessions Menu, ADR 0004) disambiguates: Claude Code sets its own terminal title to that same
/// text, so a substring match picks the right one. If it still can't be narrowed to exactly one,
/// this does nothing — a wrong guess (jumping to an unrelated tab that happens to share the
/// directory) is worse than no guess.
///
/// Entirely best-effort otherwise too: Ghostty not running, an unsupported version, a denied
/// Automation permission, or a future sdef change all degrade to silently doing nothing — same
/// rule the Reporter itself follows, never disrupt.
enum GhosttyFocus {
    private static let queue = DispatchQueue(label: "com.claude-traffic-light.ghostty-focus", qos: .userInitiated)

    /// Runs off the main thread: the first call in a session blocks on the OS's own "TrafficLight
    /// wants to control Ghostty" permission prompt, and Apple Events in general can be slow —
    /// neither should freeze every Light (one process, one run loop).
    static func focus(cwd: String, titleHint: String?) {
        queue.async {
            // Addressing an app by name launches it if it isn't running; checking first avoids
            // popping open a blank Ghostty window when the matched Session actually lives in a
            // different terminal app (out of scope for v1 — Ghostty only).
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == "Ghostty" })
            else { return }

            let source = """
            tell application "Ghostty"
                set matches to (every terminal whose working directory is "\(escape(cwd))")
                set n to count of matches
                if n is 1 then
                    focus (item 1 of matches)
                else if n > 1 then
                    \(titleHintClause(titleHint))
                end if
            end tell
            """
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }

    /// AppleScript to pick the one match whose title contains `titleHint`, when there is one —
    /// otherwise empty, so an ambiguous cwd with no usable hint does nothing rather than guess.
    private static func titleHintClause(_ titleHint: String?) -> String {
        guard let titleHint, !titleHint.isEmpty else { return "" }
        return """
        repeat with t in matches
            if (name of t) contains "\(escape(titleHint))" then
                focus t
                exit repeat
            end if
        end repeat
        """
    }

    /// Escapes text embedded into the AppleScript source — `cwd` and `titleHint` are both
    /// effectively untrusted (a title comes from a model-generated transcript field), so this
    /// guards against both a broken script and script injection via a crafted path or title.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
