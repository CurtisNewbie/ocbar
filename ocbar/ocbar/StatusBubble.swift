import AppKit

/// Speech-bubble attached below the ocbar menubar icon when a session changes status.
class StatusBubble {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var dismissWork: DispatchWorkItem?

    func show(anchor: NSView?, text: String, color: NSColor, symbol: String) {
        guard let anchor, let anchorWindow = anchor.window else { return }

        dismissWork?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        guard let label else { return }
        label.attributedStringValue = attributedTitle(text: text, color: color, symbol: symbol)

        // Position below the status item, centered on it, clamped to screen edges.
        let panelSize = panel.frame.size
        let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var x = anchorFrame.midX - panelSize.width / 2
        let y = anchorFrame.minY - panelSize.height - 4
        if let screen = anchorWindow.screen ?? NSScreen.main {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - panelSize.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.7, 1.08, 0.96, 1.0]
        pop.keyTimes = [0, 0.6, 0.8, 1]
        pop.duration = 0.35
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentView.layer?.add(pop, forKey: "bubblePop")

        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func attributedTitle(text: String, color: NSColor, symbol: String) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let attachment = NSTextAttachment()
            attachment.image = tint(base.withSymbolConfiguration(cfg) ?? base, color: color)
            attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
            title.append(NSAttributedString(attachment: attachment))
        }
        title.append(NSAttributedString(string: "  \(text)", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: color
        ]))
        return title
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

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        guard let contentView = panel.contentView else { return panel }

        let bubble = BubbleView(frame: contentView.bounds)
        bubble.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        self.label = label

        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bubble.centerYAnchor, constant: -BubbleView.tailHeight / 2),
            label.widthAnchor.constraint(lessThanOrEqualTo: bubble.widthAnchor, constant: -28)
        ])
        contentView.addSubview(bubble)
        return panel
    }
}

/// Rounded bubble with a tail pointing up at the menubar icon.
private class BubbleView: NSView {
    static let tailHeight: CGFloat = 9
    static let tailWidth: CGFloat = 18

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: Self.tailHeight, width: bounds.width, height: bounds.height - Self.tailHeight)
        let radius: CGFloat = 12

        let path = NSBezierPath()
        path.appendRoundedRect(body, xRadius: radius, yRadius: radius)
        let midX = bounds.midX
        path.move(to: NSPoint(x: midX - Self.tailWidth / 2, y: Self.tailHeight))
        path.line(to: NSPoint(x: midX, y: 0))
        path.line(to: NSPoint(x: midX + Self.tailWidth / 2, y: Self.tailHeight))
        path.close()

        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}