import Foundation
import TrafficLightCore

/// Installs/removes the hook entries in Claude Code's settings.json, and stages a stable
/// copy of this binary at ~/.claude-traffic-light/bin/reporter that the hooks point at.
enum Installer {
    /// (hook event, matcher, reporter subcommand). Matcher "" means "all".
    /// PreToolUse is intentionally omitted so we never sit in a tool's blocking path;
    /// UserPromptSubmit + PostToolUse cover WORKING (and re-green after a permission approval).
    static let routes: [(event: String, matcher: String, status: String)] = [
        ("SessionStart", "", "idle"),
        ("UserPromptSubmit", "", "working"),
        ("PostToolUse", "", "working"),
        ("Notification", "permission_prompt", "blocked"),
        ("Notification", "idle_prompt", "your-turn"),
        ("Stop", "", "your-turn"),
        ("SessionEnd", "", "end"),
    ]

    static var stagedBinary: URL { Paths.binDir.appendingPathComponent("reporter") }

    static func install() {
        let bin = stageBinary()
        let settingsURL = Paths.settingsPath

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let data = try? Data(contentsOf: settingsURL) else {
                fail("could not read \(settingsURL.path)"); return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                fail("\(settingsURL.path) is not plain JSON (comments?). Aborting — add hooks by hand.")
                return
            }
            root = dict
            let backup = settingsURL.path + ".ctl-backup"
            try? data.write(to: URL(fileURLWithPath: backup))
            print("backed up existing settings → \(backup)")
        } else {
            Paths.ensureDir(settingsURL.deletingLastPathComponent())
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Group our routes by event so each event key holds all its matchers.
        var byEvent: [String: [(matcher: String, status: String)]] = [:]
        for r in routes { byEvent[r.event, default: []].append((r.matcher, r.status)) }

        for (event, entries) in byEvent {
            var arr = hooks[event] as? [Any] ?? []
            arr.removeAll { entryReferencesOurBin($0, bin: bin) }  // idempotent re-install
            for e in entries {
                arr.append([
                    "matcher": e.matcher,
                    "hooks": [[
                        "type": "command",
                        "command": "\"\(bin)\" \(e.status)",
                        "async": true,
                        "timeout": 5,
                    ]],
                ] as [String: Any])
            }
            hooks[event] = arr
        }
        root["hooks"] = hooks

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            fail("failed to serialize settings"); return
        }
        do {
            try out.write(to: settingsURL, options: .atomic)
            print("installed \(routes.count) hooks → \(settingsURL.path)")
            print("reporter binary → \(bin)")
        } catch {
            fail("failed to write settings: \(error)")
        }
    }

    static func uninstall() {
        let bin = stagedBinary.path
        let settingsURL = Paths.settingsPath
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              var root = obj as? [String: Any] else {
            print("nothing to uninstall (no parseable settings.json)"); return
        }
        guard var hooks = root["hooks"] as? [String: Any] else {
            print("no hooks present"); return
        }
        for (event, value) in hooks {
            guard var arr = value as? [Any] else { continue }
            arr.removeAll { entryReferencesOurBin($0, bin: bin) }
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        if let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL, options: .atomic)
            print("removed our hooks → \(settingsURL.path)")
        }
    }

    // MARK: - helpers

    /// Copy the running binary to a stable location so hook commands don't point into .build.
    private static func stageBinary() -> String {
        Paths.ensureDir(Paths.binDir)
        let src = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let dst = stagedBinary
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(atPath: src, toPath: dst.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
            return dst.path
        } catch {
            // Fall back to referencing the original path in place.
            fputs("warning: could not stage binary (\(error)); referencing \(src)\n", stderr)
            return src
        }
    }

    private static func entryReferencesOurBin(_ entry: Any, bin: String) -> Bool {
        guard let dict = entry as? [String: Any],
              let hooks = dict["hooks"] as? [Any] else { return false }
        for h in hooks {
            if let hookDict = h as? [String: Any],
               let cmd = hookDict["command"] as? String,
               cmd.contains(bin) || cmd.contains("claude-traffic-light") {
                return true
            }
        }
        return false
    }

    private static func fail(_ msg: String) {
        fputs("install: \(msg)\n", stderr)
    }
}
