import Foundation

enum SessionStatus: String {
    case idle, busy, waiting, error
}

/// Context-window usage for a session, derived from its most recent completed
/// assistant turn and the model's usable ceiling. `limit` is nil when the
/// model's limit info is unknown; `fraction` is nil when `limit` is nil/0.
struct SessionContext: Equatable {
    var used: Int
    var limit: Int?
    var fraction: Double?
}

struct SessionInfo: Equatable {
    let id: String
    var status: SessionStatus
    var projectDir: String
    var clientPID: Int32? = nil
    /// Optional display title from the session JSON `title` field.
    var sessionTitle: String? = nil
    /// Session creation timestamp in milliseconds (session JSON `time.created`).
    var createdAt: TimeInterval = 0
    /// Context-window usage, present only when the feature is enabled and known.
    var context: SessionContext? = nil
}

func formatDurationLabel(sinceMS: TimeInterval, nowMS: TimeInterval) -> String {
    guard sinceMS > 0 else { return "" }
    let minutes = max(0, Int((nowMS - sinceMS) / 60_000))
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
    return "\(m)m"
}

enum AggregateStatus {
    case none, busy, idle, error
}

struct AppState {
    var sessions: [SessionInfo] = []

    var aggregate: AggregateStatus {
        if sessions.isEmpty { return .none }
        if sessions.contains(where: { $0.status == .error }) { return .error }
        if sessions.contains(where: { $0.status == .idle }) { return .idle }
        return .busy
    }
}

struct SSEEvent {
    let type: String
    let data: String
}
