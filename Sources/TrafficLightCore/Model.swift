import Foundation

/// The status of a single Claude Code session. See CONTEXT.md for definitions.
public enum Status: String, Codable, Sendable, CaseIterable {
    case blocked            // 🔴 waiting on a permission prompt (urgent)
    case yourTurn = "your-turn"  // 🟡 finished, awaiting the user's next message
    case working            // 🟢 actively running
    case idle               // dim: freshly started / dormant

    /// Worst-wins ordering for aggregation: higher priority wins the Light.
    public var priority: Int {
        switch self {
        case .blocked: return 3
        case .yourTurn: return 2
        case .working: return 1
        case .idle: return 0
        }
    }
}

/// One session's status as written by the Reporter to
/// ~/.claude-traffic-light/sessions/<session_id>.json
public struct SessionRecord: Codable, Sendable {
    public var sessionId: String
    public var status: Status
    /// PID of the owning Claude process, if it could be resolved. nil → prune by TTL.
    public var pid: Int32?
    /// Start time (Unix epoch seconds) of the pid at record time, fingerprinting the exact
    /// process. On liveness check it must still match, so a recycled pid reads as dead.
    /// nil on older records (falls back to liveness-only, the pre-fingerprint behaviour).
    public var pidStart: Double?
    /// Unix epoch seconds of the last update.
    public var updatedAt: Double
    public var cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status
        case pid
        case pidStart = "pid_start"
        case updatedAt = "updated_at"
        case cwd
    }

    public init(sessionId: String, status: Status, pid: Int32?, pidStart: Double? = nil,
                updatedAt: Double, cwd: String?) {
        self.sessionId = sessionId
        self.status = status
        self.pid = pid
        self.pidStart = pidStart
        self.updatedAt = updatedAt
        self.cwd = cwd
    }
}
