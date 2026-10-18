import Foundation

enum SessionStatus: String {
    case idle, busy, waiting, error
}

struct SessionInfo: Equatable {
    let id: String
    var status: SessionStatus
    var projectDir: String
    var clientPID: Int32? = nil
    var startedAt: TimeInterval = 0
    /// Number of root sessions collapsed into this row (same project directory).
    var sessionCount: Int = 1
    /// Start times of every root collapsed into this row (same directory),
    /// used to render each session's run time.
    var extraStartedAts: [TimeInterval] = []
}

func formatDurationLabel(startedAtMS: TimeInterval, nowMS: TimeInterval) -> String {
    guard startedAtMS > 0 else { return "" }
    let minutes = max(0, Int((nowMS - startedAtMS) / 60_000))
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
