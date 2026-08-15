import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: SessionMonitor!
    private var menu: NSMenu!
    private var lastSessions: [SessionInfo]? = nil
    private var currentState = AppState()
    private let projectsShownKey = "ocbar.projectsShown"
    private let defaultProjectsShown = 4

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu

        monitor = SessionMonitor { [weak self] state in
            self?.render(state)
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
                let attachment = NSTextAttachment()
                attachment.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: appearance.color)
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
