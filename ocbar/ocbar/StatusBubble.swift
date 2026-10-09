import AppKit

/// Where the bubble is placed on screens other than the one hosting the
/// menubar icon (the anchor screen always anchors to the icon itself).
enum BubblePosition: String, CaseIterable {
    case topCenter
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var displayName: String {
        switch self {
        case .topCenter: return "Top center"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// Notification-style card shown near the ocbar menubar icon when a session
/// changes status. Shown on every connected screen, since the menubar icon
/// itself is only visible on whichever screen currently hosts the system menu bar.
class StatusBubble {
    private struct PanelKey: Hashable {
        let screen: ObjectIdentifier
        let position: BubblePosition?
    }

    private var panels: [PanelKey: NSPanel] = [:]
    private var bubbles: [PanelKey: BubbleView] = [:]
    private var icons: [PanelKey: NSImageView] = [:]
    private var titles: [PanelKey: NSTextField] = [:]
    private var bodies: [PanelKey: NSTextField] = [:]
    private var dismissWork: DispatchWorkItem?
    private let bounceClearance: CGFloat = 6

    func show(anchor: NSView?, title: String, body: String, color: NSColor, symbol: String, background: NSColor, positions: [BubblePosition], seconds: TimeInterval) {
        dismissWork?.cancel()

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let anchorScreen = anchor?.window?.screen
        let anchorFrame: NSRect? = {
            guard let anchor, let anchorWindow = anchor.window else { return nil }
            return anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        }()

        var activeKeys: Set<PanelKey> = []

        for screen in screens {
            let screenId = ObjectIdentifier(screen)
            let isAnchorScreen = screen == anchorScreen && anchorFrame != nil

            let keys: [PanelKey] = isAnchorScreen
                ? [PanelKey(screen: screenId, position: nil)]
                : positions.map { PanelKey(screen: screenId, position: $0) }

            for key in keys {
                activeKeys.insert(key)
                let panel = panels[key] ?? makePanel(for: key)
                guard let icon = icons[key], let titleLabel = titles[key], let bodyLabel = bodies[key], let bubble = bubbles[key] else { continue }
                icon.image = iconImage(symbol: symbol, color: color)
                let (primary, secondary) = textColors(for: background)
                titleLabel.stringValue = title
                titleLabel.textColor = primary
                bodyLabel.stringValue = body
                bodyLabel.textColor = secondary
                if bubble.background != background {
                    bubble.background = background
                    bubble.needsDisplay = true
                }

                let panelSize = panel.frame.size
                var x: CGFloat
                let y: CGFloat
                if key.position == nil, let anchorFrame {
                    x = anchorFrame.midX - panelSize.width / 2
                    y = anchorFrame.minY - panelSize.height - bounceClearance
                } else {
                    let position = key.position ?? .topCenter
                    switch position {
                    case .topCenter:
                        x = screen.visibleFrame.midX - panelSize.width / 2
                        y = screen.visibleFrame.maxY - panelSize.height - bounceClearance
                    case .topLeft:
                        x = screen.visibleFrame.minX + 8
                        y = screen.visibleFrame.maxY - panelSize.height - bounceClearance
                    case .topRight:
                        x = screen.visibleFrame.maxX - panelSize.width - 8
                        y = screen.visibleFrame.maxY - panelSize.height - bounceClearance
                    case .bottomLeft:
                        x = screen.visibleFrame.minX + 8
                        y = screen.visibleFrame.minY + 8
                    case .bottomRight:
                        x = screen.visibleFrame.maxX - panelSize.width - 8
                        y = screen.visibleFrame.minY + 8
                    }
                }
                x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - panelSize.width - 8)
                panel.setFrameOrigin(NSPoint(x: x, y: y))

                panel.alphaValue = 0
                panel.orderFrontRegardless()

                guard let contentView = panel.contentView else { continue }
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

                let bounce = CABasicAnimation(keyPath: "transform.translation.y")
                bounce.fromValue = 0
                bounce.toValue = 6
                bounce.duration = 0.6
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bounce.beginTime = CACurrentMediaTime() + 0.35
                contentView.layer?.add(bounce, forKey: "bubblePulse")
            }
        }

        // Screens/positions no longer active this call (e.g. user reduced the
        // selected position set) — hide their stale panels immediately.
        for (key, panel) in panels where !activeKeys.contains(key) {
            panel.orderOut(nil)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.dismissAll()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func stopPulsing() {
        for panel in panels.values {
            panel.contentView?.layer?.removeAnimation(forKey: "bubblePulse")
        }
    }

    private func dismissAll() {
        for panel in panels.values {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }

    private func dismissNow() {
        dismissWork?.cancel()
        dismissAll()
    }

    private func interact() {
        stopPulsing()
        dismissNow()
    }

    /// Label colors that stay legible on the chosen card background.
    private func textColors(for background: NSColor) -> (primary: NSColor, secondary: NSColor) {
        let rgb = background.usingColorSpace(.deviceRGB) ?? background
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        if luminance < 0.5 {
            return (.white, NSColor.white.withAlphaComponent(0.7))
        }
        return (NSColor.black.withAlphaComponent(0.85), NSColor.black.withAlphaComponent(0.55))
    }

    /// Small rounded app-icon tile: a soft tinted square with the status glyph.
    private func iconImage(symbol: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 34, height: 34)
        return NSImage(size: size, flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            color.withAlphaComponent(0.15).setFill()
            tile.fill()

            let cfg = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
            if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let glyph = self.tint(base.withSymbolConfiguration(cfg) ?? base, color: color)
                let origin = NSPoint(x: rect.midX - glyph.size.width / 2,
                                     y: rect.midY - glyph.size.height / 2)
                glyph.draw(in: NSRect(origin: origin, size: glyph.size))
            }
            return true
        }
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

    private func makePanel(for key: PanelKey) -> NSPanel {
        let cardWidth: CGFloat = 340
        let cardHeight: CGFloat = 64
        // Padding lets the card pop/bounce inside the window without being
        // clipped by the window's bounds.
        let padding: CGFloat = 10
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: cardWidth + padding * 2, height: cardHeight + padding * 2),
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

        panels[key] = panel
        guard let contentView = panel.contentView else { return panel }

        let bubble = BubbleView(frame: contentView.bounds.insetBy(dx: padding, dy: padding))
        bubble.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        bubble.onInteract = { [weak self] in self?.interact() }
        bubbles[key] = bubble
        contentView.addSubview(bubble)

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icons[key] = icon

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titles[key] = titleLabel

        let bodyLabel = NSTextField(labelWithString: "")
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .left
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodies[key] = bodyLabel

        bubble.addSubview(icon)
        bubble.addSubview(titleLabel)
        bubble.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 13),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
        return panel
    }
}

/// Rounded notification-style card: hosts the icon and text, handles click-to-dismiss.
private class BubbleView: NSView {
    var onInteract: (() -> Void)?
    var background: NSColor = .windowBackgroundColor

    override func mouseDown(with event: NSEvent) {
        onInteract?()
    }

    // Route every click to the card so clicking anywhere dismisses it, even on a label.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 16
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        background.withAlphaComponent(0.95).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}