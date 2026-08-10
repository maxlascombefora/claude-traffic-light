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
    /// Unix epoch seconds of the last update — touched on *every* hook event, including repeat
    /// events that don't change Status (e.g. `PostToolUse` firing on each tool call while
    /// Working). Not usable as "how long has this Session been in its current Status" — see
    /// `changedAt`.
    public var updatedAt: Double
    public var cwd: String?
    /// Whether the owning process has a controlling terminal — i.e. is a real window rather
    /// than headless automation (`claude -p`). `false` is excluded from the Light. nil on
    /// older records or when no pid could be resolved (treated as interactive).
    public var interactive: Bool?
    /// Unix epoch seconds when `status` last actually changed (set by the Reporter, which reads
    /// the prior record and carries this forward when the new status matches). nil on older
    /// records written before this field existed. See ADR 0005 — this is what "oldest Session in
    /// this color" (click-to-focus) sorts by, since `updatedAt` can't answer that.
    public var changedAt: Double?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status
        case pid
        case pidStart = "pid_start"
        case updatedAt = "updated_at"
        case cwd
        case interactive
        case changedAt = "changed_at"
    }

    public init(sessionId: String, status: Status, pid: Int32?, pidStart: Double? = nil,
                updatedAt: Double, cwd: String?, interactive: Bool? = nil, changedAt: Double? = nil) {
        self.sessionId = sessionId
        self.status = status
        self.pid = pid
        self.pidStart = pidStart
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.interactive = interactive
        self.changedAt = changedAt
    }
}
