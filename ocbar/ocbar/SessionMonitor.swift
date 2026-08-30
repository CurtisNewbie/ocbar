import Foundation
import UserNotifications

@MainActor
class SessionMonitor {
    private(set) var state = AppState()
    private var knownServers: [Int: (dir: String, pid: Int32)] = [:]
    private var previousServerStatus: [Int: SessionStatus] = [:]
    private var scanTimer: Timer?
    private var pollTimer: Timer?
    private let onStateChange: (AppState) -> Void
    var onTransition: ((SessionStatus, String) -> Void)?

    init(onStateChange: @escaping (AppState) -> Void) {
        self.onStateChange = onStateChange
    }

    func start() {
        Task { await scan() }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.scan() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.poll() }
        }
    }

    private func scan() async {
        let scanner = ProcessScanner()
        let discovered = await Task.detached { scanner.scan() }.value
        let discoveredPorts = Set(discovered.map(\.port))

        for port in Set(knownServers.keys).subtracting(discoveredPorts) {
            knownServers.removeValue(forKey: port)
            previousServerStatus.removeValue(forKey: port)
        }

        for server in discovered where knownServers[server.port] == nil {
            guard await isOpenCode(port: server.port) else { continue }
            var dir = await projectPath(port: server.port)
            if dir.isEmpty || dir == "/" {
                dir = await Task.detached { ProcessScanner.cwd(pid: server.pid) }.value
            }
            knownServers[server.port] = (dir: dir, pid: server.pid)
            previousServerStatus[server.port] = .idle
        }

        await poll()
    }

    private func poll() async {
        guard !knownServers.isEmpty else {
            state.sessions = []
            onStateChange(state)
            return
        }

        var sessions: [SessionInfo] = []
        for (port, info) in knownServers {
            let busySessions = await sessionStatus(port: port)
            let pendingQuestions = await pendingQuestions(port: port)
            let status: SessionStatus = pendingQuestions > 0 ? .waiting : (busySessions.isEmpty ? .idle : .busy)

            let prev = previousServerStatus[port]
            if prev != .waiting && status == .waiting {
                sendWaitingNotification(projectDir: info.dir)
                onTransition?(.waiting, info.dir)
            }
            if prev == .busy && status == .idle {
                sendIdleNotification(projectDir: info.dir)
                onTransition?(.idle, info.dir)
            }
            previousServerStatus[port] = status

            sessions.append(SessionInfo(id: "\(port)", status: status, port: port, projectDir: info.dir))
        }

        state.sessions = sessions
        onStateChange(state)
    }

    private func isOpenCode(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/global/health"),
              let (_, resp) = try? await URLSession.shared.data(from: url) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func projectPath(port: Int) async -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/project/current"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["worktree"] as? String else { return "" }
        return path
    }

    private func sessionStatus(port: Int) async -> [String: SessionStatus] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/session/status"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return [:] }
        return raw.compactMapValues { SessionStatus(rawValue: $0["type"] ?? "") }
    }

    private func pendingQuestions(port: Int) async -> Int {
        guard let url = URL(string: "http://127.0.0.1:\(port)/question"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return raw.count
    }

    private func sendIdleNotification(projectDir: String) {
        let name = displayName(for: projectDir)
        let content = UNMutableNotificationContent()
        content.title = "Session ready"
        content.body = "\(name) is waiting for input"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func sendWaitingNotification(projectDir: String) {
        let name = displayName(for: projectDir)
        let content = UNMutableNotificationContent()
        content.title = "Question pending"
        content.body = "\(name) is waiting for you to answer a question"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func displayName(for dir: String) -> String {
        guard !dir.isEmpty && dir != "/" else { return "OpenCode" }
        return URL(fileURLWithPath: dir).lastPathComponent
    }
}
