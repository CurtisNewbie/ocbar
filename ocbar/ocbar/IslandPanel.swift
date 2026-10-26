import AppKit

/// One line in the island's expanded list.
struct IslandRow {
    let name: String
    let status: SessionStatus
    let duration: String
    let pid: Int32?
}

/// CodeIsland-style "Dynamic Island" surface: a borderless, non-activating
/// panel pinned to the very top edge of the target screen. Collapsed it hides
/// inside the notch (or in a small pill on notch-less displays) and shows one
/// small status dot per session; on hover it drops an expanded card listing
/// every session.
///
/// Everything is drawn black-and-white regardless of the system appearance,
/// because the collapsed pill stands in for the physical notch.
@MainActor
final class IslandPanel {

    // MARK: - Public API

    /// Fired with the clicked row's pid when a row is selected.
    var onSelectSession: (@MainActor (Int32?) -> Void)?

    /// Whether the card is currently in its expanded state.
    var isExpanded: Bool { expandedState }

    /// Push the current rows. Idempotent: identical content never restarts a
    /// transition nor resets hover state, so it is safe to call on every poll
    /// tick (~0.5s).
    func update(rows newRows: [IslandRow], enabled: Bool) {
        guard enabled, !newRows.isEmpty else {
            hide()
            return
        }
        ensurePanel()

        let signature = Self.signature(for: newRows)
        let contentChanged = signature != lastSignature
        rows = newRows
        if contentChanged {
            lastSignature = signature
            rebuildRows()
        }
        refreshCollapsed()

        if !visible {
            present()
        } else if contentChanged, expandedState, let metrics = currentMetrics() {
            // Row count moved while open: keep the top edge anchored and grow
            // the card downwards, without touching hover state.
            card?.contentTop = contentTop(for: metrics)
            card?.needsLayout = true
            animateFrame(to: frame(expanded: true, metrics: metrics))
        }
    }

    /// Force the card back to its collapsed state — the host calls this when
    /// the menubar menu opens, so the island never sits in the menu's way.
    func collapse() {
        setExpanded(false, animated: false)
    }

    // MARK: - Private state

    private var panel: NSPanel?
    private var card: IslandCardView?
    private var collapsedView: CollapsedContentView?
    private var rowViews: [IslandRowView] = []

    private var rows: [IslandRow] = []
    private var lastSignature: String?
    private var expandedState = false
    private var visible = false
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var hoverTimer: Timer?

    private let hoverDelay: TimeInterval = 0.35
    private let hoverInterval: TimeInterval = 0.15
    /// Downward slack on the collapsed hover rect so the pointer can travel
    /// from the pill into the growing card without a collapse being scheduled.
    private let hoverSlack: CGFloat = 6
    private let animationDuration: TimeInterval = 0.3
    private let expandedWidth: CGFloat = 340
    private let rowHeight: CGFloat = 30
    private let rowInset: CGFloat = 8
    private let bottomPadding: CGFloat = 8
    private let expandedCornerRadius: CGFloat = 18
    private let notchFlank: CGFloat = 30
    private let plainCollapsedWidth: CGFloat = 200
    private let plainCollapsedHeight: CGFloat = 24

    // swiftlint:disable:next line_length
    private static func signature(for rows: [IslandRow]) -> String {
        rows
            .map { "\($0.name)|\($0.status.rawValue)|\($0.duration)|\($0.pid.map { String($0) } ?? "-")" }
            .joined(separator: "\u{1}")
    }

    // MARK: - Screen metrics

    private struct ScreenMetrics {
        let screen: NSScreen
        let notched: Bool
        let notchWidth: CGFloat
        let topInset: CGFloat
    }

    /// Prefer a screen that actually has a notch; otherwise the main display.
    private static func targetScreen() -> NSScreen? {
        if #available(macOS 12.0, *) {
            if let notched = NSScreen.screens.first(where: {
                $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
            }) {
                return notched
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func currentMetrics() -> ScreenMetrics? {
        guard let screen = Self.targetScreen() else { return nil }
        var notched = false
        var notchWidth: CGFloat = 0
        var topInset: CGFloat = 0
        if #available(macOS 12.0, *) {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let width = right.minX - left.maxX
                if width > 8 {
                    notched = true
                    notchWidth = width
                    // The notch height is exactly the top safe-area inset.
                    topInset = max(screen.safeAreaInsets.top, plainCollapsedHeight)
                }
            }
        }
        return ScreenMetrics(screen: screen, notched: notched, notchWidth: notchWidth, topInset: topInset)
    }

    /// The collapsed pill: the notch itself (plus a small flank on each side so
    /// the aggregate is actually visible next to the physical cutout) on a
    /// notched display, or a compact centered pill elsewhere.
    private func collapsedSize(metrics: ScreenMetrics) -> NSSize {
        if metrics.notched {
            return NSSize(width: max(metrics.notchWidth + notchFlank * 2, 120), height: metrics.topInset)
        }
        return NSSize(width: plainCollapsedWidth, height: plainCollapsedHeight)
    }

    /// Where rows begin, so nothing hides under the notch.
    private func contentTop(for metrics: ScreenMetrics) -> CGFloat {
        metrics.notched ? metrics.topInset : rowInset
    }

    private func frame(expanded: Bool, metrics: ScreenMetrics) -> NSRect {
        let collapsed = collapsedSize(metrics: metrics)
        let size: NSSize
        if expanded {
            let height = contentTop(for: metrics) + CGFloat(max(rows.count, 1)) * rowHeight + bottomPadding
            size = NSSize(width: max(collapsed.width, expandedWidth), height: height)
        } else {
            size = collapsed
        }
        let screenFrame = metrics.screen.frame
        var x = screenFrame.midX - size.width / 2
        x = min(max(x, screenFrame.minX + 4), max(screenFrame.minX + 4, screenFrame.maxX - size.width - 4))
        let y = screenFrame.maxY - size.height
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private func cornerRadius(expanded: Bool, metrics: ScreenMetrics) -> CGFloat {
        let height = expanded ? frame(expanded: true, metrics: metrics).height : collapsedSize(metrics: metrics).height
        return expanded ? min(expandedCornerRadius, height / 2) : min(height / 2, 14)
    }

    // MARK: - Panel construction

    @discardableResult
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = makePanel()
        panel = created
        return created
    }

    private func makePanel() -> NSPanel {
        let panel = IslandWindow(
            contentRect: NSRect(x: 0, y: 0, width: plainCollapsedWidth, height: plainCollapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Always dark: the island stands in for the notch.
        panel.appearance = NSAppearance(named: .darkAqua)

        let card = IslandCardView(frame: NSRect(x: 0, y: 0, width: plainCollapsedWidth, height: plainCollapsedHeight))
        card.autoresizingMask = [.width, .height]
        card.wantsLayer = true
        card.rowHeight = rowHeight
        card.rowInset = rowInset
        card.onClick = { [weak self] in
            guard let self else { return }
            self.setExpanded(!self.expandedState, animated: true)
        }

        let collapsed = CollapsedContentView(frame: card.bounds)
        collapsed.autoresizingMask = [.width, .height]
        collapsed.flank = notchFlank
        card.addSubview(collapsed)

        panel.contentView = card
        self.card = card
        self.collapsedView = collapsed
        return panel
    }

    // MARK: - Content

    private func rebuildRows() {
        guard let card else { return }
        while rowViews.count < rows.count {
            let view = IslandRowView(frame: .zero)
            view.onSelect = { [weak self] pid in
                guard let self else { return }
                self.onSelectSession?(pid)
                self.setExpanded(false, animated: true)
            }
            card.addSubview(view)
            rowViews.append(view)
        }
        while rowViews.count > rows.count {
            rowViews.removeLast().removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            rowViews[index].configure(name: row.name, status: row.status, duration: row.duration, pid: row.pid)
        }
        card.rowViews = rowViews
        // New views start visible; keep them in step with the current state
        // without animating, so a poll tick never flashes the list.
        let alpha: CGFloat = expandedState ? 1 : 0
        for view in rowViews where view.alphaValue != alpha {
            view.alphaValue = alpha
        }
    }

    /// The collapsed pill's content: one status dot per session, most urgent
    /// first, rather than a single aggregate dot plus a bare count. The count
    /// was meaningless — the notch splits the pill in half, so the digit read
    /// as a stray number with no legend. A strip of coloured dots is countable
    /// on its own and the colour already carries the state.
    private func refreshCollapsed() {
        collapsedView?.sessionStatuses = rows.map(\.status)
    }

    // MARK: - Show / hide

    private func present() {
        guard let metrics = currentMetrics() else { return }
        let panel = ensurePanel()
        cancelPending()
        expandedState = false
        applyAppearance(expanded: false, metrics: metrics, animated: false)
        panel.setFrame(frame(expanded: false, metrics: metrics), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        visible = true
        startHoverTimer()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        cancelPending()
        stopHoverTimer()
        expandedState = false
        guard visible else { return }
        visible = false
        panel?.orderOut(nil)
        if let metrics = currentMetrics() {
            applyAppearance(expanded: false, metrics: metrics, animated: false)
        }
    }

    // MARK: - Expansion

    private func setExpanded(_ value: Bool, animated: Bool) {
        cancelPending()
        expandedState = value
        guard visible, let panel, let metrics = currentMetrics() else { return }
        applyAppearance(expanded: value, metrics: metrics, animated: animated)
        let target = frame(expanded: value, metrics: metrics)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animationDuration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// The window is sized to its visible bounds, so the same frame change that
    /// grows the capsule also governs hit-testing — no click monitor needed.
    private func applyAppearance(expanded: Bool, metrics: ScreenMetrics, animated: Bool) {
        guard let card, let collapsedView else { return }
        card.cornerRadius = cornerRadius(expanded: expanded, metrics: metrics)
        // Flush against the top edge: square top corners so the pill merges
        // with the notch / screen edge instead of showing a sliver behind it.
        card.squareTopCorners = metrics.notched
        card.contentTop = expanded ? contentTop(for: metrics) : rowInset
        card.rowViews = rowViews
        card.needsLayout = true

        collapsedView.notched = metrics.notched
        collapsedView.notchWidth = metrics.notchWidth
        collapsedView.flank = notchFlank

        let collapsedAlpha: CGFloat = expanded ? 0 : 1
        let rowsAlpha: CGFloat = expanded ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animationDuration * 0.7
                collapsedView.animator().alphaValue = collapsedAlpha
                for view in rowViews {
                    view.animator().alphaValue = rowsAlpha
                }
            }
        } else {
            collapsedView.alphaValue = collapsedAlpha
            for view in rowViews {
                view.alphaValue = rowsAlpha
            }
        }
    }

    private func animateFrame(to target: NSRect) {
        guard let panel, panel.frame != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Hover

    /// Poll the pointer against the island's *intended* rect instead of using a
    /// tracking area. The window frame animates, so a tracking area would be
    /// torn down and rebuilt on every step and synthesise bogus
    /// enter/exit pairs, which made the island oscillate while the pointer sat
    /// still. Reading `NSEvent.mouseLocation` against the target geometry is
    /// stable mid-transition.
    private func evaluateHover() {
        guard visible, let metrics = currentMetrics() else { return }
        if hoverRect(metrics: metrics).contains(NSEvent.mouseLocation) {
            scheduleExpand()
        } else {
            scheduleCollapse()
        }
    }

    /// Collapsed: the pill plus downward slack. Expanded: the expanded frame
    /// (which always contains the pill) so nothing is scheduled mid-transition.
    private func hoverRect(metrics: ScreenMetrics) -> NSRect {
        let rect = frame(expanded: expandedState, metrics: metrics)
        guard !expandedState else { return rect }
        return NSRect(x: rect.minX, y: rect.minY - hoverSlack, width: rect.width, height: rect.height + hoverSlack)
    }

    private func startHoverTimer() {
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.evaluateHover() }
        }
    }

    private func stopHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// The delays are one-shot. The hover poll re-runs every 0.15s, so a naive
    /// "cancel and reschedule" would push the 0.35s deadline back on every tick
    /// and the island would never actually expand or collapse.
    private func scheduleExpand() {
        collapseWork?.cancel()
        collapseWork = nil
        guard visible, !expandedState, expandWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setExpanded(true, animated: true)
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
    }

    private func scheduleCollapse() {
        expandWork?.cancel()
        expandWork = nil
        guard expandedState, collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setExpanded(false, animated: true)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
    }

    private func cancelPending() {
        expandWork?.cancel()
        expandWork = nil
        collapseWork?.cancel()
        collapseWork = nil
    }
}

// MARK: - Window

/// Non-key by construction: the island must never pull focus away from the
/// terminal it is reporting on, yet it still receives hover and click events.
private final class IslandWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Card

/// Draws the black capsule (radius per state) and owns click handling for the
/// whole surface. Hover is polled by `IslandPanel`, not tracked here.
private final class IslandCardView: NSView {
    var onClick: (@MainActor () -> Void)?
    var rowViews: [IslandRowView] = [] {
        didSet { needsLayout = true }
    }
    var rowHeight: CGFloat = 30
    var rowInset: CGFloat = 8
    var contentTop: CGFloat = 0 {
        didSet { if contentTop != oldValue { needsLayout = true } }
    }
    var cornerRadius: CGFloat = 12 {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }
    var squareTopCorners = false {
        didSet { if squareTopCorners != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    // Anything not claimed by a row toggles the island.
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Route every click explicitly: a visible row claims its own clicks, the
    // rest of the card claims the remainder (so clicks on the collapsed status
    // dots still toggle, without relying on responder-chain forwarding).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for view in rowViews.reversed() where view.alphaValue > 0.5 && view.frame.contains(local) {
            return view
        }
        return self
    }

    override func layout() {
        super.layout()
        let inset = rowInset
        let width = max(0, bounds.width - inset * 2)
        var y = contentTop
        for view in rowViews {
            view.frame = NSRect(x: inset, y: y, width: width, height: rowHeight)
            y += rowHeight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.94).setFill()
        path.fill()
        if squareTopCorners {
            // Flatten the top: merges with the notch / the screen's top edge.
            let strip = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: radius + 0.5)
            NSBezierPath(rect: strip).fill()
        } else {
            NSColor.white.withAlphaComponent(0.08).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius).stroke()
        }
    }
}

// MARK: - Collapsed content

/// The collapsed pill's content: one small status dot per session, split
/// across the two flanks of the physical cutout — the notch has no pixels, so
/// nothing may be drawn across the middle of the pill. Dots are ordered
/// most-urgent-first (error, waiting, idle, busy) so truncation drops the least
/// urgent, and a fifth slot is never needed: with more than four sessions the
/// last slot becomes a neutral ellipsis. Colour carries the state and the strip
/// is countable, so no legend and no digit are required.
private final class CollapsedContentView: NSView {
    /// The per-session statuses, in the order the panel reports them.
    var sessionStatuses: [SessionStatus] = [] {
        didSet { if sessionStatuses != oldValue { rebuildSlots() } }
    }
    var notched = false {
        didSet { if notched != oldValue { needsLayout = true } }
    }
    var notchWidth: CGFloat = 0 {
        didSet { if notchWidth != oldValue { needsLayout = true } }
    }
    var flank: CGFloat = 30

    /// Beyond this many sessions the last slot turns into an ellipsis.
    private static let maxSlots = 4
    private let slotSize: CGFloat = 9
    private let slotGap: CGFloat = 6

    /// `color == nil` means the slot is the ellipsis rather than a session.
    private struct Slot {
        let color: NSColor?
    }

    private var slots: [Slot] = []
    private var slotViews: [IslandDotView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Slots

    private func rebuildSlots() {
        let ordered = sessionStatuses.enumerated()
            .sorted { lhs, rhs in
                let a = Self.urgency(lhs.element)
                let b = Self.urgency(rhs.element)
                // Ties keep their incoming order, so the strip is stable while
                // statuses stay put and rows do not shuffle between poll ticks.
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map(\.element)

        // Three most urgent dots plus "…": the least urgent sessions are the
        // ones a fourth dot would have to drop anyway.
        let clipped = ordered.count > Self.maxSlots
        let shown = clipped ? Array(ordered.prefix(Self.maxSlots - 1)) : ordered
        var built = shown.map { Slot(color: Self.color(for: $0)) }
        if clipped { built.append(Slot(color: nil)) }
        slots = built

        while slotViews.count < built.count {
            let view = IslandDotView(frame: .zero)
            addSubview(view)
            slotViews.append(view)
        }
        while slotViews.count > built.count {
            slotViews.removeLast().removeFromSuperview()
        }
        for (view, slot) in zip(slotViews, built) {
            view.isEllipsis = slot.color == nil
            if let color = slot.color { view.dotColor = color }
        }
        needsLayout = true
    }

    /// Leftmost slot is the most urgent, so it survives truncation longest.
    private static func urgency(_ status: SessionStatus) -> Int {
        switch status {
        case .error: return 0
        case .waiting: return 1
        case .idle: return 2
        case .busy: return 3
        }
    }

    private static func color(for status: SessionStatus) -> NSColor {
        switch status {
        case .busy: return .systemOrange
        case .waiting: return .systemBlue
        case .idle: return .systemGreen
        case .error: return .systemRed
        }
    }

    override func layout() {
        super.layout()
        guard !slotViews.isEmpty else { return }

        // The pill is centred on the screen and so is the notch, so the two
        // visible flanks are treated as equal; the dots sit centred inside
        // them with a few points of clearance. Flush against the cutout would
        // clip the outermost dot on the right, which is the narrower flank.
        let split = notched && notchWidth > 0 && bounds.width > notchWidth + slotSize
        let leftCount = split ? (slotViews.count + 1) / 2 : slotViews.count
        let rightCount = split ? slotViews.count - leftCount : 0

        var origins: [CGFloat] = []
        if split {
            let regionWidth = max((bounds.width - notchWidth) / 2, flank)
            origins += slotOrigins(count: leftCount, regionOrigin: 0, regionWidth: regionWidth)
            origins += slotOrigins(
                count: rightCount,
                regionOrigin: regionWidth + notchWidth,
                regionWidth: regionWidth
            )
        } else {
            origins += slotOrigins(count: leftCount, regionOrigin: 0, regionWidth: bounds.width)
        }

        let y = bounds.midY - slotSize / 2
        for (index, view) in slotViews.enumerated() where index < origins.count {
            view.frame = NSRect(x: origins[index], y: y, width: slotSize, height: slotSize)
        }
    }

    /// Left edges of `count` equally spaced slots, centred within the region.
    private func slotOrigins(count: Int, regionOrigin: CGFloat, regionWidth: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let strip = CGFloat(count) * slotSize + CGFloat(count - 1) * slotGap
        let start = regionOrigin + (regionWidth - strip) / 2
        return (0..<count).map { start + CGFloat($0) * (slotSize + slotGap) }
    }
}

/// A single slot in the collapsed strip: a filled status dot, or the neutral
/// ellipsis shown when there are more sessions than slots. Draws itself so a
/// colour change needs no image.
private final class IslandDotView: NSView {
    var dotColor: NSColor = .systemGray {
        didSet { if dotColor != oldValue { needsDisplay = true } }
    }
    var isEllipsis = false {
        didSet { if isEllipsis != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEllipsis else {
            dotColor.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return
        }
        // Three tiny dots reading as "…" — a text glyph would be fussier at
        // this size and would not sit on the same optical baseline as the dots.
        NSColor.tertiaryLabelColor.setFill()
        let radius: CGFloat = 1.2
        let gap: CGFloat = 0.9
        let strip = radius * 6 + gap * 2
        var x = bounds.midX - strip / 2 + radius
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(
                x: x - radius,
                y: bounds.midY - radius,
                width: radius * 2,
                height: radius * 2
            )).fill()
            x += radius * 2 + gap
        }
    }
}

// MARK: - Row

/// One clickable session line: tinted status glyph, name, right-aligned age.
private final class IslandRowView: NSView {
    var onSelect: (@MainActor (Int32?) -> Void)?

    private let glyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var pid: Int32?
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        durationLabel.alignment = .right
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        addSubview(glyph)
        addSubview(nameLabel)
        addSubview(durationLabel)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 15),
            glyph.heightAnchor.constraint(equalToConstant: 15),

            nameLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            durationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(name: String, status: SessionStatus, duration: String, pid: Int32?) {
        self.pid = pid
        nameLabel.stringValue = name
        // An empty string collapses the field's intrinsic width, so the age is
        // genuinely omitted rather than left as a gap.
        durationLabel.stringValue = duration
        let appearance = Self.appearance(for: status)
        glyph.image = islandSymbolImage(symbol: appearance.symbol, color: appearance.color)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // Claim the click so it never bubbles up to the card's collapse toggle.
    override func mouseDown(with event: NSEvent) { onSelect?(pid) }

    // The panel is a non-key, non-activating window, so the first click would
    // otherwise be swallowed (delivered nowhere) instead of selecting the row.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.09).setFill()
        path.fill()
    }

    private static func appearance(for status: SessionStatus) -> (symbol: String, color: NSColor) {
        switch status {
        case .busy: return ("arrow.clockwise.circle.fill", .systemOrange)
        case .waiting: return ("questionmark.circle.fill", .systemBlue)
        case .idle: return ("checkmark.circle.fill", .systemGreen)
        case .error: return ("exclamationmark.triangle.fill", .systemRed)
        }
    }
}

// MARK: - Symbol helpers

private func islandSymbolImage(symbol: String, color: NSColor, pointSize: CGFloat = 13) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
    let configured = base.withSymbolConfiguration(config) ?? base
    return islandTinted(configured, color: color)
}

private func islandTinted(_ image: NSImage, color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        color.setFill()
        NSBezierPath(rect: rect).fill()
        return true
    }
}