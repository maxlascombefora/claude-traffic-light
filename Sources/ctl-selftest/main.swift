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

try? fm.removeItem(at: titleRoot)

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
