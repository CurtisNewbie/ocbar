import Foundation

enum SessionStatus: String {
    case idle, busy, error
}

struct SessionInfo {
    let id: String
    var status: SessionStatus
    let port: Int
    var projectDir: String
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
