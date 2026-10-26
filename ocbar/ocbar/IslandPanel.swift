import AppKit

/// One line in the island's expanded list.
struct IslandRow {
    /// The session's folder — its identity, shown first on line 1. Carries a
    /// short id tail only when two rows would otherwise be indistinguishable.
    let name: String
    /// The leading part of the session title, shown on its own line below the folder
/// name in the subordinate tone. Nil when titles are off or the session has none.
    let title: String?
    let status: SessionStatus
    let duration: String
    let pid: Int32?
    /// Context-window usage for this session, already resolved to the exact
    /// text/band the dropdown's detail row would show. Nil when the feature is
    /// off — the row then renders as a single line, exactly as before.
    let context: IslandContext?
}

/// The two text fields a row shows — the folder name on the row's first line and
/// the title on its own line below it. Kept apart so the row can set the title in
/// the subordinate tone and truncate it without touching the folder, and so the
/// two can never end up sharing a line.
struct IslandRowName: Equatable {
    let name: String
    let title: String?
}

/// Resolve the per-row fields for every session, keyed by session id.
///
/// Reuses the existing `ocbar.showSessionTitles` toggle rather than adding a
/// second switch. With it **off** this is exactly the old behaviour: the folder
/// name, plus a short id tail on collision, and no title. With it **on** a
/// session that has a title gets the title as its own field — it is never
/// appended inline to the folder name — and the id tail is kept only for
/// sessions that would *still* be indistinguishable (two sessions in one folder
/// showing the same title), so a title that already has its own line is never
/// also duplicated into the name as a disambiguator.
func islandRowNames(for sessions: [SessionInfo], showTitles: Bool) -> [String: IslandRowName] {
    // Two rows match when they agree on both fields, so the id tail is driven by
    // what is actually on screen.
    var occurrences: [String: Int] = [:]
    for session in sessions {
        let key = rowIdentityKey(
            folder: sessionFolderName(for: session),
            title: showTitles ? flattenedSessionTitle(session) : nil
        )
        occurrences[key, default: 0] += 1
    }

    var names: [String: IslandRowName] = [:]
    for session in sessions {
        let folder = sessionFolderName(for: session)
        let title = showTitles ? flattenedSessionTitle(session) : nil
        let collides = (occurrences[rowIdentityKey(folder: folder, title: title)] ?? 0) > 1
        let tail = session.id.suffix(6)
        let name = collides ? "\(folder) (\(tail.isEmpty ? "session" : String(tail)))" : folder
        names[session.id] = IslandRowName(name: name, title: title)
    }
    return names
}

private func rowIdentityKey(folder: String, title: String?) -> String {
    "\(folder)\u{1}\(title ?? "\u{0}")"
}

/// The island's rendering of one session's context usage. Built by the host
/// from the shared `ContextUsagePresentation`, so the dialect (thresholds,
/// display mode, placeholder wording) matches the menubar exactly; the island
/// only decides how to paint it on its dark card.
struct IslandContext: Equatable {
    /// Display-ready text: `6%`, `12k / 200k tokens`,
    /// `12k / 200k tokens · 6%`, or a placeholder sentence.
    let text: String
    /// Band glyph (SF Symbol name); nil out of band and for placeholders.
    let glyph: String?
    let band: ContextBand
}

/// Width of each flank of the collapsed pill — the strips either side of the
/// physical cutout. Asymmetric on purpose: the right flank holds two state
/// groups, the left one. Both are fixed at launch and independent of the session
/// counts, so the capsule never resizes as statuses change.
///
/// The right flank is exactly the least width that fits two glyph + two-digit
/// groups (`CollapsedContentView.requiredRightFlankWidth`), derived from the
/// glyph and number metrics the groups draw with rather than guessed. The left
/// holds a single dot group, which needs far less, so it is only widened to keep
/// the flanks' original 41:62 proportion — balance, not fit, and never wider
/// than the right.
///
/// Both flanks sit over the menubar strip either side of the cutout (menu titles
/// left, status items right), so every extra point covers more menubar: the
/// growth here is the minimum that makes two-digit counts readable, not slack.
private let islandRightFlank = CollapsedContentView.requiredRightFlankWidth
private let islandFlankBalance: CGFloat = 41.0 / 62.0
private let islandLeftFlank = (islandRightFlank * islandFlankBalance).rounded()

// Row geometry, shared by a session row and the folded `+k more` row so the two
// cannot drift apart.
private let islandRowLeadingInset: CGFloat = 10
private let islandRowTrailingInset: CGFloat = 10
private let islandRowGlyphSize: CGFloat = 15
private let islandRowGlyphGap: CGFloat = 8
/// x of a row's text column: past the leading inset, the status glyph and the
/// gap. Every line of a row starts here — the summary too, so `+k more` lands
/// under the session names rather than under their status glyphs.
private let islandRowTextInset = islandRowLeadingInset + islandRowGlyphSize + islandRowGlyphGap

// A row stacks up to three lines, always in this order:
//
//     folder name                      age
//     title
//     context usage
//
// The folder is always there; the title when the session has one; the context
// readout when that feature is on. Each line is a distinct concern, which is why
// the title moved off the folder's line: sharing it meant the folder and the
// title truncating each other.

/// Height of a one-line row — the original single-line row, unchanged.
let islandRowOneLineHeight: CGFloat = 30
/// What each extra line adds. The shipped pair was a 30pt one-line row and a
/// 44pt two-line row, i.e. +14 per line; extending by the same 14 gives 58 for
/// the full three-line row. The pitch below is wider than this because the added
/// lines also reclaim some of the row's padding, which is how the 30 → 44 step
/// already worked.
let islandRowHeightPerExtraLine: CGFloat = 14
/// Vertical pitch between a row's stacked lines, centre to centre — the
/// name↔context spacing that shipped (2 × the old 9pt line offset).
let islandRowLineStep: CGFloat = 18

/// Lines a row shows: the folder always, the title when there is one, the
/// context readout when that feature is on.
func islandRowLineCount(hasTitle: Bool, hasContext: Bool) -> Int {
    1 + (hasTitle ? 1 : 0) + (hasContext ? 1 : 0)
}

/// Height of a row showing that many lines. One source of truth for both the
/// card's layout and the height budget that decides how many rows fit.
func islandRowHeight(lines: Int) -> CGFloat {
    islandRowOneLineHeight + CGFloat(max(lines, 1) - 1) * islandRowHeightPerExtraLine
}

/// Height of a collapsed capsule on a display with no cutout, and the floor for
/// a notched pill's height. File-level because the notched/plain decision is
/// made in a static metrics helper as well as in the panel.
private let islandPlainCollapsedHeight: CGFloat = 24

/// Width the expanded card aims for, measured from the row's own fonts and the
/// real session titles on this machine (200 most recent), rather than guessed.
/// Of the three stacked lines the title is the binding one:
///
///  - line 1, folder + right-aligned age: the longest real folder
///    (`opencode-context-analysis-plugin`, 32 chars, 208pt at 12.5 medium) plus
///    the longest age (`12h30m`) needs a 304pt card; none of the 202 real folders
///    truncate from 420pt up, and 500 leaves a ~55-character folder box;
///  - line 3, the context readout at 11 regular: the longest string
///    (`Context unknown — model limit unavailable`, 227pt) needs 286pt;
///  - line 2, the title at 12.5 regular: this is what sets the number. Against
///    the real titles, 340 truncates 19 of 201 (9.5%), 400 truncates 5, 420
///    truncates 2 — and **500 truncates none**: its 441pt title box holds the
///    longest real title (71 characters, 430pt).
///
/// The card is the one surface with room to spare, so it is sized for the whole
/// real corpus rather than for the median (197pt) or the 90th percentile (279pt).
let islandExpandedCardTargetWidth: CGFloat = 500

/// Share of the target screen's width the card may take before it stops growing.
/// A guard rather than a live constraint here — it only binds on screens narrower
/// than ~625pt, and the attached displays are 1512pt and 1920pt.
private let expandedWidthFraction: CGFloat = 0.8

/// Width the expanded card takes on a screen `screenWidth` wide: the derived
/// target, bounded by `expandedWidthFraction` of the screen so a small display
/// degrades instead of overflowing, and never narrower than `floor` (the
/// collapsed capsule the card grows out of).
func islandExpandedCardWidth(screenWidth: CGFloat, floor: CGFloat) -> CGFloat {
    max(floor, min(islandExpandedCardTargetWidth, screenWidth * expandedWidthFraction))
}

/// Height budget for the expanded list. Pulled out of `IslandPanel` so the rule
/// lives in one small piece of maths that can be applied to any screen — the
/// notched built-in display or a plain one — without standing a panel up.
///
/// Rows no longer share one height (a row is as tall as the lines it shows), so
/// the count that fits is derived from the rows' *own* heights rather than from
/// a single row height.
struct IslandListBudget {
    /// The target screen's full frame (the card hangs from its top edge).
    let screenFrame: NSRect
    /// The target screen's usable frame, i.e. minus the menu bar and the Dock.
    let visibleFrame: NSRect
    /// Where the rows start, so nothing hides under the notch.
    let contentTop: CGFloat
    let bottomPadding: CGFloat
    let summaryRowHeight: CGFloat
    /// Tallest row in the list, so the budget can always hold one.
    let tallestRowHeight: CGFloat
    /// Share of the usable height the list may take.
    let fraction: CGFloat

    /// Points the visible session rows may use: the smaller of
    ///  - a share of the screen's usable height, so the card never takes over
    ///    the display even where there is room for it, and
    ///  - the distance from the top edge to the bottom of the usable area, less
    ///    the chrome and the summary row. The card hangs from the very top, so
    ///    this is the term that stops it running past the bottom of any screen
    ///    or over the Dock.
    /// The summary's height comes out of that *ceiling* but never out of the
    /// budget itself, so folding a list never costs a visible session row.
    var rowBudget: CGFloat {
        let soft = visibleFrame.height * fraction
        let hard = screenFrame.maxY - visibleFrame.minY - contentTop - bottomPadding - summaryRowHeight
        // Always leave room for the tallest row, so the card never comes up empty.
        return max(tallestRowHeight, min(soft, hard))
    }

    /// How many leading rows fit, walking the list and stopping at the first row
    /// that would overrun the budget. Rows are already ranked most-urgent-first,
    /// so the row that breaks the budget and everything after it folds. The
    /// first row is always taken, so a non-empty list can never render empty.
    func visibleCount(forRowHeights heights: [CGFloat]) -> Int {
        var used: CGFloat = 0
        var count = 0
        for height in heights {
            if count > 0, used + height > rowBudget { break }
            used += height
            count += 1
        }
        return count
    }

    /// Total card height for a set of visible rows. The card reports the same
    /// number from the views it holds, so frame and layout agree.
    func cardHeight(forRowHeights heights: [CGFloat], folded: Bool) -> CGFloat {
        var height = contentTop + heights.reduce(0, +)
        if folded { height += summaryRowHeight }
        return height + bottomPadding
    }

    /// Whether that card still clears the bottom of the usable area.
    func fits(forRowHeights heights: [CGFloat], folded: Bool) -> Bool {
        screenFrame.maxY - cardHeight(forRowHeights: heights, folded: folded) >= visibleFrame.minY
    }
}

/// CodeIsland-style "Dynamic Island" surface: a borderless, non-activating
/// panel pinned to the very top edge of **one** screen. Collapsed it hides
/// inside that screen's notch — or, on a display with no cutout, becomes a
/// top-centred stand-in capsule — and carries two self-explanatory readouts, one
/// per flank: a dot with the number of running sessions on the left, and the
/// non-running states — up to two of them, most urgent first — each with its own
/// count on the right. On hover it drops an expanded card listing every session.
///
/// One instance belongs to one `NSScreen`; `IslandHost` owns the set of them.
///
/// Everything is drawn black-and-white regardless of the system appearance,
/// because the collapsed pill stands in for the physical notch.
@MainActor
final class IslandPanel {

    /// The screen this island belongs to. Held for the panel's whole life: the
    /// host retires the panel if that screen goes away, so there is never a
    /// panel for a display that is gone.
    let screen: NSScreen

    init(screen: NSScreen) {
        self.screen = screen
    }

    // MARK: - Public API

    /// Fired with the clicked row's pid when a row is selected.
    var onSelectSession: (@MainActor (Int32?) -> Void)?

    /// Whether the card is currently in its expanded state.
    var isExpanded: Bool { expandedState }

    /// Retire this panel: off screen, timers stopped, window released. The host
    /// calls it when the display it belongs to is no longer attached.
    func retire() {
        hide()
        panel = nil
        card = nil
        collapsedView = nil
        rowViews = []
    }

    /// Push the current rows. Idempotent: identical content never restarts a
    /// transition nor resets hover state, so it is safe to call on every poll
    /// tick (~0.5s).
    func update(rows newRows: [IslandRow], enabled: Bool) {
        guard enabled, !newRows.isEmpty else {
            hide()
            return
        }
        ensurePanel()

        rows = newRows
        recomputeFold(metrics: currentMetrics())
        let signature = Self.signature(for: visibleRows, folded: foldedCount)
        let contentChanged = signature != lastSignature
        if contentChanged {
            lastSignature = signature
            rebuildRows()
        }
        refreshCollapsed()

        if !visible {
            present()
        } else if contentChanged, expandedState {
            // The fold moved while open: keep the top edge anchored and grow or
            // shrink the card downwards, without touching hover state.
            let metrics = currentMetrics()
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
    /// The prefix of `rows` that fits the height budget, and how many were
    /// folded into the summary. Both are recomputed every tick from the current
    /// screen, and are the single source of truth for the card's layout, the
    /// window frame and the summary text.
    private var visibleRows: [IslandRow] = []
    private var foldedCount = 0
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
    private let rowInset: CGFloat = 8
    private let bottomPadding: CGFloat = 8
    private let expandedCornerRadius: CGFloat = 18
    /// Fake-notch capsule width for a display with no cutout: a share of the
    /// screen's width, floored and capped so it stays a pill rather than a band.
    /// It sits top-centred over that strip of menubar by design — there is no
    /// cutout to hide inside and no attempt to dodge the menu-bar items.
    private func fakeNotchWidth(for screen: NSScreen) -> CGFloat {
        min(max(screen.frame.width * fakeNotchFraction, fakeNotchMinWidth), fakeNotchMaxWidth)
    }
    private let fakeNotchFraction: CGFloat = 0.14
    private let fakeNotchMinWidth: CGFloat = 160
    private let fakeNotchMaxWidth: CGFloat = 240
    /// Height of the inert `+k more` row that closes a folded list. Shorter than
    /// a session row on purpose: it is a footnote, not a session.
    private let summaryRowHeight: CGFloat = 24
    /// Share of the target screen's *usable* height the expanded list may take.
    /// The card is a glance, not a pane: 0.4 leaves 60% of the screen clear and,
    /// on the built-in display, holds the whole list in the common case and
    /// stops it once sessions pile up. The count is derived from each row's own
    /// height rather than hard-coded, so the one-line, two-line and three-line
    /// rows and the notch-less second display each get their own number.
    private let listHeightFraction: CGFloat = 0.4

    /// Height of the row `row` will render at, from the lines it will show.
    private static func rowHeight(for row: IslandRow) -> CGFloat {
        islandRowHeight(lines: islandRowLineCount(hasTitle: !(row.title ?? "").isEmpty,
                                                 hasContext: row.context != nil))
    }

    /// Signature of what is actually rendered: the visible rows plus how many
    /// were folded away. The folded count is part of it so folding or unfolding
    /// rebuilds the card — and, when it is open, resizes it.
    private static func signature(for rows: [IslandRow], folded: Int) -> String {
        let list = rows
            .map { row in
                let context = row.context.map { "\($0.text)|\($0.glyph ?? "-")|\($0.band.rawValue)" } ?? "-"
                return "\(row.name)|\(row.title ?? "-")|\(row.status.rawValue)|\(row.duration)|\(row.pid.map { String($0) } ?? "-")|\(context)"
            }
            .joined(separator: "\u{1}")
        return "\(folded)\u{2}\(list)"
    }

    /// `error < waiting < busy < idle`, mirroring `SessionMonitor.publish`'s
    /// order. Re-applied here, stably (so the incoming name/id order survives
    /// inside a rank), because the fold is only correct if the list really is
    /// ranked: folding the tail then provably drops idle rows before busy,
    /// waiting and error ones, so a folded count can never hide an error while
    /// an idle row stays on show.
    private static func attentionRanked(_ rows: [IslandRow]) -> [IslandRow] {
        rows.enumerated()
            .sorted { lhs, rhs in
                let leftRank = attentionRank(lhs.element.status)
                let rightRank = attentionRank(rhs.element.status)
                return leftRank != rightRank ? leftRank < rightRank : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    private static func attentionRank(_ status: SessionStatus) -> Int {
        switch status {
        case .error: return 0
        case .waiting: return 1
        case .busy: return 2
        case .idle: return 3
        }
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

    /// This panel's geometry, re-measured from its own screen on every use, so a
    /// resolution, Dock or menu-bar change is picked up without the host having
    /// to rebuild anything.
    private func currentMetrics() -> ScreenMetrics {
        Self.metrics(for: screen)
    }

    private static func metrics(for screen: NSScreen) -> ScreenMetrics {
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
                    topInset = max(screen.safeAreaInsets.top, islandPlainCollapsedHeight)
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

    /// The collapsed pill. On a notched display it is the cutout flanked by a
    /// status strip each side, so the readouts are actually visible next to the
    /// physical cutout — the flanks are deliberately asymmetric
    /// (`islandLeftFlank` / `islandRightFlank`) and the total is fixed, so the
    /// capsule never resizes as statuses change. A display with no cutout has
    /// nothing to flank, so the same content becomes one continuous top-centred
    /// capsule instead (`fakeNotchWidth`), with no gap to bridge.
    private func collapsedSize(metrics: ScreenMetrics) -> NSSize {
        if metrics.notched {
            return NSSize(width: islandLeftFlank + metrics.notchWidth + islandRightFlank, height: metrics.topInset)
        }
        return NSSize(width: fakeNotchWidth(for: metrics.screen), height: islandPlainCollapsedHeight)
    }

    /// Where rows begin, so nothing hides under the notch.
    private func contentTop(for metrics: ScreenMetrics) -> CGFloat {
        metrics.notched ? metrics.topInset : rowInset
    }

    /// The expanded card sizes itself from the content it actually holds — rows
    /// plus the folded summary — and `IslandCardView.layout()` positions those
    /// same views, so the window frame and the layout can never disagree. Its
    /// width is the derived target, bounded by the target screen.
    private func frame(expanded: Bool, metrics: ScreenMetrics) -> NSRect {
        let collapsed = collapsedSize(metrics: metrics)
        let size: NSSize
        if expanded {
            let height = card?.contentHeight
                ?? (contentTop(for: metrics) + islandRowOneLineHeight + bottomPadding)
            size = NSSize(width: expandedCardWidth(collapsedWidth: collapsed.width, metrics: metrics), height: height)
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
            // No cutout to anchor on: the card is centred on the screen, which
            // keeps it concentric with the stand-in capsule.
            x = screenFrame.midX - size.width / 2
        }
        // Both branches centre the card, and `expandedCardWidth` keeps it inside
        // `expandedWidthFraction` of the screen, so this is a plain clamp: the
        // upper bound can never fall below the lower one.
        x = min(max(x, screenFrame.minX + 4), screenFrame.maxX - size.width - 4)
        let y = screenFrame.maxY - size.height
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Width the expanded card takes, bounded by the target screen so a small
    /// display degrades instead of overflowing, and never narrower than the
    /// collapsed capsule.
    private func expandedCardWidth(collapsedWidth: CGFloat, metrics: ScreenMetrics) -> CGFloat {
        islandExpandedCardWidth(screenWidth: metrics.screen.frame.width, floor: collapsedWidth)
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
        let initial = collapsedSize(metrics: currentMetrics())
        let panel = IslandWindow(
            contentRect: NSRect(origin: .zero, size: initial),
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

        let card = IslandCardView(frame: NSRect(origin: .zero, size: initial))
        card.autoresizingMask = [.width, .height]
        card.wantsLayer = true
        card.rowHeight = islandRowOneLineHeight
        card.rowHeightPerExtraLine = islandRowHeightPerExtraLine
        card.rowInset = rowInset
        card.summaryRowHeight = summaryRowHeight
        card.bottomPadding = bottomPadding
        card.onClick = { [weak self] in
            guard let self else { return }
            self.setExpanded(!self.expandedState, animated: true)
        }

        let collapsed = CollapsedContentView(frame: card.bounds)
        collapsed.autoresizingMask = [.width, .height]
        collapsed.wantsLayer = true
        // The right flank is sized so two two-digit groups fit with clearance, but a
        // three-digit count (or a wider glyph) can still overrun it. This mask is
        // the backstop for that: the overflow is trimmed at the capsule's edge
        // rather than painted past it.
        collapsed.layer?.masksToBounds = true
        card.addSubview(collapsed)

        panel.contentView = card
        self.card = card
        self.collapsedView = collapsed
        return panel
    }

    // MARK: - List folding

    /// Split the (attention-ranked) list into what fits and what folds. Stored
    /// on the panel so the card, the window frame and the summary text all come
    /// from the same split. Each row contributes its own height, so a list of
    /// one-line rows shows more rows than a list of three-line ones.
    private func recomputeFold(metrics: ScreenMetrics) {
        let ranked = Self.attentionRanked(rows)
        let heights = ranked.map(Self.rowHeight(for:))
        let budget = listBudget(for: metrics, tallestRowHeight: heights.max() ?? islandRowOneLineHeight)
        visibleRows = Array(ranked.prefix(budget.visibleCount(forRowHeights: heights)))
        foldedCount = max(0, ranked.count - visibleRows.count)
    }

    /// The height budget for the current screen and row set.
    private func listBudget(for metrics: ScreenMetrics, tallestRowHeight: CGFloat) -> IslandListBudget {
        IslandListBudget(
            screenFrame: metrics.screen.frame,
            visibleFrame: metrics.screen.visibleFrame,
            contentTop: contentTop(for: metrics),
            bottomPadding: bottomPadding,
            summaryRowHeight: summaryRowHeight,
            tallestRowHeight: tallestRowHeight,
            fraction: listHeightFraction
        )
    }

    // MARK: - Content

    private func rebuildRows() {
        guard let card else { return }
        while rowViews.count < visibleRows.count {
            let view = IslandRowView(frame: .zero)
            view.onSelect = { [weak self] pid in
                guard let self else { return }
                self.onSelectSession?(pid)
                self.setExpanded(false, animated: true)
            }
            card.addSubview(view)
            rowViews.append(view)
        }
        while rowViews.count > visibleRows.count {
            rowViews.removeLast().removeFromSuperview()
        }
        for (index, row) in visibleRows.enumerated() {
            rowViews[index].configure(
                name: row.name,
                title: row.title,
                status: row.status,
                duration: row.duration,
                pid: row.pid,
                context: row.context
            )
        }
        card.rowViews = rowViews
        rebuildSummary(in: card)

        // New views start visible; keep them in step with the current state
        // without animating, so a poll tick never flashes the list.
        let alpha: CGFloat = expandedState ? 1 : 0
        for view in rowViews where view.alphaValue != alpha {
            view.alphaValue = alpha
        }
        if let summary = card.summaryView, summary.alphaValue != alpha {
            summary.alphaValue = alpha
        }
    }

    /// Add, refresh or drop the inert `+k more` row that closes a folded list.
    private func rebuildSummary(in card: IslandCardView) {
        guard foldedCount > 0 else {
            card.summaryView?.removeFromSuperview()
            card.summaryView = nil
            return
        }
        if let existing = card.summaryView {
            existing.foldedCount = foldedCount
        } else {
            let summary = IslandSummaryView(frame: .zero)
            summary.foldedCount = foldedCount
            card.addSubview(summary)
            card.summaryView = summary
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
        let metrics = currentMetrics()
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
        applyAppearance(expanded: false, metrics: currentMetrics(), animated: false)
    }

    // MARK: - Expansion

    private func setExpanded(_ value: Bool, animated: Bool) {
        cancelPending()
        expandedState = value
        guard visible, let panel else { return }
        let metrics = currentMetrics()
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
        let contentViews: [NSView] = card.summaryView.map { rowViews + [$0] } ?? rowViews
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animationDuration * 0.7
                collapsedView.animator().alphaValue = collapsedAlpha
                for view in contentViews {
                    view.animator().alphaValue = rowsAlpha
                }
            }
        } else {
            collapsedView.alphaValue = collapsedAlpha
            for view in contentViews {
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
        guard visible else { return }
        if hoverRect(metrics: currentMetrics()).contains(NSEvent.mouseLocation) {
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
    /// The inert `+k more` row, when the list was folded. Never part of
    /// `rowViews`: `hitTest` below only ever hands clicks to session rows, so a
    /// click on the summary falls through to the card's expand/collapse toggle
    /// like any other blank part of the card.
    var summaryView: IslandSummaryView? {
        didSet { needsLayout = true }
    }
    /// Height of a one-line row. A row is as tall as the lines it shows, so this is
/// the base: `rowHeight + (lines - 1) × rowHeightPerExtraLine`. The panel
/// injects the model's constants, so the card and the height budget agree.
    var rowHeight: CGFloat = 30 {
        didSet { if rowHeight != oldValue { needsLayout = true } }
    }
    /// What each stacked line beyond the first adds to that row.
    var rowHeightPerExtraLine: CGFloat = 14 {
        didSet { if rowHeightPerExtraLine != oldValue { needsLayout = true } }
    }
    /// Height of the summary row. The panel and the card share the number so the
    /// window frame and this layout cannot drift.
    var summaryRowHeight: CGFloat = 24 {
        didSet { if summaryRowHeight != oldValue { needsLayout = true } }
    }
    var rowInset: CGFloat = 8
    var bottomPadding: CGFloat = 8
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

    /// Height a row view needs, from the lines it currently shows.
    private func height(of view: IslandRowView) -> CGFloat {
        rowHeight + CGFloat(max(view.lineCount, 1) - 1) * rowHeightPerExtraLine
    }

    /// Height the card needs for the content it currently holds. The panel sizes
    /// the window from this and `layout()` positions the very same views with the
    /// same heights, so the two can never disagree — one source of truth for the
    /// expanded height. Empty rows fall back to a single-line row, as before.
    var contentHeight: CGFloat {
        let rowTotal = rowViews.isEmpty ? rowHeight : rowViews.reduce(0) { $0 + height(of: $1) }
        var total = contentTop + rowTotal
        if summaryView != nil { total += summaryRowHeight }
        return total + bottomPadding
    }

    // Anything not claimed by a row toggles the island.
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Route every click explicitly: a visible row claims its own clicks, the
    // rest of the card claims the remainder (so clicks on the collapsed status
    // dots still toggle, without relying on responder-chain forwarding). The
    // summary is deliberately not a candidate, so it stays inert as a row.
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
            // Each row is as tall as the lines it shows, so a list mixes heights.
            let h = height(of: view)
            view.frame = NSRect(x: inset, y: y, width: width, height: h)
            y += h
        }
        summaryView?.frame = NSRect(x: inset, y: y, width: width, height: summaryRowHeight)
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

    /// How many non-busy state groups the right flank shows at once. Beyond this the
    /// caller drops the least urgent state.
    static let maxAttentionGroups = 2

    /// Space between two groups in a flank. A group's own marker-to-number gap is
    /// 4.5pt, so this has to read as a stronger separation.
    static let groupGap: CGFloat = 6

    /// Clearance kept between the drawn content and each edge it sits near — the
    /// cutout edge and the capsule edge.
    static let minFlankClearance: CGFloat = 2

    /// Breathing room on top of that minimum, so two two-digit groups never sit
    /// flush against the flank's edges.
    static let flankMargin: CGFloat = 2

    /// Least width the right flank needs to show two glyph groups with two-digit
    /// counts, the full `groupGap` and the clearance on both sides. Derived from
    /// the same glyph and number metrics the groups draw with, so it cannot drift
    /// from them — and it is the *least* such width: a three-digit count would
    /// need `IslandMarkerGroup.widestGlyphWidth + markerGap + 3 digits` per group
    /// and would still clip here, which is the documented limit rather than
    /// something to over-provision for.
    static let requiredRightFlankWidth: CGFloat = {
        let group = IslandMarkerGroup.widestGlyphWidth
            + IslandMarkerGroup.markerGap
            + IslandMarkerGroup.twoDigitCountWidth
        return (2 * group + groupGap + 2 * minFlankClearance + flankMargin).rounded(.up)
    }()

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
    /// edges get the same clearance. The right flank is now sized so that cannot
    /// happen (see `requiredRightFlankWidth`), but the shrinking and clamping stay
    /// as a backstop: a three-digit count, or a wider glyph than today's, shrinks
    /// the gap first, down to zero, before the clearance is allowed to give. If
    /// the groups are still wider than the region the block is clamped so its
    /// left edge stays on the region's edge and never crosses the cutout; the view
    /// masks its own bounds, so whatever is still past the far edge is trimmed
    /// there rather than painted over the capsule.
    private func place(_ groups: [IslandMarkerGroup], in region: NSRect) {
        let widths = groups.map { $0.groupWidth }
        let content = widths.reduce(0, +)
        var gap = Self.groupGap
        if groups.count > 1 {
            gap = min(gap, max(0, region.width - content - Self.minFlankClearance * 2))
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

    /// The pill's number font and the two metrics the pill's own groups are
    /// measured with. Kept static so the flank widths (`islandLeftFlank` /
    /// `islandRightFlank`) can be derived from the very numbers that are drawn,
    /// instead of from a guess that could drift away from them.
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static let dotDiameter: CGFloat = 8
    static let markerGap: CGFloat = 4.5

    /// Width of a two-digit count at the width the cell needs to draw it unclipped
    /// — see `numberWidth`. `99` is the widest count the pill is provisioned for.
    static let twoDigitCountWidth: CGFloat = {
        let label = NSTextField(labelWithString: "99")
        label.font = numberFont
        return numberWidth(label)
    }()

    /// Width of the widest status glyph at the pill's point size, i.e. what a
    /// right-flank marker costs. Measured from the symbols the groups actually
    /// use, so it cannot go stale if a symbol's artwork changes.
    static let widestGlyphWidth: CGFloat = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let symbols = ["arrow.clockwise.circle.fill", "questionmark.circle.fill",
                       "checkmark.circle.fill", "exclamationmark.triangle.fill"]
        let widths = symbols.compactMap { name -> CGFloat? in
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
            return (base.withSymbolConfiguration(cfg) ?? base).size.width
        }
        return widths.max() ?? 14
    }()

    private let numberLabel = NSTextField(labelWithString: "0")
    private let glyphView = NSImageView()

    /// Width the number needs.
    ///
    /// `intrinsicContentSize` is the bare tabular advance, but the cell that
    /// draws the digit lays it out a couple of points in from the frame's edge
    /// and then **clips at that edge**, so a frame sized to the advance shaves
    /// the right side of every digit — the widest (`4`) draws out to 8.66pt in a
    /// 7.5pt advance — while `1` survives, its ink being only ~3.4pt wide. That
    /// is the "shaved 2" the maintainer saw, and it looks the same on both pills
    /// because it is the cell's own rendering, not the geometry.
    ///
    /// `cellSize` is the cell's answer for how wide it must be to draw this text
    /// unclipped; it also does not depend on the backing scale the way
    /// `intrinsicContentSize` does (7.5 at 2x, 8.0 at 1x), so the pill lays out
    /// identically on both displays.
    static func numberWidth(_ label: NSTextField) -> CGFloat {
        let unclipped = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 20)).width ?? 0
        return max(label.intrinsicContentSize.width, unclipped)
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        numberLabel.font = Self.numberFont
        numberLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        addSubview(numberLabel)
        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.isHidden = true
        addSubview(glyphView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Full width of the group: marker, gap, digits. The digits get the width the
    /// cell needs to draw them unclipped, not the bare advance (see `numberWidth`).
    var groupWidth: CGFloat {
        if case .empty = marker { return 0 }
        return markerWidth + Self.markerGap + Self.numberWidth(numberLabel)
    }

    private var markerWidth: CGFloat {
        switch marker {
        case .empty: return 0
        case .dot: return Self.dotDiameter
        case .glyph(let image): return image.size.width
        }
    }

    override func layout() {
        super.layout()
        let labelSize = numberLabel.intrinsicContentSize
        numberLabel.frame = NSRect(
            x: markerWidth + Self.markerGap,
            y: (bounds.height - labelSize.height) / 2,
            width: Self.numberWidth(numberLabel),
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
            y: bounds.midY - Self.dotDiameter / 2,
            width: Self.dotDiameter,
            height: Self.dotDiameter
        )).fill()
    }
}

// MARK: - Row

/// One clickable session row, stacking up to three lines:
///
///     folder name                      age
///     title
///     context usage
///
/// The folder is always there; the title when the session has one; the context
/// readout when that feature is on. A row is exactly as tall as the lines it
/// shows, so an absent line collapses the row rather than leaving a gap.
private final class IslandRowView: NSView {
    var onSelect: (@MainActor (Int32?) -> Void)?

    private let glyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// The title, on its own line. Kept as its own field so it can be set in the
    /// subordinate tone and truncate without touching the folder name.
    private let titleLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "")
    private let contextGlyph = NSImageView()
    private let contextLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var pid: Int32?
    private var hasContext = false
    private var hasTitleText = false
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    /// Number of stacked lines this row currently shows — the folder always, the
    /// title when it has one, the context readout when that is on. The card sizes
    /// the row from this, and `layout()` stacks exactly these lines.
    var lineCount: Int { islandRowLineCount(hasTitle: hasTitleText, hasContext: hasContext) }

    // Geometry. This view lays its children out by frame — like the rest of the
    // island — rather than Auto Layout, because the stacked lines need exact
    // vertical control and must reproduce the single-line geometry pixel-for-
    // pixel when the row has only its folder name. The column constants are
    // shared with the summary row (`islandRow…` above) and the line pitch is the
    // shared `islandRowLineStep`, so the card's height and this layout agree.
    /// Which stacked line this is, top to bottom. The order is fixed: the title
    /// never swaps places with the context readout.
    private enum RowLine: Int, CaseIterable {
        case name
        case title
        case context
    }

    /// The lines this row shows, in order, with absent ones simply skipped — so
    /// the context readout moves up when there is no title.
    private var lines: [RowLine] {
        var lines: [RowLine] = [.name]
        if hasTitleText { lines.append(.title) }
        if hasContext { lines.append(.context) }
        return lines
    }

    // Flipped so y grows downwards, which puts the name line above the title.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        glyph.imageScaling = .scaleProportionallyDown
        contextGlyph.imageScaling = .scaleProportionallyDown

        nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail

        // The title is real content, so it stays at the name's size — only its
        // weight and alpha set it below the folder name and above the age.
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        titleLabel.lineBreakMode = .byTruncatingTail

        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        durationLabel.alignment = .right

        // The context line is deliberately subordinate to both the name (12.5 /
        // full white) and the age (11 / white 0.55): 11pt regular at white 0.5,
        // dimmer still for the placeholders.
        contextLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        contextLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        contextLabel.lineBreakMode = .byTruncatingTail

        // One field per line is the row's contract, so no field is ever allowed
        // to wrap onto the next line: each truncates at its tail instead. This is
        // belt-and-braces — `layout()` already gives every field a single-line
        // frame — but it makes the contract hold even if a frame were mis-sized.
        for label in [nameLabel, titleLabel, durationLabel, contextLabel] {
            label.usesSingleLineMode = true
        }

        addSubview(glyph)
        addSubview(nameLabel)
        addSubview(titleLabel)
        addSubview(durationLabel)
        addSubview(contextGlyph)
        addSubview(contextLabel)
        titleLabel.isHidden = true
        contextGlyph.isHidden = true
        contextLabel.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(name: String, title: String?, status: SessionStatus, duration: String, pid: Int32?, context: IslandContext?) {
        self.pid = pid
        nameLabel.stringValue = name
        // The title is a line of its own, so it needs no separator and no width
        // sharing with the folder name.
        hasTitleText = !(title ?? "").isEmpty
        titleLabel.stringValue = hasTitleText ? (title ?? "") : ""
        titleLabel.isHidden = !hasTitleText
        // An empty string collapses the field's intrinsic width, so the age is
        // genuinely omitted rather than left as a gap.
        durationLabel.stringValue = duration
        let appearance = Self.appearance(for: status)
        glyph.image = islandSymbolImage(symbol: appearance.symbol, color: appearance.color)

        hasContext = context != nil
        contextLabel.isHidden = context == nil
        contextGlyph.isHidden = true
        contextGlyph.image = nil
        if let context {
            contextLabel.stringValue = context.text
            let color = Self.contextColor(for: context.band)
            contextLabel.textColor = color
            if let symbol = context.glyph,
               let image = islandSymbolImage(symbol: symbol, color: color, pointSize: 11) {
                contextGlyph.image = image
                contextGlyph.isHidden = false
            }
        } else {
            contextLabel.stringValue = ""
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Stack the row's lines about its midline: the whole block is centred, so
        // a row with only a folder name sits exactly where it always did, and
        // adding a line grows the block symmetrically.
        let shown = lines
        let count = CGFloat(shown.count)
        func centreY(_ index: Int) -> CGFloat {
            bounds.midY + (CGFloat(index) - (count - 1) / 2) * islandRowLineStep
        }
        let nameCenterY = centreY(0)

        // Line 1: status glyph, folder name, right-aligned age. The folder has
        // the line to itself, so it is never truncated for a title — it simply
        // fills the room the age leaves.
        glyph.frame = NSRect(x: islandRowLeadingInset, y: nameCenterY - islandRowGlyphSize / 2,
                             width: islandRowGlyphSize, height: islandRowGlyphSize)
        let durationSize = durationLabel.intrinsicContentSize
        durationLabel.frame = NSRect(
            x: bounds.width - islandRowTrailingInset - durationSize.width,
            y: nameCenterY - durationSize.height / 2,
            width: durationSize.width,
            height: durationSize.height
        )
        let nameWidth = max(0, durationLabel.frame.minX - islandRowGlyphGap - islandRowTextInset)
        let nameSize = nameLabel.intrinsicContentSize
        nameLabel.frame = NSRect(
            x: islandRowTextInset,
            y: nameCenterY - nameSize.height / 2,
            width: nameWidth,
            height: nameSize.height
        )

        // The other lines run the full width: nothing sits to their right.
        let fullWidth = max(0, bounds.width - islandRowTrailingInset - islandRowTextInset)
        for (index, line) in shown.enumerated() where line != .name {
            let centreYValue = centreY(index)
            switch line {
            case .title:
                let size = titleLabel.intrinsicContentSize
                titleLabel.frame = NSRect(
                    x: islandRowTextInset,
                    y: centreYValue - size.height / 2,
                    width: fullWidth,
                    height: size.height
                )
            case .context:
                // The band glyph sits in the status-glyph column — mirroring the
                // dropdown, whose detail-row badge aligns under the status glyph —
                // while the text lines up under the session name. The text x is
                // fixed even when there is no band glyph, so alignment never
                // shifts.
                contextGlyph.frame = NSRect(x: islandRowLeadingInset, y: centreYValue - islandRowGlyphSize / 2,
                                            width: islandRowGlyphSize, height: islandRowGlyphSize)
                let size = contextLabel.intrinsicContentSize
                contextLabel.frame = NSRect(
                    x: islandRowTextInset,
                    y: centreYValue - size.height / 2,
                    width: fullWidth,
                    height: size.height
                )
            case .name:
                break
            }
        }
    }

    /// Context-line colour on the dark card. The warn/critical colours are the
    /// same saturated system colours the menu uses, so the band reads
    /// identically; only the neutral cases are dimmed to stay subordinate.
    private static func contextColor(for band: ContextBand) -> NSColor {
        switch band {
        case .critical: return .systemRed
        case .warn: return .systemOrange
        case .none: return NSColor.white.withAlphaComponent(0.5)
        case .unknown: return NSColor.white.withAlphaComponent(0.32)
        }
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

// MARK: - Summary row

/// The inert tail row of a folded list: `+3 more`. Secondary text on the card,
/// and deliberately not a session row — no status glyph, no hover highlight, no
/// pointing-hand cursor, and it is never in `IslandCardView.rowViews`, so the
/// card's `hitTest` never routes a click to it (a click falls through to the
/// card's expand/collapse toggle, exactly like any other blank part of the
/// card). It has no `onSelect`, so it can never focus a session.
private final class IslandSummaryView: NSView {
    /// How many sessions the fold hid. Drives the label.
    var foldedCount: Int = 0 {
        didSet {
            guard foldedCount != oldValue else { return }
            label.stringValue = "+\(foldedCount) more"
            needsLayout = true
        }
    }

    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The card's one secondary tone, same as a context line.
        label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.5)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(
            x: islandRowTextInset,
            y: (bounds.height - size.height) / 2,
            width: max(0, bounds.width - islandRowTextInset - islandRowTrailingInset),
            height: size.height
        )
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

// MARK: - Host

/// Owns one `IslandPanel` per attached screen, so every display gets its own
/// island, and fan-outs the one row list to all of them. It rebuilds the set
/// when the displays change, so a panel never lingers on a screen that is gone.
///
/// Each panel keeps its own state — hover poll, expansion, fold — because the
/// island under the pointer is not the island on the other display. The cost of
/// showing on every screen is therefore **one layer-26 window and one 0.15s
/// hover poll per screen**, and one row-cap computation per screen (each draws
/// its own budget from its own `visibleFrame`).
@MainActor
final class IslandHost {

    /// Fired with the clicked row's pid, from whichever screen's island was
    /// clicked.
    var onSelectSession: (@MainActor (Int32?) -> Void)?

    init() {
        rebuild(for: NSScreen.screens)
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; hop explicitly so the main-actor call
            // is checkable.
            guard let host = self else { return }
            Task { @MainActor in host.screensDidChange() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Push the same rows to every screen's island. Any capping happens inside
    /// each panel, against its own screen's budget.
    func update(rows: [IslandRow], enabled: Bool) {
        lastRows = rows
        lastEnabled = enabled
        for panel in panels { panel.update(rows: rows, enabled: enabled) }
    }

    /// Collapse every island. The menubar calls this as its menu opens, so no
    /// island anywhere sits in the menu's way.
    func collapse() {
        for panel in panels { panel.collapse() }
    }

    /// Whether any island is currently expanded.
    var isExpanded: Bool { panels.contains { $0.isExpanded } }

    private var panels: [IslandPanel] = []
    private var lastRows: [IslandRow] = []
    private var lastEnabled = false
    private var observer: NSObjectProtocol?

    private func screensDidChange() {
        let screens = NSScreen.screens
        // Geometry is re-measured from the screen on every use, so only a change
        // to the *set* of displays needs anything rebuilt.
        let sameDisplays = screens.count == panels.count
            && zip(screens, panels).allSatisfy { pair in pair.0 === pair.1.screen }
        guard !sameDisplays else { return }
        rebuild(for: screens)
    }

    private func rebuild(for screens: [NSScreen]) {
        for panel in panels { panel.retire() }
        panels = screens.map { screen in
            let panel = IslandPanel(screen: screen)
            panel.onSelectSession = { [weak self] pid in self?.onSelectSession?(pid) }
            return panel
        }
        // Re-apply the current state so a rebuild does not blank the islands.
        for panel in panels { panel.update(rows: lastRows, enabled: lastEnabled) }
    }
}