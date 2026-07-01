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

func rec(_ status: Status, pid: Int32? = nil, ageSeconds: Double = 0) -> SessionRecord {
    SessionRecord(sessionId: UUID().uuidString, status: status, pid: pid,
                  updatedAt: now - ageSeconds, cwd: nil)
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

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
