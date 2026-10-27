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
    private var sessionIDToPID: [String: Int32] = [:]
    /// Per-model usable context ceiling, keyed by "providerID/id". A missing key
    /// means the model's limit info is unknown (=> nil display limit).
    private var modelUsable: [String: Int] = [:]
    private var modelUsableFetchedAt: Date?
    private let modelUsableTTL: TimeInterval = 300
    /// Last computed context usage per session, with the fetch time, so the
    /// 0.5s poll does not re-fetch each time.
    private var contextCache: [String: (ctx: SessionContext, fetchedAt: Date)] = [:]
    private let contextRefreshInterval: TimeInterval = 2
    private var scanTimer: Timer?
    private var pollTimer: Timer?
    private let onStateChange: (AppState) -> Void
    var onTransition: ((SessionStatus, String, Int32?, String?) -> Void)?
    var onDismiss: ((String) -> Void)?

    /// A root session is shown while its work is active/waiting, or if it has
    /// been viewed and the later of its last view and last activity is newer
    /// than this window. 12h: a session parked overnight should still be in the
    /// island when the user comes back to it.
    private static let recentWindow: TimeInterval = 43200

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
            sessionIDToPID = [:]
            await poll()
            return
        }
        service = endpoint
        let pid = endpoint.pid
        let clients = await Task.detached {
            SessionMonitor.attachedClients(servicePID: pid)
        }.value
        sessionIDToPID = clients
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
            let created = (time["created"] as? NSNumber)?.doubleValue ?? 0
            let lastSeen = max(viewed ?? 0, updated)
            let recentlySeen = now - lastSeen <= Self.recentWindow * 1000
            guard isWaiting || isBusy || ((viewed ?? 0) > 0 && recentlySeen) else { continue }

            guard let pid = sessionIDToPID[id] else { continue }
            let dir = (s["location"] as? [String: Any])?["directory"] as? String ?? ""
            sessions.append(SessionInfo(id: id, status: status, projectDir: dir, clientPID: pid, sessionTitle: s["title"] as? String, createdAt: created))
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

        await fillContext(for: &sessions, endpoint: endpoint)

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

    // MARK: - Context-window usage

    /// Feature gate; default off. Reads `UserDefaults` directly so it reflects
    /// toggles without an app restart.
    private var contextUsageEnabled: Bool {
        (UserDefaults.standard.object(forKey: "ocbar.contextUsage") as? Bool) ?? false
    }

    /// Fill each visible session's `context` before publishing. Only runs when
    /// enabled; the `/api/model` map is TTL-cached and each session is refreshed
    /// at most every `contextRefreshInterval` seconds.
    private func fillContext(for sessions: inout [SessionInfo], endpoint: ServiceEndpoint) async {
        guard contextUsageEnabled, !sessions.isEmpty else {
            contextCache.removeAll()
            return
        }

        let usableByKey = await modelUsableMap(endpoint: endpoint)
        let now = Date()

        for i in sessions.indices {
            let id = sessions[i].id
            if let cached = contextCache[id], now.timeIntervalSince(cached.fetchedAt) < contextRefreshInterval {
                sessions[i].context = cached.ctx
            } else if let ctx = await fetchContext(endpoint: endpoint, sessionID: id, usableByKey: usableByKey) {
                contextCache[id] = (ctx, now)
                sessions[i].context = ctx
            } else {
                // Unknown this round: keep the last known value (or nil).
                sessions[i].context = contextCache[id]?.ctx
            }
        }

        // Drop cache entries for sessions that are no longer visible.
        let visible = Set(sessions.map(\.id))
        contextCache = contextCache.filter { visible.contains($0.key) }
    }

    /// Usable context ceiling per model key ("providerID/id"), TTL-cached.
    /// A missing key means the model's limit info is unknown.
    private func modelUsableMap(endpoint: ServiceEndpoint) async -> [String: Int] {
        if let fetched = modelUsableFetchedAt, Date().timeIntervalSince(fetched) < modelUsableTTL {
            return modelUsable
        }
        guard let json = await getJSON(endpoint: endpoint, path: "api/model") as? [String: Any],
              let data = json["data"] as? [[String: Any]] else {
            // Keep the last known map on failure; don't stamp the TTL.
            return modelUsable
        }
        var map: [String: Int] = [:]
        for m in data {
            guard let providerID = m["providerID"] as? String,
                  let id = m["id"] as? String else { continue }
            let limit = m["limit"] as? [String: Any]
            let usable = Self.usableCeiling(
                context: (limit?["context"] as? NSNumber)?.intValue,
                input: (limit?["input"] as? NSNumber)?.intValue,
                output: (limit?["output"] as? NSNumber)?.intValue)
            if let usable { map["\(providerID)/\(id)"] = usable }
        }
        modelUsable = map
        modelUsableFetchedAt = Date()
        return map
    }

    /// Usable context ceiling, mirroring opencode's
    /// `packages/opencode/src/session/overflow.ts`:
    ///   mx = min(output ?? 32000, 32000); reserved = min(20000, mx)
    ///   usable = (input != nil) ? max(0, input - reserved) : max(0, context - mx)
    private static func usableCeiling(context: Int?, input: Int?, output: Int?) -> Int? {
        if input == nil && context == nil { return nil }
        let outputTokenMax = 32000
        let mx = min(output ?? outputTokenMax, outputTokenMax)
        let reserved = min(20000, mx)
        if let input { return max(0, input - reserved) }
        return max(0, (context ?? 0) - mx)
    }

    /// Fetch one session's context usage from its newest completed assistant
    /// turn. Returns nil when unknown (no completed turn / no tokens / error).
    private func fetchContext(endpoint: ServiceEndpoint, sessionID: String, usableByKey: [String: Int]) async -> SessionContext? {
        guard let json = await getJSON(
                endpoint: endpoint,
                path: "api/session/\(sessionID)/message",
                query: [URLQueryItem(name: "limit", value: "10")]
              ) as? [String: Any],
              let messages = json["data"] as? [[String: Any]] else { return nil }

        // Newest-first; the first completed assistant turn carries `tokens`.
        guard let assistant = messages.first(where: {
                ($0["type"] as? String) == "assistant" && $0["tokens"] != nil
              }),
              let tokens = assistant["tokens"] as? [String: Any] else { return nil }

        let cache = tokens["cache"] as? [String: Any]
        let used = ((tokens["input"] as? NSNumber)?.intValue ?? 0)
            + ((tokens["output"] as? NSNumber)?.intValue ?? 0)
            + ((cache?["read"] as? NSNumber)?.intValue ?? 0)
            + ((cache?["write"] as? NSNumber)?.intValue ?? 0)

        var limit: Int?
        if let model = assistant["model"] as? [String: Any],
           let providerID = model["providerID"] as? String,
           let modelID = model["id"] as? String {
            limit = usableByKey["\(providerID)/\(modelID)"]
        }

        let fraction: Double? = {
            guard let limit, limit > 0 else { return nil }
            return Double(used) / Double(limit)
        }()

        return SessionContext(used: used, limit: limit, fraction: fraction)
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
                onTransition?(.waiting, session.projectDir, session.clientPID, session.sessionTitle)
            }
            if prev == .busy && session.status == .idle {
                sendIdleNotification(projectDir: session.projectDir)
                onTransition?(.idle, session.projectDir, session.clientPID, session.sessionTitle)
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

    /// Map each running `opencode` client (excluding the shared
    /// `opencode serve --service` process) to the exact session it is driving,
    /// i.e. session id -> client pid. The first pid wins per session id.
    ///
    /// The authoritative source is the binding file a Web/TUI plugin publishes
    /// per client at `~/.local/state/ocbar/bindings/<pid>.json`, which reflects
    /// the client's *live* route (`/clear`, `/new`, session tabs, … all change
    /// it without touching argv). The launch-time argv id (`--session <id>` /
    /// `-s <id>`) is only a fallback for clients with no fresh binding file.
    private nonisolated static func attachedClients(servicePID: Int32) -> [String: Int32] {
        var sessionIDToPID: [String: Int32] = [:]

        var argvByPID: [Int32: String] = [:]
        let argsOutput = runShell("ps -Ao pid=,args= -ww")
        for line in argsOutput.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int32(cols[0]) else { continue }
            argvByPID[pid] = String(cols[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let published = publishedBindings()

        var clientPIDs: [Int32] = []
        let output = runShell("ps -Ao pid=,comm=")
        for line in output.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int32(cols[0]) else { continue }
            let comm = String(cols[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (comm as NSString).lastPathComponent == "opencode" else { continue }
            guard pid != servicePID else { continue }
            clientPIDs.append(pid)
        }

        for pid in clientPIDs.sorted() {
            // A fresh published binding is authoritative for this client.
            if let binding = published[pid] {
                if let sessionID = binding, sessionIDToPID[sessionID] == nil {
                    sessionIDToPID[sessionID] = pid
                }
                // A `nil` binding means the client has no current session; do
                // not fall back to the stale argv id in that case.
                continue
            }

            // No fresh binding file: fall back to the launch-time argv id.
            if let argv = argvByPID[pid],
               let sessionID = sessionID(fromArgv: argv),
               sessionIDToPID[sessionID] == nil {
                sessionIDToPID[sessionID] = pid
            }
        }
        return sessionIDToPID
    }

    /// Read the per-client binding files published by the Web/TUI plugin under
    /// `~/.local/state/ocbar/bindings/<pid>.json`, each reporting the session
    /// that client is currently driving (live route). `sessionID: null` is
    /// meaningful: the client currently has no session.
    ///
    /// Missing/corrupt files are skipped silently. A file is ignored when its
    /// pid/`updatedAt` is missing, its `updatedAt` is stale (> 15s), or its
    /// `isRoot` is explicitly `false`. Returns `[pid: sessionID?]`.
    private nonisolated static func publishedBindings() -> [Int32: String?] {
        var bindings: [Int32: String?] = [:]
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/ocbar/bindings")
        guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return [:] }

        let nowMS = Date().timeIntervalSince1970 * 1000

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let pid: Int32?
            if let jsonPID = (json["pid"] as? NSNumber)?.int32Value {
                pid = jsonPID
            } else if let name = Int32(file.deletingPathExtension().lastPathComponent) {
                pid = name
            } else {
                pid = nil
            }
            guard let pid else { continue }

            guard let updatedAt = (json["updatedAt"] as? NSNumber)?.doubleValue else { continue }
            guard abs(nowMS - updatedAt) <= 15_000 else { continue }

            if let isRoot = json["isRoot"] as? Bool, isRoot == false { continue }

            bindings[pid] = json["sessionID"] as? String
        }
        return bindings
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