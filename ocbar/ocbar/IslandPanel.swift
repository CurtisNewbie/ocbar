import AppKit

/// One line in the island's expanded list.
struct IslandRow {
    let name: String
    let status: SessionStatus
    let duration: String
    let pid: Int32?
}

/// Width of each flank of the collapsed pill — the strips either side of the
/// physical cutout. Asymmetric on purpose: the right flank has to hold two
/// state groups, the left only one. Fixed, never derived from the content, so
/// the capsule cannot resize as statuses change.
private let islandLeftFlank: CGFloat = 41
private let islandRightFlank: CGFloat = 62

/// CodeIsland-style "Dynamic Island" surface: a borderless, non-activating
/// panel pinned to the very top edge of the target screen. Collapsed it hides
/// inside the notch (or in a small pill on notch-less displays) and carries two
/// self-explanatory readouts, one per flank: a dot with the number of running
/// sessions on the left, and the non-running states — up to two of them, most
/// urgent first — each with its own count on the right. On hover it drops an
/// expanded card listing every session.
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
        /// Left edge of the physical cutout, in screen coordinates. The pill is
        /// positioned from this rather than from the screen's midpoint: the
        /// flanks are asymmetric, so a centred pill would not line the cutout
        /// up with the notch.
        let notchOrigin: CGFloat
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
        var notchOrigin: CGFloat = 0
        var topInset: CGFloat = 0
        if #available(macOS 12.0, *) {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let width = right.minX - left.maxX
                if width > 8 {
                    notched = true
                    notchWidth = width
                    notchOrigin = left.maxX
                    // The notch height is exactly the top safe-area inset.
                    topInset = max(screen.safeAreaInsets.top, plainCollapsedHeight)
                }
            }
        }
        return ScreenMetrics(
            screen: screen,
            notched: notched,
            notchWidth: notchWidth,
            notchOrigin: notchOrigin,
            topInset: topInset
        )
    }

    /// The collapsed pill: the cutout flanked by a status strip on each side, so
    /// the readouts are actually visible next to the physical cutout. The flanks
    /// are deliberately asymmetric (`islandLeftFlank` / `islandRightFlank`) and
    /// the total is fixed, so the capsule never resizes as statuses change.
    private func collapsedSize(metrics: ScreenMetrics) -> NSSize {
        if metrics.notched {
            return NSSize(width: islandLeftFlank + metrics.notchWidth + islandRightFlank, height: metrics.topInset)
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
        var x: CGFloat
        if metrics.notched {
            // Anchor on the cutout, not the screen centre, so the cutout lands
            // exactly under the notch: the pill spans
            // `cutoutLeft - leftFlank … cutoutRight + rightFlank`, which puts
            // its left edge at exactly `notchOrigin - islandLeftFlank`. When the
            // card is expanded it is wider than the pill, so it is centred on
            // the cutout instead.
            if expanded {
                x = metrics.notchOrigin + metrics.notchWidth / 2 - size.width / 2
            } else {
                x = metrics.notchOrigin - islandLeftFlank
            }
        } else {
            x = screenFrame.midX - size.width / 2
        }
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
        collapsed.wantsLayer = true
        // Two two-digit counts are wider than the right flank, so the strip can
        // legitimately be asked for more room than it has. This mask stops the
        // rare overflow from painting past the capsule's edge; the strip itself
        // is positioned to stay clear of the cutout.
        collapsed.layer?.masksToBounds = true
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

    /// The collapsed pill's two readouts: how many sessions are running (left)
    /// and which non-running states need attention (right). Left answers "how
    /// many are working", right answers "what needs me": each distinct
    /// non-running state gets its own tinted glyph and count, most urgent first,
    /// up to the two the flank can hold. Cheap: the collapsed view relayouts
    /// only when a count or one of the shown states changes.
    private func refreshCollapsed() {
        var busy = 0
        var waiting = 0
        var idle = 0
        var errors = 0
        for row in rows {
            switch row.status {
            case .busy: busy += 1
            case .waiting: waiting += 1
            case .idle: idle += 1
            case .error: errors += 1
            }
        }
        collapsedView?.busyCount = busy
        collapsedView?.attentions = Self.attentionStates(errors: errors, waiting: waiting, idle: idle)
    }

    /// The right flank's groups, ranked error > waiting > idle. The flank holds
    /// two, so the least urgent state beyond that is dropped — with an error, a
    /// waiting and a finished session the pill shows `! n ? m` and only the
    /// finished count goes. Dropping is deliberate and is the whole point: a
    /// single rolled-up count would misreport the state, and spending a group on
    /// an ellipsis would hide one state to say nothing about another.
    private static func attentionStates(
        errors: Int,
        waiting: Int,
        idle: Int
    ) -> [CollapsedContentView.Attention] {
        var states: [CollapsedContentView.Attention] = []
        if errors > 0 { states.append(.init(status: .error, count: errors)) }
        if waiting > 0 { states.append(.init(status: .waiting, count: waiting)) }
        if idle > 0 { states.append(.init(status: .idle, count: idle)) }
        return Array(states.prefix(CollapsedContentView.maxAttentionGroups))
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

/// The collapsed pill's content, split across the two flanks of the physical
/// cutout — the notch has no pixels, so nothing may be drawn across the middle
/// of the pill. The left flank carries one small, self-explanatory group: a
/// filled orange dot plus the number of *running* (busy) sessions. The right
/// flank carries the *non-running* states, each as a tinted glyph plus its own
/// count, up to two of them side by side. Left answers "how many are working",
/// right answers "what needs me"; a bare digit was meaningless, the marker is
/// what gives it meaning.
private final class CollapsedContentView: NSView {

    /// How many non-busy state groups the right flank shows at once. The flank
    /// is only 62pt wide; beyond this the caller drops the least urgent state.
    static let maxAttentionGroups = 2

    /// One non-busy state on show, with its own count.
    struct Attention: Equatable {
        let status: SessionStatus
        let count: Int
    }

    /// Busy sessions counted on the left flank. Zero hides the whole group.
    var busyCount: Int = 0 {
        didSet {
            guard busyCount != oldValue else { return }
            leftGroup.number = busyCount
            leftGroup.isHidden = busyCount == 0
            needsLayout = true
        }
    }

    /// The non-busy states on the right flank, most urgent first, at most
    /// `maxAttentionGroups` of them. Empty (nothing non-busy) hides the whole
    /// side — the "quiet while working" case.
    var attentions: [Attention] = [] {
        didSet {
            guard attentions != oldValue else { return }
            applyAttentions()
            needsLayout = true
        }
    }

    var notched = false {
        didSet { if notched != oldValue { needsLayout = true } }
    }
    var notchWidth: CGFloat = 0 {
        didSet { if notchWidth != oldValue { needsLayout = true } }
    }

    /// Space between two groups in a flank. A group's own marker-to-number gap
    /// is 4.5pt; this has to read as a stronger separation. Six is the widest
    /// that still leaves the required 2pt clearance from each flank edge when
    /// both groups hold one digit (the flank's 62pt minus two 26pt groups leaves
    /// 10pt to share between the gap and the two clearances).
    private let groupGap: CGFloat = 6

    /// Clearance kept between the drawn content and each edge it sits near —
    /// the cutout edge and the capsule edge.
    private let minFlankClearance: CGFloat = 2

    private let leftGroup = IslandMarkerGroup(frame: .zero)
    private let rightGroups = (0..<CollapsedContentView.maxAttentionGroups)
        .map { _ in IslandMarkerGroup(frame: .zero) }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        leftGroup.marker = .dot(.systemOrange)
        leftGroup.isHidden = true
        addSubview(leftGroup)
        for group in rightGroups {
            group.isHidden = true
            addSubview(group)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func applyAttentions() {
        for (index, group) in rightGroups.enumerated() {
            guard index < attentions.count else {
                group.isHidden = true
                continue
            }
            let attention = attentions[index]
            group.number = attention.count
            if let image = islandSymbolImage(
                symbol: Self.symbol(for: attention.status),
                color: Self.color(for: attention.status),
                pointSize: 11
            ) {
                group.marker = .glyph(image)
            }
            group.isHidden = false
        }
    }

    private static func symbol(for status: SessionStatus) -> String {
        switch status {
        case .busy: return "arrow.clockwise.circle.fill"
        case .waiting: return "questionmark.circle.fill"
        case .idle: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
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
        if notched && notchWidth > 0 {
            // The window is positioned so the cutout's left edge sits exactly
            // `islandLeftFlank` in from the pill's left edge, which puts the
            // cutout at that same x here — no guessing from the view's centre.
            let cutoutStart = islandLeftFlank
            let cutoutEnd = cutoutStart + notchWidth
            if !leftGroup.isHidden {
                place([leftGroup], in: NSRect(x: 0, y: 0, width: cutoutStart, height: bounds.height))
            }
            let right = rightGroups.filter { !$0.isHidden }
            if !right.isEmpty {
                place(right, in: NSRect(x: cutoutEnd, y: 0, width: bounds.width - cutoutEnd, height: bounds.height))
            }
        } else {
            // No cutout: both sides simply sit together, centred in the pill.
            var groups: [IslandMarkerGroup] = []
            if !leftGroup.isHidden { groups.append(leftGroup) }
            groups.append(contentsOf: rightGroups.filter { !$0.isHidden })
            if !groups.isEmpty { place(groups, in: bounds) }
        }
    }

    /// Lay groups out left-to-right inside `region`, the block centred so both
    /// edges get the same clearance. When the block would eat into that
    /// clearance — two counts in the 62pt right flank can — the gap shrinks
    /// first, down to zero, before the clearance is allowed to give. If the
    /// groups are still wider than the region (two two-digit counts need 67pt)
    /// the block is clamped so its left edge stays on the region's edge and
    /// never crosses the cutout; the view masks its own bounds, so whatever is
    /// still past the far edge is trimmed there rather than painted over the
    /// capsule.
    private func place(_ groups: [IslandMarkerGroup], in region: NSRect) {
        let widths = groups.map { $0.groupWidth }
        let content = widths.reduce(0, +)
        var gap = groupGap
        if groups.count > 1 {
            gap = min(gap, max(0, region.width - content - minFlankClearance * 2))
        }
        let total = content + gap * CGFloat(groups.count - 1)
        let x = max(region.minX, min(region.minX + (region.width - total) / 2, region.maxX - total))
        var cursor = x
        for (index, group) in groups.enumerated() {
            group.frame = NSRect(
                x: cursor.rounded(),
                y: region.minY,
                width: widths[index],
                height: region.height
            )
            cursor += widths[index] + gap
        }
    }
}

/// One group in a flank of the collapsed pill: a small marker followed by the
/// number of sessions it counts. The left group's marker is a plain filled dot
/// — "how many are working" — while a right group's is a tinted SF Symbol —
/// "what needs me". The number uses tabular digits so the group's width does not
/// jitter as the count changes.
private final class IslandMarkerGroup: NSView {

    enum Marker {
        case empty
        case dot(NSColor)
        case glyph(NSImage)
    }

    var marker: Marker = .empty {
        didSet { applyMarker() }
    }
    var number: Int = 0 {
        didSet {
            guard number != oldValue else { return }
            numberLabel.stringValue = "\(number)"
            needsLayout = true
        }
    }

    private let dotDiameter: CGFloat = 8
    private let gap: CGFloat = 4.5

    private let numberLabel = NSTextField(labelWithString: "0")
    private let glyphView = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        numberLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        addSubview(numberLabel)
        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.isHidden = true
        addSubview(glyphView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Full width of the group: marker, gap, digits.
    var groupWidth: CGFloat {
        if case .empty = marker { return 0 }
        return markerWidth + gap + numberLabel.intrinsicContentSize.width
    }

    private var markerWidth: CGFloat {
        switch marker {
        case .empty: return 0
        case .dot: return dotDiameter
        case .glyph(let image): return image.size.width
        }
    }

    override func layout() {
        super.layout()
        let labelSize = numberLabel.intrinsicContentSize
        numberLabel.frame = NSRect(
            x: markerWidth + gap,
            y: (bounds.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        if case .glyph(let image) = marker {
            glyphView.frame = NSRect(
                x: 0,
                y: (bounds.height - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            )
        }
    }

    private func applyMarker() {
        switch marker {
        case .empty:
            glyphView.isHidden = true
        case .dot:
            glyphView.isHidden = true
            needsDisplay = true
        case .glyph(let image):
            glyphView.image = image
            glyphView.isHidden = false
        }
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard case .dot(let color) = marker else { return }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: 0,
            y: bounds.midY - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )).fill()
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