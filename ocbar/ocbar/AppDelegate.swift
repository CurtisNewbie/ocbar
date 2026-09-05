import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: SessionMonitor!
    private var menu: NSMenu!
    private var lastSessions: [SessionInfo]? = nil
    private var currentState = AppState()
    private var bubble: StatusBubble!
    private let projectsShownKey = "ocbar.projectsShown"
    private let defaultProjectsShown = 4
    private let bubblePositionKey = "ocbar.bubblePosition"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu

        monitor = SessionMonitor { [weak self] state in
            self?.render(state)
        }
        bubble = StatusBubble()
        monitor.onTransition = { [weak self] status, dir in
            self?.showBubble(status: status, projectDir: dir)
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        monitor.start()
        render(AppState())
    }

    private func render(_ state: AppState, forceMenuRefresh: Bool = false) {
        guard let button = statusItem.button else { return }
        currentState = state

        let busyCount = state.sessions.filter { $0.status == .busy }.count
        let idleCount = state.sessions.filter { $0.status == .idle }.count
        let waitingCount = state.sessions.filter { $0.status == .waiting }.count
        let errorCount = state.sessions.filter { $0.status == .error }.count

        let color: NSColor
        let label: String

        if state.sessions.isEmpty {
            color = .secondaryLabelColor
            label = "No Opencode Session"
        } else if errorCount > 0 {
            color = .systemRed
            label = "\(errorCount) error"
        } else if waitingCount > 0 {
            color = .systemBlue
            label = busyCount > 0 ? "\(waitingCount) waiting · \(busyCount) busy" : "\(waitingCount) waiting"
        } else if idleCount > 0 && busyCount > 0 {
            color = .systemGreen
            label = "\(busyCount) busy · \(idleCount) idle"
        } else if idleCount > 0 {
            color = .systemGreen
            label = "\(idleCount) idle"
        } else {
            color = .systemOrange
            label = "\(busyCount) busy"
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
            button.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: color)
        }
        button.imagePosition = .imageLeft
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuBarFont(ofSize: 13)
        ]
        if (1...projectsShown).contains(state.sessions.count) {
            button.image = nil
            button.attributedTitle = sessionTitle(for: state.sessions, attributes: attrs)
        } else {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            button.image = nil
            if let base = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
                button.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: color)
            }
            button.imagePosition = .imageLeft
            button.attributedTitle = NSAttributedString(string: " \(label)", attributes: attrs)
        }

        let sessions = state.sessions
        guard forceMenuRefresh || sessions != lastSessions else { return }
        lastSessions = sessions

        menu.removeAllItems()
        if sessions.isEmpty {
            menu.addItem(menuLabel("No OpenCode sessions"))
        } else {
            for s in sessions {
                menu.addItem(sessionItem(name: sessionName(for: s), status: s.status))
            }
        }
        menu.addItem(.separator())
        menu.addItem(projectsShownMenu())
        menu.addItem(bubblePositionMenu())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ocbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var projectsShown: Int {
        guard let stored = UserDefaults.standard.object(forKey: projectsShownKey) as? Int,
              (1...10).contains(stored) else {
            return defaultProjectsShown
        }
        return stored
    }

    private func projectsShownMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for count in 1...10 {
            let item = NSMenuItem(title: "\(count)", action: #selector(projectsShownSelected(_:)), keyEquivalent: "")
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
        guard (1...10).contains(sender.tag) else { return }
        UserDefaults.standard.set(sender.tag, forKey: projectsShownKey)
        render(currentState, forceMenuRefresh: true)
    }

    private var bubblePosition: BubblePosition {
        guard let raw = UserDefaults.standard.string(forKey: bubblePositionKey),
              let position = BubblePosition(rawValue: raw) else { return .topCenter }
        return position
    }

    private func bubblePositionMenu() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, position) in BubblePosition.allCases.enumerated() {
            let item = NSMenuItem(title: position.displayName, action: #selector(bubblePositionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = position == bubblePosition ? .on : .off
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Bubble position", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    @objc private func bubblePositionSelected(_ sender: NSMenuItem) {
        let all = BubblePosition.allCases
        guard all.indices.contains(sender.tag) else { return }
        UserDefaults.standard.set(all[sender.tag].rawValue, forKey: bubblePositionKey)
        render(currentState, forceMenuRefresh: true)
    }

    private func menuLabel(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    private func sessionTitle(for sessions: [SessionInfo], attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        for (index, session) in sessions.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  ·  ", attributes: attributes))
            }

            let appearance = statusAppearance(for: session.status)
            if let base = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: session.status.rawValue) {
                let img = tint(base.withSymbolConfiguration(cfg) ?? base, color: appearance.color)
                let attachment = NSTextAttachment()
                attachment.image = img
                // Nudge down so glyph center aligns with text center (glyph sits ~1.84pt high otherwise)
                attachment.bounds = NSRect(x: 0, y: -1.84, width: img.size.width, height: img.size.height)
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " \(sessionName(for: session))", attributes: attributes))
        }

        return title
    }

    private func sessionName(for session: SessionInfo) -> String {
        let raw = URL(fileURLWithPath: session.projectDir).lastPathComponent
        return (session.projectDir.isEmpty || session.projectDir == "/") ? "port \(session.port)" : raw
    }

    private func statusAppearance(for status: SessionStatus) -> (symbol: String, color: NSColor) {
        switch status {
        case .busy:
            return ("circle.fill", .systemOrange)
        case .waiting:
            return ("questionmark.circle.fill", .systemBlue)
        case .idle:
            return ("checkmark.circle.fill", .systemGreen)
        case .error:
            return ("exclamationmark.triangle.fill", .systemRed)
        }
    }

    private func sessionItem(name: String, status: SessionStatus) -> NSMenuItem {
        let appearance = statusAppearance(for: status)
        let item = NSMenuItem(title: "\(name) — \(status.rawValue)", action: nil, keyEquivalent: "")
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let base = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: status.rawValue) {
            item.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: appearance.color)
        }
        item.isEnabled = true
        return item
    }

    private func showBubble(status: SessionStatus, projectDir: String) {
        let name = displayName(for: projectDir)
        let text: String
        let color: NSColor
        let symbol: String
        switch status {
        case .idle:
            text = "\(name) ready"
            color = .systemGreen
            symbol = "checkmark.circle.fill"
        case .waiting:
            text = "\(name) needs input"
            color = .systemBlue
            symbol = "questionmark.circle.fill"
        default:
            return
        }
        bounceIcon()
        bubble.show(anchor: statusItem.button, text: text, color: color, symbol: symbol, position: bubblePosition)
    }

    private func bounceIcon() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.5, 0.85, 1.2, 1.0]
        bounce.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        bounce.duration = 0.6
        bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(bounce, forKey: "bubbleBounce")
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
