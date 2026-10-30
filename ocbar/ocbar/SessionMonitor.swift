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
    /// Client pid -> the tmux pane that client's terminal is showing, as the client's own binding
    /// published it. Only for the click path (`focusSession`), refreshed with the bindings every
    /// `scanTimer` tick; a pid missing here just takes the slower tty-based resolution.
    private var focusByPID: [Int32: TmuxPaneRef] = [:]
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
            // No service, no live clients: the pane hints go too, so a click never acts on a pid that
            // has since been reused.
            focusByPID = [:]
            await poll()
            return
        }
        service = endpoint
        let pid = endpoint.pid
        let clients = await Task.detached {
            SessionMonitor.attachedClients(servicePID: pid)
        }.value
        sessionIDToPID = clients.sessionIDToPID
        focusByPID = clients.focusByPID
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
            // The subagent tally: active descendants, minus the root — the root is in `active`
            // while it works on its own turn, which is not a subagent. Same two sets the
            // status above is derived from, so this costs no request.
            let runningSubagents = descendants.intersection(active).subtracting([id]).count
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
            sessions.append(SessionInfo(id: id, status: status, projectDir: dir, clientPID: pid,
                                        sessionTitle: s["title"] as? String,
                                        createdAt: created, updatedAt: updated,
                                        runningSubagents: runningSubagents))
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
    ///
    /// The same pass collects the **focus target** (client pid -> tmux pane) those bindings carry,
    /// so a click does not have to rediscover it; see `publishedBindings()` and `focusSession`.
    private nonisolated static func attachedClients(servicePID: Int32) -> ClientScan {
        var scan = ClientScan()

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
                if let sessionID = binding.sessionID, scan.sessionIDToPID[sessionID] == nil {
                    scan.sessionIDToPID[sessionID] = pid
                }
                // A `nil` binding means the client has no current session; do
                // not fall back to the stale argv id in that case.
                if let pane = binding.pane { scan.focusByPID[pid] = pane }
                continue
            }

            // No fresh binding file: fall back to the launch-time argv id.
            if let argv = argvByPID[pid],
               let sessionID = sessionID(fromArgv: argv),
               scan.sessionIDToPID[sessionID] == nil {
                scan.sessionIDToPID[sessionID] = pid
            }
        }
        return scan
    }

    /// One pass over the running clients: the session each one drives, and the tmux pane each one is
    /// in (where its binding reported one).
    private struct ClientScan {
        var sessionIDToPID: [String: Int32] = [:]
        var focusByPID: [Int32: TmuxPaneRef] = [:]
    }

    /// Read the per-client binding files published by the Web/TUI plugin under
    /// `~/.local/state/ocbar/bindings/<pid>.json`, each reporting the session
    /// that client is currently driving (live route). `sessionID: null` is
    /// meaningful: the client currently has no session.
    ///
    /// Missing/corrupt files are skipped silently. A file is ignored when its
    /// pid/`updatedAt` is missing, its `updatedAt` is stale (> 15s), or its
    /// `isRoot` is explicitly `false`. Returns `[pid: PublishedBinding]`.
    ///
    /// The same file carries the tmux pane the client runs in (`tmuxPane` / `tmuxSocket`, from the
    /// plugin's own `TMUX_PANE` / `TMUX`), which is what makes a row click one `tmux switch-client`
    /// instead of a `ps` + `list-panes` hunt — see `focusSession`. It can be trusted *because* it is
    /// published by the process in the pane and refreshed every 200ms: the pane id, not a guess from
    /// a tty, and never older than the same 15s the session id is allowed.
    private nonisolated static func publishedBindings() -> [Int32: PublishedBinding] {
        var bindings: [Int32: PublishedBinding] = [:]
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

            bindings[pid] = PublishedBinding(
                sessionID: json["sessionID"] as? String,
                pane: (json["tmuxPane"] as? String).map {
                    TmuxPaneRef(pane: $0, socket: json["tmuxSocket"] as? String)
                })
        }
        return bindings
    }

    /// A live binding's two answers: the session the client is driving, and — when the plugin saw a
    /// `TMUX_PANE` — the pane that session's terminal is showing. `pane` is nil both outside tmux and
    /// for a binding written by a plugin older than this field; either way the click falls back to
    /// resolving the pane from the client's tty.
    private struct PublishedBinding {
        let sessionID: String?
        let pane: TmuxPaneRef?
    }

    /// The pane a client is in, as its own process reported it. `socket` is the tmux server's socket
    /// path (`$TMUX`'s first field), so the switch hits the server the client is actually attached to
    /// even when the app's own `TMPDIR` would have pointed tmux somewhere else.
    private struct TmuxPaneRef {
        let pane: String
        let socket: String?
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
    ///
    /// This is the one path a mouse click waits on, so nothing here may wait on a process it does
    /// not need — and the halves that *are* processes run at once:
    ///
    /// - **The pane is known before the click.** The ocbar-bridge plugin runs inside the pane, so it
    ///   publishes that pane's id (`tmuxPane`, from its own `TMUX_PANE`) into the same binding file
    ///   that carries the session id, and `scan()` keeps the pid→pane map refreshed. A click
    ///   therefore spends **one** spawn (`switch-client`) instead of discovering the pane first.
    ///   When the map has no entry for the pid — not in tmux, or a binding from a plugin older than
    ///   the field — the client's *environment* answers with the same pane and still one spawn
    ///   (`paneFromEnvironment`); only when neither says anything does the tty route run.
    /// - **The client's tty is a syscall.** `ps -o tty= | tr -d ' '` (a `sh`, a `ps` and a `tr`)
    ///   became one `sysctl(KERN_PROC_PID)` reading `kinfo_proc.kp_eproc.e_tdev`: the same
    ///   `ttys004`, in microseconds.
    /// - **The AppleScript hop is gone.** `osascript … focus (first terminal whose tty is …)` could
    ///   not succeed: Ghostty 1.3 dropped the `tty` property, so every click spent ~200ms — behind an
    ///   Apple Events consent check — earning a `-2753`, and then fell through to `open -a Ghostty`
    ///   anyway. Terminal-level *tab* selection is still not something ocbar can do (it is the
    ///   residual approximation `terminalHostAppPID(forClient:)` documents), and paying for it on
    ///   every click was most of the click's latency.
    /// - **The raise and the pane switch overlap.** They are independent: `open` brings the window
    ///   forward, `switch-client` decides which pane that window shows, and tmux repaints in the
    ///   background. Serially they were ~250ms; overlapped, the click costs the longer of the two.
    /// - **`open -a`, not `NSRunningApplication.activate`.** Activating Ghostty by pid was measured
    ///   and is *refused* for an accessory app that is not itself frontmost — exactly the state a
    ///   click on the island comes from — and it fails silently. `open` goes through launchservicesd,
    ///   which can raise the app, in ~120ms.
    ///
    /// Measured inside a bundle, per click: ~590ms with the old shell pipeline, ~220–250ms once the
    /// pipeline became syscalls plus one `list-panes` and one `switch-client` (each spawn ~110ms:
    /// dyld + a server round trip, with `open`'s 120ms hidden under them), and ~130ms now that the
    /// pane comes from the binding and only the switch is left. What remains is that one spawn plus
    /// Ghostty's own raise.
    func focusSession(pid: Int32?) {
        let known = pid.flatMap { focusByPID[$0] }
        Task.detached(priority: .userInitiated) {
            async let raised: Void = SessionMonitor.activateTerminal()
            if let pid { SessionMonitor.showPane(ofClient: pid, known: known) }
            await raised
        }
    }

    /// `open -a Ghostty`, run to exit: the caller's task is already detached and concurrent, so the
    /// wait costs the click nothing and the child is reaped like every other spawn in this file.
    private nonisolated static func activateTerminal() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Ghostty"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Make the tmux pane that hosts `pid` the one its client is showing. A silent no-op when the
    /// client is not in tmux — that case is answered by the app raise alone.
    ///
    /// Three answers, cheapest and most trustworthy first, each falling through on failure:
    ///
    /// 1. **The client's binding** (`known`): the pane the plugin running *inside* that pane
    ///    published, already parsed with the session id on every scan.
    /// 2. **The client's environment**: `TMUX_PANE` + `$TMUX`'s socket read straight out of the
    ///    process. No spawn, and the answer for a client whose binding was written by a plugin older
    ///    than those fields — which is every client running across an ocbar upgrade until it restarts.
    /// 3. **The client's tty**: what is left when neither says anything, and the only reason
    ///    `controllingTTY` and `paneID` still exist.
    ///
    /// A wrong pane id — a pane that has since been closed, a server restarted under a binding — is
    /// caught by `switch-client` itself: its exit status is the fall-through.
    private nonisolated static func showPane(ofClient pid: pid_t, known: TmuxPaneRef?) {
        // No `-c <client>`: with one attached client that is the one, and with several tmux picks
        // the most recently active — the client the user was last in. Naming one costs another
        // spawn (`list-clients`) to tell tmux what it already knows.
        if let known, tmux(["switch-client", "-t", known.pane], socket: known.socket).ok { return }
        if let live = paneFromEnvironment(of: pid),
           tmux(["switch-client", "-t", live.pane], socket: live.socket).ok { return }
        guard let tty = controllingTTY(of: pid), let pane = paneID(forTTY: tty) else { return }
        _ = tmux(["switch-client", "-t", pane])
    }

    /// The pane `pid` is in, from its own environment: `$TMUX_PANE`, and the server's socket as
    /// `$TMUX`'s first comma-separated field. Nil outside tmux.
    private nonisolated static func paneFromEnvironment(of pid: pid_t) -> TmuxPaneRef? {
        let env = environment(of: pid)
        guard let pane = env["TMUX_PANE"], !pane.isEmpty else { return nil }
        let socket = env["TMUX"].flatMap { $0.split(separator: ",").first.map(String.init) }
        return TmuxPaneRef(pane: pane, socket: (socket?.isEmpty ?? true) ? nil : socket)
    }

    /// `pid`'s environment block, read from the kernel: same-uid processes only, which is every
    /// client ocbar shows, and no process spawn.
    ///
    /// `KERN_PROCARGS2` hands back one buffer: an `Int32` argc, the exec path, NUL padding, `argc`
    /// argv strings, then the `KEY=VALUE` block. Anything unreadable (a restricted process, a
    /// truncated read) is an empty dictionary — the caller then falls through to the tty route.
    private nonisolated static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [:] }
        var buf = [UInt8](repeating: 0, count: size)
        guard buf.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0 else { return [:] }
        let end = min(size, buf.count)

        var argc: Int32 = 0
        memcpy(&argc, buf, MemoryLayout<Int32>.size)
        var i = MemoryLayout<Int32>.size
        while i < end && buf[i] != 0 { i += 1 }   // exec path
        while i < end && buf[i] == 0 { i += 1 }   // padding
        var arg = 0
        while arg < Int(argc) && i < end {         // argv
            while i < end && buf[i] != 0 { i += 1 }
            i += 1
            arg += 1
        }

        var env: [String: String] = [:]
        while i < end && buf[i] != 0 {
            let start = i
            while i < end && buf[i] != 0 { i += 1 }
            let pair = String(decoding: buf[start..<i], as: UTF8.self)
            if let eq = pair.firstIndex(of: "=") {
                env[String(pair[pair.startIndex..<eq])] = String(pair[pair.index(after: eq)...])
            }
            i += 1
        }
        return env
    }

    /// The controlling terminal of `pid` in `ps`'s form (`ttys004`), or nil outside a terminal.
    private nonisolated static func controllingTTY(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        // `e_tdev` is NODEV (-1) for a process with no controlling terminal, and 0 when the kernel
        // has nothing to say; both mean "not in a terminal" here.
        guard rc == 0, info.kp_eproc.e_tdev != -1, info.kp_eproc.e_tdev != 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard devname_r(info.kp_eproc.e_tdev, S_IFCHR, &buf, Int32(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }

    /// The tmux pane whose tty is `tty` (`ttys004`), as tmux names it (`%2269`).
    private nonisolated static func paneID(forTTY tty: String) -> String? {
        let want = Substring("/dev/" + tty)
        // One `list-panes` for the whole server, matched here instead of in an `awk` child.
        for line in tmux(["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]).out.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count == 2, fields[0] == want { return String(fields[1]) }
        }
        return nil
    }

    /// Run `tmux` and report its stdout and whether it succeeded.
    ///
    /// `tmux` lives in Homebrew's paths that a GUI app's `PATH` does not include, so the binary is
    /// found by absolute path — no `sh` wrapper — and the environment is inherited untouched, so the
    /// server (and its socket directory) is the one the user is actually attached to.
    ///
    /// `socket` is passed as `-S` when the caller got it from a client's own `$TMUX`: that names the
    /// exact server socket, instead of leaving tmux to guess it from `TMUX_TMPDIR`/`TMPDIR`, which a
    /// GUI app's environment can answer differently from the shell's.
    private nonisolated static func tmux(_ args: [String], socket: String? = nil) -> (out: String, ok: Bool) {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return ("", false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = socket.map { ["-S", $0] + args } ?? args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus == 0)
    }

    // MARK: - Terminal host

    /// One row of `ps -Ao pid=,ppid=,tty=,comm=`.
    private struct ProcessEntry {
        let pid: pid_t
        let ppid: pid_t
        let tty: String
        let comm: String
    }

    /// The **application** that owns the terminal client `pid` runs in — Ghostty, Terminal, iTerm2,
    /// VS Code — **and only when that terminal is actually showing the session**, or nil.
    ///
    /// This is what lets the island ask "is the user already looking at this session's terminal?",
    /// which is a different question from the one `focusSession` answers: that one *moves* the
    /// terminal, this one only reports where it is.
    ///
    /// **For a tmux pane the answer is gated on tmux's own view state**, not on the app being in
    /// front (that is the caller's half of the check). A pane is shown only when it is the active
    /// pane of the active window *and* a client is attached — `pane_active`, `window_active`,
    /// `session_attached`, which is also what makes a focus in one split of the window count
    /// correctly. Without that gate the check was "Ghostty is in front", and since every pane of a
    /// session shares the app, a session sitting in a background window read as seen: the card
    /// folded 3s in while the user was looking at something else entirely.
    ///
    /// What remains approximate is the *tab*, not the pane: a terminal with two tabs attached to
    /// **different tmux sessions** cannot say which one is in front (a terminal's focused surface is
    /// invisible from outside without Accessibility, which ocbar does not ask for, or a per-terminal
    /// AppleScript — and Ghostty 1.3 dropped the `tty` property the old focus script was written
    /// against, which is why `focusSession` no longer tries it).
    /// That residual case is why the shortener is opt-in (`ocbar.alertFocusedFold`).
    ///
    /// The walk is the ppid chain, with one hop for tmux: a pane's shell is a child of the tmux
    /// *server*, which has been daemonized (ppid 1), so the chain from the client never reaches the
    /// terminal at all. The terminal's tty is then the **client's** tty (`tmux list-clients`), and
    /// the process holding it is a child of the app — the same routing `focusSession` uses to find
    /// the window, reused here to find the app. Outside tmux the client's own tty chain is used, and
    /// the pane question cannot be asked at all: the app is all there is to report.
    ///
    /// Off the main thread by construction (two to three process spawns): callers run it detached.
    nonisolated static func terminalHostAppPID(forClient pid: Int32) -> pid_t? {
        let table = processTable()
        guard table[pid] != nil else { return nil }
        var chain = ancestors(of: pid, in: table)
        let isTmuxPane = chain.contains { ($0.comm as NSString).lastPathComponent == "tmux" }
        if isTmuxPane {
            guard let paneTTY = table[pid]?.tty, !paneTTY.isEmpty, paneTTY != "??",
                  let pane = tmuxPaneState(forPaneTTY: paneTTY), pane.isShowing,
                  let clientTTY = pane.clientTTY,
                  let holder = table.values.first(where: { $0.tty == clientTTY }) else { return nil }
            chain = ancestors(of: holder.pid, in: table)
        }
        // The first ancestor that is a bundled application's main executable is the terminal. No
        // LaunchServices lookup is needed — and none is wanted: matching the bundle layout keeps this
        // file free of AppKit, and `login`/the shell/tmux (`/usr/bin/login`, `/bin/bash`,
        // `/opt/homebrew/bin/tmux`) cannot be mistaken for one.
        return chain.first { $0.comm.contains(".app/Contents/MacOS/") }?.pid
    }

    private nonisolated static func processTable() -> [pid_t: ProcessEntry] {
        var table: [pid_t: ProcessEntry] = [:]
        for line in runShell("ps -Ao pid=,ppid=,tty=,comm=").split(separator: "\n") {
            // `comm` can hold spaces (`Google Chrome Helper`), so it takes the rest of the line.
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]) else { continue }
            // `ps` pads its columns, and the remainder taken past `maxSplits` keeps that padding —
            // without the trim, `comm` reads "      tmux" and matches no bundle path.
            table[pid] = ProcessEntry(pid: pid, ppid: ppid,
                                      tty: fields[2].trimmingCharacters(in: .whitespaces),
                                      comm: fields[3].trimmingCharacters(in: .whitespaces))
        }
        return table
    }

    /// `pid` and its parents, nearest first. Capped, because a ppid cycle would spin here forever.
    private nonisolated static func ancestors(of pid: pid_t, in table: [pid_t: ProcessEntry]) -> [ProcessEntry] {
        var chain: [ProcessEntry] = []
        var current = pid
        while let entry = table[current], chain.count < 32 {
            chain.append(entry)
            current = entry.ppid
        }
        return chain
    }

    /// What tmux says about one pane: whether its session is currently *showing* it, and the tty of
    /// a client attached to that session (the terminal surface's own tty).
    private struct TmuxPaneState {
        let isShowing: Bool
        let clientTTY: String?
    }

    /// Ask tmux about the pane on `pane` (`ttys003`).
    ///
    /// `isShowing` is tmux's own view state: the pane is the active one in its window
    /// (`pane_active`), that window is the active one in its session (`window_active`), and at least
    /// one client is attached (`session_attached`). Any of the three failing means the session is
    /// *not* on screen, whatever the terminal app is doing — which is the whole point of asking.
    ///
    /// The client's tty comes back too because it is the only route to the app: the pane's own shell
    /// hangs off the daemonized tmux server, and the terminal is a parent of the **client**.
    private nonisolated static func tmuxPaneState(forPaneTTY pane: String) -> TmuxPaneState? {
        // `tmux` lives in Homebrew paths that a GUI app's PATH doesn't include. One `sh` for both
        // queries: this already runs behind a `ps` table, on the alert path.
        let out = runShell("""
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        ROW=$(tmux list-panes -a -F '#{pane_tty} #{session_name} #{pane_active} #{window_active} #{session_attached}' 2>/dev/null | awk -v p="/dev/\(pane)" '$1==p{print $2, $3, $4, $5; exit}')
        [ -z "$ROW" ] && exit 0
        set -- $ROW
        CLIENT=$(tmux list-clients -F '#{client_tty} #{client_session}' 2>/dev/null | awk -v s="$1" '$2==s{print $1; exit}')
        echo "$2 $3 $4 $CLIENT"
        """).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard out.count == 4 else { return nil }
        let attached = Int(out[2]) ?? 0
        let isShowing = out[0] == "1" && out[1] == "1" && attached > 0
        // `/dev/ttys000` → `ttys000`, the form `ps` prints.
        let clientTTY = out[3].isEmpty ? nil : (out[3] as NSString).lastPathComponent
        return TmuxPaneState(isShowing: isShowing, clientTTY: clientTTY)
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