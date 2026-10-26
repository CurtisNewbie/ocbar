import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: SessionMonitor!
    private var menu: NSMenu!
    private var lastSessions: [SessionInfo]? = nil
    private var currentState = AppState()
    private var bubble: StatusBubble!
    private var island: IslandPanel!
    private var spinnerTimer: Timer?
    private var spinnerAngle: CGFloat = 0
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
    private static let sessionMenuImageWidth: CGFloat = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let symbols = ["arrow.clockwise.circle.fill", "questionmark.circle.fill",
                       "checkmark.circle.fill", "exclamationmark.triangle.fill"]
        var widths = symbols.compactMap { symbol -> CGFloat? in
            guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
            return (img.withSymbolConfiguration(cfg) ?? img).size.width
        }
        // Busy rows use the spinner drawn on the checkmark canvas at pointSize 13.
        let spinCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
            widths.append((img.withSymbolConfiguration(spinCfg) ?? img).size.width)
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
        island = IslandPanel()
        island.onSelectSession = { [weak self] pid in
            self?.monitor.focusSession(pid: pid)
        }
        monitor.onTransition = { [weak self] status, dir, pid, title in
            self?.showBubble(status: status, projectDir: dir, pid: pid, title: title)
        }
        monitor.onDismiss = { [weak self] dir in
            self?.dismissBubble(projectDir: dir)
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        monitor.start()
        render(AppState())
    }

    private func render(_ state: AppState, forceMenuRefresh: Bool = false) {
        currentState = state
        updateButton(for: state)
        updateSpinner()
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

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuBarFont(ofSize: 13)
        ]

        let total = state.sessions.count
        var accessibility: String
        if total == 0 {
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
        } else if projectsShown == 0 {
            // No names at all: one glyph + count per status that has sessions.
            // Same status vocabulary the menu rows and the island use, and the
            // glyphs alone are otherwise invisible to VoiceOver.
            button.image = nil
            let built = aggregateTitle(for: state.sessions, attributes: attrs)
            busyTitleAttachments = built.busyAttachments
            currentButtonTitle = built.title
            button.attributedTitle = built.title
            accessibility = built.summary
        } else if total <= projectsShown {
            button.image = nil
            let built = sessionTitle(for: state.sessions, attributes: attrs)
            busyTitleAttachments = built.busyAttachments
            currentButtonTitle = built.title
            button.attributedTitle = built.title
            accessibility = spokenNames(for: state.sessions)
        } else {
            button.image = nil
            let built = foldedTitle(for: state.sessions, attributes: attrs)
            busyTitleAttachments = built.busyAttachments
            currentButtonTitle = built.title
            button.attributedTitle = built.title
            accessibility = spokenNames(for: state.sessions)
        }
        button.setAccessibilityLabel(accessibility)
    }

    private func updateSpinner() {
        let busy = currentState.sessions.contains { $0.status == .busy }
        if busy {
            guard spinnerTimer == nil else { return }
            let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                self?.tickSpinner()
            }
            RunLoop.main.add(timer, forMode: .common)
            spinnerTimer = timer
        } else if let timer = spinnerTimer {
            timer.invalidate()
            spinnerTimer = nil
            spinnerAngle = 0
        }
    }

    private func tickSpinner() {
        // Rotate clockwise to match the arrow's direction. 45° per 0.06s
        // tick keeps the apparent speed at ~750°/s while running ~16.7 fps.
        spinnerAngle = (spinnerAngle - 45).truncatingRemainder(dividingBy: 360)
        // Swap the busy glyphs inside the already-built title instead of
        // rebuilding the whole attributed string every frame.
        if !busyTitleAttachments.isEmpty, let title = currentButtonTitle {
            let img = busySpinnerImage(color: .systemOrange, pointSize: 11)
            for attachment in busyTitleAttachments {
                attachment.image = img
            }
            statusItem.button?.attributedTitle = title
        }
        for item in busyMenuItems {
            item.image = busySpinnerImage(color: .systemOrange, pointSize: 13)
        }
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

    private enum ContextDisplay: String, CaseIterable {
        case percent
        case tokens
        case both

        var displayName: String {
            switch self {
            case .percent: return "Percent"
            case .tokens: return "Tokens used"
            case .both: return "Percent + tokens"
            }
        }
    }

    private var contextUsageDisplay: ContextDisplay {
        guard let raw = UserDefaults.standard.string(forKey: contextUsageDisplayKey),
              let display = ContextDisplay(rawValue: raw) else { return .both }
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

        for (index, display) in ContextDisplay.allCases.enumerated() {
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
        let all = ContextDisplay.allCases
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
        // lands exactly under the session's name (busy rows use the spinner
        // canvas, other rows the status symbol at the row's point size).
        let badgeWidth: CGFloat
        if session.status == .busy {
            badgeWidth = Self.spinnerGeometry(pointSize: 13).canvas.width
        } else if let img = NSImage(systemSymbolName: statusAppearance(for: session.status).symbol, accessibilityDescription: nil) {
            badgeWidth = (img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) ?? img).size.width
        } else {
            badgeWidth = Self.sessionMenuImageWidth
        }

        let baseFont = NSFont.menuFont(ofSize: 0)
        let unknownAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        guard let context = session.context else {
            item.attributedTitle = NSAttributedString(string: "Context — no completed turn yet", attributes: unknownAttributes)
            item.image = contextDetailImage(glyph: nil, color: .tertiaryLabelColor, width: badgeWidth)
            return item
        }
        guard let limit = context.limit else {
            item.attributedTitle = NSAttributedString(string: "Context unknown — model limit unavailable", attributes: unknownAttributes)
            item.image = contextDetailImage(glyph: nil, color: .tertiaryLabelColor, width: badgeWidth)
            return item
        }

        let pct: Int
        if let fraction = context.fraction {
            pct = min(100, max(0, Int((fraction * 100).rounded())))
        } else {
            pct = min(100, max(0, Int((Double(context.used) / Double(limit) * 100).rounded())))
        }

        let bandColor: NSColor
        let bandGlyph: String?
        if pct >= contextUsageCritical {
            bandColor = .systemRed
            bandGlyph = "exclamationmark.octagon.fill"
        } else if pct >= contextUsageWarn {
            bandColor = .systemOrange
            bandGlyph = "exclamationmark.triangle.fill"
        } else {
            bandColor = .labelColor
            bandGlyph = nil
        }

        let tokensText = "\(compactTokens(context.used)) / \(compactTokens(limit)) tokens"
        let percentText = "\(pct)%"
        // Semibold percent is a redundant, colour-independent cue that only
        // applies inside a band (warn or critical).
        let inBand = bandGlyph != nil
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
        item.image = contextDetailImage(glyph: bandGlyph, color: bandColor, width: badgeWidth)
        return item
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

    /// Compact token formatter: `1_234 → "1.2k"`, `32_000 → "32k"`, ≥1M → `"1M"`.
    private func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if value >= 1_000 {
            let thousands = Double(value) / 1_000
            return thousands == thousands.rounded() ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
        }
        return "\(value)"
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

    /// Rows handed to the island: the same disambiguated names, status and age
    /// the dropdown uses, so the island and the menu tell the same story.
    private func islandRows(for sessions: [SessionInfo]) -> [IslandRow] {
        let nowMS = Date().timeIntervalSince1970 * 1000
        let names = disambiguatedNames(for: sessions)
        return sessions.map { session in
            IslandRow(
                name: names[session.id] ?? sessionName(for: session),
                status: session.status,
                duration: showSessionTime ? formatDurationLabel(sinceMS: session.createdAt, nowMS: nowMS) : "",
                pid: session.clientPID
            )
        }
    }

    private func menuLabel(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    private func sessionTitle(for sessions: [SessionInfo], attributes: [NSAttributedString.Key: Any]) -> (title: NSAttributedString, busyAttachments: [NSTextAttachment]) {
        let title = NSMutableAttributedString()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
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
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
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
            if let base = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: SessionStatus.idle.rawValue) {
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
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let title = NSMutableAttributedString()
        var busyAttachments: [NSTextAttachment] = []
        var spoken: [String] = []

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
            spoken.append("\(count) \(status.rawValue)")
        }

        return (title, busyAttachments, spoken.joined(separator: ", "))
    }

    /// VoiceOver text for the menubar item while it renders project names.
    private func spokenNames(for sessions: [SessionInfo]) -> String {
        let names = disambiguatedNames(for: sessions)
        return sessions.map { names[$0.id] ?? sessionName(for: $0) }.joined(separator: ", ")
    }

    private func sessionName(for session: SessionInfo) -> String {
        if !session.projectDir.isEmpty && session.projectDir != "/" {
            return URL(fileURLWithPath: session.projectDir).lastPathComponent
        }
        return session.id.isEmpty ? "session" : String(session.id.suffix(6))
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
        if showSessionTitles {
            let title = (session.sessionTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return truncated(title, limit: 24)
            }
        }
        let tail = session.id.suffix(6)
        return tail.isEmpty ? "session" : String(tail)
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func statusAppearance(for status: SessionStatus) -> (symbol: String, color: NSColor) {
        switch status {
        case .busy:
            return ("arrow.clockwise.circle.fill", .systemOrange)
        case .waiting:
            return ("questionmark.circle.fill", .systemBlue)
        case .idle:
            return ("checkmark.circle.fill", .systemGreen)
        case .error:
            return ("exclamationmark.triangle.fill", .systemRed)
        }
    }

    private func statusGlyphImage(appearance: (symbol: String, color: NSColor), status: SessionStatus, cfg: NSImage.SymbolConfiguration) -> NSImage? {
        guard let base = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: status.rawValue) else { return nil }
        let configured = base.withSymbolConfiguration(cfg) ?? base
        if status == .busy {
            return busySpinnerImage(color: appearance.color)
        }
        return tint(configured, color: appearance.color)
    }

    // The busy spinner is drawn as vector paths so it stays crisp at every angle.
    // A solid disc with a rotating gap keeps the same visual mass as the idle
    // check-circle (also a disc with a knocked-out mark) and matches its outer
    // diameter, so the running state reads as solid and bright as the green disc.
    private func busySpinnerImage(color: NSColor, pointSize: CGFloat = 11) -> NSImage {
        let geometry = Self.spinnerGeometry(pointSize: pointSize)
        let canvas = geometry.canvas
        let radius = geometry.diameter / 2
        return NSImage(size: canvas, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()

            // Knock out a rotating gap. spinnerAngle decreases each tick, which
            // is clockwise in this unflipped space, matching the arrow's
            // former direction.
            guard let ctx = NSGraphicsContext.current else { return true }
            ctx.compositingOperation = .clear
            let gap = NSBezierPath()
            gap.move(to: center)
            gap.appendArc(withCenter: center, radius: radius,
                          startAngle: self.spinnerAngle, endAngle: self.spinnerAngle - self.spinnerWedgeDegrees,
                          clockwise: true)
            gap.close()
            gap.fill()
            return true
        }
    }

    // Busy spinner geometry. The canvas matches the idle check-circle's symbol
    // image size so the attachment baseline offset is unchanged, and the disc's
    // outer diameter is matched to the green disc's circle. The wedge removes a
    // similar fraction of area as the checkmark does from the idle disc.
    private let spinnerWedgeDegrees: CGFloat = 70
    private static let spinnerOpticalScale: CGFloat = 1.0

    // Geometry is constant for a given (symbol, pointSize, weight), so the
    // expensive glyph measurement is memoized per pointSize instead of being
    // repeated every spinner frame.
    private static var spinnerGeometryCache: [CGFloat: (canvas: NSSize, diameter: CGFloat)] = [:]

    private static func spinnerGeometry(pointSize: CGFloat) -> (canvas: NSSize, diameter: CGFloat) {
        if let cached = spinnerGeometryCache[pointSize] { return cached }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let canvas = symbolImageSize("checkmark.circle.fill", cfg: cfg)
        let diameter = (visualGlyphDiameter(symbol: "checkmark.circle.fill", cfg: cfg) ?? 12) * spinnerOpticalScale
        let geometry = (canvas: canvas, diameter: diameter)
        spinnerGeometryCache[pointSize] = geometry
        return geometry
    }

    private static func symbolImageSize(_ symbol: String, cfg: NSImage.SymbolConfiguration) -> NSSize {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return NSSize(width: 14, height: 14)
        }
        return (base.withSymbolConfiguration(cfg) ?? base).size
    }

    // Diameter of a glyph's circle, measured from its opaque bounds so different
    // SF Symbols can be compared regardless of their image padding.
    private static func visualGlyphDiameter(symbol: String, cfg: NSImage.SymbolConfiguration) -> CGFloat? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let image = base.withSymbolConfiguration(cfg) ?? base
        let scale: CGFloat = 8
        let px = Int((max(image.size.width, image.size.height) * scale).rounded())
        guard px > 0,
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: px * px * 4)
        var minX = px, maxX = -1, minY = px, maxY = -1
        for y in 0..<px { for x in 0..<px where ptr[(y * px + x) * 4 + 3] > 128 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        } }
        guard maxX >= 0, maxY >= 0 else { return nil }
        return CGFloat(max(maxX - minX + 1, maxY - minY + 1)) / scale
    }

    private func sessionItem(name: String, status: SessionStatus, pid: Int32?, duration: String) -> NSMenuItem {
        let appearance = statusAppearance(for: status)
        let title = duration.isEmpty ? name : "\(name)  ·  \(duration)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if status == .busy {
            item.image = busySpinnerImage(color: appearance.color, pointSize: 13)
        } else if let base = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: status.rawValue) {
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
        bounceIcon()
        alertSound.play()
        bubble.show(anchor: statusItem.button, title: name, body: body, color: color, symbol: symbol, background: bubbleColor.color, positions: Array(bubblePositions), seconds: TimeInterval(bubbleSeconds)) { [weak self] in
            self?.monitor.focusSession(pid: pid)
        }
    }

    private func dismissBubble(projectDir: String) {
        bubble.dismiss(ifShowing: displayName(for: projectDir))
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
