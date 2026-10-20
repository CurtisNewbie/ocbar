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
    private var previousDir: [String: String] = [:]
    private var attachedDirs: Set<String> = []
    private var dirToPID: [String: Int32] = [:]
    private var sessionIDToPID: [String: Int32] = [:]
    private var scanTimer: Timer?
    private var pollTimer: Timer?
    private let onStateChange: (AppState) -> Void
    var onTransition: ((SessionStatus, String, Int32?) -> Void)?
    var onDismiss: ((String) -> Void)?

    /// A root session is shown while its work is active/waiting, or if it has
    /// been viewed and the later of its last view and last activity is newer
    /// than this window.
    private static let recentWindow: TimeInterval = 900

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
            dirToPID = [:]
            sessionIDToPID = [:]
            await poll()
            return
        }
        service = endpoint
        let pid = endpoint.pid
        let clients = await Task.detached {
            SessionMonitor.attachedClients(servicePID: pid)
        }.value
        attachedDirs = Set(clients.dirToPID.keys)
        dirToPID = clients.dirToPID
        sessionIDToPID = clients.sessionIDToPID
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

            // An unviewed session is only shown while its work is active/waiting.
            let viewed = (time["viewed"] as? NSNumber)?.doubleValue

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
            let lastSeen = max(viewed ?? 0, updated)
            let recentlySeen = now - lastSeen <= Self.recentWindow * 1000
            guard isWaiting || isBusy || ((viewed ?? 0) > 0 && recentlySeen) else { continue }

            let dir = (s["location"] as? [String: Any])?["directory"] as? String ?? ""
            let canonical = Self.canonicalPath(dir)
            guard sessionIDToPID[id] != nil || attachedDirs.contains(canonical) else { continue }
            let pid = sessionIDToPID[id] ?? dirToPID[canonical]
            sessions.append(SessionInfo(id: id, status: status, projectDir: dir, clientPID: pid, sessionTitle: s["title"] as? String, updatedAt: updated))
        }

        // A revert/fork leaves the original session behind as a separate root.
        // Hide a root while a visible session was forked from it, so one
        // project does not show two identical rows.
        let visibleIDs = Set(sessions.map(\.id))
        let supersededIDs = Set(sessionList.compactMap { s -> String? in
            guard let id = s["id"] as? String,
                  visibleIDs.contains(id),
                  let source = (s["fork"] as? [String: Any])?["sessionID"] as? String else { return nil }
            return source
        })
        if !supersededIDs.isEmpty {
            sessions.removeAll { supersededIDs.contains($0.id) }
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
            if let dir = previousDir.removeValue(forKey: id) {
                onDismiss?(dir)
            }
            previousStatus.removeValue(forKey: id)
        }

        for session in sessions {
            let prev = previousStatus[session.id] ?? .idle
            if (prev == .waiting && session.status != .waiting) || (prev == .idle && session.status == .busy) {
                onDismiss?(session.projectDir)
            }
            if prev != .waiting && session.status == .waiting {
                sendWaitingNotification(projectDir: session.projectDir)
                onTransition?(.waiting, session.projectDir, session.clientPID)
            }
            if prev == .busy && session.status == .idle {
                sendIdleNotification(projectDir: session.projectDir)
                onTransition?(.idle, session.projectDir, session.clientPID)
            }
            previousStatus[session.id] = session.status
            previousDir[session.id] = session.projectDir
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
    /// `opencode serve --service` process. Returns canonicalized dir -> client pid
    /// (first pid wins per dir) plus an exact session id -> client pid binding
    /// parsed from the client's argv (`--session <id>` / `-s <id>`). The dir map
    /// drives visibility; the session map lets a bubble click focus the exact pane.
    private nonisolated static func attachedClients(servicePID: Int32) -> (dirToPID: [String: Int32], sessionIDToPID: [String: Int32]) {
        var dirToPID: [String: Int32] = [:]
        var sessionIDToPID: [String: Int32] = [:]

        var argvByPID: [Int32: String] = [:]
        let argsOutput = runShell("ps -Ao pid=,args= -ww")
        for line in argsOutput.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int32(cols[0]) else { continue }
            argvByPID[pid] = String(cols[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let output = runShell("ps -Ao pid=,comm=")
        for line in output.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int32(cols[0]) else { continue }
            let comm = String(cols[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (comm as NSString).lastPathComponent == "opencode" else { continue }
            guard pid != servicePID else { continue }

            let dir = cwd(pid: pid)
            if !dir.isEmpty {
                let canonical = canonicalPath(dir)
                if dirToPID[canonical] == nil {
                    dirToPID[canonical] = pid
                }
            }

            if let argv = argvByPID[pid],
               let sessionID = sessionID(fromArgv: argv),
               sessionIDToPID[sessionID] == nil {
                sessionIDToPID[sessionID] = pid
            }
        }
        return (dirToPID, sessionIDToPID)
    }

    /// Extract the session id passed on the command line, accepting
    /// `--session <id>`, `-s <id>`, `--session=<id>` and `-s=<id>`.
    private nonisolated static func sessionID(fromArgv argv: String) -> String? {
        let tokens = argv.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        var i = 0
        while i < tokens.count {
            let token = String(tokens[i])
            if token == "--session" || token == "-s" {
                if i + 1 < tokens.count {
                    let id = String(tokens[i + 1])
                    if id.hasPrefix("ses") { return id }
                }
            } else if token.hasPrefix("--session=") {
                let id = String(token.dropFirst("--session=".count))
                if id.hasPrefix("ses") { return id }
            } else if token.hasPrefix("-s=") {
                let id = String(token.dropFirst("-s=".count))
                if id.hasPrefix("ses") { return id }
            }
            i += 1
        }
        return nil
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

    /// Focus the tmux pane hosting the OpenCode client `pid` in Ghostty.
    /// Runs off the main thread since it spawns processes + `osascript`.
    func focusSession(pid: Int32?) {
        let pidArg = pid.map(String.init) ?? ""
        Task.detached {
            _ = SessionMonitor.runShell(SessionMonitor.focusCommand(pid: pidArg))
        }
    }

    private nonisolated static func focusCommand(pid: String) -> String {
        // `tmux` lives in Homebrew paths that a GUI app's PATH doesn't include.
        // The `osascript` call triggers a one-time macOS Automation permission
        // prompt ("ocbar wants to control Ghostty"); denying it falls back to
        // plain `open -a Ghostty`.
        """
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        PID='\(pid)'
        if [ -z "$PID" ] || ! command -v tmux >/dev/null 2>&1; then open -a Ghostty; exit 0; fi
        PT=$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')
        if [ -z "$PT" ]; then open -a Ghostty; exit 0; fi
        ROW=$(tmux list-panes -a -F '#{pane_tty} #{pane_id} #{session_name}' 2>/dev/null | awk -v t="/dev/$PT" '$1==t{print $2" "$3; exit}')
        if [ -z "$ROW" ]; then open -a Ghostty; exit 0; fi
        PANE_ID=${ROW%% *}; SESS=${ROW#* }
        CLIENT=$(tmux list-clients -F '#{client_tty} #{client_session}' 2>/dev/null | awk -v s="$SESS" '$2==s{print $1; exit}')
        if [ -n "$CLIENT" ]; then tmux switch-client -c "$CLIENT" -t "$PANE_ID" 2>/dev/null || true; fi
        if [ -n "$CLIENT" ]; then
          osascript -e "tell application \\"Ghostty\\" to focus (first terminal whose tty is \\"$CLIENT\\")" 2>/dev/null || open -a Ghostty
        else
          open -a Ghostty
        fi
        """
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