import AppKit
import UserNotifications

// <menubar-title-shape>
// The sentinel comments around this block are load-bearing: an out-of-tree
// harness extracts the bytes between them and compiles this AppKit-free piece
// standalone, so the title decision can be asserted without a status item.
// Anything added inside must stay free of AppKit.
/// Which shape the menubar status item takes. Decided purely from the session
/// count and the two toggles, so the choice can be driven outside AppKit.
/// `appName` is the plain "ocbar" label used when project names are off but the
/// island is on and therefore already carrying the per-status detail.
enum MenubarTitleShape: Equatable {
    case empty
    case appName
    case aggregate
    case named
    case folded
}

func menubarTitleShape(sessionCount: Int, projectsShown: Int, islandEnabled: Bool) -> MenubarTitleShape {
    if sessionCount == 0 { return .empty }
    if projectsShown == 0 { return islandEnabled ? .appName : .aggregate }
    return sessionCount <= projectsShown ? .named : .folded
}

/// VoiceOver summary for the glyph + count vocabulary ("2 busy, 1 waiting"),
/// ordered most urgent first. Shared by `aggregateTitle` and the plain "ocbar"
/// title, which drops the visible counts but must keep the spoken state.
func aggregateSummary(statuses: [String]) -> String {
    var parts: [String] = []
    for status in ["error", "busy", "waiting", "idle"] {
        let count = statuses.filter { $0 == status }.count
        guard count > 0 else { continue }
        parts.append("\(count) \(status)")
    }
    return parts.joined(separator: ", ")
}
// </menubar-title-shape>

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: SessionMonitor!
    /// The point size the status glyphs — and therefore the running mark standing among them — are drawn
    /// at in the menubar title and in the dropdown rows. Named because the mark's canvas and its outer
    /// diameter are both measured from the check-circle at exactly this size
    /// (`IslandRing.image(pointSize:angle:)`): a "tidier" number here would silently resize the mark
    /// relative to the discs beside it.
    private let titleMarkPointSize: CGFloat = 11
    private let menuMarkPointSize: CGFloat = 13
    private var menu: NSMenu!
    private var lastSessions: [SessionInfo]? = nil
    private var currentState = AppState()
    private var bubble: StatusBubble!
    private var island: IslandHost!
    private var runningMarkTimer: Timer?
    /// The menubar's running mark's current angle. Advances from the clock (see `tickRunningMark`) and is
    /// held at `IslandRing.restingAngle` whenever the mark may not turn.
    private var runningMarkAngle: CGFloat = IslandRing.restingAngle
    /// Reduce Motion changes have to reach the menubar's mark without waiting for the next poll tick:
    /// turning it on stops the rotation at the resting angle, and turning it off starts it again.
    private var reduceMotionObserver: NSObjectProtocol?
    private var busyMenuItems: [NSMenuItem] = []
    private var busyTitleAttachments: [NSTextAttachment] = []
    private var currentButtonTitle: NSAttributedString?
    private let projectsShownKey = "ocbar.projectsShown"
    private let showSessionTimeKey = "ocbar.showSessionTime"
    private let showSessionTitlesKey = "ocbar.showSessionTitles"
    private let defaultProjectsShown = 4
    private let bubblePositionsKey = "ocbar.bubblePositions"
    private let bubbleSecondsKey = "ocbar.bubbleSeconds"
    private let bubbleColorKey = "ocbar.bubbleColor"
    private let bubbleEnabledKey = "ocbar.bubble"
    private let alertSoundKey = "ocbar.alertSound"
    private let islandEnabledKey = "ocbar.island"
    private let defaultBubbleSeconds = 10
    private let contextUsageKey = "ocbar.contextUsage"
    private let contextUsageDisplayKey = "ocbar.contextUsageDisplay"
    private let contextUsageWarnKey = "ocbar.contextUsageWarn"
    private let contextUsageCriticalKey = "ocbar.contextUsageCritical"
    private let defaultContextUsageWarn = 80
    private let defaultContextUsageCritical = 95
    private static let contextWarnOptions = [70, 80, 90]
    private static let contextCriticalOptions = [90, 95, 98]

    /// Width of the status-glyph slot a session menu row uses, measured from the
    /// same symbols/config `sessionItem` draws them with. The detail row mirrors
    /// this width so AppKit lays its text out under the session name.
    ///
    /// A running row's slot is the *mark's* canvas (`IslandRing.canvasSize`), which is the
    /// check-circle's image box at this point size — so it is already one of the widths measured here
    /// and needs no entry of its own. (It used to need one, for the wedge spinner's canvas.)
    private static let sessionMenuImageWidth: CGFloat = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let symbols = ["questionmark.circle.fill",
                       "checkmark.circle.fill", "exclamationmark.triangle.fill"]
        let widths = symbols.compactMap { symbol -> CGFloat? in
            guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
            return (img.withSymbolConfiguration(cfg) ?? img).size.width
        }
        return widths.max() ?? 16
    }()
    private static let sessionMenuImageHeight: CGFloat = 16
    /// Extra leading inset (pt) added to the detail row's badge; bump to nudge
    /// the detail text further right if the alignment needs fine-tuning.
    private static let contextDetailExtraInset: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        monitor = SessionMonitor { [weak self] state in
            self?.render(state)
        }
        bubble = StatusBubble()
        // One island per attached screen; the host owns the set and fans the
        // same rows out to all of them.
        island = IslandHost()
        island.onSelectSession = { [weak self] pid in
            self?.monitor.focusSession(pid: pid)
        }
        monitor.onTransition = { [weak self] status, dir, pid, title in
            self?.showBubble(status: status, projectDir: dir, pid: pid, title: title)
        }
        monitor.onDismiss = { [weak self] dir in
            self?.dismissReminders(projectDir: dir)
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Reduce Motion reaches the menubar's running mark for the first time: the island's ring
        // re-reads the setting on this same notification, so the menubar's mark follows it — off stops
        // the rotation and paints the mark still, on starts it turning again. `queue: .main`, so this
        // is the main thread, where `updateRunningMark` and the status item belong.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateRunningMark()
        }
        monitor.start()
        render(AppState())
    }

    private func render(_ state: AppState, forceMenuRefresh: Bool = false) {
        currentState = state
        // `updateRunningMark` first: it owns the running mark's angle (it holds it at the resting angle
        // when Reduce Motion forbids turning it), and `updateButton` below renders that angle into the
        // title. Swapping the two would draw one frame at a stale angle on the tick Reduce Motion
        // changes — the observer catches it immediately, but the poll tick should not need catching.
        updateRunningMark()
        updateButton(for: state)
        // `render` is nonisolated but is only ever invoked on the main thread
        // (AppKit callbacks + the monitor's main-actor poll); the island is a
        // @MainActor type, so hop its push onto the main actor explicitly.
        let islandSnapshot = islandRows(for: state.sessions)
        let islandIsEnabled = islandEnabled
        Task { @MainActor [island] in island?.update(rows: islandSnapshot, enabled: islandIsEnabled) }

        let sessions = state.sessions
        guard forceMenuRefresh || sessions != lastSessions else { return }
        lastSessions = sessions

        menu.removeAllItems()
        busyMenuItems.removeAll()
        if sessions.isEmpty {
            menu.addItem(menuLabel("No OpenCode sessions"))
        } else {
            let nowMS = Date().timeIntervalSince1970 * 1000
            let names = disambiguatedNames(for: sessions)
            for s in sessions {
                let item = sessionItem(name: names[s.id] ?? sessionName(for: s), status: s.status, pid: s.clientPID,
                                       duration: showSessionTime ? formatDurationLabel(sinceMS: s.createdAt, nowMS: nowMS) : "")
                if s.status == .busy { busyMenuItems.append(item) }
                menu.addItem(item)
                if contextUsageEnabled {
                    menu.addItem(contextDetailItem(for: s))
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(projectsShownMenu())
        menu.addItem(showBubbleMenu())
        menu.addItem(bubblePositionMenu())
        menu.addItem(bubbleSecondsMenu())
        menu.addItem(bubbleColorMenu())
        menu.addItem(alertSoundMenu())
        menu.addItem(islandMenu())
        menu.addItem(showSessionTimeMenu())
        menu.addItem(showSessionTitlesMenu())
        menu.addItem(contextUsageMenu())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ocbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func updateButton(for state: AppState) {
        guard let button = statusItem.button else { return }

        let cfg = NSImage.SymbolConfiguration(pointSize: titleMarkPointSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuBarFont(ofSize: 13)
        ]

        let total = state.sessions.count
        let shape = menubarTitleShape(sessionCount: total, projectsShown: projectsShown, islandEnabled: islandEnabled)
        var accessibility: String

        switch shape {
        case .empty:
            button.image = nil
            // No sessions: glyph only. The status item shrinks to a bare dot —
            // the same dot-plus-name grammar the populated states use, minus a
            // name to show. The words live in the menu ("No OpenCode sessions").
            if let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "No OpenCode sessions") {
                button.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: .secondaryLabelColor)
            }
            button.imagePosition = .imageOnly
            busyTitleAttachments = []
            currentButtonTitle = nil
            button.attributedTitle = NSAttributedString(string: "", attributes: attrs)
            accessibility = "No OpenCode sessions"
        case .appName:
            // Project names are off but the island is on, so the island already
            // shows the per-status detail; the menubar drops to the bare app
            // name. The visible glyphs and counts are gone, so VoiceOver keeps
            // the spoken state summary rather than reading just "ocbar".
            button.image = nil
            let title = NSAttributedString(string: "ocbar", attributes: attrs)
            busyTitleAttachments = []
            currentButtonTitle = title
            button.attributedTitle = title
            accessibility = aggregateSummary(statuses: state.sessions.map { $0.status.rawValue })
        case .aggregate:
            // No names at all: one glyph + count per status that has sessions.
            // Same status vocabulary the menu rows and the island use, and the
            // glyphs alone are otherwise invisible to VoiceOver.
            button.image = nil
            let built = aggregateTitle(for: state.sessions, attributes: attrs)
            busyTitleAttachments = built.busyAttachments
            currentButtonTitle = built.title
            button.attributedTitle = built.title
            accessibility = built.summary
        case .named:
            button.image = nil
            let built = sessionTitle(for: state.sessions, attributes: attrs)
            busyTitleAttachments = built.busyAttachments
            currentButtonTitle = built.title
            button.attributedTitle = built.title
            accessibility = spokenNames(for: state.sessions)
        case .folded:
            button.image = nil
            let built = foldedTitle(for: state.sessions, attributes: attrs)
            busyTitleAttachments = built.busyAttachments
            currentButtonTitle = built.title
            button.attributedTitle = built.title
            accessibility = spokenNames(for: state.sessions)
        }
        button.setAccessibilityLabel(accessibility)
    }

    private func updateRunningMark() {
        let busy = currentState.sessions.contains { $0.status == .busy }
        // **Reduce Motion, honoured on the menubar's mark for the first time.** The mark still says
        // "running" — its tint and its shape do that — but it holds at its resting angle instead of
        // turning, exactly as the island's ring does (`IslandActivityView.shouldPlay`). With nothing
        // moving there is also nothing for a 16.7fps timer to repaint, so it does not run.
        let turning = busy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if turning {
            guard runningMarkTimer == nil else { return }
            let timer = Timer(timeInterval: IslandRing.tickInterval, repeats: true) { [weak self] _ in
                self?.tickRunningMark()
            }
            RunLoop.main.add(timer, forMode: .common)
            runningMarkTimer = timer
            return
        }
        runningMarkTimer?.invalidate()
        runningMarkTimer = nil
        // A mark that is not turning is put back to its resting angle rather than left wherever the
        // last tick stopped it: a gap frozen at an arbitrary angle reads as a spinner that has
        // stalled (the island's ring is held the same way).
        runningMarkAngle = IslandRing.restingAngle
        // …and if there *is* something running, repaint it still, now, instead of leaving the last
        // angle on screen until the next render.
        if busy { refreshBusyMarks() }
    }

    /// Repaint every running mark at the current angle: the title's attachments in place, rather than
    /// rebuilding the whole attributed string every frame, and the dropdown rows' images.
    private func refreshBusyMarks() {
        if !busyTitleAttachments.isEmpty, let title = currentButtonTitle {
            let img = IslandRing.image(pointSize: titleMarkPointSize, angle: runningMarkAngle)
            for attachment in busyTitleAttachments {
                attachment.image = img
            }
            statusItem.button?.attributedTitle = title
        }
        for item in busyMenuItems {
            item.image = IslandRing.image(pointSize: menuMarkPointSize, angle: runningMarkAngle)
        }
    }

    private func tickRunningMark() {
        // The angle is a function of the clock, not an accumulator, so every ring in the app — this
        // one, the island's pill and its card rows — is at the same angle at the same instant, and a
        // late tick cannot make this mark drift away from the others. The tick only decides *when*
        // the image is redrawn, which is still `IslandRing.tickInterval` (0.06s, the ~16.7fps the
        // wedge spinner ran at; the speed itself is `IslandRing.stepDegrees`/`revolutionSeconds`).
        runningMarkAngle = IslandRing.angle(at: Date())
        refreshBusyMarks()
    }

    private var projectsShown: Int {
        guard let stored = UserDefaults.standard.object(forKey: projectsShownKey) as? Int,
              (0...10).contains(stored) else {
            return defaultProjectsShown
        }
        return stored
    }

    private var showSessionTime: Bool {
        guard let stored = UserDefaults.standard.object(forKey: showSessionTimeKey) as? Bool else { return true }
        return stored
    }

    private func showSessionTimeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Show session time", action: #selector(showSessionTimeToggled(_:)), keyEquivalent: "")
        item.target = self
        item.state = showSessionTime ? .on : .off
        return item
    }

    @objc private func showSessionTimeToggled(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!showSessionTime, forKey: showSessionTimeKey)
        render(currentState, forceMenuRefresh: true)
    }

    private var showSessionTitles: Bool {
        guard let stored = UserDefaults.standard.object(forKey: showSessionTitlesKey) as? Bool else { return true }
        return stored
    }

    private func showSessionTitlesMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Show session titles", action: #selector(showSessionTitlesToggled(_:)), keyEquivalent: "")
        item.target = self
        item.state = showSessionTitles ? .on : .off
        return item
    }

    @objc private func showSessionTitlesToggled(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!showSessionTitles, forKey: showSessionTitlesKey)
        render(currentState, forceMenuRefresh: true)
    }

    // MARK: - Context usage

    private var contextUsageEnabled: Bool {
        guard let stored = UserDefaults.standard.object(forKey: contextUsageKey) as? Bool else { return false }
        return stored
    }

    private var contextUsageDisplay: ContextDisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: contextUsageDisplayKey),
              let display = ContextDisplayMode(rawValue: raw) else { return .both }
        return display
    }

    private var contextUsageWarn: Int {
        guard let stored = UserDefaults.standard.object(forKey: contextUsageWarnKey) as? Int else { return defaultContextUsageWarn }
        return stored
    }

    private var contextUsageCritical: Int {
        guard let stored = UserDefaults.standard.object(forKey: contextUsageCriticalKey) as? Int else { return defaultContextUsageCritical }
        return stored
    }

    private func contextUsageMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let toggle = NSMenuItem(title: "Show context usage", action: #selector(contextUsageToggled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = contextUsageEnabled ? .on : .off
        submenu.addItem(toggle)
        submenu.addItem(.separator())

        for (index, display) in ContextDisplayMode.allCases.enumerated() {
            let item = NSMenuItem(title: display.displayName, action: #selector(contextUsageDisplaySelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = display == contextUsageDisplay ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        for value in Self.contextWarnOptions {
            let item = NSMenuItem(title: "Warn at \(value)%", action: #selector(contextUsageWarnSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = value == contextUsageWarn ? .on : .off
            submenu.addItem(item)
        }

        for value in Self.contextCriticalOptions {
            let item = NSMenuItem(title: "Critical at \(value)%", action: #selector(contextUsageCriticalSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = value == contextUsageCritical ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Context usage", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    @objc private func contextUsageToggled(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!contextUsageEnabled, forKey: contextUsageKey)
        render(currentState, forceMenuRefresh: true)
    }

    @objc private func contextUsageDisplaySelected(_ sender: NSMenuItem) {
        let all = ContextDisplayMode.allCases
        guard all.indices.contains(sender.tag) else { return }
        UserDefaults.standard.set(all[sender.tag].rawValue, forKey: contextUsageDisplayKey)
        render(currentState, forceMenuRefresh: true)
    }

    @objc private func contextUsageWarnSelected(_ sender: NSMenuItem) {
        guard Self.contextWarnOptions.contains(sender.tag) else { return }
        UserDefaults.standard.set(sender.tag, forKey: contextUsageWarnKey)
        render(currentState, forceMenuRefresh: true)
    }

    @objc private func contextUsageCriticalSelected(_ sender: NSMenuItem) {
        guard Self.contextCriticalOptions.contains(sender.tag) else { return }
        UserDefaults.standard.set(sender.tag, forKey: contextUsageCriticalKey)
        render(currentState, forceMenuRefresh: true)
    }

    /// Detail row shown beneath a session row when context usage is enabled.
    /// Non-actionable (nil action + isEnabled) so its image slot is not dimmed.
    private func contextDetailItem(for session: SessionInfo) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = true
        // The session row's text starts after its status glyph in the image
        // slot. Mirror that exact geometry instead of relying on an indent:
        // image width = session glyph width, indentation = 0. AppKit then lays
        // the detail text at the same x as the session name (under the name,
        // not under the glyph).
        item.indentationLevel = 0

        // Width of this session row's own status-glyph slot, so the detail text
        // lands exactly under the session's name (a running row uses the mark's
        // canvas, other rows the status symbol at the row's point size).
        let badgeWidth: CGFloat
        if session.status == .busy {
            badgeWidth = IslandRing.canvasSize(pointSize: menuMarkPointSize).width
        } else if let symbol = statusAppearance(for: session.status).symbol,
                  let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            badgeWidth = (img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: menuMarkPointSize, weight: .regular)) ?? img).size.width
        } else {
            badgeWidth = Self.sessionMenuImageWidth
        }

        let baseFont = NSFont.menuFont(ofSize: 0)
        let unknownAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        // Thresholds, wording, banding: all shared with the island row via
        // ContextUsagePresentation, so the two surfaces cannot drift.
        let presentation = contextPresentation(for: session)

        switch presentation.content {
        case .placeholder(let text):
            item.attributedTitle = NSAttributedString(string: text, attributes: unknownAttributes)
            item.image = contextDetailImage(glyph: nil, color: .tertiaryLabelColor, width: badgeWidth)
            return item
        case .usage(let tokensText, let percentText):
            let bandColor = presentation.band.menuColor
            // Semibold percent is a redundant, colour-independent cue that only
            // applies inside a band (warn or critical).
            let inBand = presentation.band.inBand
            let percentFont = inBand ? NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold) : baseFont
            let normalAttributes: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: bandColor]
            let percentAttributes: [NSAttributedString.Key: Any] = [.font: percentFont, .foregroundColor: bandColor]

            let title = NSMutableAttributedString()
            switch contextUsageDisplay {
            case .percent:
                title.append(NSAttributedString(string: percentText, attributes: percentAttributes))
            case .tokens:
                title.append(NSAttributedString(string: tokensText, attributes: normalAttributes))
            case .both:
                title.append(NSAttributedString(string: "\(tokensText) · ", attributes: normalAttributes))
                title.append(NSAttributedString(string: percentText, attributes: percentAttributes))
            }
            item.attributedTitle = title
            item.image = contextDetailImage(glyph: presentation.band.glyph, color: bandColor, width: badgeWidth)
            return item
        }
    }

    /// A fixed-width leading badge for the detail row. Its width equals a
    /// session row's status-glyph slot so the detail text (and the band glyph)
    /// line up under the session name. Transparent when there is no band, so
    /// alignment does not depend on band state.
    private func contextDetailImage(glyph: String?, color: NSColor, width badgeWidth: CGFloat) -> NSImage {
        let width = badgeWidth + Self.contextDetailExtraInset
        let height = Self.sessionMenuImageHeight
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let glyph,
                  let base = NSImage(systemSymbolName: glyph, accessibilityDescription: nil) else { return true }
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            let img = self.tint(base.withSymbolConfiguration(cfg) ?? base, color: color)
            let x = (rect.width - img.size.width) / 2
            let y = (rect.height - img.size.height) / 2
            img.draw(in: NSRect(x: x, y: y, width: img.size.width, height: img.size.height))
            return true
        }
    }

    /// Thresholds, wording and banding for one session's context usage — the
    /// same values the menubar detail row is built from.
    private func contextPresentation(for session: SessionInfo) -> ContextUsagePresentation {
        ContextUsagePresentation(
            context: session.context,
            warn: contextUsageWarn,
            critical: contextUsageCritical
        )
    }

    private func projectsShownMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // 0 drops every project name; the menubar falls back to a glyph + count
        // summary per status (see aggregateTitle).
        for count in 0...10 {
            let title = count == 0 ? "0 (none)" : "\(count)"
            let item = NSMenuItem(title: title, action: #selector(projectsShownSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            item.state = count == projectsShown ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Projects shown", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    @objc private func projectsShownSelected(_ sender: NSMenuItem) {
        guard (0...10).contains(sender.tag) else { return }
        UserDefaults.standard.set(sender.tag, forKey: projectsShownKey)
        render(currentState, forceMenuRefresh: true)
    }

    private var bubbleEnabled: Bool {
        guard let stored = UserDefaults.standard.object(forKey: bubbleEnabledKey) as? Bool else { return true }
        return stored
    }

    private func showBubbleMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Show bubble", action: #selector(showBubbleToggled(_:)), keyEquivalent: "")
        item.target = self
        item.state = bubbleEnabled ? .on : .off
        return item
    }

    @objc private func showBubbleToggled(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!bubbleEnabled, forKey: bubbleEnabledKey)
        render(currentState, forceMenuRefresh: true)
    }

    private var bubblePositions: Set<BubblePosition> {
        guard let raw = UserDefaults.standard.array(forKey: bubblePositionsKey) as? [String] else {
            return [.topCenter]
        }
        let positions = Set(raw.compactMap(BubblePosition.init(rawValue:)))
        return positions.isEmpty ? [.topCenter] : positions
    }

    private func bubblePositionMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selected = bubblePositions
        for (index, position) in BubblePosition.allCases.enumerated() {
            let item = NSMenuItem(title: position.displayName, action: #selector(bubblePositionToggled(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = selected.contains(position) ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Bubble position", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    @objc private func bubblePositionToggled(_ sender: NSMenuItem) {
        let all = BubblePosition.allCases
        guard all.indices.contains(sender.tag) else { return }
        let tapped = all[sender.tag]
        var current = bubblePositions
        if current.contains(tapped) {
            guard current.count > 1 else { return }
            current.remove(tapped)
        } else {
            current.insert(tapped)
        }
        UserDefaults.standard.set(current.map { $0.rawValue }, forKey: bubblePositionsKey)
        render(currentState, forceMenuRefresh: true)
    }

    private var bubbleSeconds: Int {
        guard let stored = UserDefaults.standard.object(forKey: bubbleSecondsKey) as? Int,
              [5, 10, 20, 30, 60].contains(stored) else {
            return defaultBubbleSeconds
        }
        return stored
    }

    private func bubbleSecondsMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for seconds in [5, 10, 20, 30, 60] {
            let item = NSMenuItem(title: "\(seconds)s", action: #selector(bubbleSecondsSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = seconds == bubbleSeconds ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Bubble duration", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    @objc private func bubbleSecondsSelected(_ sender: NSMenuItem) {
        guard [5, 10, 20, 30, 60].contains(sender.tag) else { return }
        UserDefaults.standard.set(sender.tag, forKey: bubbleSecondsKey)
        render(currentState, forceMenuRefresh: true)
    }

    private enum BubbleColor: String, CaseIterable {
        case system
        case light
        case dark

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var color: NSColor {
            switch self {
            case .system: return .windowBackgroundColor
            case .light: return .white
            case .dark: return NSColor(white: 0.12, alpha: 1)
            }
        }
    }

    private var bubbleColor: BubbleColor {
        guard let raw = UserDefaults.standard.string(forKey: bubbleColorKey),
              let color = BubbleColor(rawValue: raw) else { return .light }
        return color
    }

    private func bubbleColorMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, color) in BubbleColor.allCases.enumerated() {
            let item = NSMenuItem(title: color.displayName, action: #selector(bubbleColorSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = color == bubbleColor ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Bubble color", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    @objc private func bubbleColorSelected(_ sender: NSMenuItem) {
        let all = BubbleColor.allCases
        guard all.indices.contains(sender.tag) else { return }
        UserDefaults.standard.set(all[sender.tag].rawValue, forKey: bubbleColorKey)
        render(currentState, forceMenuRefresh: true)
    }

    // The alert played alongside the bubble. "System alert" uses the user's
    // configured alert sound (NSSound.beep()); the rest are the macOS system
    // sounds, which NSSound looks up by their capitalized name.
    private enum AlertSound: String, CaseIterable {
        case off
        case system
        case basso
        case blow
        case bottle
        case frog
        case funk
        case glass
        case hero
        case morse
        case ping
        case pop
        case purr
        case sosumi
        case submarine
        case tink

        var displayName: String {
            switch self {
            case .off: return "Off"
            case .system: return "System alert"
            default: return rawValue.capitalized
            }
        }

        func play() {
            switch self {
            case .off: return
            case .system: NSSound.beep()
            default: NSSound(named: rawValue.capitalized)?.play()
            }
        }
    }

    private var alertSound: AlertSound {
        guard let raw = UserDefaults.standard.string(forKey: alertSoundKey),
              let sound = AlertSound(rawValue: raw) else { return .off }
        return sound
    }

    private func alertSoundMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, sound) in AlertSound.allCases.enumerated() {
            let item = NSMenuItem(title: sound.displayName, action: #selector(alertSoundSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = sound == alertSound ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Alert sound", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    @objc private func alertSoundSelected(_ sender: NSMenuItem) {
        let all = AlertSound.allCases
        guard all.indices.contains(sender.tag) else { return }
        let selected = all[sender.tag]
        UserDefaults.standard.set(selected.rawValue, forKey: alertSoundKey)
        // Preview the pick immediately so the user hears what they chose; .off is a no-op.
        selected.play()
        render(currentState, forceMenuRefresh: true)
    }

    // MARK: - Island

    private var islandEnabled: Bool {
        guard let stored = UserDefaults.standard.object(forKey: islandEnabledKey) as? Bool else { return true }
        return stored
    }

    private func islandMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Show island", action: #selector(islandToggled(_:)), keyEquivalent: "")
        item.target = self
        item.state = islandEnabled ? .on : .off
        return item
    }

    @objc private func islandToggled(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!islandEnabled, forKey: islandEnabledKey)
        render(currentState, forceMenuRefresh: true)
    }

    /// Rows handed to the island: the same status and age the dropdown uses, plus
    /// the folder name and the session title's leading part on line 1, the
    /// context-usage line when that feature is on — again built from the same
    /// presentation the dropdown's detail row uses — and, on that same line's
    /// right end, how long ago the session was last updated.
    private func islandRows(for sessions: [SessionInfo]) -> [IslandRow] {
        let nowMS = Date().timeIntervalSince1970 * 1000
        let names = islandRowNames(for: sessions, showTitles: showSessionTitles)
        return sessions.map { session in
            let naming = names[session.id]
                ?? IslandRowName(name: sessionFolderName(for: session), title: nil)
            return IslandRow(
                name: naming.name,
                title: naming.title,
                status: session.status,
                duration: showSessionTime ? formatDurationLabel(sinceMS: session.createdAt, nowMS: nowMS) : "",
                pid: session.clientPID,
                context: islandContext(for: session),
                stamp: showSessionTime ? formatStampLabel(updatedMS: session.updatedAt, createdMS: session.createdAt, nowMS: nowMS) : ""
            )
        }
    }

    /// The island's context line for one session, or nil when the feature is
    /// off — in which case the island row renders exactly as it did before
    /// context usage existed. Reads no endpoint itself: it reuses the value the
    /// monitor already filled (throttled to 2s per session).
    private func islandContext(for session: SessionInfo) -> IslandContext? {
        guard contextUsageEnabled else { return nil }
        let presentation = contextPresentation(for: session)
        return IslandContext(
            text: presentation.displayText(contextUsageDisplay),
            glyph: presentation.band.glyph,
            band: presentation.band
        )
    }

    private func menuLabel(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    private func sessionTitle(for sessions: [SessionInfo], attributes: [NSAttributedString.Key: Any]) -> (title: NSAttributedString, busyAttachments: [NSTextAttachment]) {
        let title = NSMutableAttributedString()
        let cfg = NSImage.SymbolConfiguration(pointSize: titleMarkPointSize, weight: .medium)
        var busyAttachments: [NSTextAttachment] = []

        for (index, session) in sessions.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  ·  ", attributes: attributes))
            }

            let appearance = statusAppearance(for: session.status)
            if let img = statusGlyphImage(appearance: appearance, status: session.status, cfg: cfg) {
                let attachment = NSTextAttachment()
                attachment.image = img
                // Nudge down so glyph center aligns with text center (glyph sits ~1.84pt high otherwise)
                attachment.bounds = NSRect(x: 0, y: -1.84, width: img.size.width, height: img.size.height)
                title.append(NSAttributedString(attachment: attachment))
                if session.status == .busy { busyAttachments.append(attachment) }
            }
            title.append(NSAttributedString(string: " \(sessionName(for: session))", attributes: attributes))
        }

        return (title, busyAttachments)
    }

    private func foldedTitle(for sessions: [SessionInfo], attributes: [NSAttributedString.Key: Any]) -> (title: NSAttributedString, busyAttachments: [NSTextAttachment]) {
        let title = NSMutableAttributedString()
        let cfg = NSImage.SymbolConfiguration(pointSize: titleMarkPointSize, weight: .medium)
        var busyAttachments: [NSTextAttachment] = []

        let active = sessions.filter { $0.status != .idle }
        let idle = sessions.filter { $0.status == .idle }

        for session in active {
            if title.length > 0 {
                title.append(NSAttributedString(string: "  ·  ", attributes: attributes))
            }

            let appearance = statusAppearance(for: session.status)
            if let img = statusGlyphImage(appearance: appearance, status: session.status, cfg: cfg) {
                let attachment = NSTextAttachment()
                attachment.image = img
                // Nudge down so glyph center aligns with text center (glyph sits ~1.84pt high otherwise)
                attachment.bounds = NSRect(x: 0, y: -1.84, width: img.size.width, height: img.size.height)
                title.append(NSAttributedString(attachment: attachment))
                if session.status == .busy { busyAttachments.append(attachment) }
            }
            title.append(NSAttributedString(string: " \(sessionName(for: session))", attributes: attributes))
        }

        if !idle.isEmpty {
            if title.length > 0 {
                title.append(NSAttributedString(string: "  ·  ", attributes: attributes))
            }

            let appearance = statusAppearance(for: .idle)
            if let symbol = appearance.symbol,
               let base = NSImage(systemSymbolName: symbol, accessibilityDescription: SessionStatus.idle.rawValue) {
                let img = tint(base.withSymbolConfiguration(cfg) ?? base, color: appearance.color)
                let attachment = NSTextAttachment()
                attachment.image = img
                attachment.bounds = NSRect(x: 0, y: -1.84, width: img.size.width, height: img.size.height)
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " \(idle.count) idle", attributes: attributes))
        }

        return (title, busyAttachments)
    }

    /// Menubar label with no project names: one glyph + count per status that
    /// actually has sessions, most urgent first, so the everyday case is the
    /// same shape the island uses — `● 2  ·  ✓ 1`. Used when "Projects shown"
    /// is 0. `summary` is the VoiceOver text, since glyphs and digits alone
    /// say nothing out loud.
    private func aggregateTitle(for sessions: [SessionInfo], attributes: [NSAttributedString.Key: Any]) -> (title: NSAttributedString, busyAttachments: [NSTextAttachment], summary: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: titleMarkPointSize, weight: .medium)
        let title = NSMutableAttributedString()
        var busyAttachments: [NSTextAttachment] = []

        for status in [SessionStatus.error, .busy, .waiting, .idle] {
            let count = sessions.filter { $0.status == status }.count
            guard count > 0 else { continue }
            if title.length > 0 {
                title.append(NSAttributedString(string: "  ·  ", attributes: attributes))
            }

            let appearance = statusAppearance(for: status)
            if let img = statusGlyphImage(appearance: appearance, status: status, cfg: cfg) {
                let attachment = NSTextAttachment()
                attachment.image = img
                // Nudge down so glyph center aligns with text center (glyph sits ~1.84pt high otherwise)
                attachment.bounds = NSRect(x: 0, y: -1.84, width: img.size.width, height: img.size.height)
                title.append(NSAttributedString(attachment: attachment))
                if status == .busy { busyAttachments.append(attachment) }
            }
            title.append(NSAttributedString(string: " \(count)", attributes: attributes))
        }

        return (title, busyAttachments, aggregateSummary(statuses: sessions.map { $0.status.rawValue }))
    }

    /// VoiceOver text for the menubar item while it renders project names.
    private func spokenNames(for sessions: [SessionInfo]) -> String {
        let names = disambiguatedNames(for: sessions)
        return sessions.map { names[$0.id] ?? sessionName(for: $0) }.joined(separator: ", ")
    }

    /// The folder a session belongs to, shared with the island's line-1 naming so
    /// the two surfaces agree on it. See `sessionFolderName`.
    private func sessionName(for session: SessionInfo) -> String {
        sessionFolderName(for: session)
    }

    // Several live sessions can share one project folder, which would otherwise
    // render as identical rows. Only names that actually collide get a short
    // suffix — the session's server title when it has one, otherwise the tail of
    // its id — so a unique folder name stays clean.
    private func disambiguatedNames(for sessions: [SessionInfo]) -> [String: String] {
        var counts: [String: Int] = [:]
        for session in sessions {
            counts[sessionName(for: session), default: 0] += 1
        }
        var names: [String: String] = [:]
        for session in sessions {
            let base = sessionName(for: session)
            if (counts[base] ?? 0) > 1 {
                names[session.id] = "\(base) (\(sessionDisambiguator(for: session)))"
            } else {
                names[session.id] = base
            }
        }
        return names
    }

    private func sessionDisambiguator(for session: SessionInfo) -> String {
        // One shared "display title" — same cleaning the island's title field
        // gets, so the two surfaces never disagree about what a title is.
        if showSessionTitles, let title = flattenedSessionTitle(session) {
            return truncated(title, limit: 24)
        }
        let tail = session.id.suffix(6)
        return tail.isEmpty ? "session" : String(tail)
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// How a status becomes a mark. `symbol` is `nil` for `.busy`: its mark is not an SF Symbol any
    /// more, it is the ring (`IslandRing`) that the island, the menubar and the dropdown all draw —
    /// the same mark, from the same construction. The colour is still resolved here, and `.busy` reads
    /// `IslandRing.runningTint`, so a status still becomes a colour in one place per surface.
    private func statusAppearance(for status: SessionStatus) -> (symbol: String?, color: NSColor) {
        switch status {
        case .busy:
            return (nil, IslandRing.runningTint)
        case .waiting:
            return ("questionmark.circle.fill", .systemBlue)
        case .idle:
            return ("checkmark.circle.fill", .systemGreen)
        case .error:
            return ("exclamationmark.triangle.fill", .systemRed)
        }
    }

    private func statusGlyphImage(appearance: (symbol: String?, color: NSColor), status: SessionStatus, cfg: NSImage.SymbolConfiguration) -> NSImage? {
        // The running mark: the same ring the island draws, rendered as an image because a title
        // attachment and a menu item cannot host a view. Its canvas is the check-circle's image box at
        // this point size — the box the attachment's bounds and baseline nudge are computed against —
        // and its outer edge lands on that circle's measured ink, so a busy entry is neither a
        // different size nor a different shape from the idle one beside it.
        if status == .busy {
            return IslandRing.image(pointSize: titleMarkPointSize, angle: runningMarkAngle)
        }
        guard let symbol = appearance.symbol,
              let base = NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue) else { return nil }
        return tint(base.withSymbolConfiguration(cfg) ?? base, color: appearance.color)
    }

    private func sessionItem(name: String, status: SessionStatus, pid: Int32?, duration: String) -> NSMenuItem {
        let appearance = statusAppearance(for: status)
        let title = duration.isEmpty ? name : "\(name)  ·  \(duration)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let cfg = NSImage.SymbolConfiguration(pointSize: menuMarkPointSize, weight: .regular)
        if status == .busy {
            // The same ring the menubar's title and the island draw, as a menu-item image.
            item.image = IslandRing.image(pointSize: menuMarkPointSize, angle: runningMarkAngle)
        } else if let symbol = appearance.symbol,
                  let base = NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue) {
            item.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: appearance.color)
        }
        item.isEnabled = true
        item.target = self
        item.action = #selector(focusSessionFromMenu(_:))
        item.representedObject = pid.map { NSNumber(value: $0) }
        return item
    }

    @MainActor @objc private func focusSessionFromMenu(_ sender: NSMenuItem) {
        let pid = (sender.representedObject as? NSNumber)?.int32Value
        monitor.focusSession(pid: pid)
    }

    private func showBubble(status: SessionStatus, projectDir: String, pid: Int32?, title: String?) {
        let name = displayName(for: projectDir)
        let statusWord: String
        let color: NSColor
        let symbol: String
        switch status {
        case .idle:
            statusWord = "Ready"
            color = .systemGreen
            symbol = "checkmark.circle.fill"
        case .waiting:
            statusWord = "Needs input"
            color = .systemBlue
            symbol = "questionmark.circle.fill"
        default:
            return
        }
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (showSessionTitles && !trimmedTitle.isEmpty) ? trimmedTitle : statusWord
        // Which surface carries the reminder is a chain, not two independent
        // switches: the bubble when it is on, otherwise the island, otherwise
        // nothing (the system notification from SessionMonitor still lands).
        // The icon bounce exists only to draw the eye to the bubble, so with the
        // bubble off it would point at nothing; gating it here keeps the two from
        // ever disagreeing.
        if bubbleEnabled {
            bounceIcon()
            bubble.show(anchor: statusItem.button, title: name, body: body, color: color, symbol: symbol, background: bubbleColor.color, positions: Array(bubblePositions), seconds: TimeInterval(bubbleSeconds)) { [weak self] in
                self?.monitor.focusSession(pid: pid)
            }
        } else if islandEnabled {
            // The island takes over: it opens itself on the transition and folds
            // back after the same number of seconds the bubble would have stayed
            // up, so the two surfaces read as one reminder at two durations. The
            // island is a `@MainActor` type and this runs on the transition
            // callback, so the push hops explicitly — the same shape as `render`'s
            // island push.
            let kind: IslandAlertKind = status == .waiting ? .waiting : .ready
            let seconds = TimeInterval(bubbleSeconds)
            // `name` is the folder's display name, which is also what `dismissReminders` matches on when
            // the reminder's reason goes away — the same key the bubble uses.
            Task { @MainActor [island] in island?.alert(name: name, kind: kind, pid: pid, seconds: seconds) }
        }
        // "Alert sound" is its own setting and is not owned by either surface: it
        // rings whenever one of them is going to show something. `.off` is the
        // default, so a user who never picked a sound is unaffected.
        if bubbleEnabled || islandEnabled {
            alertSound.play()
        }
    }

    /// The reason for a reminder is gone: the user answered the prompt, or the session went back to work
    /// (`SessionMonitor.onDismiss`, which fires for exactly those two, plus a session that disappears).
    /// Both surfaces are dismissed by the **same key** — the folder's display name — because that is what
    /// the callback carries, and the two reminders are the same event reported twice.
    private func dismissReminders(projectDir: String) {
        let name = displayName(for: projectDir)
        bubble.dismiss(ifShowing: name)
        // The island retracts its own way: it hands the card back to its hover machine rather than folding
        // it (an unattended card closes on the ordinary hover deadline, a card the user is pointing at
        // stays up), and it only touches a panel whose armed alert is this one. It is a `@MainActor` type
        // and this runs on the monitor's callback, so the push hops explicitly — the same shape as the
        // alert push in `showBubble`.
        Task { @MainActor [island] in island?.dismissAlert(named: name) }
    }

    private func bounceIcon() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.15, 0.95, 1.05, 1.0]
        bounce.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        bounce.duration = 0.6
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(bounce, forKey: "bubbleBounce")
    }

    func menuWillOpen(_ menu: NSMenu) {
        bubble.stopPulsing()
        island.collapse()
        render(currentState, forceMenuRefresh: true)
    }

    private func displayName(for dir: String) -> String {
        guard !dir.isEmpty && dir != "/" else { return "OpenCode" }
        return URL(fileURLWithPath: dir).lastPathComponent
    }

    private func tint(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSGraphicsContext.current?.compositingOperation = .sourceAtop
            color.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
    }
}
