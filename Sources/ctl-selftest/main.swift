import Foundation
import TrafficLightCore

// Minimal dependency-free self-test for the core aggregation/pruning logic.
// XCTest requires full Xcode; this runs anywhere Swift does. `swift run ctl-selftest`.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

let now: Double = 1000
let allAlive: (Int32) -> Bool = { _ in true }
let allDead: (Int32) -> Bool = { _ in false }

func rec(_ status: Status, pid: Int32? = nil, ageSeconds: Double = 0,
         interactive: Bool? = nil, changedAt: Double? = nil, cwd: String? = nil) -> SessionRecord {
    SessionRecord(sessionId: UUID().uuidString, status: status, pid: pid,
                  updatedAt: now - ageSeconds, cwd: cwd, interactive: interactive, changedAt: changedAt)
}

print("aggregation:")
check(aggregate([rec(.working, pid: 1), rec(.yourTurn, pid: 2), rec(.blocked, pid: 3)],
                now: now, alive: allAlive) == .blocked,
      "worst-wins: blocked beats all")
check(aggregate([rec(.working, pid: 1), rec(.yourTurn, pid: 2)], now: now, alive: allAlive) == .yourTurn,
      "your-turn beats working")
check(aggregate([], now: now) == .idle,
      "no sessions => idle")
check(aggregate([rec(.blocked, pid: 42), rec(.working, pid: 7)],
                now: now, alive: { $0 == 7 }) == .working,
      "dead pid excluded: stuck red cleared")

print("liveness:")
check(isLive(rec(.yourTurn, pid: nil, ageSeconds: 60), now: now, alive: allDead),
      "pid-less within TTL stays live")
check(!isLive(rec(.yourTurn, pid: nil, ageSeconds: defaultTTLSeconds + 1), now: now, alive: allDead),
      "pid-less past TTL expires")
check(isLive(rec(.yourTurn, pid: 99, ageSeconds: defaultTTLSeconds * 10), now: now, alive: allAlive),
      "live pid never expires by age (persist-until-closed)")

print("pid reuse:")
func fpRec(_ status: Status, pid: Int32, start: Double) -> SessionRecord {
    SessionRecord(sessionId: UUID().uuidString, status: status, pid: pid, pidStart: start,
                  updatedAt: now, cwd: nil)
}
check(isLive(fpRec(.yourTurn, pid: 802, start: 500), now: now,
             alive: allAlive, startTime: { _ in 500 }),
      "fingerprint matches: same process stays live")
check(!isLive(fpRec(.yourTurn, pid: 802, start: 500), now: now,
              alive: allAlive, startTime: { _ in 999 }),
      "fingerprint mismatch: recycled pid reads as dead")
check(isLive(fpRec(.working, pid: 802, start: 500), now: now,
             alive: allAlive, startTime: { _ in nil }),
      "unreadable start time stays lenient (not pruned)")
check(aggregate([fpRec(.yourTurn, pid: 802, start: 500), rec(.working, pid: 7)],
                now: now, alive: allAlive,
                startTime: { pid in pid == 7 ? 500 : 999 }) == .working,
      "stale your-turn on recycled pid no longer forces yellow")

print("interactive filter:")
check(!isLive(rec(.blocked, pid: 1, interactive: false), now: now, alive: allAlive),
      "headless session excluded even while alive")
check(isLive(rec(.working, pid: 1, interactive: true), now: now, alive: allAlive),
      "interactive session counts")
check(isLive(rec(.working, pid: 1, interactive: nil), now: now, alive: allAlive),
      "unknown interactivity treated as a window (backward compatible)")
check(aggregate([rec(.yourTurn, pid: 1, interactive: false),
                 rec(.working, pid: 2, interactive: true)],
                now: now, alive: allAlive) == .working,
      "headless your-turn (openclaw) no longer forces yellow over a real working window")

print("mute filter:")
func srec(_ id: String, _ status: Status) -> SessionRecord {
    SessionRecord(sessionId: id, status: status, pid: 1, updatedAt: now, cwd: nil)
}
let blockedA = srec("a", .blocked)
let workingB = srec("b", .working)

let muteBlocked = applyMutes([blockedA, workingB], mutes: ["a": .blocked])
check(muteBlocked.contributing.map(\.sessionId) == ["b"],
      "muted session excluded from the contributing set")
check(aggregate(muteBlocked.contributing, now: now, alive: allAlive) == .working,
      "muting the sole blocked session drops the Light to working")
check(muteBlocked.mutes["a"] == .blocked, "still-matching mute is retained")

let statusMoved = applyMutes([srec("a", .working), workingB], mutes: ["a": .blocked])
check(statusMoved.mutes["a"] == nil,
      "mute clears when status differs from the muted value (bind-to-value)")
check(statusMoved.contributing.count == 2, "a cleared-mute session contributes again")

let vanished = applyMutes([workingB], mutes: ["a": .blocked])
check(vanished.mutes["a"] == nil, "mute for a vanished session is dropped")

let twoYellow = applyMutes([srec("y1", .yourTurn), srec("y2", .yourTurn)], mutes: ["y1": .yourTurn])
check(aggregate(twoYellow.contributing, now: now, alive: allAlive) == .yourTurn,
      "muting one of two yellows leaves the Light yellow")

let allMuted = applyMutes([blockedA, srec("b2", .working)],
                          mutes: ["a": .blocked, "b2": .working])
check(aggregate(allMuted.contributing, now: now, alive: allAlive) == .idle,
      "muting every contributor dims the Light")

print("away mode:")
check(awayAggregate([rec(.working, pid: 1), rec(.yourTurn, pid: 2)], now: now, alive: allAlive) == .working,
      "away: a Working session beats Your Turn")
check(awayAggregate([rec(.working, pid: 1), rec(.yourTurn, pid: 2), rec(.blocked, pid: 3)],
                    now: now, alive: allAlive) == .blocked,
      "away: Blocked still wins")
check(awayAggregate([rec(.yourTurn, pid: 1), rec(.idle, pid: 2)], now: now, alive: allAlive) == .yourTurn,
      "away: no Working session falls back to Your Turn")
check(awayAggregate([rec(.working, pid: 42), rec(.yourTurn, pid: 7)],
                    now: now, alive: { $0 == 7 }) == .yourTurn,
      "away: a dead Working session does not keep the Light green")
check(awayAggregate([], now: now) == .idle, "away: nothing live => idle")
check(awayAggregate([rec(.working, pid: 1), rec(.yourTurn, pid: 2)],
                    now: now, minWorking: 2, alive: allAlive) == .yourTurn,
      "away threshold 2: one Working session is not enough")
check(awayAggregate([rec(.working, pid: 1), rec(.working, pid: 3), rec(.yourTurn, pid: 2)],
                    now: now, minWorking: 2, alive: allAlive) == .working,
      "away threshold 2: two Working sessions hold the Light green")
check(awayAggregate([rec(.working, pid: 1), rec(.working, pid: 42), rec(.yourTurn, pid: 2)],
                    now: now, minWorking: 2, alive: { $0 != 42 }) == .yourTurn,
      "away threshold 2: a dead Working session does not count")
check(awayAggregate([rec(.working, pid: 1), rec(.working, pid: 3), rec(.yourTurn, pid: 2), rec(.blocked, pid: 4)],
                    now: now, minWorking: 2, alive: allAlive) == .blocked,
      "away threshold 2: Blocked still wins")
check(awayAggregate([rec(.working, pid: 1), rec(.yourTurn, pid: 2)],
                    now: now, minWorking: 0, alive: allAlive) == .working,
      "away threshold below 1 is treated as 1")

print("focus candidate:")
check(focusCandidate(matching: .yourTurn, in: [
    rec(.yourTurn, changedAt: 500, cwd: "/a"),
    rec(.yourTurn, changedAt: 100, cwd: "/b"),
    rec(.blocked, changedAt: 1, cwd: "/c"),
]).map(\.cwd) == "/b",
      "oldest changedAt among matching-color candidates wins")
check(focusCandidate(matching: .yourTurn, in: [
    rec(.yourTurn, changedAt: 1, cwd: nil),
    rec(.yourTurn, changedAt: 500, cwd: "/b"),
]).map(\.cwd) == "/b",
      "cwd-less candidate skipped even though it's older, so the queue never gets stuck")
check(focusCandidate(matching: .working, in: [rec(.yourTurn, cwd: "/a")]) == nil,
      "no candidate of the requested color => nil")
check(focusCandidate(matching: .yourTurn, in: []) == nil,
      "no live sessions => nil")
check(focusCandidate(matching: .yourTurn, in: [
    rec(.yourTurn, ageSeconds: 10, cwd: "/a"),  // no changedAt: falls back to updatedAt (now - 10)
    rec(.yourTurn, changedAt: now - 5, cwd: "/b"),
]).map(\.cwd) == "/a",
      "missing changedAt (pre-upgrade record) falls back to updatedAt for ordering")

print("orphaned sessions:")
func orec(_ id: String, pid: Int32 = 1, start: Double? = 100) -> SessionRecord {
    SessionRecord(sessionId: id, status: .yourTurn, pid: pid, pidStart: start, updatedAt: now, cwd: nil)
}
let snap = GhosttyTTYSnapshot(ttys: ["/dev/ttys001"], takenAt: 500)
let ttyByPid: (Int32) -> String? = { $0 == 1 ? "/dev/ttys001" : "/dev/ttys005" }
let ghostty: (Int32) -> Bool = { _ in true }
func kept(_ r: [SessionRecord], snapshot: GhosttyTTYSnapshot? = snap,
          tty: @escaping (Int32) -> String? = ttyByPid,
          underGhostty: @escaping (Int32) -> Bool = ghostty) -> [String] {
    dropOrphans(r, snapshot: snapshot, tty: tty, underGhostty: underGhostty).map(\.sessionId)
}
check(kept([orec("open", pid: 1), orec("closed", pid: 2)]) == ["open"],
      "session on a tty no Ghostty terminal has is dropped")
check(kept([orec("closed", pid: 2)], snapshot: nil) == ["closed"],
      "no snapshot (Ghostty without tty support) keeps every session")
check(kept([orec("new", pid: 2, start: 600)]) == ["new"],
      "process started after the snapshot is kept until the next snapshot")
check(kept([orec("old", pid: 2, start: nil)]) == ["old"],
      "record without pidStart is kept")
check(kept([orec("vscode", pid: 2)], underGhostty: { _ in false }) == ["vscode"],
      "session outside Ghostty is kept")
check(kept([orec("unknown", pid: 2)], tty: { _ in nil }) == ["unknown"],
      "unreadable tty is kept")
check(kept([orec("closed", pid: 2)], snapshot: GhosttyTTYSnapshot(ttys: [], takenAt: 500)) == [],
      "Ghostty with no terminals open drops its sessions")

print("daemon pty (Claude Code 2.1.306):")
// Window `claude` 100 on ttys001 spawns `claude daemon run` 200 (no tty), which spawns
// `claude bg-pty-host` 300 (no tty), which spawns `claude bg-spare` 400 on ttys002, a pty the
// daemon made. The hooks run in 400. A closed-tab orphan 500 sits on ttys005 under zsh 501.
let chainParent: [Int32: Int32] = [400: 300, 300: 200, 200: 100, 100: 50, 50: 1, 500: 501, 501: 1]
let chainTTY: [Int32: String] = [400: "/dev/ttys002", 100: "/dev/ttys001", 50: "/dev/ttys001",
                                 500: "/dev/ttys005", 501: "/dev/ttys005"]
let parentOf: (Int32) -> Int32? = { chainParent[$0] }
let ttyOf: (Int32) -> String? = { chainTTY[$0] }
func keptChain(_ r: [SessionRecord], snapshot: GhosttyTTYSnapshot? = snap,
               tty: @escaping (Int32) -> String? = ttyOf,
               underGhostty: @escaping (Int32) -> Bool = ghostty) -> [String] {
    dropOrphans(r, snapshot: snapshot, tty: tty, parent: parentOf, underGhostty: underGhostty)
        .map(\.sessionId)
}
check(terminalTTY(of: 400, snapshot: snap, tty: ttyOf, parent: parentOf) == "/dev/ttys001",
      "terminal tty resolves through the daemon chain to the window's tty")
check(terminalTTY(of: 500, snapshot: snap, tty: ttyOf, parent: parentOf) == nil,
      "chain with no open Ghostty tty resolves to nil")
check(terminalTTY(of: 400, snapshot: snap, tty: ttyOf, parent: { _ in 400 }, maxHops: 3) == nil,
      "hop cap stops a parent cycle")
check(keptChain([orec("spare", pid: 400), orec("closed", pid: 500)]) == ["spare"],
      "session on a daemon pty whose ancestor sits on an open Ghostty tty is kept, orphan dropped")
check(keptChain([orec("closed", pid: 500)], snapshot: nil) == ["closed"],
      "no snapshot keeps every session")
check(keptChain([orec("new", pid: 500, start: 600)]) == ["new"],
      "process started after the snapshot is kept")
check(keptChain([orec("old", pid: 500, start: nil)]) == ["old"],
      "record without pidStart is kept")
check(keptChain([orec("vscode", pid: 500)], underGhostty: { _ in false }) == ["vscode"],
      "session outside Ghostty is kept")
check(keptChain([orec("unknown", pid: 300)]) == ["unknown"],
      "own tty unreadable with no ancestor tty is kept")

print("one record per terminal:")
func trec(_ id: String, _ status: Status, pid: Int32, ageSeconds: Double) -> SessionRecord {
    SessionRecord(sessionId: id, status: status, pid: pid, pidStart: 100,
                  updatedAt: now - ageSeconds, cwd: nil)
}
func collapsed(_ r: [SessionRecord], snapshot: GhosttyTTYSnapshot? = snap,
               underGhostty: @escaping (Int32) -> Bool = ghostty) -> [SessionRecord] {
    collapseSameTerminal(r, snapshot: snapshot, tty: ttyOf, parent: parentOf, underGhostty: underGhostty)
}
// The exact bug: the window process 100 keeps its pre-restart record stuck on working, while
// the hooks now report under the spare 400 on the same terminal.
let stale = trec("stale", .working, pid: 100, ageSeconds: 600)
let fresh = trec("fresh", .yourTurn, pid: 400, ageSeconds: 5)
check(collapsed([stale, fresh]).map(\.sessionId) == ["fresh"],
      "two records on the same terminal keep only the newer updatedAt")
check(collapsed([fresh, stale]).map(\.sessionId) == ["fresh"],
      "newest wins whatever the input order")
check(aggregate(collapsed([stale, fresh]), now: now, alive: allAlive, startTime: { _ in nil }) == .yourTurn,
      "stale working record no longer hides your-turn on the same terminal")
let other = trec("other", .idle, pid: 500, ageSeconds: 1)
let wide = GhosttyTTYSnapshot(ttys: ["/dev/ttys001", "/dev/ttys005"], takenAt: 500)
check(collapsed([fresh, other], snapshot: wide).map(\.sessionId) == ["fresh", "other"],
      "records on different terminals both survive")
check(collapsed([fresh, other]).map(\.sessionId) == ["fresh", "other"],
      "record with no resolvable terminal passes through")
check(collapsed([stale, fresh], snapshot: nil).map(\.sessionId) == ["stale", "fresh"],
      "no snapshot collapses nothing")
check(collapsed([stale, fresh], underGhostty: { _ in false }).map(\.sessionId) == ["stale", "fresh"],
      "sessions outside Ghostty are not collapsed")
let noPid = SessionRecord(sessionId: "nopid", status: .yourTurn, pid: nil, updatedAt: now, cwd: nil)
check(collapsed([stale, noPid]).map(\.sessionId) == ["stale", "nopid"],
      "record without a pid passes through")

print("auto-resume:")
check(willAutoResume(hookJSON: ["background_tasks": [["id": "x", "status": "running"]]]),
      "running background task => session resumes on its own")
check(willAutoResume(hookJSON: ["background_tasks": [["id": "x"]]]),
      "task with no status assumed running")
check(!willAutoResume(hookJSON: ["background_tasks": [["id": "x", "status": "completed"]]]),
      "completed background task does not hold green")
check(willAutoResume(hookJSON: ["session_crons": [["id": "c"]]]),
      "scheduled wakeup => session resumes on its own")
check(!willAutoResume(hookJSON: ["background_tasks": [], "session_crons": []]),
      "empty arrays => your turn")
check(!willAutoResume(hookJSON: ["session_id": "s"]),
      "payload without the arrays (older CLI) => your turn")

print("long-lived background tasks:")
let devServer: [String: Any] = [
    "id": "b1", "type": "shell", "status": "running",
    "description": "Restart the dev server on port 3009 in the background",
    "command": "PID=$(lsof -nP -tiTCP:3009 -sTCP:LISTEN | head -1); [ -n \"$PID\" ] && kill \"$PID\"; sleep 2; exec node_modules/.bin/next dev -p 3009",
]
let ciWatch: [String: Any] = [
    "id": "b2", "type": "shell", "status": "running",
    "description": "Wait for CI on the PR",
    "command": "gh pr checks 2448 --watch",
]
let subagent: [String: Any] = ["id": "b3", "type": "subagent", "status": "running", "agent_type": "Explore"]
check(!willAutoResume(hookJSON: ["background_tasks": [devServer]]),
      "a dev server never exits, so it does not hold green")
check(willAutoResume(hookJSON: ["background_tasks": [ciWatch]]),
      "a CI watch finishes, so it holds green")
check(willAutoResume(hookJSON: ["background_tasks": [devServer, ciWatch]]),
      "a CI watch next to a dev server still holds green")
check(willAutoResume(hookJSON: ["background_tasks": [subagent]]),
      "a subagent has no command and holds green")
check(willAutoResume(hookJSON: ["background_tasks": [["id": "b4", "type": "shell", "status": "running"]]]),
      "a shell task without a command keeps the benefit of the doubt")
for cmd in [
    "yarn dev", "npm run dev", "pnpm start", "bun run serve", "yarn storybook",
    "./node_modules/.bin/vite", "vite dev --port 5173", "nodemon server.js",
    "python manage.py runserver 0.0.0.0:8000", "docker compose up web", "docker-compose up",
    "python3 -m http.server 8080", "tail -f /var/log/syslog", "tail -n0 -F app.log",
    "yarn vitest --watch", "npx tsc --watch", "tsc -w -p .",
] {
    check(isLongLived(command: cmd), "long-lived: \(cmd)")
}
for cmd in [
    "gh pr checks 2448 --watch", "scripts/ci_state.sh ForaTravel/fora-tools 2448 --wait",
    "yarn build", "vite build", "vite preview", "docker compose up -d web", "yarn test",
    "npx vitest run src/app", "tail -n 20 app.log", "npm run dev:build", "git push",
    "sleep 600 && echo done", "nextcloud dev", "yarn start-release-notes",
] {
    check(!isLongLived(command: cmd), "finishes: \(cmd)")
}

print("session title:")
let fm = FileManager.default
let titleRoot = fm.temporaryDirectory
    .appendingPathComponent("ctl-title-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
let projDir = titleRoot.appendingPathComponent("-Users-me-project", isDirectory: true)
try? fm.createDirectory(at: projDir, withIntermediateDirectories: true)

let titleSid = "11111111-2222-3333-4444-555555555555"
let transcript = """
{"type":"mode","sessionId":"\(titleSid)"}
{"type":"ai-title","aiTitle":"First title","sessionId":"\(titleSid)"}
{"type":"user"}
{"type":"ai-title","aiTitle":"Latest title","sessionId":"\(titleSid)"}
"""
try? transcript.write(to: projDir.appendingPathComponent("\(titleSid).jsonl"),
                      atomically: true, encoding: .utf8)

check(SessionTitle.read(sessionId: titleSid, projectsDir: titleRoot) == "Latest title",
      "reads the last ai-title in the transcript")
check(SessionTitle.read(sessionId: "no-such-id", projectsDir: titleRoot) == nil,
      "missing transcript => nil")
// Escape attempt: `..` resolves back to the real file on disk; sanitizing the id blocks it.
check(SessionTitle.read(sessionId: "../-Users-me-project/\(titleSid)", projectsDir: titleRoot) == nil,
      "path-separator id cannot escape the projects dir")

let noTitleSid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
try? "{\"type\":\"user\"}".write(to: projDir.appendingPathComponent("\(noTitleSid).jsonl"),
                                 atomically: true, encoding: .utf8)
check(SessionTitle.read(sessionId: noTitleSid, projectsDir: titleRoot) == nil,
      "transcript without an ai-title => nil")

let desktopOrg = titleRoot.appendingPathComponent("desktop/acct/org", isDirectory: true)
try? fm.createDirectory(at: desktopOrg, withIntermediateDirectories: true)
try? "{\"sessionId\":\"local_abc\",\"title\":\"06 [blocked] Sidebar title\"}"
    .write(to: desktopOrg.appendingPathComponent("local_abc.json"), atomically: true, encoding: .utf8)
let desktopRoot = titleRoot.appendingPathComponent("desktop", isDirectory: true)
check(SessionTitle.readDesktop(hostSessionId: "local_abc", desktopDir: desktopRoot) == "06 [blocked] Sidebar title",
      "reads the desktop app's sidebar title")
check(SessionTitle.readDesktop(hostSessionId: "local_missing", desktopDir: desktopRoot) == nil,
      "missing desktop metadata => nil")
check(SessionTitle.readDesktop(hostSessionId: "../acct/org/local_abc", desktopDir: desktopRoot) == nil,
      "path-separator host id cannot escape the desktop dir")

try? fm.removeItem(at: titleRoot)

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
