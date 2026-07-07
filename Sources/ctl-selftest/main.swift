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
         interactive: Bool? = nil) -> SessionRecord {
    SessionRecord(sessionId: UUID().uuidString, status: status, pid: pid,
                  updatedAt: now - ageSeconds, cwd: nil, interactive: interactive)
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

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
