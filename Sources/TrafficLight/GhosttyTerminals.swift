import AppKit
import TrafficLightCore

/// Reads the tty of every open Ghostty terminal, to find Orphaned Sessions (see ADR 0006).
///
/// Ghostty's AppleScript `terminal` class gets a `tty` property after 1.3.1 (it is on GitHub
/// `main`, code `Gtty`, value like "/dev/ttys016"). This checks the sdef inside the installed app
/// first and sends no Apple Event when the property is missing, so an older Ghostty never
/// triggers the "TrafficLight wants to control Ghostty" permission prompt for nothing.
///
/// Call off the main thread: Apple Events can be slow, and the first one blocks on that prompt.
enum GhosttyTerminals {
    /// The ttys of all open Ghostty terminals, or nil when Ghostty isn't running, has no `tty`
    /// property, or the script fails. nil means "unknown", and `dropOrphans` then keeps every
    /// Session.
    static func snapshot() -> GhosttyTTYSnapshot? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName == "Ghostty" }),
              let bundle = app.bundleURL, supportsTTY(bundle: bundle) else { return nil }

        // Taken before the query: a terminal open at this time is in the result.
        let takenAt = Date().timeIntervalSince1970
        guard let script = NSAppleScript(source: """
            tell application "Ghostty" to get tty of every terminal
            """) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }

        var ttys: Set<String> = []
        if result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                if let tty = result.atIndex(i)?.stringValue, !tty.isEmpty { ttys.insert(tty) }
            }
        }
        return GhosttyTTYSnapshot(ttys: ttys, takenAt: takenAt)
    }

    /// Does the installed Ghostty's scripting dictionary define the terminal `tty` property?
    private static func supportsTTY(bundle: URL) -> Bool {
        let sdef = bundle.appendingPathComponent("Contents/Resources/Ghostty.sdef")
        guard let text = try? String(contentsOf: sdef, encoding: .utf8) else { return false }
        return text.contains("code=\"Gtty\"")
    }
}
