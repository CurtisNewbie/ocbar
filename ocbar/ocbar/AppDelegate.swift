import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitor: SessionMonitor!
    private var menu: NSMenu!
    private var lastSessions: [SessionInfo]? = nil

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

    private func render(_ state: AppState) {
        guard let button = statusItem.button else { return }

        let busyCount = state.sessions.filter { $0.status == .busy }.count
        let idleCount = state.sessions.filter { $0.status == .idle }.count
        let errorCount = state.sessions.filter { $0.status == .error }.count

        let color: NSColor
        let label: String

        if state.sessions.isEmpty {
            color = .secondaryLabelColor
            label = "oc"
        } else if errorCount > 0 {
            color = .systemRed
            label = "\(errorCount) error"
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
        button.attributedTitle = NSAttributedString(string: " \(label)", attributes: attrs)

        let sessions = state.sessions
        guard sessions != lastSessions else { return }
        lastSessions = sessions

        menu.removeAllItems()
        if sessions.isEmpty {
            menu.addItem(menuLabel("No OpenCode sessions"))
        } else {
            for s in sessions {
                let raw = URL(fileURLWithPath: s.projectDir).lastPathComponent
                let name = (s.projectDir.isEmpty || s.projectDir == "/") ? "port \(s.port)" : raw
                menu.addItem(sessionItem(name: name, status: s.status))
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ocbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func menuLabel(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    private func sessionItem(name: String, status: SessionStatus) -> NSMenuItem {
        let symbol: String
        let color: NSColor
        switch status {
        case .busy:
            symbol = "circle.fill"
            color = .systemOrange
        case .idle:
            symbol = "checkmark.circle.fill"
            color = .systemGreen
        case .error:
            symbol = "exclamationmark.triangle.fill"
            color = .systemRed
        }
        let item = NSMenuItem(title: "\(name) — \(status.rawValue)", action: nil, keyEquivalent: "")
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue) {
            item.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: color)
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
