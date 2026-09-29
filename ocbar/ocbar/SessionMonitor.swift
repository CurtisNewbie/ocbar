import Foundation
import UserNotifications

private struct ServiceEndpoint {
    let url: URL
    let password: String
    let pid: Int32
}

@MainActor
class SessionMonitor {
    private(set) var state = AppState()
    private var service: ServiceEndpoint?
    private var previousStatus: [String: SessionStatus] = [:]
    private var attachedDirs: Set<String> = []
    private var scanTimer: Timer?
    private var pollTimer: Timer?
    private let onStateChange: (AppState) -> Void
    var onTransition: ((SessionStatus, String) -> Void)?

    /// A root session is shown while its work is active/waiting or its last
    /// update is newer than this window.
    private static let recentWindow: TimeInterval = 1800

    init(onStateChange: @escaping (AppState) -> Void) {
        self.onStateChange = onStateChange
    }

    func start() {
        Task { await scan() }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.scan() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.poll() }
        }
    }

    private func scan() async {
        guard let endpoint = readService(), await isReady(endpoint) else {
            service = nil
            attachedDirs = []
            await poll()
            return
        }
        service = endpoint
        let pid = endpoint.pid
        attachedDirs = await Task.detached {
            SessionMonitor.attachedDirectories(servicePID: pid)
        }.value
        await poll()
    }

    private func readService() -> ServiceEndpoint? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/opencode/service.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["url"] as? String,
              let password = json["password"] as? String,
              let pid = (json["pid"] as? NSNumber)?.int32Value,
              let url = URL(string: urlString) else { return nil }
        return ServiceEndpoint(url: url, password: password, pid: pid)
    }

    private func isReady(_ endpoint: ServiceEndpoint) async -> Bool {
        await getJSON(endpoint: endpoint, path: "api/info") != nil
    }

    private func poll() async {
        guard let endpoint = service else {
            publish(sessions: [])
            return
        }

        guard let sessionsJSON = await getJSON(
                endpoint: endpoint,
                path: "api/session",
                query: [URLQueryItem(name: "limit", value: "100"),
                        URLQueryItem(name: "order", value: "desc")]
              ) as? [String: Any],
              let sessionList = sessionsJSON["data"] as? [[String: Any]] else {
            publish(sessions: [])
            return
        }

        let active = await activeSessions(endpoint)
        let waiting = await waitingSessions(endpoint, sessionList: sessionList, active: active)

        var children: [String: [String]] = [:]
        for s in sessionList {
            guard let id = s["id"] as? String,
                  let parent = s["parentID"] as? String else { continue }
            children[parent, default: []].append(id)
        }

        let now = Date().timeIntervalSince1970 * 1000

        var sessions: [SessionInfo] = []
        for s in sessionList {
            guard let id = s["id"] as? String,
                  s["parentID"] == nil,
                  let time = s["time"] as? [String: Any],
                  time["archived"] == nil else { continue }

            let descendants = descendantIDs(of: id, children: children)
            let isWaiting = !descendants.isDisjoint(with: waiting)
            let isBusy = !descendants.isDisjoint(with: active)
            let outcome = s["outcome"] as? String

            let status: SessionStatus
            if isWaiting {
                status = .waiting
            } else if isBusy {
                status = .busy
            } else if outcome == "failed" {
                status = .error
            } else {
                status = .idle
            }

            let updated = (time["updated"] as? NSNumber)?.doubleValue ?? 0
            let recent = now - updated <= Self.recentWindow * 1000
            guard isWaiting || isBusy || recent else { continue }

            let dir = (s["location"] as? [String: Any])?["directory"] as? String ?? ""
            guard attachedDirs.contains(Self.canonicalPath(dir)) else { continue }
            sessions.append(SessionInfo(id: id, status: status, projectDir: dir))
        }

        publish(sessions: sessions)
    }

    private func descendantIDs(of root: String, children: [String: [String]]) -> Set<String> {
        var result: Set<String> = [root]
        var queue = [root]
        while let current = queue.popLast() {
            for child in children[current] ?? [] where !result.contains(child) {
                result.insert(child)
                queue.append(child)
            }
        }
        return result
    }

    private func activeSessions(_ endpoint: ServiceEndpoint) async -> Set<String> {
        guard let json = await getJSON(endpoint: endpoint, path: "api/session/active") as? [String: Any],
              let data = json["data"] as? [String: Any] else { return [] }
        return Set(data.keys)
    }

    private func waitingSessions(_ endpoint: ServiceEndpoint, sessionList: [[String: Any]], active: Set<String>) async -> Set<String> {
        let now = Date().timeIntervalSince1970 * 1000
        let previousWaiting = Set(previousStatus.compactMap { $0.value == .waiting ? $0.key : nil })

        var directories: Set<String> = []
        for s in sessionList {
            guard let id = s["id"] as? String,
                  let dir = (s["location"] as? [String: Any])?["directory"] as? String,
                  !dir.isEmpty else { continue }
            let updated = ((s["time"] as? [String: Any])?["updated"] as? NSNumber)?.doubleValue ?? 0
            let recent = now - updated <= Self.recentWindow * 1000
            if active.contains(id) || recent || previousWaiting.contains(id) {
                directories.insert(dir)
            }
        }

        guard !directories.isEmpty else { return [] }

        var waiting: Set<String> = []
        for dir in directories {
            let query = [URLQueryItem(name: "location[directory]", value: dir)]
            for path in ["api/form", "api/permission/request"] {
                guard let json = await getJSON(endpoint: endpoint, path: path, query: query) as? [String: Any],
                      let items = json["data"] as? [[String: Any]] else { continue }
                for item in items {
                    if let sessionID = item["sessionID"] as? String {
                        waiting.insert(sessionID)
                    }
                }
            }
        }
        return waiting
    }

    private func publish(sessions: [SessionInfo]) {
        let visibleIDs = Set(sessions.map(\.id))
        for id in Set(previousStatus.keys).subtracting(visibleIDs) {
            previousStatus.removeValue(forKey: id)
        }

        for session in sessions {
            let prev = previousStatus[session.id] ?? .idle
            if prev != .waiting && session.status == .waiting {
                sendWaitingNotification(projectDir: session.projectDir)
                onTransition?(.waiting, session.projectDir)
            }
            if prev == .busy && session.status == .idle {
                sendIdleNotification(projectDir: session.projectDir)
                onTransition?(.idle, session.projectDir)
            }
            previousStatus[session.id] = session.status
        }

        let sorted = sessions.sorted { lhs, rhs in
            let lr = attentionRank(lhs.status)
            let rr = attentionRank(rhs.status)
            if lr != rr { return lr < rr }
            let byName = projectName(for: lhs.projectDir).localizedStandardCompare(projectName(for: rhs.projectDir))
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }

        state.sessions = sorted
        onStateChange(state)
    }

    private func attentionRank(_ status: SessionStatus) -> Int {
        switch status {
        case .error: return 0
        case .waiting: return 1
        case .busy: return 2
        case .idle: return 3
        }
    }

    private func projectName(for dir: String) -> String {
        guard !dir.isEmpty && dir != "/" else { return "" }
        return URL(fileURLWithPath: dir).lastPathComponent
    }

    private func getJSON(endpoint: ServiceEndpoint, path: String, query: [URLQueryItem] = []) async -> Any? {
        var components = URLComponents(url: endpoint.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let token = Data("opencode:\(endpoint.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private nonisolated static func canonicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Directories with an attached `opencode` client, excluding the shared
    /// `opencode serve --service` process.
    private nonisolated static func attachedDirectories(servicePID: Int32) -> Set<String> {
        var dirs: Set<String> = []
        let output = runShell("ps -Ao pid=,comm=")
        for line in output.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int32(cols[0]) else { continue }
            let comm = String(cols[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (comm as NSString).lastPathComponent == "opencode" else { continue }
            guard pid != servicePID else { continue }
            let dir = cwd(pid: pid)
            guard !dir.isEmpty else { continue }
            dirs.insert(canonicalPath(dir))
        }
        return dirs
    }

    private nonisolated static func cwd(pid: Int32) -> String {
        let output = runShell("lsof -p \(pid) -a -d cwd -Fn 2>/dev/null")
        for line in output.components(separatedBy: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return ""
    }

    private nonisolated static func runShell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
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