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

    /// Tail direction for this placement: corner bubbles point toward the
    /// edge they are pinned to; top-center keeps the downward tail.
    fileprivate var tailDirection: BubbleView.TailDirection {
        switch self {
        case .topCenter: return .down
        case .topLeft, .bottomLeft: return .left
        case .topRight, .bottomRight: return .right
        }
    }
}

/// Speech-bubble attached below the ocbar menubar icon when a session changes status.
/// Shown on every connected screen, since the menubar icon itself is only
/// visible on whichever screen currently hosts the system menu bar.
class StatusBubble {
    private var panels: [ObjectIdentifier: NSPanel] = [:]
    private var labels: [ObjectIdentifier: NSTextField] = [:]
    private var bubbles: [ObjectIdentifier: BubbleView] = [:]
    private var labelCenters: [ObjectIdentifier: (x: NSLayoutConstraint, y: NSLayoutConstraint)] = [:]
    private var dismissWork: DispatchWorkItem?

    func show(anchor: NSView?, text: String, color: NSColor, symbol: String, position: BubblePosition) {
        dismissWork?.cancel()

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let anchorScreen = anchor?.window?.screen
        let anchorFrame: NSRect? = {
            guard let anchor, let anchorWindow = anchor.window else { return nil }
            return anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        }()

        for screen in screens {
            let key = ObjectIdentifier(screen)
            let panel = panels[key] ?? makePanel(for: screen)
            guard let label = labels[key], let bubble = bubbles[key] else { continue }
            label.attributedStringValue = attributedTitle(text: text, color: color, symbol: symbol)

            // Tail follows the bubble: down when anchored to the icon or
            // top-center; otherwise toward the corner it is pinned to.
            let isAnchorScreen = screen == anchorScreen && anchorFrame != nil
            let desiredDirection: BubbleView.TailDirection = isAnchorScreen ? .down : position.tailDirection
            if bubble.tailDirection != desiredDirection {
                bubble.tailDirection = desiredDirection
                bubble.needsDisplay = true
            }

            // Keep the label centered on the bubble body (the tail eats into
            // the view on the side it points to). The down-tail keeps its
            // original offset, which reads optically centered.
            if let centers = labelCenters[key] {
                switch desiredDirection {
                case .down:
                    centers.x.constant = 0
                    centers.y.constant = -BubbleView.tailHeight / 2
                case .right:
                    centers.x.constant = -BubbleView.tailHeight / 2
                    centers.y.constant = 0
                case .left:
                    centers.x.constant = BubbleView.tailHeight / 2
                    centers.y.constant = 0
                }
            }

            // On the screen hosting the status item, anchor below the icon.
            // On other screens (no visible icon there), use the configured position.
            let panelSize = panel.frame.size
            var x: CGFloat
            let y: CGFloat
            if isAnchorScreen, let anchorFrame {
                x = anchorFrame.midX - panelSize.width / 2
                y = anchorFrame.minY - panelSize.height - 4
            } else {
                switch position {
                case .topCenter:
                    x = screen.visibleFrame.midX - panelSize.width / 2
                    y = screen.visibleFrame.maxY - panelSize.height - 4
                case .topLeft:
                    x = screen.visibleFrame.minX + 8
                    y = screen.visibleFrame.maxY - panelSize.height - 4
                case .topRight:
                    x = screen.visibleFrame.maxX - panelSize.width - 8
                    y = screen.visibleFrame.maxY - panelSize.height - 4
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
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for panel in self.panels.values {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    panel.orderOut(nil)
                })
            }
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

    private func makePanel(for screen: NSScreen) -> NSPanel {
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

        let key = ObjectIdentifier(screen)
        panels[key] = panel

        guard let contentView = panel.contentView else { return panel }

        let bubble = BubbleView(frame: contentView.bounds)
        bubble.autoresizingMask = [.width, .height]
        bubbles[key] = bubble

        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        labels[key] = label

        bubble.addSubview(label)
        let centerX = label.centerXAnchor.constraint(equalTo: bubble.centerXAnchor)
        let centerY = label.centerYAnchor.constraint(equalTo: bubble.centerYAnchor, constant: -BubbleView.tailHeight / 2)
        let width = label.widthAnchor.constraint(lessThanOrEqualTo: bubble.widthAnchor, constant: -28)
        NSLayoutConstraint.activate([centerX, centerY, width])
        labelCenters[key] = (centerX, centerY)
        contentView.addSubview(bubble)
        return panel
    }
}

/// Rounded speech bubble with a tail. The tail points down (at the menubar
/// icon) or toward the screen edge the bubble is pinned to (left/right).
private class BubbleView: NSView {
    static let tailHeight: CGFloat = 9
    static let tailWidth: CGFloat = 18

    enum TailDirection {
        case down
        case left
        case right
    }

    var tailDirection: TailDirection = .down

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 12
        let path = NSBezierPath()

        switch tailDirection {
        case .down:
            let body = NSRect(x: 0, y: Self.tailHeight, width: bounds.width, height: bounds.height - Self.tailHeight)
            path.appendRoundedRect(body, xRadius: radius, yRadius: radius)
            let x = bounds.midX
            path.move(to: NSPoint(x: x - Self.tailWidth / 2, y: Self.tailHeight))
            path.line(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + Self.tailWidth / 2, y: Self.tailHeight))
        case .right:
            let body = NSRect(x: 0, y: 0, width: bounds.width - Self.tailHeight, height: bounds.height)
            path.appendRoundedRect(body, xRadius: radius, yRadius: radius)
            let y = bounds.midY
            path.move(to: NSPoint(x: bounds.width - Self.tailHeight, y: y - Self.tailWidth / 2))
            path.line(to: NSPoint(x: bounds.width, y: y))
            path.line(to: NSPoint(x: bounds.width - Self.tailHeight, y: y + Self.tailWidth / 2))
        case .left:
            let body = NSRect(x: Self.tailHeight, y: 0, width: bounds.width - Self.tailHeight, height: bounds.height)
            path.appendRoundedRect(body, xRadius: radius, yRadius: radius)
            let y = bounds.midY
            path.move(to: NSPoint(x: Self.tailHeight, y: y - Self.tailWidth / 2))
            path.line(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: Self.tailHeight, y: y + Self.tailWidth / 2))
        }
        path.close()

        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}