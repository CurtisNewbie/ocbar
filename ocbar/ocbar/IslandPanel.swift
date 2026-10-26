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

/// Width of **each** flank of the collapsed pill — the strips either side of the physical
/// cutout, which are now the *same* width, so the capsule is symmetric about the notch.
///
/// One constant, not two, because symmetry is what sets it: `CollapsedContentView.flankWidth`
/// is the wider of the two sides' content requirements, applied to both. The sides want
/// different amounts — the left holds the ring and the running badge (62pt of content plus
/// clearance), the right holds the three remaining states (130) — and taking the smaller for
/// the right would be the one thing this pill may not do: the right flank would be
/// under-provisioned, and `place` trims an overrun at the capsule edge *silently*, so a
/// fourteen-session finished count would be drawn as `1`. Symmetry at the smaller width would
/// also be no symmetry at all, since the left's content would then decide the width anyway.
/// So both wings are 130 and the spare room on the left is the price of a balanced capsule.
///
/// The pill reads left to right as two different questions:
///
///   - the **left** flank asks "is work happening, and how much" — the running ring, then the
///     badge with the number of sessions in it.
///   - the **right** flank asks "what needs me, most urgent first" — one badge per remaining
///     state.
///
/// This is launch geometry: the window's x is computed from it so the cutout lines up with
/// the notch, and the collapsed view masks its own bounds as a backstop. Both flanks sit over
/// the menubar strip either side of the cutout (menu titles left, status items right), so every
/// extra point covers more menubar. The pill is 445pt — 68pt wider than the 377pt it was when
/// the wings were sized to their contents — and **all of that growth is leftwards**: the
/// trailing edge stays at x 980, where it was, so the outer 532pt of menubar (the status items)
/// is untouched, while the leading edge reaches from 603 to x 535, 68pt deeper into the
/// menu-title strip. A symmetric capsule for an off-centre notch has to pay for itself
/// somewhere, and this is where it pays.
private let islandFlank = CollapsedContentView.flankWidth

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

/// Width a label needs to draw its text **without clipping** — which is wider
/// than `intrinsicContentSize`.
///
/// `intrinsicContentSize` is the bare glyph advance, but the cell that draws the
/// label lays the text out a couple of points in from the frame's edge and then
/// **clips at that edge**. A frame sized to the advance therefore shaves the
/// trailing glyph: the pill's `2` lost ~1.2pt, and the row's right-aligned age
/// loses ~0.8pt off its `m` (`5h36m` needs 38.28 in a 37.5 frame).
/// `cellSize` is the cell's own answer for how wide it must be, and unlike the
/// intrinsic width it does not change with the backing scale, so layout is
/// identical on every display.
///
/// Every island label whose frame is derived from its own text is sized through
/// this. Labels the layout sizes instead — the row's name, title and context,
/// which fill the line and truncate — are not affected: when the text is too
/// long the cell truncates *inside* its drawing rect, so the ellipsis is never
/// shaved (measured on 441pt frames, their ink ends 10–166pt short of the edge).
func islandLabelWidth(for label: NSTextField) -> CGFloat {
    let unclipped = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 20)).width ?? 0
    return max(label.intrinsicContentSize.width, unclipped)
}

/// Height of a collapsed capsule on a display with no cutout, and the floor for
/// a notched pill's height. File-level because the notched/plain decision is
/// made in a static metrics helper as well as in the panel.
private let islandPlainCollapsedHeight: CGFloat = 24

/// Width of the stand-in capsule on a display with no cutout: a share of the screen's width,
/// floored and capped so it stays a pill rather than a band.
///
/// **Floored again by what it has to hold**, and that floor is load-bearing: the share alone is
/// 0.14 × screenWidth, so a 1024pt-wide display asks for 143pt and clamps up to the 160 floor —
/// and the block that capsule holds in its worst case (ring + four two-digit badges + the gaps
/// between them, `CollapsedContentView.standInCapsuleMinWidth` = 191) is *wider than 160*. That
/// is the silent-failure shape this pill is built to avoid: `place` centres what it can and the
/// view's mask trims the rest, so the finished count would be drawn as `1`. The content floor is
/// therefore a floor on top of the fraction, not a replacement for it — on the maintainer's
/// 1512pt display the share (211.7) is still what sets the width, and the floor only ever lifts
/// a small display (a 1366pt one asks for 191.2, so it is lifted there too; the 240 cap still
/// holds, so the capsule can never become a band).
func islandStandInCapsuleWidth(screenWidth: CGFloat) -> CGFloat {
    let share = min(max(screenWidth * fakeNotchFraction, fakeNotchMinWidth), fakeNotchMaxWidth)
    return max(share, CollapsedContentView.standInCapsuleMinWidth)
}
private let fakeNotchFraction: CGFloat = 0.14
private let fakeNotchMinWidth: CGFloat = 160
private let fakeNotchMaxWidth: CGFloat = 240

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
/// collapsed capsule the card grows out of — 445pt on the built-in display, where the target
/// 500pt still wins, so nothing about the card changes; the floor's own threshold moves from
/// a ~470pt screen to a ~556pt one, below which the card is as wide as the pill it grew from).
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
/// top-centred stand-in capsule — and answers two questions, one per flank: on the
/// left "is work happening, and how much" (a status light that is always there, orange
/// and turning while any session is working and dim and still when none is, followed by
/// the running badge); on the right "what needs me, most urgent first" (one badge per
/// remaining state that has sessions). A badge is a status glyph plus the number of
/// sessions in that status. On hover it drops an expanded card listing every session.
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
    /// Fake-notch capsule width for a display with no cutout. The rule is `islandStandInCapsuleWidth`
    /// — a share of the screen's width, floored and capped so it stays a pill, and floored again by
    /// the block it has to hold, which is what keeps a small display from trimming a count. It sits
    /// top-centred over that strip of menubar by design — there is no cutout to hide inside and no
    /// attempt to dodge the menu-bar items.
    private func fakeNotchWidth(for screen: NSScreen) -> CGFloat {
        islandStandInCapsuleWidth(screenWidth: screen.frame.width)
    }
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

    /// The collapsed pill. On a notched display it is the cutout flanked by a status strip each
    /// side, so the readouts are actually visible next to the physical cutout — the two flanks
    /// are the same width by construction (`islandFlank`, symmetric about the cutout) and the
    /// total is fixed, so the capsule never resizes as statuses change. A display with no cutout has
    /// nothing to flank, so the same content becomes one continuous top-centred
    /// capsule instead (`fakeNotchWidth`), with no gap to bridge.
    private func collapsedSize(metrics: ScreenMetrics) -> NSSize {
        if metrics.notched {
            return NSSize(width: 2 * islandFlank + metrics.notchWidth, height: metrics.topInset)
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
            // its left edge at exactly `notchOrigin - islandFlank`. When the
            // card is expanded it is wider than the pill, so it is centred on
            // the cutout instead.
            if expanded {
                x = metrics.notchOrigin + metrics.notchWidth / 2 - size.width / 2
            } else {
                x = metrics.notchOrigin - islandFlank
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
        // Both flanks are sized so their own worst case (one two-digit badge per slot they
        // hold) fits with clearance, but a three-digit count (or a wider glyph) can still
        // overrun one — and on a display with no cutout the stand-in capsule can be too
        // narrow to hold the whole block. This mask is the backstop for both: the overflow
        // is trimmed at the capsule's edge rather than painted past it.
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

    /// The collapsed pill's readouts, as one dictionary: how many sessions are in
    /// each state, counted once and handed over whole.
    ///
    /// The pill is the only surface that reads it, and it derives *everything*
    /// from it — the badge per state and the left flank's status light — so the mark
    /// is orange and turning exactly while the orange badge is showing and the two
    /// can never drift apart. Cheap: the collapsed view relayouts only when a count
    /// changes.
    private func refreshCollapsed() {
        collapsedView?.counts = Self.statusCounts(rows)
    }

    /// Sessions per state, for the pill. Every state is counted and every count is
    /// handed over: each state has its own slot on one flank or the other, so nothing
    /// is dropped and there is no ranking for the caller to apply here. The *order* the
    /// slots are drawn in is the pill's own two questions —
    /// `CollapsedContentView.badgeStatuses`, running first (left flank) and then the
    /// right flank's most-urgent-first list — which keeps the right flank's reading
    /// identical to how the expanded card sorts its rows (`attentionRanked`).
    private static func statusCounts(_ rows: [IslandRow]) -> [SessionStatus: Int] {
        var counts: [SessionStatus: Int] = [:]
        for row in rows {
            counts[row.status, default: 0] += 1
        }
        return counts
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
        // Now that the pill is really on screen its status light may animate; the
        // same flag is cleared in `hide()`, which is the only other place this
        // panel is ordered out.
        collapsedView?.onScreen = true
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
        // Off screen means nothing may keep animating: the status light's ticker
        // stops here, and the pill's counts stay as they were for the next time
        // the island is shown.
        collapsedView?.onScreen = false
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

/// The collapsed pill's content, split by the physical cutout — the notch has no
/// pixels, so nothing may be drawn across the middle of the pill, and the cutout is
/// itself the divider between the two sides. The pill reads left to right as two
/// different questions, and neither flank is now a single list of urgency:
///
///   - **left: "is work happening, and how much".** A hollow ring
///     (`IslandActivityView`) — orange and turning while any session is running, dim
///     neutral and still when none is, **always there**, so that side of the pill is
///     never a blank stub — followed by the running badge, `⟳` orange and the number of
///     sessions working. The ring answers "is it happening" in two channels (tint *and*
///     motion) precisely so that taking the motion away — Reduce Motion — does not take
///     the answer with it; the badge answers "how many".
///   - **right: "what needs me, most urgent first".** One badge per remaining state that
///     has sessions — error `!` red, waiting `?` blue, idle `✓` green, in that order —
///     each a status glyph plus the number of sessions in that state. This is the order
///     `IslandPanel.attentionRank` sorts the expanded card's rows by, so the wing still
///     states the card's priority; the running state is simply no longer part of it.
///
/// The marking carries the running count on **both** sides of the cutout, which is not
/// noise: the ring is the pill's *pulse* (something is happening now, right at the pill's
/// leading edge) and the badge beside it is its *tally* (how many). Both are read from one
/// dictionary (`counts`) and gated on the same count, so the ring cannot turn while the
/// badge is absent or vice versa. CodeIsland pairs its mascot with a count the same way.
///
/// **Every state gets its own slot, so nothing is ever dropped.** With an error, a waiting,
/// a running and a finished session the pill shows all four badges — one on the left with
/// the ring, three on the right — and both flanks are provisioned for their own slots at
/// two digits (`requiredLeftFlankWidth`, `requiredRightFlankWidth`). That is the lesson of
/// the two designs that failed here. The first drew a hand-drawn 8pt dot beside 11pt SF
/// Symbols whose ink measures 12pt: the busiest state at 67% of its neighbours' size, sitting in
/// the badge row where a badge was expected, drawn by separate code, which is why nothing
/// caught it. The second drew a glyph + count group per state but capped at two, so a state
/// was dropped — a *fact* the pill knows and chose not to show. This design keeps the ring
/// out of the badge rows entirely — it is a different shape class from their filled discs,
/// at the badge glyphs' own apparent size and carrying no count, so it cannot be read as a
/// badge that lost its number — and gives every state a slot of its own at one size, so no
/// badge is a different kind of thing from its neighbour and no state is left out.
private final class CollapsedContentView: NSView {

    /// The states the **right** flank shows, one badge each, most urgent first. These are
    /// `IslandPanel.attentionRank`'s ranking minus the running state, which lives on the
    /// other flank now, and the badges' left-to-right order *is* that ranking: the right
    /// flank states the same priority the expanded card sorts its rows by, so the two
    /// cannot disagree about which state matters more.
    static let rightBadgeOrder: [SessionStatus] = [.error, .waiting, .idle]

    /// The state the **left** flank's badge shows: how many sessions are working, beside
    /// the ring that says whether any are. It is named apart from `rightBadgeOrder` on
    /// purpose — the pill's left-to-right reading is **no longer one urgency list**: it
    /// is "is work happening + how much" (left), then "what needs me, most urgent first"
    /// (right). Ranking the running count inside the right flank's order is what made the
    /// old single `badgeOrder` a lie once the badge moved.
    static let runningStatus: SessionStatus = .busy

    /// Every status that can carry a badge, in the pill's reading order: the running one
    /// first, then the right flank's, most urgent first. One place that lists all four,
    /// so a state cannot be forgotten by one side while the other draws it.
    static var badgeStatuses: [SessionStatus] { [runningStatus] + rightBadgeOrder }

    /// Space between two elements sitting in the same region: the ring and the running
    /// badge in the left flank, two badges in the right flank, or the whole capsule on a
    /// display with no cutout, where everything sits together in one block. A badge's own
    /// glyph-to-number gap is 4.5pt, so this has to read as a stronger separation.
    static let groupGap: CGFloat = 6

    /// Clearance kept between the drawn content and each edge it sits near — the
    /// cutout edge and the capsule edge.
    static let minFlankClearance: CGFloat = 2

    /// Breathing room on top of that minimum, so a two-digit badge never sits
    /// flush against the flank's edges.
    static let flankMargin: CGFloat = 2

    /// Least width the **stand-in capsule** needs on a display with no cutout, where the ring and
    /// all four badges sit in one centred block: ring + one two-digit badge per state + the gaps
    /// between them + the same clearance the wings use. This is the floor `islandStandInCapsuleWidth`
    /// puts under its screen share; without it the share's own 160pt floor is narrower than the
    /// block (191pt), and the last badge would be trimmed at the capsule's edge — a wrong count,
    /// silently, on a small external display.
    static let standInCapsuleMinWidth: CGFloat = {
        let items = 1 + badgeStatuses.count
        let content = IslandActivityView.diameterCap + CGFloat(badgeStatuses.count) * twoDigitBadgeWidth
        let gaps = CGFloat(items - 1) * groupGap
        return (content + gaps + 2 * minFlankClearance + flankMargin).rounded(.up)
    }()

    /// Width of **both** flanks of the notched pill. Symmetry sets it: it is the wider of the
    /// two sides' content requirements, and both sides get it. See `islandFlank` for why the
    /// smaller (one-digit) reading of the right flank is not an option — `place` trims an
    /// overrun at the capsule edge silently, and a wrong count is the one thing this pill may
    /// not do. Every extra point sits over the menubar strip either side of the cutout.
    static let flankWidth: CGFloat = max(requiredLeftFlankWidth, requiredRightFlankWidth)

    /// What the **left** flank's content costs at its widest: the ring, the gap, one two-digit
    /// badge. The flank is wider than that once symmetry is taken into account, and this is the
    /// width its content is centred against (`leftContentInset`).
    private static var leftContentWidth: CGFloat {
        IslandActivityView.diameterCap + groupGap + twoDigitBadgeWidth
    }

    /// Where the left flank's content starts, so the pair it is provisioned for sits **centred**
    /// in the symmetrically-sized wing: `(flankWidth − leftContentWidth) / 2`.
    ///
    /// A *fixed* offset, which is the whole point: the ring is the one element that is always
    /// there, so its position is a landmark, and the layout pins it here whether or not the
    /// running badge is beside it. Centring the *actual* content instead would drag the ring
    /// 21.5pt sideways every time a session started or stopped. The consequence when nothing is
    /// running is that the ring sits at this offset with the badge's room empty to its right —
    /// and since that room runs into the cutout, which has no pixels either, the emptiness is
    /// black beside black and reads as the notch being wider, not as a hole in the pill.
    static var leftContentInset: CGFloat {
        ((flankWidth - leftContentWidth) / 2).rounded()
    }

    /// Least width the right flank needs: one two-digit badge per state it holds, the full
    /// `groupGap` between them and the clearance on both sides. Derived from the same
    /// glyph and number metrics the badges draw with (`twoDigitBadgeWidth`), so it cannot
    /// drift from them — and it is the *least* such width: a three-digit count would need
    /// `IslandMarkerGroup.widestGlyphWidth + markerGap + 3 digits` per badge and would
    /// still clip here, which is the documented limit rather than something to
    /// over-provision for.
    ///
    /// Sized for its slots at two digits rather than at one on purpose. A count is a fact,
    /// and the alternative fails *silently*: the block is trimmed at the capsule's edge
    /// (`place`), so a twelve-session finished count in a one-digit-wide slot would be
    /// drawn as `1` rather than being visibly wrong. Rare here, but this is the surface
    /// whose whole job is to be read at a glance, so a wrong number is the one thing it
    /// may not do.
    static let requiredRightFlankWidth: CGFloat = {
        let slots = CGFloat(rightBadgeOrder.count)
        return (slots * twoDigitBadgeWidth + (slots - 1) * groupGap + 2 * minFlankClearance + flankMargin).rounded(.up)
    }()

    /// Least width the left flank needs: the running ring, the gap, and one two-digit
    /// running badge, with the clearance on both sides — the same formula as the right
    /// flank's, over the two things this side holds.
    ///
    /// The rounding is the only slack, and it is the same slack the right flank always
    /// had: at two digits the content is 55.06 of the 62pt, leaving 3.47pt per side against
    /// `minFlankClearance`'s 2 — and because `place` measures the *gap* from what is left
    /// over, the full `groupGap` survives rather than being squeezed to fit.
    static let requiredLeftFlankWidth: CGFloat = {
        (IslandActivityView.diameterCap + groupGap + twoDigitBadgeWidth
            + 2 * minFlankClearance + flankMargin).rounded(.up)
    }()

    /// What one badge costs at the widest count both flanks are provisioned for. Shared
    /// by the two flank widths so they cannot disagree about the size of the unit they
    /// are built from.
    private static var twoDigitBadgeWidth: CGFloat {
        IslandMarkerGroup.widestGlyphWidth
            + IslandMarkerGroup.markerGap
            + IslandMarkerGroup.twoDigitCountWidth
    }

    /// Sessions in each state, straight from the caller — **the pill's only
    /// input**. The badges are one per non-empty state and the ring plays while
    /// `.busy` is non-zero, both read from this one dictionary, so "the ring is
    /// turning" and "the running badge is showing" cannot drift apart. A missing
    /// or zero entry is an absent badge: a `0` beside a glyph would report a state
    /// that is not happening, and an empty side already says "none" without
    /// spending a badge on it.
    var counts: [SessionStatus: Int] = [:] {
        didSet {
            guard counts != oldValue else { return }
            applyCounts()
            needsLayout = true
        }
    }

    /// Whether the island is on screen, forwarded to the left flank's mark: nothing
    /// the pill *draws* depends on it, but the mark must not turn where nobody can
    /// see it (see `IslandActivityView`).
    var onScreen = false {
        didSet { activity.onScreen = onScreen }
    }

    var notched = false {
        didSet { if notched != oldValue { needsLayout = true } }
    }
    var notchWidth: CGFloat = 0 {
        didSet { if notchWidth != oldValue { needsLayout = true } }
    }

    /// The left flank's status light, and one badge group per state — including the
    /// running one, whose group is laid out in the *left* flank. The badges only exist as
    /// "this many sessions in this state", so an empty slot is empty rather than showing a
    /// zero; the mark is the opposite — always there, because the wing it sits in must
    /// never be blank.
    private let activity = IslandActivityView(frame: .zero)
    private let groups: [SessionStatus: IslandMarkerGroup] = Dictionary(
        uniqueKeysWithValues: CollapsedContentView.badgeStatuses.map { ($0, IslandMarkerGroup(frame: .zero)) }
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(activity)
        for status in Self.badgeStatuses {
            guard let group = groups[status] else { continue }
            group.isHidden = true
            addSubview(group)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Fill the pill from `counts`: the mark's state first, then one badge per
    /// non-empty state, both through the pill's single badge vocabulary below.
    /// Both sides are filled here and nowhere else, and the mark's running tint
    /// comes from the same `color(for:)` the orange badge uses, so the pill still
    /// has exactly one place where a status becomes a glyph and a tint.
    ///
    /// The mark is never hidden — see `IslandActivityView`: it is the left flank's
    /// status light, so with nothing running it is still there, dim and still,
    /// rather than leaving that side of the pill blank.
    private func applyCounts() {
        activity.runningTint = Self.color(for: Self.runningStatus)
        activity.running = (counts[Self.runningStatus] ?? 0) > 0
        for status in Self.badgeStatuses {
            guard let group = groups[status] else { continue }
            let count = counts[status] ?? 0
            guard count > 0 else {
                group.clear()
                group.isHidden = true
                continue
            }
            show(status, count: count, in: group)
        }
    }

    /// Point one badge at a status and a count. The design that failed here wrote
    /// the two flanks in two separate places and drew them with two different
    /// techniques, which is how the left ended up 8pt against 12pt; there is one
    /// place now, and it fills every badge on the pill.
    private func show(_ status: SessionStatus, count: Int, in group: IslandMarkerGroup) {
        guard let image = IslandMarkerGroup.badgeImage(
            symbol: Self.symbol(for: status),
            color: Self.color(for: status),
            description: status.rawValue
        ) else {
            // Without its glyph a count is a digit with no meaning, so the badge
            // is dropped whole rather than half-drawn.
            group.clear()
            group.isHidden = true
            return
        }
        group.marker = image
        group.number = count
        group.isHidden = false
    }

    /// The pill's badge vocabulary: the one place a status becomes a glyph and a
    /// tint, so a status can only ever look like one thing on the pill. The busy
    /// entry is the same symbol the menubar's spinner and the expanded card's
    /// rows use for a running session.
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
        // The running badge belongs to the left flank, the rest to the right — two named
        // orders (`runningStatus`, `rightBadgeOrder`), not one list.
        let leftBadges = [Self.runningStatus].compactMap { groups[$0] }.filter { !$0.isHidden }
        let rightBadges = Self.rightBadgeOrder.compactMap { groups[$0] }.filter { !$0.isHidden }
        if notched && notchWidth > 0 {
            // The window is positioned so the cutout's left edge sits exactly `islandFlank`
            // in from the pill's left edge, which puts the cutout at that same x here — no
            // guessing from the view's centre. Both regions below are therefore `islandFlank`
            // wide, because the pill is symmetric by construction. The ring is placed
            // unconditionally: it cannot be hidden, so the left flank always reserves its
            // width.
            let cutoutStart = islandFlank
            let cutoutEnd = cutoutStart + notchWidth
            // Left flank: **pinned** at `leftContentInset`, which is where the ring + running
            // badge pair sits centred in the wing. Pinned, not centred, so the ring keeps the
            // same spot whether or not the badge is beside it — centring the actual content
            // would drag the landmark 21.5pt sideways every time a session started or stopped.
            var leftItems: [IslandFlankElement] = [activity]
            leftItems.append(contentsOf: leftBadges)
            place(leftItems, in: NSRect(x: 0, y: 0, width: cutoutStart, height: bounds.height),
                  alignment: .pinned(inset: Self.leftContentInset))
            if !rightBadges.isEmpty {
                // Right flank: **centred** — it holds a tally whose badges are peers, with
                // no always-present element whose position is a landmark.
                place(rightBadges, in: NSRect(x: cutoutEnd, y: 0, width: bounds.width - cutoutEnd, height: bounds.height))
            }
        } else {
            // No cutout: the ring, the running badge and the rest sit together as one
            // block, centred in the stand-in capsule, in the same left-to-right reading
            // order. One region, so one alignment.
            var items: [IslandFlankElement] = [activity]
            items.append(contentsOf: leftBadges)
            items.append(contentsOf: rightBadges)
            place(items, in: bounds)
        }
    }

    /// How `place` puts a block of elements inside its region.
    private enum FlankAlignment {
        /// Centre the block, so both edges get the same clearance. The right flank's badges are
        /// peers of one tally and none of them is always there, so the block re-centring when
        /// its set changes is a group reflow, not a landmark moving.
        case centred
        /// Pin the block's leading edge `inset` inside the region. The left flank's ring is
        /// always present, so its position is a landmark and must not move when the badge beside
        /// it comes and goes. Its inset parks the ring + badge pair dead centre of the wing.
        case pinned(inset: CGFloat)
    }

    /// Lay elements out left-to-right inside `region`, at the alignment the caller asks
    /// for. Each element answers for its own width at the height it is given, so the ring
    /// and the badges go through one placement path rather than two — the two that drifted
    /// apart before were positioned by separate code as well as drawn by it.
    ///
    /// **The right flank is centred, never anchored** to the cutout or the capsule's outer
    /// edge. It is provisioned for three badges but usually holds one or two, so anchoring
    /// would put the ink at one end of a mostly-empty black wing: a badge floating 100pt
    /// from the cutout, or a black gap between the cutout and the badges that reads as a
    /// mistake. Centring keeps that wing symmetric around whatever it holds. The cost is
    /// that a badge shifts by ~18pt when a state appears or disappears — acceptable
    /// because those badges are peers of one tally, so the eye follows the group, not any
    /// single badge.
    ///
    /// **The left flank is pinned** (`.pinned`), at `leftContentInset`: its ring is always
    /// present, so its position is a landmark, and centring the *actual* content would move that
    /// landmark 21.5pt every time a session starts or stops. Pinning it where the ring + badge
    /// pair sits centred means the wing looks balanced whenever something is running (the common
    /// case) and the ring does not budge when it stops — with the badge's room left empty next to
    /// a cutout that is equally black, so nothing reads as missing. It is the one place the two
    /// wings use different alignments, and the reason is that only the left has an always-present
    /// element whose position is a landmark.
    ///
    /// The flanks are sized so their worst cases cannot overrun them (see
    /// `requiredRightFlankWidth` and `requiredLeftFlankWidth`), but the shrinking and
    /// clamping stay as a backstop: a three-digit count, a wider glyph than today's, or
    /// the narrow stand-in capsule on a display with no cutout shrinks the gap first, down
    /// to zero, before the clearance is allowed to give. If the elements are still wider
    /// than the region the block is clamped so its leading edge stays on the region's edge
    /// and never crosses the cutout; the view masks its own bounds, so whatever is still
    /// past the far edge is trimmed there rather than painted over the capsule.
    private func place(_ items: [IslandFlankElement], in region: NSRect, alignment: FlankAlignment = .centred) {
        let widths = items.map { $0.flankWidth(atHeight: region.height) }
        let content = widths.reduce(0, +)
        var gap = Self.groupGap
        if items.count > 1 {
            gap = min(gap, max(0, region.width - content - Self.minFlankClearance * 2))
        }
        let total = content + gap * CGFloat(items.count - 1)
        let x: CGFloat
        switch alignment {
        case .centred:
            x = max(region.minX, min(region.minX + (region.width - total) / 2, region.maxX - total))
        case .pinned(let inset):
            x = max(region.minX, min(region.minX + inset, region.maxX - total))
        }
        var cursor = x
        for (index, item) in items.enumerated() {
            item.frame = NSRect(
                x: cursor.rounded(),
                y: region.minY,
                width: widths[index],
                height: region.height
            )
            cursor += widths[index] + gap
        }
    }
}

/// Anything the collapsed pill lays out in a flank or in the stand-in capsule: the
/// left flank's status light and a badge group. Both answer for their own width at the
/// height they are given, so one placement path lays out both and neither can be
/// positioned by code that does not know how it is drawn.
private protocol IslandFlankElement: NSView {
    func flankWidth(atHeight height: CGFloat) -> CGFloat
}

/// One badge on the collapsed pill — the running one in the left flank, the rest in the
/// right: a status glyph followed by the number of sessions in that status.
///
/// Deliberately dumb — it draws a glyph and a count and does not know what a
/// status is — because the pill must have exactly one way to fill a badge
/// (`CollapsedContentView.show(_:count:in:)`). It also has **no second marker
/// kind**: the hand-drawn 8pt dot that used to sit on the left flank painted 67%
/// of the ink its neighbours' glyphs did, and being drawn by separate code is
/// precisely why nothing caught that. The left flank no longer draws a badge at
/// all — the left flank's ring is a different shape class, matched to a glyph's apparent
/// size and carrying no count, so it cannot be read as a badge or compared with one (see
/// `IslandActivityView`); the badges themselves are one
/// construction, one point size, measured from the same constants the flank widths
/// are derived from.
///
/// The number uses tabular digits so a badge's width does not jitter as the
/// count changes.
private final class IslandMarkerGroup: NSView, IslandFlankElement {

    /// The badge's leading glyph, already tinted for its status. Nil means the
    /// group holds no badge at all — its width is then 0 and the count is not
    /// drawn either, because a number without its glyph says nothing.
    var marker: NSImage? {
        didSet { applyMarker() }
    }

    var number: Int = 0 {
        didSet {
            guard number != oldValue else { return }
            numberLabel.stringValue = "\(number)"
            needsLayout = true
        }
    }

    /// Drop the badge: no glyph, no count. The caller hides the group as well.
    func clear() {
        marker = nil
        number = 0
    }

    /// The pill's number font and the metrics the pill's own badges are measured
    /// with. Kept static so the flank width (`islandFlank`) can be derived from the
    /// very numbers that are drawn,
    /// instead of from a guess that could drift away from them.
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    /// Point size and weight of every badge glyph on the pill — one value for the
    /// whole pill, read both by `badgeImage` (what is drawn) and by
    /// `widestGlyphWidth` (what is measured), so the two cannot disagree. At this size the
    /// circle glyphs' ink **measures 12.00 × 12.00pt** inside their 14pt image box, read off the
    /// pill's own render at 1×, 2× and 8× (the harness prints it beside the ring's box in
    /// `silhouetteMatch`). Measure it as the silhouette's **extent** — any pixel the shape reaches
    /// into — not as its solid core: a filled symbol's outermost sliver is a low-coverage skirt, so a
    /// strict cut-off (>25%) reports 11.0–11.25 while a stroked ring's harder edge still reports
    /// 12.00. That is rim *density*, not size, and conflating the two is what produced the wrong
    /// "the ring is 0.75pt larger" note this replaced — the two are the same silhouette. The badge
    /// widths are built from the *box* — that is what has to fit — while the ring's cap is built from
    /// the ink, because that is what the eye compares it with.
    static let markerPointSize: CGFloat = 11
    static let markerWeight: NSFont.Weight = .semibold

    /// Space between a badge's glyph and its count.
    static let markerGap: CGFloat = 4.5

    /// A badge's glyph, built exactly as `widestGlyphWidth` measures it and tinted
    /// for the status. `description` is what the glyph means for accessibility.
    static func badgeImage(symbol: String, color: NSColor, description: String?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: markerPointSize, weight: markerWeight)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return nil }
        return islandTinted(base.withSymbolConfiguration(config) ?? base, color: color)
    }

    /// Width of a two-digit count at the width the cell needs to draw it unclipped
    /// — see `islandLabelWidth`. `99` is the widest count the pill is provisioned for.
    static let twoDigitCountWidth: CGFloat = {
        let label = NSTextField(labelWithString: "99")
        label.font = numberFont
        return islandLabelWidth(for: label)
    }()

    /// Width of the widest status glyph at the pill's point size: what the marker
    /// of *any* badge costs, the running one included now that it is a glyph
    /// rather than a dot of its own size. Measured from the symbols the badges
    /// actually use, at the point size they are actually drawn at, so it cannot
    /// go stale if a symbol's artwork changes.
    static let widestGlyphWidth: CGFloat = {
        let config = NSImage.SymbolConfiguration(pointSize: markerPointSize, weight: markerWeight)
        let symbols = ["arrow.clockwise.circle.fill", "questionmark.circle.fill",
                       "checkmark.circle.fill", "exclamationmark.triangle.fill"]
        let widths = symbols.compactMap { name -> CGFloat? in
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
            return (base.withSymbolConfiguration(config) ?? base).size.width
        }
        return widths.max() ?? 14
    }()

    private let numberLabel = NSTextField(labelWithString: "0")
    private let glyphView = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        numberLabel.font = Self.numberFont
        numberLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        numberLabel.isHidden = true
        addSubview(numberLabel)
        glyphView.imageScaling = .scaleProportionallyDown
        glyphView.isHidden = true
        addSubview(glyphView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Full width of the badge: glyph, gap, digits. The digits get the width the
    /// cell needs to draw them unclipped, not the bare advance
    /// (`islandLabelWidth`). Zero without a glyph. A badge is a fixed-height
    /// thumbnail of one status, so it ignores the height it is asked about — only
    /// the status light's size depends on the pill's height.
    func flankWidth(atHeight height: CGFloat) -> CGFloat {
        guard marker != nil else { return 0 }
        return markerWidth + Self.markerGap + islandLabelWidth(for: numberLabel)
    }

    private var markerWidth: CGFloat { marker?.size.width ?? 0 }

    override func layout() {
        super.layout()
        let labelSize = numberLabel.intrinsicContentSize
        numberLabel.frame = NSRect(
            x: markerWidth + Self.markerGap,
            y: (bounds.height - labelSize.height) / 2,
            width: islandLabelWidth(for: numberLabel),
            height: labelSize.height
        )
        if let image = marker {
            glyphView.frame = NSRect(
                x: 0,
                y: (bounds.height - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            )
        }
    }

    private func applyMarker() {
        glyphView.image = marker
        // The glyph leads the count, so neither is drawn without the other: a
        // bare digit is what made the old dot read as a legend-less status light.
        glyphView.isHidden = marker == nil
        numberLabel.isHidden = marker == nil
        needsLayout = true
    }
}

/// The left flank's status light: a hollow ring with a gap in it — orange and turning
/// while a session is running, and the same ring at the same size, dimmed to a neutral
/// grey and held still, when none is. The running badge sits to its right, so the left
/// flank reads "is it happening, and how much" before the cutout.
///
/// **It is never hidden, and that is the fix for a real complaint.** It used to
/// exist only while something was running, which left the left flank a blank 32pt
/// stub of black beside a 173pt wing full of badges whenever nothing was. A blank
/// wing beside a full one reads as something missing, not as a state: the pill
/// looked lopsided rather than quiet. So the wing always carries its mark, and the
/// mark always carries a state — dim and still when nothing is running, bright and
/// turning when something is. It is the pill's status light.
///
/// Two channels say "something is running", and either alone is enough:
///
///  - **tint** — `runningTint` (orange, the badge's own running colour) while
///    running, `restingTint` (a dim neutral) while not;
///  - **motion** — turning while running, held at `restingAngle` while not.
///
/// The redundancy is the whole point: **Reduce Motion deletes the second channel**,
/// so the first has to carry the state by itself. Under it a running pill is a
/// bright orange ring held still and a quiet one is a dim grey ring held still —
/// visibly different pictures, which motion alone could never give. Only two things
/// can change the tint: `running` going true or false. It does not chase the
/// per-state colours (an errored or waiting session is the badges' business, and
/// tracking them here would make the wing flicker between tints), and because
/// `running` is `counts[.busy] > 0` it stays orange while *any* session is busy, so
/// the wing does not blink as other sessions come and go. It switches instantly,
/// like the badges themselves; a crossfade would need a ticker for a change that
/// has no in-between.
///
/// It is drawn as vector paths so it stays crisp at every angle, like the
/// menubar's spinner, but it is deliberately **not** that spinner. The menubar's
/// is a solid disc with a wedge knocked out of it — the same filled-disc-plus-
/// knocked-out-mark construction as the `checkmark.circle.fill` it replaces — and
/// every badge glyph on this pill is a filled disc too. A filled disc here would
/// be an oversized copy of the orange badge beside it, i.e. a badge that lost its
/// number. A hollow ring with a gap is a different shape class: it reads as
/// "working" at a glance, it lets the pill's black through the middle of it,
/// and it cannot be mistaken for a badge.
///
/// **Its size is exactly the badge glyph's.** The ring is 12pt across on a 32pt pill and the
/// glyph beside it is 11pt of SF Symbol whose ink measures **12.00 × 12.00pt** inside its 14pt image
/// box (`IslandMarkerGroup.widestGlyphWidth`) — so the two silhouettes are the same size to the
/// measurement, which is the requirement: they are neighbours in the same wing, and a 2pt difference
/// between neighbours shows. The harness measures both boxes off one render of the pill and asserts
/// they agree to 0.3pt (`silhouetteMatch`); the measure is the silhouette's **extent**, and it has
/// to be, because a filled symbol's outermost sliver is a low-coverage skirt that a strict cut-off
/// trims (it then reports 11.0–11.25) while a stroked ring's harder edge does not (still 12.00).
/// That is rim density, not size — an earlier note here read the strict number as the size and
/// claimed the ring was "0.75pt larger as drawn", which is wrong. (It is not inflated for presence
/// either: 63pt² of ink against the filled glyph's ~99pt² disc, the right hierarchy for the one mark
/// on the pill that carries no number, with hue and motion earning the attention. The caps this
/// replaced were 24pt — 75% of the pill's height, 2.1× a glyph's ink mass, so it read as the pill's
/// headline while being its least informative element — and then 14pt, which matched the glyphs'
/// *box* by putting the ring's centre-line on their ink. Every one of those was chosen off a ramp
/// rendered from this code, now at 11/12/13/14pt: 11 would be 1pt *under* the glyph and its gap
/// falls to 2.5 stroke widths, so there is nothing to trade.)
/// CodeIsland buys the same presence with a pixel-art
/// mascot; that was rejected here because the app has no pixel-art language anywhere else
/// and a second drawing technique beside the SF Symbols is exactly what produced the
/// 8pt-dot failure this file records. That failure was a marker at 71% of its neighbours'
/// size *inside the badge row*, where a badge was expected; this mark is at the glyphs' own
/// size and on the other side of the cutout, so neither the mismatched-size problem nor the
/// headline problem applies.
///
/// So nothing here is ever hidden — the *motion* is what is gated, and three things
/// gate it, all read in one place (`shouldPlay`):
///
///  1. **something must be running.** With nothing running the ring is drawn, still,
///     and **there is no timer at all**: that is the user's rule and the CPU rule at
///     once. A timer to hold a mark still would be a ticker spent on nothing.
///  2. **Reduce Motion.** `NSWorkspace.accessibilityDisplayShouldReduceMotion` holds
///     the ring at its resting angle instead of turning it; the tint still says
///     which of the two states it is, so nothing is lost. This is the choice
///     CodeIsland makes with its pulsing badge, and the setting is re-read when the
///     system announces it changed. Nothing in this app honoured it before; the pill
///     animates in the notch, so it must.
///  3. **the island must be on screen.** The panel's `present()`/`hide()` are the
///     only two places the island is ordered in or out, and they set `onScreen`
///     on the way past — including when the island is switched off or has no
///     rows — so a ring nobody can see never keeps a timer turning. The tick
///     re-checks the same flag, so the two cannot drift apart in the other
///     direction either.
private final class IslandActivityView: NSView, IslandFlankElement {

    /// The ring's diameter ceiling and the air kept outside it, on every side.
    ///
    /// **12pt, so the ring's outer edge lands on a badge glyph's ink.** The badge glyphs are
    /// 11pt SF Symbols whose ink is a 12pt circle inside a 14pt image box
    /// (`IslandMarkerGroup.widestGlyphWidth`); the disc the eye sees is that 12pt of ink, so
    /// a 12pt ring is the same size as the glyph beside it rather than 2pt larger. That is the
    /// whole requirement: the ring and the running badge sit adjacent in the same wing, and
    /// the two silhouettes have to match. Nothing else on the pill hangs off this number —
    /// the flank is derived from it, so the wing and the window's x follow automatically.
    ///
    /// **What it costs, measured rather than waved away.** At 12pt with the 2pt stroke floor
    /// the ring's centre-line is 10pt — narrower than the glyphs' ink circle, which is fine
    /// because a hollow ring is *judged* by its outer edge when it sits next to a filled disc
    /// — and the 90° gap leaves 3.0 stroke widths of visible opening, the thinnest of the
    /// range (it is 3.7 at 14pt, 3.9 at 16–20pt). 3.0 is right at the point where a gap still
    /// reads as an opening rather than a nick, and a 14pt cap was chosen before precisely to
    /// keep it comfortable — but the maintainer's eye says the two shapes have to be the same
    /// size, and that beats gap comfort. If the opening ever looks like a nick, `gapDegrees`
    /// is the lever (it is a fixed 90°, not a size-dependent table), not the cap.
    ///
    /// The mark's diameter is `min(diameterCap, height - 2 * inset)`, so the clamp is only a
    /// guard for a shorter pill: at 12 it binds on neither surface (32pt notched pill, 24pt
    /// stand-in capsule), so both draw the ring at exactly 12.
    static let diameterCap: CGFloat = 12
    static let inset: CGFloat = 4

    /// The ring has no width constant of its own: it contributes its diameter to the
    /// flank (`CollapsedContentView.requiredLeftFlankWidth`), the *air* around it comes
    /// from that flank's clearance budget, and `inset` is what pins its leading edge. A
    /// separate "ring plus its air" width existed only while the ring had the flank to
    /// itself, and leaving it here would have been a constant that lied about what the
    /// flank holds.

    /// The mark's diameter in a pill `height` tall: the ceiling, clamped so it keeps its air
    /// on a shorter pill. At the shipped ceiling the clamp does not bind on either surface
    /// (32pt notched pill, 24pt stand-in capsule), so the mark is the same size on both.
    static func diameter(forHeight height: CGFloat) -> CGFloat {
        max(0, min(diameterCap, height - 2 * inset))
    }

    /// The ring's stroke, as a share of its diameter, and a floor under it. A stroke
    /// proportional to the ring keeps a big one from reading as a hairline outline; the
    /// floor keeps a small one from reading as a hairline *ring*, which is what the bare
    /// `0.14 × diameter` gives at the bottom of the useful range (1.7pt at 12pt). 2pt is
    /// the pill's own line weight — an 11pt semibold digit's stems are ~1.7pt — so a
    /// floored ring is never thinner than the numbers it sits opposite.
    static let strokeRatio: CGFloat = 0.14
    static let strokeFloor: CGFloat = 2.0

    static func strokeWidth(forDiameter diameter: CGFloat) -> CGFloat {
        max(strokeFloor, diameter * strokeRatio)
    }

    /// One revolution in 1.2s: 18° per 0.06s tick, clockwise, the direction the
    /// menubar's spinner turns. The mark shares the menubar's tick interval but not its
    /// angular step, and that is about the *shape*, not the size: the menubar's spinner
    /// is a filled disc with a wedge taken out, so its spin reads as a bright flicker,
    /// while this mark's 90° gap is a large, high-contrast discontinuity that travels the
    /// whole circumference — at the menubar's 750°/s that gap laps the ring every 0.48s,
    /// which reads as a warning blink rather than the steady "working" pulse a badge-sized
    /// status light wants. 300°/s is the classic indeterminate rate and keeps the mark
    /// quiet, which is its job now that it is no larger than the badges opposite it.
    static let tickInterval: TimeInterval = 0.06
    static let stepDegrees: CGFloat = 18

    /// Degrees of the ring left open. A three-quarter ring is the most
    /// recognisable "working" mark there is, and a hollow ring's gap reads smaller
    /// than the same angle knocked out of a solid disc.
    ///
    /// It stays 90° at every size instead of growing as the ring shrinks, because what has
    /// to stay legible is the gap *in stroke widths* and the round caps already scale with
    /// the stroke. Measured on the rendered ring, the opening a 90° gap leaves is **3.0
    /// stroke widths at the shipped 12pt**, 3.7 at 14pt and 3.9 at 16–20pt. 3.0 is the
    /// thinnest of the range and sits right at the edge of reading as an opening rather than
    /// a nick — accepted deliberately, because the ring has to match the size of the glyph
    /// beside it and 14pt was only ever chosen to keep this number comfortable. Under ~3
    /// stroke widths it stops reading as an opening at all, which is the floor: if the ring
    /// shrinks again, widen the gap rather than lower the stroke.
    static let gapDegrees: CGFloat = 90

    /// Angle the ring rests at when it is not turning. This is the arc's start
    /// angle, and the gap opens `gapDegrees` counter-clockwise from it, so
    /// `90 - gapDegrees / 2` centres the gap on 12 o'clock and a still ring is
    /// symmetric instead of looking stopped at random.
    static let restingAngle: CGFloat = 90 - gapDegrees / 2

    /// The mark's tint when nothing is running: a dim neutral, so a quiet wing
    /// still reads as *present* without competing with the badges. It is in the
    /// same family as the card's subordinate tones (its placeholders are white
    /// α0.32, its context line α0.5) — and, crucially, it is far enough from
    /// `runningTint` in both hue and brightness that "running" survives on the tint
    /// alone when Reduce Motion has taken the rotation away.
    static let restingTint = NSColor.white.withAlphaComponent(0.40)

    /// Whether a session is running. The caller sets this from the same count that
    /// fills the orange badge, so the two can only ever agree. It drives both
    /// channels at once — the tint and the motion — which is what keeps a running
    /// pill and a quiet one from ever looking the same.
    var running = false {
        didSet {
            guard running != oldValue else { return }
            // The tint changed, so the mark must be redrawn whether or not it is
            // also about to start or stop turning.
            needsDisplay = true
            updateMotion()
        }
    }

    /// The tint the ring takes while something is running. Handed in by the
    /// collapsed view from its own badge vocabulary
    /// (`CollapsedContentView.color(for:)`), so the pill still has one place where a
    /// status becomes a colour — orange on this mark and orange on the running badge
    /// are the same statement at two levels of detail.
    var runningTint: NSColor = .systemOrange {
        didSet { needsDisplay = true }
    }

    /// What the ring is drawn in: the running tint or the resting one, and nothing
    /// else — this is the single expression of "which state is the mark in".
    private var tint: NSColor { running ? runningTint : Self.restingTint }

    /// Whether the island is actually on screen, set by the panel from its own
    /// visibility — `present()` sets it true, `hide()` false, and those are the only
    /// two places the panel orders itself in or out. A notification would be more
    /// indirect and this app has no other window that could hide the island behind
    /// its back, so the third gate is wired from the one place that knows.
    var onScreen = false {
        didSet {
            guard onScreen != oldValue else { return }
            updateMotion()
        }
    }

    private var angle = IslandActivityView.restingAngle
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Drawn in the standard, unflipped space, like the menubar's spinner, so the
    /// same sign of rotation turns both clockwise.
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Re-read Reduce Motion when the system says it changed, so turning it on
        // takes effect without a relaunch. Notifications arrive on the main queue.
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateMotion()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        timer?.invalidate()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
    }

    /// Width for layout: the mark's own diameter at this height, so a shorter pill
    /// gets a smaller mark rather than one clipped to the pill's edge.
    func flankWidth(atHeight height: CGFloat) -> CGFloat {
        Self.diameter(forHeight: height)
    }

    /// The three gates on the *motion* — the mark itself is never hidden. Something
    /// running, motion allowed, and the island actually on screen. `restingAngle` is
    /// where a ring that is not playing is held (see `updateMotion`).
    private var shouldPlay: Bool {
        running
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && onScreen
    }

    /// Start or stop the ticker. The only way a timer can come into existence or be
    /// torn down: it is created when the mark starts playing and invalidated the
    /// moment it stops, so a quiet pill costs nothing at all — the mark is drawn,
    /// it just is not moving. This is the CPU rule and the state rule meeting.
    private func updateMotion() {
        if shouldPlay {
            startTicking()
        } else {
            stopTicking()
            // A ring that is not playing — reduced motion, nothing running, or a pill
            // that has just come back on screen — is put back to its resting angle
            // rather than left wherever the last tick happened to stop it. A gap
            // frozen at an arbitrary angle reads as a spinner that has stalled; a
            // gap centred on 12 o'clock reads as a mark that is deliberately still.
            if angle != Self.restingAngle {
                angle = Self.restingAngle
                needsDisplay = true
            }
        }
    }

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// One step of the ring, clockwise. Nothing is redrawn once the mark stops
    /// playing — that is the self-healing half of the third gate, in case the
    /// visibility flag and the ticker ever disagree.
    private func tick() {
        guard shouldPlay else {
            updateMotion()
            return
        }
        angle = (angle - Self.stepDegrees).truncatingRemainder(dividingBy: 360)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = Self.diameter(forHeight: bounds.height)
        guard diameter > 0 else { return }
        let lineWidth = Self.strokeWidth(forDiameter: diameter)
        let radius = (diameter - lineWidth) / 2
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let ring = NSBezierPath()
        ring.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: angle,
            endAngle: angle - (360 - Self.gapDegrees),
            clockwise: true
        )
        ring.lineWidth = lineWidth
        ring.lineCapStyle = .round
        tint.setStroke()
        ring.stroke()
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
        // Right-aligned age. Its width comes from the text's *unclipped* need,
        // not the bare advance — otherwise the cell clips the trailing glyph
        // inside the label (`5h36m` loses ~0.8pt off the `m`). Anchoring the
        // frame's right edge keeps the alignment, so the extra room appears to
        // its left, which costs the folder name the same hair via `nameWidth`
        // below.
        let durationWidth = islandLabelWidth(for: durationLabel)
        durationLabel.frame = NSRect(
            x: bounds.width - islandRowTrailingInset - durationWidth,
            y: nameCenterY - durationSize.height / 2,
            width: durationWidth,
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