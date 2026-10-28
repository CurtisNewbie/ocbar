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
    /// off — the row's state line then carries the stamp alone, or is absent when
    /// there is no stamp either, which is how the row shrinks back to the shape
    /// it had before this line existed.
    let context: IslandContext?
    /// How long ago the session was last updated, drawn in line 1's right slot
    /// just right of the age (`5h36m · 2m`). Empty means there is nothing to
    /// show — no `time.updated`, or an update stamp that is just the creation
    /// time, which the age beside it already says. So an empty string is a
    /// decision, not a gap.
    let stamp: String
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

/// The separator inside line 1's right slot: `5h36m · 2m`. The age and the
/// last-update stamp are two answers to the same question — how long — so they
/// share one slot and one glance rather than each claiming a column.
private let islandAgeStampSeparator = "· "
/// The space left of that separator. The dot brings its own on the right, so
/// this is only its left side, and it is tighter than the 8pt glyph gap: these
/// two stamps are read as one unit, and `·` is a separator inside it, not the
/// distance between two columns.
private let islandAgeStampGap: CGFloat = 5

// The alert's mark on a row: a short saturated rule in the row's leading padding.
// That padding is the one column of a row nothing else is drawn in — the status
// glyph starts at `islandRowLeadingInset`, 3pt to its right, and no line of text
// begins before `islandRowTextInset` — so the rule lines up with neither and reads
// as a mark *on* the row rather than as one more thing *in* it (see
// `IslandAlertMark` for why the mark is a rule at all).
private let islandAlertMarkWidth: CGFloat = 3
private let islandAlertMarkInset: CGFloat = 3
/// Its margin top and bottom, so the rule follows a row's height — 16pt on a
/// one-line row, 44 on a three-line one — instead of being a fixed stub.
private let islandAlertMarkVerticalInset: CGFloat = 7

/// Point size and weight every card row's status glyph is drawn at, shared with `islandSymbolImage`'s
/// defaults and named because the row's *ring* has to be measured at exactly this configuration for
/// its outer edge to land on the discs the same box draws for the other three states
/// (`IslandRowView.ringDiameter`). Two readers, one number.
private let islandRowGlyphPointSize: CGFloat = 13
private let islandRowGlyphWeight: NSFont.Weight = .semibold

/// Point size of the card's body text — the row's folder name and its title.
private let islandCardBaseFontSize: CGFloat = 12.5
/// Point size of everything subordinate on the card: a row's age and context line, the folded
/// `+k more` footnote, and the alert's `Hide` button. One number for all four, so the card's
/// subordinate tier cannot drift apart — the button is *of* that tier, not merely near it.
private let islandCardSecondaryFontSize: CGFloat = 11

/// The card's ground — **opaque black**, and the card's only fill, so this one number decides whether the
/// wallpaper reads through the surface. It used to be α0.94, and that six percent was a real reading cost:
/// a bright wallpaper shifted the card's tone and knocked the whole α0.5–0.7 text ladder below it down
/// with it, on the display where the island is looked at most, for no gain — the card stands in for the
/// notch, and a notch has no wallpaper behind it. Nothing else here is translucent at all: the surface has
/// no border on any display (it used to carry a 1px α0.08 edge on a cutout-less screen), so this one
/// number really is the whole of the island's ground.
private let islandCardFillAlpha: CGFloat = 1

/// The card's hover wash: the fill and geometry a session row takes under the pointer, and the tone the
/// alert's button **returns to** on hover. One construction, so the card cannot end up with two hover
/// idioms that drift: the row builds it as a path in its own `draw`, the button as a layer behind its
/// label, and both read these numbers.
private let islandHoverWashDX: CGFloat = 3
private let islandHoverWashDY: CGFloat = 2
private let islandHoverWashRadius: CGFloat = 7
private let islandHoverWashAlpha: CGFloat = 0.09

/// The alert's action-row button, `Hide`: a quiet way out, trailing, on a row under the card's content,
/// hiding the card without acting on the session. What it is drawn with, in this card's own terms:
///
///  - **type** is the card's subordinate size (`islandCardSecondaryFontSize`, 11) at regular weight —
///    the size the age, the context line and the `+k more` footnote are drawn at, and regular because
///    the card's only medium text is a session *name*, which this must not read as;
///  - **tone** at rest is white α0.55 — the age's step, a hair above the inert footnote (α0.5) because
///    this one can be pressed — stepping to α0.7 on hover, the title's step. Both values already exist
///    on this card, so the button moves along the card's own alpha ladder;
///  - **ground** at rest is `islandActionButtonRestingFillAlpha`, derived below;
///  - **hover** is the card's wash itself (`islandHoverWash…`): the same fill and geometry a session row
///    takes under the pointer, in the file's own micro duration;
///  - **height** is not the button's at all: the action row is a row of the card, laid out at the card's
///    own short-row height `summaryRowHeight` (the `+k more` footnote's 24), so a control row and the
///    fold's row sit on the same line of the card's rhythm;
///  - **no pressed state, no border, no scale, no material, and no colour vocabulary**: a green/red/blue
///    palette ranks a decision against its alternatives, and this button is not a decision.
///
/// **What the resting ground cost, and why it is worth it.** The first version of this button had no
/// ground at all, on the argument that any fill competes with the thing the card is actually saying —
/// the marked row — and that a quiet control should be pure text. Both halves turned out to be misfiled:
/// "quiet" is judged against other filled controls on a card that has them, while this one is flat black
/// and type-only, so a control with no ground reads as one more line of text rather than as something to
/// press; and the competition argument is really about *brightness*, which a ceiling handles better than
/// abstention does. The purity given up is real —
/// every other element on this card is text or a status glyph, and this is now the only shape that
/// exists in order to be clicked — and it buys the one thing type alone could not say.
let islandActionButtonLabel = "Hide"
/// The tooltip, and the second half of it is what this card actually does: hiding leaves the card with
/// one way back, which is hovering the island again.
let islandActionButtonTooltip = "Hide this card. The session keeps waiting — hover the island to bring it back."
/// The label's unclipped need plus the card's own 8pt either side (`rowInset`, `islandRowGlyphGap`).
/// There is no height here on purpose: the card lays the button out at its own row height.
private let islandActionButtonHorizontalPadding: CGFloat = 8
/// **At rest the button carries half a hovered row's wash** — 0.045. This card has exactly one surface
/// tone (`islandHoverWashAlpha`, 0.09: a row under the pointer) and nothing lighter, so a button that
/// must read as a button without out-shouting a row takes a *fraction* of that tone rather than a new
/// one: half of it. Two reasons it is a fraction and not a peer — a resting control must never be
/// brighter than a row the pointer is actually on, and the gap between the two is what gives the hover
/// its step, since the button's hover *is* the wash and the ground therefore doubles from rest to hover.
/// The two brighter tones this app already owns were both rejected as grounds: `CollapsedContentView`
/// `restingTint` (0.40) and the bubble's icon block (a tint at 0.15) are each louder than a hovered row
/// here, i.e. they would make a resting button louder than the row the user is pointing at.
private let islandActionButtonRestingFillAlpha = islandHoverWashAlpha / 2
private let islandActionButtonForegroundAlpha: CGFloat = 0.55
private let islandActionButtonHoverForegroundAlpha: CGFloat = 0.7
/// The file's own micro duration — the one `present()`'s fade-in uses — on the file's own curve.
private let islandActionButtonHoverDuration: TimeInterval = 0.15

// A row stacks up to three lines, always in this order:
//
//     folder name          age · updated
//     title
//     context usage
//
// The folder is always there; the title when the session has one; the context
// readout when that feature is on. Each line is a distinct concern, which is why
// the title moved off the folder's line: sharing it meant the folder and the
// title truncating each other. The last-update stamp stays on line 1 instead of
// joining the context line: both times belong to the session as a whole, and a
// right-aligned column of them reads as one glance — the context line is about
// the window, which is a different question.

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
/// and the block that capsule holds in its worst case (ring + the three two-digit badges + the
/// bare two-digit running count + the gaps between them,
/// `CollapsedContentView.standInCapsuleMinWidth` = 172) is *wider than 160*. That is the
/// silent-failure shape this pill is built to avoid: `place` centres what it can and the view's
/// mask trims the rest, so the finished count would be drawn as `1`. The content floor is
/// therefore a floor on top of the fraction, not a replacement for it — on a 1512pt display the
/// share (211.7) is what sets the width, the floor only ever lifts a smaller one (below 1228pt
/// the share is under 172), and the 240 cap binds from 1714pt up, so the capsule can never
/// become a band.
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
///    the longest age (`12h30m`); with a session's last-update stamp beside it
///    (`12h30m · 1h6m`) the right slot is still under 100pt. None of the 202
///    real folders truncate from 420pt up, and 500 leaves a ~55-character
///    folder box;
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
    /// Height of the alert's action row when the card is carrying one (0 when it is not). New chrome,
    /// so it comes off the list budget exactly as `summaryRowHeight` does: a card with a `Hide` button
    /// has one row's worth less room than the same card without it, and the button can never be pushed
    /// past the bottom of the screen by a fold that was computed without it.
    let actionRowHeight: CGFloat
    /// Tallest row in the list, so the budget can always hold one.
    let tallestRowHeight: CGFloat
    /// Share of the usable height the list may take.
    let fraction: CGFloat

    /// Points the visible session rows may use: the smaller of
    ///  - a share of the screen's usable height, so the card never takes over
    ///    the display even where there is room for it, and
    ///  - the distance from the top edge to the bottom of the usable area, less
    ///    the chrome, the summary row and the action row. The card hangs from the
    ///    very top, so this is the term that stops it running past the bottom of
    ///    any screen or over the Dock.
    /// The summary's and the action row's heights come out of that *ceiling* but
    /// never out of the budget itself, so neither folding a list nor an alert's
    /// `Hide` button ever costs a visible session row.
    var rowBudget: CGFloat {
        let soft = visibleFrame.height * fraction
        let hard = screenFrame.maxY - visibleFrame.minY - contentTop - bottomPadding - summaryRowHeight - actionRowHeight
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
        var height = contentTop + heights.reduce(0, +) + actionRowHeight
        if folded { height += summaryRowHeight }
        return height + bottomPadding
    }

    /// Whether that card still clears the bottom of the usable area.
    func fits(forRowHeights heights: [CGFloat], folded: Bool) -> Bool {
        screenFrame.maxY - cardHeight(forRowHeights: heights, folded: folded) >= visibleFrame.minY
    }
}

/// Why the island opened itself. The two moments the bubble already announces —
/// `SessionMonitor.publish` fires them for exactly this purpose — which is why
/// there are two kinds and not a general "something happened":
///
///  - `waiting`: a session has just come up wanting input;
///  - `ready`: a session has just finished a turn.
///
/// It is not a second status vocabulary. The kind says *which transition* fired
/// and fixes the tint the alerted row is marked in and nothing else — the row's own
/// status glyph still carries the state, so an alert never repeats it. The two
/// tints are the app's existing blue and green for those states, in the menubar,
/// the bubble, the row glyph and the pill's badge alike, so an alert speaks the
/// colour language the app already has instead of adding a colour to it.
enum IslandAlertKind {
    case waiting
    case ready

    var color: NSColor {
        switch self {
        case .waiting: return .systemBlue
        case .ready: return .systemGreen
        }
    }
}

// MARK: - Hover dwell preference

/// The hover dwell is the one of the island's timings the user gets to set, because it is the open they
/// feel: the pause between pointing at the pill and the card arriving. **Only the open** — the fold has
/// its own fixed `hoverCloseDelay` (0.2s, in `IslandPanel`), since a pointer that has left an open card
/// has already decided and should not wait out a dwell it did not choose. It shipped as a constant
/// 0.35; the default is now 0.1 — as prompt as the 0.15s poll can deliver — and the dropdown offers a
/// spread up to 1s for anyone who wants the card to wait (`ocbar.islandHoverDelay`).
///
/// Milliseconds, not seconds, because the menu carries the choice in an `NSMenuItem.tag`, which is an
/// `Int`. The option list is the payload and the reader validates against it, so a stale or
/// hand-edited value can only fall back to the default and never to "the island never opens".
let islandHoverDelayOptions = [100, 200, 350, 500, 800, 1000]
let defaultIslandHoverDelay = 100
private let islandHoverDelayKey = "ocbar.islandHoverDelay"

/// Read at schedule time rather than cached at launch, so a pick in the dropdown applies to the next
/// hover instead of the next launch. Below the 0.15 poll the poll decides: at the 0.1 default the card
/// opens on the following tick, which is the floor — and why the fastest option is not zero.
func islandHoverDelay() -> TimeInterval {
    guard let ms = UserDefaults.standard.object(forKey: islandHoverDelayKey) as? Int,
          islandHoverDelayOptions.contains(ms) else {
        return TimeInterval(defaultIslandHoverDelay) / 1000
    }
    return TimeInterval(ms) / 1000
}

/// Write side of the preference, validated here so the dropdown and a hand-edited `defaults write`
/// pass through the same gate: an illegal value is dropped, not stored.
func setIslandHoverDelay(milliseconds: Int) {
    guard islandHoverDelayOptions.contains(milliseconds) else { return }
    UserDefaults.standard.set(milliseconds, forKey: islandHoverDelayKey)
}

/// CodeIsland-style "Dynamic Island" surface: a borderless, non-activating
/// panel pinned to the very top edge of **one** screen. Collapsed it hides
/// inside that screen's notch — or, on a display with no cutout, becomes a
/// top-centred stand-in capsule — and answers two questions, one per flank: on the
/// left "is work happening, and how much" (a status light that is always there, orange
/// and turning while any session is working and dim and still when none is, followed by
/// the running badge); on the right "what needs me, most urgent first" (one badge per
/// remaining state that has sessions). A badge is a status glyph plus the number of
/// sessions in that status. On hover it drops an expanded card listing every session —
/// and, while an alert is armed, listing **only the session that just moved**, with the
/// rest folded into the card's `+k more` footnote (`recomputeFold`).
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

    /// Fired with the clicked row's pid when a row is selected. Answered by the **host**, not locally by
    /// the click: a row click is the user answering a reminder that was shown on *every* screen, so the
    /// fold has to happen everywhere, and only the host can reach the other panels
    /// (`IslandHost.rowActivated`).
    var onRowActivated: (@MainActor (Int32?) -> Void)?

    /// Fired when the alert's `Hide` button is clicked. Answered by the host with the **same dismissal a
    /// row click uses** — `collapse()` on every panel — and deliberately **without** the focus: this
    /// button hides the card without acting on the session, so the agent keeps waiting and the terminal
    /// is not brought forward. Host-owned for the row click's reason: the reminder is shown on every
    /// screen, and hiding it on one screen has to hide it on all of them.
    var onHideRequested: (@MainActor () -> Void)?

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
        // The alert's chrome is part of the card, so it is settled *before* the fold is worked out: the
        // action row takes its height out of the same budget the rows are measured against, and a fold
        // computed without it would put the button past the bottom of the screen.
        let actionRowChanged = syncActionRow()

        rows = newRows
        // The fold and the rows it renders, from the same helper the alert's own arm/end use: the card's
        // listed set is derived from `alertArmed` (`recomputeFold`), so both callers have to run exactly
        // this and only this, or one of them would show a card the other's state disagrees with.
        let contentChanged = refoldCard()
        refreshCollapsed()
        // Re-applied on *every* tick, not only when the alert is armed or the rows
        // changed: an alert normally arrives **before** the row list contains its
        // session — the transition comes from `SessionMonitor.publish`, the rows
        // from the render tick after it — so the alert holds a pid and this is
        // where that pid finally lands on a row. Cheap when nothing is armed (one
        // nil assignment per row, and `IslandRowView.alert` ignores a repeat).
        applyAlertMark()

        if !visible {
            present()
            // An alert armed while the island was off screen — no rows to show,
            // so no card for it to open — opens it now, on the first tick that
            // gives it one.
            if alertArmed {
                setExpanded(true, animated: true, duration: alertExpandDuration)
            }
        } else if contentChanged || actionRowChanged, expandedState {
            // The card's height changed while it was open — the fold moved, or the alert's action row
            // came or went — so it grows or shrinks downwards with its top edge anchored.
            resizeOpenCard()
        }
    }

    /// Force the card back to its collapsed state — the host calls this when the menubar menu opens, so
    /// the island never sits in the menu's way, **and when a row is clicked or the alert's `Hide` button
    /// is pressed on any screen**, so one click folds them all. An alert in flight dies with it: all three
    /// are the user answering the reminder.
    ///
    /// It also **latches the hover open off** (see `hoverLatched`): a dismissal the pointer is standing
    /// inside must not be undone by the next 0.15s poll tick.
    func collapse() {
        hoverLatched = true
        // Fold *first*: it takes the card off screen, so the alert's chrome then comes off a collapsed card
        // and `clearAlert`'s "an open card shrank" resize cannot race the fold's own frame change.
        setExpanded(false, animated: false)
        clearAlert()
    }

    /// Open the card by itself, on a session transition, and fold it back after
    /// `seconds`. The island's first *unprompted* expansion — hover is the user
    /// asking, this is the island telling — and it exists because the island is
    /// the reminder surface whenever the bubble is switched off
    /// (`AppDelegate.showBubble` routes the same two moments here).
    ///
    /// `pid` is the client ocbar bound to that session; nil means the session is
    /// bound to no running client, and the card then opens with no row marked,
    /// because there is no row the mark could be about.
    ///
    /// `name` is that session's **folder display name** — the same string the bubble is dismissed by
    /// (`AppDelegate.dismissBubble`), because it is what `SessionMonitor.onDismiss` carries. It exists so
    /// this alert can be *retracted* when its reason is gone (`retractAlert(named:)`), which is the
    /// bubble's own behaviour: the user answers the question and the reminder disappears, rather than
    /// sitting there for its remaining seconds.
    ///
    /// The alert owns the card for `seconds` (see `armAlertTimer`), and when it
    /// ends it does not decide anything: it hands the card back to the hover
    /// machine, which is what kept the two from disagreeing in the first place.
    ///
    /// **While it is armed the card lists this one row and folds the rest away**
    /// (`recomputeFold`): the alert is about a single transition, so the card is about a
    /// single session. The fold is re-derived right here rather than left to the next
    /// `update` tick, because an alert can land on a card the pointer already had open —
    /// which would otherwise sit there showing the whole list, and marking one row, until
    /// the next poll.
    func alert(name: String, kind: IslandAlertKind, pid: Int32?, seconds: TimeInterval) {
        alert = ActiveAlert(name: name, kind: kind, pid: pid)
        alertGeneration += 1
        // The alert takes over **both** directions of the hover machine, a fold
        // already booked included. `scheduleCollapse` only refuses to *schedule* a
        // fold while an alert is armed, so a 0.35s deadline created a moment before
        // the alert arrived — the pointer left the card, then the session moved —
        // would still fire and fold the card 0.15s after it opened. Cancelling here
        // is what makes every pending deadline the alert's to keep or drop.
        cancelPending()
        armAlertTimer(seconds: seconds)
        // The chrome first, then the rows: the action row is alert-only, and an alert landing on an
        // already-open card has to grow that card rather than push a button past its bottom edge.
        let chromeChanged = syncActionRow()
        // And the rows with it: the card is now about one session, so the list is re-derived here —
        // this is also what makes a re-arm on a *different* session swap the row, while a re-arm on
        // the same one is a no-op here and lands entirely on the mark below.
        let contentChanged = refoldCard()
        // Mark first, expand second: the mark lives inside a row that the
        // expansion is still fading in, so the two arrive together instead of one
        // after the other.
        applyAlertMark()
        // Both changes move an open card's height — the chrome adds a row's worth, the scoped list
        // takes it back — so one resize serves both, top edge anchored.
        if chromeChanged || contentChanged { resizeOpenCard() }

        // Nothing on screen yet. The rows for this session arrive on the render
        // tick that follows the transition, and the tail of `update` opens the
        // card on the first tick that has one — so this arms and returns rather
        // than waiting. A card that never arrives is not awaited forever either:
        // the timer ends the alert regardless.
        guard visible else { return }
        // Already open because the pointer is on it. The mark, the action row, the narrowed list and the
        // timer are then the whole alert: the frame has nowhere else to move, and replaying the open would
        // restart the fade for no reason.
        guard !expandedState else { return }
        setExpanded(true, animated: true, duration: alertExpandDuration)
    }

    /// Retract the alert because its **reason** is gone — the user answered the prompt, or the session
    /// went back to work — if it is the alert this panel is showing.
    ///
    /// Matched by the folder display name, the bubble's own key (see `alert(name:kind:pid:seconds:)`).
    /// Only one alert exists at a time (a new one replaces it), so the looseness of a name match cannot
    /// bite.
    ///
    /// **Deliberately `endAlert()`, and deliberately not `collapse()`.** This is the third exit, and the
    /// one whose pointer is *not* inside the island: the user is in a terminal, answering a prompt. So it
    /// exits exactly as the alert's own timer does — hand the card back to the hover machine — and an
    /// unattended card folds on the ordinary 0.35s deadline while a card somebody is actually pointing at
    /// stays up. `collapse()` is for the two exits where the pointer *is* inside by construction (the
    /// `Hide` button, a row click) and which therefore must latch (`hoverLatched`); merging the two would
    /// either freeze a card the user is reading or leave the poll free to re-open a card they dismissed.
    func retractAlert(named name: String) {
        guard alert?.name == name else { return }
        endAlert()
    }

    // MARK: - Private state

    private var panel: NSPanel?
    private var card: IslandCardView?
    private var collapsedView: CollapsedContentView?
    private var rowViews: [IslandRowView] = []

    private var rows: [IslandRow] = []
    /// The prefix of the card's *listed* rows that fits the height budget, and how many were
    /// folded into the summary. Both are recomputed every tick from the current
    /// screen, and are the single source of truth for the card's layout, the
    /// window frame and the summary text — and the listed set is itself derived there
    /// from the alert (`recomputeFold`), so an armed alert's one row and the
    /// `+k more` count that replaces the rest come off the same calculation.
    private var visibleRows: [IslandRow] = []
    private var foldedCount = 0
    private var lastSignature: String?
    private var expandedState = false
    private var visible = false
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var hoverTimer: Timer?

    /// **A dismissal latches the hover open off until the pointer leaves.** Set by `collapse()` — the
    /// menubar opening and a row click on any screen — and released in exactly three situations: the
    /// pointer is *seen* outside the hover rect (`evaluateHover`, the only thing that can observe what
    /// the latch is waiting for), anything else opens the card (`setExpanded(true)` — an alert is new
    /// information the user has not answered, not the poll second-guessing a dismissal), and the panel
    /// leaving or returning to screen (`hide`/`present`, so a latch set while the island was off screen
    /// cannot stick to it).
    ///
    /// Not a nicety. The pointer is inside the island when a row is clicked, and on a display with no
    /// cutout the rows begin *above* the collapsed pill's own bottom edge (`contentTop` is 8 there
    /// against a 24pt capsule), so a click on the first row lands inside the rect the poll tests: the
    /// card would come back 0.35s later, every time, on the one path where the user has explicitly
    /// said they are done with it.
    private var hoverLatched = false

    /// What an alert is, once armed: which transition fired, the session it is about — its folder display
    /// name, so it can be retracted when that session's reason for the reminder is gone — and the row it
    /// marks. Set and cleared together with `alertWork`, always — `alert != nil` is therefore the same
    /// statement as "a timer is pending that will end it", and `alertArmed` is the one place the rest of
    /// the panel asks that question.
    private struct ActiveAlert {
        let name: String
        let kind: IslandAlertKind
        let pid: Int32?
    }

    private var alert: ActiveAlert?
    /// Which alert the current mark belongs to, bumped on every arm. It is what the
    /// row's pop is keyed on: an alert that re-arms on the *same* row has to pop
    /// again, and the tint cannot say that — the tint is the same blue or green
    /// either way. Never reset, so no two alerts can share a generation.
    private var alertGeneration = 0
    /// The alert's own one-shot: it, and nothing else, owns the fold while an alert
    /// is up. Kept out of `expandWork`/`collapseWork` deliberately — those two are
    /// the hover machine's, and `cancelPending` cancels them on every expansion, so
    /// an alert deadline parked in either would be cancelled by the very expansion
    /// it was armed for.
    private var alertWork: DispatchWorkItem?

    /// Whether an alert currently owns the card, read by the hover poll to know
    /// that the fold is not its to make.
    private var alertArmed: Bool { alert != nil }

    /// An alert's open, one-shot. Shorter than the hover's 0.3 on the same curve:
    /// the hover open answers the user, so it can afford to be unhurried, while an
    /// alert is competing for attention it did not ask for and has to land as
    /// decisively as it can without being a jump. The curve itself is the file's
    /// own (`setExpanded`), not a second one.
    private let alertExpandDuration: TimeInterval = 0.22
    /// Floor under whatever duration the caller hands in. It is the bubble's own
    /// duration (`ocbar.bubbleSeconds`), and a zero or negative one would end the
    /// alert on the same turn it was armed — a card that opens and folds in one
    /// frame, which is worse than an alert held for a moment too long.
    private let alertMinimumSeconds: TimeInterval = 1

    /// The dwell before the card opens: the one island timing the user sets
    /// (`ocbar.islandHoverDelay`, see `islandHoverDelay()`), read here at schedule time so a change in
    /// the dropdown lands on the next hover.
    private var hoverDelay: TimeInterval { islandHoverDelay() }
    /// The dwell before the card folds, and **fixed on purpose** — the dropdown moves the open, never
    /// this. The two are not symmetric events: the open has to earn itself against a pointer that may
    /// only be crossing the pill, while a pointer that has *left* an open card has already decided, so
    /// the fold should answer it. 0.2s is just clear of the 0.15s poll, which keeps a pointer skimming
    /// the card's edge from tearing it down mid-gesture.
    private let hoverCloseDelay: TimeInterval = 0.2
    private let hoverInterval: TimeInterval = 0.15
    /// Downward slack on the collapsed hover rect so the pointer can travel
    /// from the pill into the growing card without a collapse being scheduled.
    private let hoverSlack: CGFloat = 6
    private let animationDuration: TimeInterval = 0.3
    private let rowInset: CGFloat = 8
    private let bottomPadding: CGFloat = 8
    /// Extra bottom air the card pays **only when it has no action row**. The hover card's last session
    /// row otherwise sits `bottomPadding` (8) above a bottom edge rounded up to 18, while the top edge
    /// pays two steps (the cutout — or `rowInset` — plus `islandExpandedTopPadding`), so the card read
    /// heavy at the top and pinched at the bottom. The alert's card needs none of it: the `Hide` row
    /// already stands between the last session row and the edge, which is why this is a *conditional*
    /// step and not a bigger `bottomPadding`.
    private let bottomPaddingWithoutActionRow: CGFloat = 8
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
    ///
    /// The stamp is part of each row's entry for the same reason its age is: it
    /// is text on screen, so `now → 1m` has to rebuild the card.
    private static func signature(for rows: [IslandRow], folded: Int) -> String {
        let list = rows
            .map { row in
                let context = row.context.map { "\($0.text)|\($0.glyph ?? "-")|\($0.band.rawValue)" } ?? "-"
                return "\(row.name)|\(row.title ?? "-")|\(row.status.rawValue)|\(row.duration)|\(row.stamp)|\(row.pid.map { String($0) } ?? "-")|\(context)"
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

    /// Extra room above the **expanded** card's first row, on top of whatever already keeps it clear of the
    /// top edge (the cutout's own height, or `rowInset` on a display with no cutout): one more step of the
    /// card's own padding, i.e. another `rowInset` (8).
    ///
    /// The first row is the only row that abuts *chrome* rather than another row. On a notched display its
    /// frame starts exactly at the cutout's bottom edge — `topInset` is the notch's height to the point — and a
    /// row keeps its own air above its first line (measured on a render: the first line's ink sits 7.5pt below
    /// a two-line row's frame), so without this the card's first row clears the notch by **nothing at all** and
    /// only its text clears it, by 7.5pt. Measured on the same render, this constant moves the frame's gap to
    /// 8pt and the text's to 15.5pt.
    /// The step is that same 8: the card already keeps 8 either side of its rows and 8 below its last one
    /// (`rowInset`, `bottomPadding`), so the top edge pays the card's own unit *plus* the row's internal air,
    /// rather than a fourth number invented for one edge.
    ///
    /// **The expanded value only.** The collapsed card's rows keep `rowInset` (8) untouched, and that 8 being
    /// *smaller* than the stand-in capsule's 24pt is load-bearing — it is what puts the collapsed rows inside
    /// the collapsed rect, which is what `hoverLatched` reasons about (see there).
    private let islandExpandedTopPadding: CGFloat = 8

    /// Where the card's rows begin. On a notched display that is the cutout's own height (`topInset`), so
    /// nothing hides under the notch; on a display with no cutout there is nothing to clear and it is the
    /// card's padding. Either way the **expanded** card adds `islandExpandedTopPadding`, because its first row
    /// is the one that abuts the top edge — see that constant, and for why the collapsed card's own 8 must not
    /// move with it.
    private func contentTop(for metrics: ScreenMetrics) -> CGFloat {
        (metrics.notched ? metrics.topInset : rowInset) + islandExpandedTopPadding
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
                ?? (contentTop(for: metrics) + islandRowOneLineHeight + cardBottomPadding)
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
            // **An armed alert is not folded by a blank click.** Everything that reaches this closure is
            // "not a session row, not the `Hide` button" — the card's margins, and the inert `+k more`
            // footnote, which this same path claims because `hitTest` deliberately lets the summary fall
            // through. On a hover card that is the way out (the pointer is on the card because the user put
            // it there), but an unprompted card has one way out and it is visible: `Hide`. Folding on a
            // stray click would end the reminder silently — `setExpanded(false)` neither latches the hover
            // open off nor ends the alert, so the card would sit armed and unseen, or, if the pointer
            // happened to stay inside the collapsed hover rect, pop back 0.35s later off the 0.15s poll:
            // one click, two outcomes. It is made no click at all. Clicking a *collapsed* card to open it
            // still works — while an alert is armed only `collapse()` folds the card, and that ends the
            // alert, so this guard only ever refuses the fold.
            guard !(self.alertArmed && self.expandedState) else { return }
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
    ///
    /// **An armed alert narrows the card to one session.** `alertArmed` and its pid are part of this
    /// computation, and not a second list computed beside it: an unprompted card exists because *one*
    /// session moved, so showing the full attention-ranked list would make the user hunt for the row that
    /// did — the alert would open a card and then make its own point the fourth row down. Instead the
    /// alerted row *is* the list and every other session folds into the `+k more` summary, whose count is
    /// therefore `ranked.count - 1`. The row goes through the budget below like any other (it is simply
    /// never the one that folds, since a list of one always fits), so the card, the window frame and the
    /// summary text still come from this one split.
    ///
    /// When the alert cannot be pinned to a row — a nil pid, or a pid that is not in this tick's list
    /// because the session is filtered out or unbound — the card falls back to the **whole ranked list,
    /// exactly as a hover card shows it**, and marks nothing. That is the one rule this may not break: a
    /// card that opened must never open empty, and an alert with nowhere to point is still a card the user
    /// has to be told about. A card armed while the island is off screen lands here with no rows at all and
    /// scopes on the first tick that has the row (`update`).
    private func recomputeFold(metrics: ScreenMetrics) {
        let ranked = Self.attentionRanked(rows)
        // The rows this card is allowed to list, and the sessions already folded away before the budget is
        // applied — 0, or the rest of the list when an alert pinned one row out of it.
        let listed: [IslandRow]
        let foldedAway: Int
        if let focused = alertScopedIndex(in: ranked) {
            listed = [ranked[focused]]
            foldedAway = ranked.count - 1
        } else {
            listed = ranked
            foldedAway = 0
        }
        let heights = listed.map(Self.rowHeight(for:))
        let budget = listBudget(for: metrics, tallestRowHeight: heights.max() ?? islandRowOneLineHeight)
        visibleRows = Array(listed.prefix(budget.visibleCount(forRowHeights: heights)))
        foldedCount = max(0, foldedAway + listed.count - visibleRows.count)
    }

    /// The alerted row's position in the ranked list, or nil when the alert cannot be pinned to one.
    ///
    /// That is the whole scope: no alert (so no pid at all), a nil pid — the session is bound to no running
    /// client, so there is no row the mark could be about — or a pid absent from this tick's list. The
    /// caller reads nil as "show the whole list" (`recomputeFold`), which is what keeps an unmatched alert
    /// from opening an empty card.
    private func alertScopedIndex(in ranked: [IslandRow]) -> Int? {
        guard let pid = alert?.pid else { return nil }
        return ranked.firstIndex { $0.pid == pid }
    }

    /// Height budget for the current screen and row set.
    private func listBudget(for metrics: ScreenMetrics, tallestRowHeight: CGFloat) -> IslandListBudget {
        IslandListBudget(
            screenFrame: metrics.screen.frame,
            visibleFrame: metrics.screen.visibleFrame,
            contentTop: contentTop(for: metrics),
            bottomPadding: cardBottomPadding,
            summaryRowHeight: summaryRowHeight,
            actionRowHeight: actionRowHeight,
            tallestRowHeight: tallestRowHeight,
            fraction: listHeightFraction
        )
    }

    /// Height of the card's action row: the card's own short-row height, `summaryRowHeight` — the same
    /// 24 the folded `+k more` row uses — while an alert is armed, and nothing otherwise. The action row
    /// is a row *of this card*, so it takes the card's rhythm rather than a height of its own, and the
    /// panel's copy and the card's (`IslandCardView.actionRowHeight`) come from that one number.
    private var actionRowHeight: CGFloat { alertArmed ? summaryRowHeight : 0 }

    /// The bottom air the card pays *right now*: its one unit, plus `bottomPaddingWithoutActionRow` when
    /// there is no `Hide` row under the last session row. One expression for the three readers — the
    /// height budget, the fallback frame, and `card.bottomPadding` (pushed in `applyAppearance` /
    /// `resizeOpenCard`), which is what `IslandCardView.contentHeight` moves the window by — so a change
    /// here cannot leave the frame and the layout disagreeing about the card's height.
    private var cardBottomPadding: CGFloat {
        bottomPadding + (actionRowHeight > 0 ? 0 : bottomPaddingWithoutActionRow)
    }

    /// Add or remove the alert's action row, and report whether the card's chrome changed.
    ///
    /// The `Hide` button is on the card **only while an alert is armed**. A hover-opened card needs no
    /// way out — moving the pointer away already folds it — so an explicit control there would be a
    /// button whose only function is what leaving does for free; and the alert is the one card the user
    /// did not ask for, which is exactly the moment a quiet way out is worth a button.
    @discardableResult
    private func syncActionRow() -> Bool {
        guard let card else { return false }
        if alertArmed {
            guard card.actionButton == nil else { return false }
            let button = IslandCardButton(frame: .zero)
            button.onActivate = { [weak self] in
                // Answered by the host, with the same dismissal a row click uses and **without** the
                // focus: this button hides the card without acting on the session — the agent keeps
                // waiting, the terminal is not brought forward — and the reminder is on every screen, so
                // one click has to fold them all. The pointer is on the button, so the latch `collapse()`
                // sets is what keeps the poll from re-opening the card the user just hid.
                self?.onHideRequested?()
            }
            // New views start in step with the current state, without animating, exactly as a new row does
            // (`rebuildRows`): an alert that lands on an already-open card must not be invisible.
            button.alphaValue = expandedState ? 1 : 0
            card.addSubview(button)
            card.actionButton = button
            return true
        }
        guard let button = card.actionButton else { return false }
        button.removeFromSuperview()
        card.actionButton = nil
        return true
    }

    /// Resize an open card to its current height, top edge anchored, without touching hover state. Two
    /// things change that height: the fold, and the action row coming or going with an alert.
    private func resizeOpenCard() {
        guard visible, expandedState, let card else { return }
        let metrics = currentMetrics()
        card.contentTop = contentTop(for: metrics)
        // The action row coming or going moves the bottom air with it (`cardBottomPadding`), so the
        // shrink below is the row's 24 *and* this step, never one of them.
        card.bottomPadding = cardBottomPadding
        card.needsLayout = true
        animateFrame(to: frame(expanded: true, metrics: metrics))
    }

    // MARK: - Content

    private func rebuildRows() {
        guard let card else { return }
        while rowViews.count < visibleRows.count {
            let view = IslandRowView(frame: .zero)
            view.onSelect = { [weak self] pid in
                guard let self else { return }
                // Answered by the host rather than here: one screen's row click has to end the reminder
                // on *every* screen (the other display's card would otherwise sit open for the rest of
                // the alert's seconds), and only the host can reach the other panels. It also carries
                // the hover latch the panel needs, since the pointer is inside this island by
                // construction — see `IslandHost.rowActivated`.
                self.onRowActivated?(pid)
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
                context: row.context,
                stamp: row.stamp
            )
        }
        card.rowViews = rowViews
        rebuildSummary(in: card)
        // A row built on this tick has to inherit the current visibility along with everything
        // else, or the ring on a freshly built busy row would start before anyone could see it.
        updateRowOnScreen()

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

    /// Whether the card's rows are really on screen: the panel is up **and** the card is open. A row
    /// parked at alpha 0 behind the collapsed pill is a row nobody can see — the pill is what carries
    /// the state then — and a panel that has been ordered out is not visible either.
    ///
    /// The pill's own status light has had this gate since it existed (`collapsedView.onScreen`); the
    /// rows' marks need it now that a card row draws one too, and the rule is the file's own third
    /// gate: a mark nobody can see must not keep the shared ticker subscribed.
    private var rowsOnScreen: Bool { visible && expandedState }

    /// Push that to every row's mark. Called wherever either half of it changes — `present`, `hide`,
    /// `setExpanded` — and after a rebuild, because a row created on this tick has to inherit it too.
    private func updateRowOnScreen() {
        for view in rowViews { view.onScreen = rowsOnScreen }
    }

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
        // A card that comes back on screen comes back with no dismissal held against it: `hide()`
        // clears the latch too, and this is the other side of the same coin — a latch set while the
        // panel was off screen (`collapse()` still latches an invisible panel) must not greet the
        // pointer on the way back in.
        hoverLatched = false
        // Now that the pill is really on screen its status light may animate; the
        // same flag is cleared in `hide()`, which is the only other place this
        // panel is ordered out.
        collapsedView?.onScreen = true
        updateRowOnScreen()
        startHoverTimer()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        // An alert cannot outlive the card it was showing: no rows means no card,
        // and a panel being retired is a screen that is gone.
        clearAlert()
        // A dismissal latch dies with the panel too: it latches the *hover* open off, and there is
        // nothing to hover once the island is off screen — leaving it set would make a returning island
        // ignore the pointer that is still sitting where it was.
        hoverLatched = false
        cancelPending()
        stopHoverTimer()
        expandedState = false
        guard visible else { return }
        visible = false
        // Off screen means nothing may keep animating: the status light's ticker
        // stops here, and the pill's counts stay as they were for the next time
        // the island is shown. The card rows' marks go with it.
        collapsedView?.onScreen = false
        updateRowOnScreen()
        panel?.orderOut(nil)
        applyAppearance(expanded: false, metrics: currentMetrics(), animated: false)
    }

    // MARK: - Expansion

    /// Open or close the card. `duration` is the alert's one-shot override; without
    /// it the file's own `animationDuration` is used, so hover's open and close are
    /// exactly what they were.
    private func setExpanded(_ value: Bool, animated: Bool, duration: TimeInterval? = nil) {
        cancelPending()
        // Anything *else* opening the card supersedes a dismissal: an alert is new information the user
        // has not answered, not the hover machine re-opening what they closed.
        if value { hoverLatched = false }
        expandedState = value
        // Before the guard: the card's rows follow `expandedState` whether or not this panel is up,
        // and a row's mark must stop the moment the card starts closing rather than at the next tick.
        updateRowOnScreen()
        guard visible, let panel else { return }
        let metrics = currentMetrics()
        let time = duration ?? animationDuration
        applyAppearance(expanded: value, metrics: metrics, animated: animated, duration: time)
        let target = frame(expanded: value, metrics: metrics)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = time
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// The window is sized to its visible bounds, so the same frame change that
    /// grows the capsule also governs hit-testing — no click monitor needed.
    private func applyAppearance(expanded: Bool, metrics: ScreenMetrics, animated: Bool, duration: TimeInterval? = nil) {
        guard let card, let collapsedView else { return }
        card.cornerRadius = cornerRadius(expanded: expanded, metrics: metrics)
        // Flush against the top edge: the card's own `draw` squares the top corners on every
        // display — see there for why the shape does not vary with the screen.
        card.contentTop = expanded ? contentTop(for: metrics) : rowInset
        // Same rule as `contentTop`, one edge down: the extra step is the *expanded* card's, and it only
        // applies while the card has no action row to sit above (`cardBottomPadding`).
        card.bottomPadding = expanded ? cardBottomPadding : bottomPadding
        card.rowViews = rowViews
        card.needsLayout = true

        collapsedView.notched = metrics.notched
        collapsedView.notchWidth = metrics.notchWidth

        let collapsedAlpha: CGFloat = expanded ? 0 : 1
        let rowsAlpha: CGFloat = expanded ? 1 : 0
        // Everything the card holds that is not the collapsed pill: the rows, the folded summary, and the
        // alert's action row — so the `Hide` button is invisible with the rows when the card is folded.
        var contentViews: [NSView] = rowViews
        if let summary = card.summaryView { contentViews.append(summary) }
        if let actionButton = card.actionButton { contentViews.append(actionButton) }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = (duration ?? animationDuration) * 0.7
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
        let inside = hoverRect(metrics: currentMetrics()).contains(NSEvent.mouseLocation)
        // **The latch, and the only place it can be released.** A dismissal leaves the pointer inside
        // the island — that is where a row is — so with no latch the poll would call `scheduleExpand`
        // on its very next tick and the card the user just dismissed would be back 0.35s later. The
        // latch is released by the pointer actually *leaving* the hover rect and by nothing else, so
        // the dismissal holds for as long as the pointer stays put.
        if hoverLatched {
            guard !inside else { return }
            hoverLatched = false
        }
        if inside {
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
    /// "cancel and reschedule" would push the deadline back on every tick
    /// and the island would never actually expand or collapse.
    private func scheduleExpand() {
        collapseWork?.cancel()
        collapseWork = nil
        // The latch is checked here as well as in `evaluateHover`, so no caller of the hover open can
        // get past a dismissal — `evaluateHover` is the only one today, and that is exactly the kind of
        // assumption a later edit breaks silently.
        guard visible, !hoverLatched, !expandedState, expandWork == nil else { return }
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
        // **An alert's card is not the hover poll's to fold.** That poll runs every
        // 0.15s and the pointer is usually *outside* the island when an alert fires
        // — that is what an unprompted expansion is — so without this guard the
        // alert would be folded one `hoverCloseDelay` after it opened and nobody would ever read
        // it. While one is armed, the alert's own timer owns the fold and hands the
        // card back here when it ends (`endAlert`). Expansion is deliberately not
        // guarded *by the alert*: unless a dismissal has latched the hover open off
        // (`hoverLatched`), the poll may still open the card mid-alert, it just may not
        // close it.
        guard !alertArmed, expandedState, collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setExpanded(false, animated: true)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverCloseDelay, execute: work)
    }

    private func cancelPending() {
        expandWork?.cancel()
        expandWork = nil
        collapseWork?.cancel()
        collapseWork = nil
    }

    // MARK: - Alert

    /// Hold the card for `seconds` and then hand it back. Re-arming **replaces**
    /// the deadline instead of stacking a second one: two transitions a moment
    /// apart must leave exactly one, or the first would fold a card the second is
    /// still holding open — and a stack of them is how a card ends up open for as
    /// long as sessions keep transitioning.
    private func armAlertTimer(seconds: TimeInterval) {
        alertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.endAlert()
        }
        alertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, alertMinimumSeconds), execute: work)
    }

    /// The alert's time is up: drop the mark and — this is the whole handover —
    /// give the card's fate back to the hover machine.
    ///
    /// Deliberately not a plain `setExpanded(false)`. If the pointer is inside the
    /// card by now the user is reading it, and folding it out from under the
    /// pointer would only make the poll expand it again on a later tick: a fold and
    /// an open for one decision. Outside the card the hover machine schedules its
    /// ordinary fold straight away, so an alert still closes itself with nobody
    /// near it — which is the whole point of it being unprompted.
    private func endAlert() {
        clearAlert()
        evaluateHover()
    }

    /// Take the alert off the card: the mark goes, and no timer is left to fire.
    /// Called from everywhere the card stops being the alert's — the menu opening
    /// (`collapse`), the island going off screen (`hide`), a row being clicked, and
    /// the alert's own timer — so there is exactly one way an alert ends and no
    /// path that can leave a mark up or a timer primed after the fact.
    private func clearAlert() {
        alertWork?.cancel()
        alertWork = nil
        alert = nil
        // The alert is off, so the card is no longer scoped to one session: the fold is re-derived here
        // for the same reason `alert(...)` re-derives it, because `alertArmed` is this calculation's input
        // and the alert's own timer ends it with no `update` tick in sight. **The full list comes back
        // immediately, not on the next fold.** Holding the scoped list until the card folded was the other
        // candidate and is not expressible: with the alert gone, `recomputeFold` already returns the whole
        // list on the very next poll tick, so a hold would need a second flag duplicating the fold this
        // file insists has one source — and the card would swap from `+k more` to five rows up to half a
        // second later, on a tick about something else, which reads as a flicker. Restoring here means the
        // card the pointer is still reading grows back in the same frame the mark leaves.
        let contentChanged = refoldCard()
        applyAlertMark()
        // The alert's chrome goes with the alert — the `Hide` button exists only while one is armed — and
        // that is a height change like any other, so an open card resizes. It is not a fold: `endAlert` and
        // `retractAlert` leave the card to the hover machine, which is what makes this the one exit that
        // shrinks an open card rather than closing it. (`collapse` folds first, so this is a no-op there —
        // `resizeOpenCard` is guarded on `expandedState`, and the restored rows come back invisibly for the
        // next open.)
        if syncActionRow() || contentChanged { resizeOpenCard() }
    }

    /// Re-derive the fold from the panel's current state — the rows, and the alert that may scope them —
    /// and rebuild the card's rows when that changed what is rendered. Reports whether the rendered content
    /// changed, so an open card can be resized to its new height.
    ///
    /// The one place a fold becomes a card. `update` runs it every poll tick, and the two moments an alert
    /// *starts* and *ends* run it too, because those flip the scope without necessarily being followed by an
    /// `update` that carries the rows — an alert normally arrives *before* the row list contains its session,
    /// and it can also land on a card the pointer already had open — so waiting up to half a second for the
    /// poll would leave a stale card on screen. An unchanged signature is a no-op, which is what keeps a
    /// re-arm on the *same* row from rebuilding anything: that case is the mark's, and the mark is re-applied
    /// by the caller either way.
    @discardableResult
    private func refoldCard() -> Bool {
        recomputeFold(metrics: currentMetrics())
        let signature = Self.signature(for: visibleRows, folded: foldedCount)
        guard signature != lastSignature else { return false }
        lastSignature = signature
        rebuildRows()
        return true
    }

    /// Mark the alerted row and clear the mark from every other row.
    ///
    /// Called from wherever the rows are rebuilt as well as when the alert is armed
    /// or dropped, because the alert normally arrives *before* the row it belongs
    /// to: holding the pid and re-applying it is what puts the mark on the row the
    /// user is meant to look at, rather than on the row as it looked one tick ago.
    ///
    /// Marked rows are matched by pid, which is the exact client↔session binding
    /// (`SessionMonitor`), so the mark can only ever land on the session that
    /// actually transitioned. While an alert is armed its row is also the card's
    /// only row (`recomputeFold`), so the two cannot disagree: the row that is shown
    /// is the row that is marked, and the pop lands where the eye already is. A nil
    /// pid — or a pid that is not in this tick's list — is the one case where the
    /// card falls back to the whole list and no row is marked, which is the honest
    /// outcome: the card has opened and the mark has nowhere to be.
    private func applyAlertMark() {
        let current = alert.map { IslandRowAlert(tint: $0.kind.color, generation: alertGeneration) }
        for (index, row) in visibleRows.enumerated() where index < rowViews.count {
            let marksThisRow = current != nil && alert?.pid != nil && row.pid == alert?.pid
            rowViews[index].alert = marksThisRow ? current : nil
        }
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
    /// `rowViews`: `hitTest` below hands clicks to session rows and (while an alert
    /// is armed) to the `Hide` button in its own frame, and never to this, so a
    /// click on the summary falls through to the card's expand/collapse toggle
    /// like any other blank part of the card.
    var summaryView: IslandSummaryView? {
        didSet { needsLayout = true }
    }
    /// The alert's action row — the card's one interactive thing that is not a session row. Nil unless
    /// an alert is armed (`IslandPanel.syncActionRow`), and deliberately not part of `rowViews`: it is
    /// the summary row's opposite, in that it *does* claim exactly its own frame in `hitTest` while the
    /// summary claims nothing.
    var actionButton: IslandCardButton? {
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
        total += actionRowHeight
        return total + bottomPadding
    }

    /// Height of the alert's action row: the card's short-row height, the same 24 the `+k more` footnote
    /// is laid out at, while the button is on the card. The presence is the card's own state, the number
    /// is the card's own field, and the panel budgets for it from the same constant
    /// (`IslandPanel.actionRowHeight`).
    private var actionRowHeight: CGFloat { actionButton == nil ? 0 : summaryRowHeight }

    // Anything not claimed by a row toggles the island.
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Route every click explicitly: a visible row claims its own clicks, the
    // rest of the card claims the remainder (so clicks on the collapsed status
    // dots still toggle, without relying on responder-chain forwarding). The
    // summary is deliberately not a candidate, so it stays inert as a row; the
    // alert's action row is, but only inside its own frame — the card's blank
    // area must keep toggling the island everywhere else (`onClick` itself refuses
    // that toggle while an alert is armed, which is where the alert's one-way-out
    // is kept, not here).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let actionButton, actionButton.alphaValue > 0.5, actionButton.frame.contains(local) {
            // The button itself, not `actionButton.hitTest`: its frame is the target, and letting AppKit
            // descend one level further would hand the click to the label inside it, which does nothing.
            return actionButton
        }
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
        if let summaryView {
            summaryView.frame = NSRect(x: inset, y: y, width: width, height: summaryRowHeight)
            y += summaryRowHeight
        }
        // The action row closes the card: the last child, trailing (right-aligned to the rows' own
        // inset), under everything, with no divider above it — the card's own placement, and it keeps
        // the button out of the rows' vertical rhythm rather than pretending to be one of them.
        if let actionButton {
            let width = IslandCardButton.width
            actionButton.frame = NSRect(
                x: bounds.width - inset - width,
                y: y,
                width: width,
                height: actionRowHeight
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(islandCardFillAlpha).setFill()
        path.fill()
        // Flatten the top: the surface hangs from the screen's top edge on **every** display, so a
        // rounded top corner there is a corner no one can see a use for, and on a notched display it
        // would leave black gaps beside the cutout. One shape for both kinds of screen — a flat top
        // and rounded bottom — so the pill does not change shape when the pointer moves between
        // displays. No stroke: an edge is a border, and this surface's only edge is the screen's.
        let strip = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: radius + 0.5)
        NSBezierPath(rect: strip).fill()
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
///     never a blank stub — followed by the number of sessions working, drawn **bare**: no
///     glyph, because the ring is this slot's glyph. The ring answers "is it happening" in two
///     channels (tint *and* motion) precisely so that taking the motion away — Reduce Motion —
///     does not take the answer with it; the number answers "how many". An orange `⟳` used to
///     sit between them, which made the same statement twice with two orange shapes side by
///     side (see `symbol(for:)`).
///   - **right: "what needs me, most urgent first".** One badge per remaining state that
///     has sessions — error `!` red, waiting `?` blue, idle `✓` green, in that order —
///     each a status glyph plus the number of sessions in that state. This is the order
///     `IslandPanel.attentionRank` sorts the expanded card's rows by, so the wing still
///     states the card's priority; the running state is simply no longer part of it.
///
/// The pill states the running count in two parts, which is not noise: the ring is its
/// *pulse* (something is happening now, right at the pill's leading edge) and the number
/// beside it is its *tally* (how many). Both are read from one dictionary (`counts`) and
/// gated on the same count, so the ring cannot turn while the number is absent or vice
/// versa. Only the ring carries the colour: every count on this pill is white, and the
/// running number is no exception — orange belongs to glyphs, and that slot has none.
///
/// **Every state gets its own slot, so nothing is ever dropped.** With an error, a waiting,
/// a running and a finished session the pill shows all four — the running count bare, beside
/// the ring, and three glyph+count badges on the right — and both flanks are provisioned for
/// their own slots at two digits (`requiredLeftFlankWidth`, `requiredRightFlankWidth`). That is the lesson of
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

    /// The state the **left** flank's slot shows: how many sessions are working, beside
    /// the ring that says whether any are. It is named apart from `rightBadgeOrder` on
    /// purpose — the pill's left-to-right reading is **no longer one urgency list**: it
    /// is "is work happening + how much" (left), then "what needs me, most urgent first"
    /// (right). Ranking the running count inside the right flank's order is what made the
    /// old single `badgeOrder` a lie once the slot moved.
    static let runningStatus: SessionStatus = .busy

    /// Every status the pill gives a slot to, in the pill's reading order: the running one first, then the
    /// right flank's, most urgent first. One place that lists all four, so a state cannot be forgotten by
    /// one side while the other draws it. Three of the four slots draw a glyph and a count; the running
    /// one draws the count alone.
    static var badgeStatuses: [SessionStatus] { [runningStatus] + rightBadgeOrder }

    /// Space between two elements sitting in the same region: the ring and the running count in
    /// the left flank, two badges in the right flank, or the whole capsule on a
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
    /// all four counts sit in one centred block: the ring, the three glyph+count badges of the right
    /// flank, the running slot's **bare count**, the gaps between them and the same clearance the wings
    /// use. This is the floor `islandStandInCapsuleWidth` puts under its screen share; without it the
    /// share's own 160pt floor is narrower than the block, and the last count would be trimmed at the
    /// capsule's edge — a wrong count, silently, on a small external display.
    ///
    /// The running slot is the one item here that costs a count and no glyph, which is why the block is
    /// 19pt narrower (172) than it was while that slot still carried a glyph (191).
    static let standInCapsuleMinWidth: CGFloat = {
        let items = 1 + badgeStatuses.count
        let content = IslandRing.diameterCap
            + CGFloat(badgeStatuses.count - 1) * twoDigitBadgeWidth
            + twoDigitCountWidth
        let gaps = CGFloat(items - 1) * groupGap
        return (content + gaps + 2 * minFlankClearance + flankMargin).rounded(.up)
    }()

    /// Width of **both** flanks of the notched pill. Symmetry sets it: it is the wider of the
    /// two sides' content requirements, and both sides get it. See `islandFlank` for why the
    /// smaller (one-digit) reading of the right flank is not an option — `place` trims an
    /// overrun at the capsule edge silently, and a wrong count is the one thing this pill may
    /// not do. Every extra point sits over the menubar strip either side of the cutout.
    static let flankWidth: CGFloat = max(requiredLeftFlankWidth, requiredRightFlankWidth)

    /// What the **left** flank's content costs at its widest: the ring, the gap, and the running slot's
    /// two-digit **count**. No glyph in that sum any more — the ring is the running mark, so the count is
    /// drawn bare (`show(_:count:in:)`). The flank is wider than this once symmetry is taken into account,
    /// and this is the width its content is centred against (`leftContentInset`).
    private static var leftContentWidth: CGFloat {
        IslandRing.diameterCap + groupGap + twoDigitCountWidth
    }

    /// Where the left flank's content starts, so the pair it is provisioned for sits **centred**
    /// in the symmetrically-sized wing: `(flankWidth − leftContentWidth) / 2`.
    ///
    /// A *fixed* offset, which is the whole point: the ring is the one element that is always
    /// there, so its position is a landmark, and the layout pins it here whether or not the count is
    /// beside it. Centring the *actual* content instead would drag the ring sideways every time a
    /// session started or stopped. The consequence when nothing is running is that the ring sits at
    /// this offset with the count's room empty to its right — and since that room runs into the cutout,
    /// which has no pixels either, the emptiness is black beside black and reads as the notch being
    /// wider, not as a hole in the pill.
    ///
    /// The offset follows `leftContentWidth`, so the *pair* stays centred in the wing: dropping the
    /// running slot's glyph moved the ring 37 → 47 in one step, and it stays at 47 in both states —
    /// that constancy is what this number is for, not the value itself.
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

    /// Least width the left flank needs: the running ring, the gap, and that slot's two-digit count,
    /// with the clearance on both sides — the same formula as the right flank's, over what this side holds.
    /// 12 + 6 + 18.565 = 36.565 of content, so it rounds up to **43**.
    ///
    /// It is far below the right flank's 130, which is the point: the pill's wings stay the same width
    /// (`islandFlank` is the wider of the two, and the right's 130 still binds), so this number only sets
    /// where the pair sits inside the wing. What it *must* not do is overrun: `place` trims an overrun at
    /// the capsule edge silently, and a two-digit count that got trimmed would be a wrong fact.
    static let requiredLeftFlankWidth: CGFloat = {
        (IslandRing.diameterCap + groupGap + twoDigitCountWidth
            + 2 * minFlankClearance + flankMargin).rounded(.up)
    }()

    /// Width of a two-digit count at the font the counts are drawn with — the running slot's whole badge,
    /// and the number half of every other badge. `islandLabelWidth`, so the digits cannot be shaved, and
    /// tabular, so they cannot shimmy.
    private static var twoDigitCountWidth: CGFloat { IslandMarkerGroup.twoDigitCountWidth }

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
    /// Both sides are filled here and nowhere else.
    ///
    /// The mark's tint is no longer handed in from here: the ring's orange is `IslandRing.runningTint`,
    /// because the menubar's mark and the card's rows draw the same ring and a tint that came from the
    /// pill's vocabulary would only be *equal* to theirs by coincidence. `color(for: .busy)` reads that
    /// same constant for the badge beside it, so the tally and the ring are still one statement.
    ///
    /// The mark is never hidden — see `IslandActivityView`: it is the left flank's
    /// status light, so with nothing running it is still there, dim and still,
    /// rather than leaving that side of the pill blank.
    private func applyCounts() {
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
        // The **running** slot has no glyph: the ring beside it is its glyph, so its count is drawn bare.
        // For every other status the glyph *is* the badge's meaning, and a missing one drops the badge whole
        // rather than leaving a digit with nothing to say (the failure this pill records).
        let symbol = Self.symbol(for: status)
        let image = symbol.flatMap {
            IslandMarkerGroup.badgeImage(symbol: $0, color: Self.color(for: status), description: status.rawValue)
        }
        guard symbol == nil || image != nil else {
            group.clear()
            group.isHidden = true
            return
        }
        group.marker = image
        group.number = count
        group.isHidden = false
    }

    /// The pill's badge vocabulary: the one place a status becomes a glyph and a tint, so a status can only
    /// ever look like one thing on the pill. The running entry is **`nil`** — the ring beside the count is the
    /// running mark (`IslandRing`, the pulse; the count is its tally), so that slot's count carries no glyph of
    /// its own. An earlier version drew the arrow-circle here as well, which put the same statement on the pill
    /// twice: an orange shape that turned right next to an orange shape that turned, one of them with a number
    /// stuck to it. Which is exactly the "badge that lost its number" problem inverted — a *number* that kept a
    /// redundant glyph.
    private static func symbol(for status: SessionStatus) -> String? {
        switch status {
        case .busy: return nil
        case .waiting: return "questionmark.circle.fill"
        case .idle: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private static func color(for status: SessionStatus) -> NSColor {
        switch status {
        // The same constant the ring is stroked with, not a second orange that matches it.
        case .busy: return IslandRing.runningTint
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
/// right: the number of sessions in that status, preceded by a status glyph **when the status has
/// one**. The running slot does not: the ring beside it is its glyph (see
/// `CollapsedContentView.show(_:count:in:)`), so that slot is a bare count.
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

    /// The badge's leading glyph, already tinted for its status, or `nil` when the badge has none: the pill's
    /// **running** slot is a bare count, because the ring beside it *is* its glyph
    /// (`CollapsedContentView.show(_:count:in:)`). For every other status a `nil` marker means the group holds
    /// no badge at all and its count is not drawn either — a number without its glyph says nothing.
    var marker: NSImage? {
        didSet { applyMarker() }
    }

    /// How many sessions the badge counts. **This is what makes the badge a badge**: a count of zero draws
    /// nothing even if a glyph is set, so `clear()` and "no sessions in this state" are the same state.
    var number: Int = 0 {
        didSet {
            guard number != oldValue else { return }
            numberLabel.stringValue = "\(number)"
            numberLabel.isHidden = number == 0
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

    /// Width of the widest status glyph at the pill's point size: what the marker of any badge that
    /// **has** one costs. The running slot is no longer among them — its glyph is the ring beside it, so
    /// it draws a bare count — and neither is that slot's old `arrow.clockwise.circle.fill`, which was
    /// measured here long after nothing drew it. Measured from the symbols the badges actually use, at the
    /// point size they are actually drawn at, so it cannot go stale if a symbol's artwork changes.
    static let widestGlyphWidth: CGFloat = {
        let config = NSImage.SymbolConfiguration(pointSize: markerPointSize, weight: markerWeight)
        let symbols = ["questionmark.circle.fill",
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

    /// Full width of the badge: the glyph and its gap when there is one, then the digits. The digits get the
    /// width the cell needs to draw them unclipped, not the bare advance (`islandLabelWidth`), so a count
    /// cannot shimmy between 1 and 2 digits. **Zero without a count** — a badge is "this many sessions in
    /// this state", so the count is what makes it exist; the glyph is optional (see `marker`). A badge is a
    /// fixed-height thumbnail of one status, so it ignores the height it is asked about — only the status
    /// light's size depends on the pill's height.
    func flankWidth(atHeight height: CGFloat) -> CGFloat {
        guard number > 0 else { return 0 }
        return markerOffset + islandLabelWidth(for: numberLabel)
    }

    private var markerWidth: CGFloat { marker?.size.width ?? 0 }

    /// Where the count starts: past the glyph and its gap when there is one, at the badge's leading edge when
    /// there is not — the running slot's bare count.
    private var markerOffset: CGFloat { marker == nil ? 0 : markerWidth + Self.markerGap }

    override func layout() {
        super.layout()
        let labelSize = numberLabel.intrinsicContentSize
        numberLabel.frame = NSRect(
            x: markerOffset,
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
        // Only the glyph's own visibility is the glyph's business. A glyph and a count are drawn
        // *independently* here: the running slot has a count and no glyph, and a bare digit used to be what
        // made the old dot read as a legend-less status light — that mark is now the ring beside the count,
        // so a legend-less digit is exactly what this slot should look like.
        glyphView.isHidden = marker == nil
        needsLayout = true
    }
}

// MARK: - The running mark

/// The app's one running mark — a hollow ring with a 90° gap — and the only place its numbers or
/// its shape come from.
///
/// It is drawn on four surfaces and hosted two ways: as a live `NSView` (`IslandActivityView`) on
/// the collapsed pill's left flank and in the expanded card's rows, and as a rendered `NSImage` —
/// `image(pointSize:angle:)`, built from the *same* `arcPath` the view strokes — in the menubar
/// title and the dropdown's session rows, neither of which can host a view. Two hosts, one
/// construction: the drawn mark and the rendered one cannot be two different marks.
///
/// **One speed, one phase.** `stepDegrees`/`tickInterval` (18° per 0.06s — 300°/s, one revolution
/// in 1.2s) are every site's now, the menubar's included. That mark used to run at 45° per tick
/// (750°/s) for a reason that belonged to its *shape*: it was a filled disc with a 70° wedge knocked
/// out, so what moved was a low-contrast notch inside a solid shape, and 300°/s barely registered
/// as motion on it. The ring is the opposite — a 90° gap in a thin stroke, a large high-contrast
/// discontinuity that travels the whole circumference — and at 750°/s that gap laps the ring every
/// 0.48s and reads as a warning blink rather than a steady "working" pulse. 300°/s is the classic
/// indeterminate rate and has been this mark's rate since it existed. `angle(at:)` is a pure
/// function of the clock rather than a per-instance accumulator, so every ring on screen — pill,
/// card rows, menubar title, menu rows — is at the same angle at the same instant by construction,
/// and a late or dropped tick cannot make one of them drift away from the others.
///
/// **One tint.** `runningTint` is the orange every surface already used for a running session, so the
/// pill's running badge, the menubar's mark and the card's rows can no longer disagree about what
/// "running" looks like; `restingTint` is the dim neutral the pill's ring takes when nothing is
/// running — a state only the pill can be in, because the other three surfaces only ever draw a mark
/// for a session that *is* running (see `image(pointSize:angle:)`).
enum IslandRing {

    /// Degrees of the ring left open. A three-quarter ring is the most recognisable "working" mark
    /// there is, and a hollow ring's gap reads smaller than the same angle knocked out of a solid
    /// disc.
    ///
    /// It stays 90° at every size instead of growing as the ring shrinks, because what has to stay
    /// legible is the gap *in stroke widths*, and the round caps already scale with the stroke.
    /// Measured on the rendered ring, the opening a 90° gap leaves is **3.0 stroke widths at the
    /// pill's 12pt** — 12 is the narrowest ring this app draws (the menubar title measures to the same
    /// 12.000; a card row is 13.125 and a dropdown row 14.000), so no other surface has a tighter
    /// opening than the one already measured. Under ~3 stroke widths it stops reading as an opening at
    /// all, which is the floor: if the ring shrinks again, widen the gap rather than lower the stroke.
    static let gapDegrees: CGFloat = 90

    /// Angle the ring rests at when it is not turning. This is the arc's start angle, and the gap
    /// opens `gapDegrees` counter-clockwise from it, so `90 - gapDegrees / 2` centres the gap on
    /// 12 o'clock and a still ring is symmetric instead of looking stopped at random.
    static let restingAngle: CGFloat = 90 - gapDegrees / 2

    /// The ring's stroke, as a share of its diameter, and a floor under it. A stroke proportional to
    /// the ring keeps a large one from reading as a hairline outline; the floor keeps a small one
    /// from reading as a hairline *ring*, which is what the bare `0.14 × diameter` gives at the
    /// bottom of the useful range (1.7pt at 12pt). 2pt is the pill's own line weight — an 11pt
    /// semibold digit's stems are ~1.7pt — so a floored ring is never thinner than the numbers it
    /// sits opposite.
    ///
    /// The floor is what binds on **every** surface this app draws the ring on: 0.14 × 12 = 1.68 (the
    /// pill and the menubar title), × 13.125 = 1.84 (a card row), × 14 = 1.96 (a dropdown row). So all
    /// four stroke at exactly 2pt, and a mark that moves between surfaces keeps the same line weight.
    static let strokeRatio: CGFloat = 0.14
    static let strokeFloor: CGFloat = 2.0

    static func strokeWidth(forDiameter diameter: CGFloat) -> CGFloat {
        max(strokeFloor, diameter * strokeRatio)
    }

    /// The tick interval and the angular step: the ring's *cadence* and its *speed*, kept together
    /// because one without the other is meaningless — and kept as two numbers rather than one, because
    /// the cadence is also how often each host repaints (`IslandRingTicker`, and the menubar's own
    /// timer) while the speed is what `angle(at:)` interpolates.
    static let tickInterval: TimeInterval = 0.06
    static let stepDegrees: CGFloat = 18

    /// Seconds per revolution, derived from the two above so the speed and the cadence can never
    /// disagree: at the nominal cadence a tick advances the ring by exactly `stepDegrees`.
    static let revolutionSeconds: TimeInterval = tickInterval * Double(360 / stepDegrees)

    /// The ring's angle `time` into the revolution. Absolute (measured from the reference date) so
    /// every ring in the app reads the same phase, clockwise — i.e. decreasing, which is the
    /// direction `arcPath`'s `clockwise: true` turns in the unflipped space the mark is drawn in.
    static func angle(at time: Date) -> CGFloat {
        let phase = time.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: revolutionSeconds) / revolutionSeconds
        return restingAngle - CGFloat(phase) * 360
    }

    /// The pill's ceiling for the ring's diameter, and the air kept outside it on every side.
    ///
    /// **12pt, so the ring's outer edge lands on a badge glyph's ink.** The badge glyphs are 11pt SF
    /// Symbols whose ink is a 12pt circle inside a 14pt image box
    /// (`IslandMarkerGroup.widestGlyphWidth`); the disc the eye sees is that 12pt of ink, so a 12pt
    /// ring is the same size as a glyph rather than 2pt larger. That is the whole requirement: the ring
    /// and the badges' glyphs are the pill's two kinds of mark, and their silhouettes have to match — the
    /// harness measures both boxes off one render of the pill and asserts they agree to 0.3pt
    /// (`silhouetteMatch`), and the measure has to be the silhouette's **extent** (a filled symbol's
    /// outermost sliver is a low-coverage skirt a strict cut-off trims to 11.0–11.25, while a stroked
    /// ring's harder edge still reports 12.00 — rim density, not size). The two no longer share a flank —
    /// the running slot's count is bare and the ring is its glyph — so what the match is now measured
    /// across is the ring against the three glyph badges on the far side of the cutout; the number is the
    /// same and the harness check is unchanged. Nothing else on the pill hangs off this number: the flank
    /// is derived from it, so the wing and the window's x follow automatically.
    ///
    /// **What it costs.** At 12pt with the 2pt stroke the ring's centre-line is 10pt — narrower than
    /// the glyphs' ink circle, which is fine because a hollow ring is *judged* by its outer edge when
    /// it sits next to a filled disc — and the 90° gap leaves the 3.0 stroke widths above, the
    /// thinnest of the range. A 14pt cap was chosen before precisely to keep that number comfortable;
    /// the maintainer's eye says the two shapes have to be the same size, and that beats gap comfort.
    /// If the opening ever looks like a nick, `gapDegrees` is the lever, not this cap.
    ///
    /// The diameter is `min(diameterCap, height - 2 * inset)`, so the clamp is only a guard for a
    /// shorter pill: at 12 it binds on neither of the pill's two surfaces (32pt notched, 24pt
    /// stand-in capsule), so both draw the ring at exactly 12. The menubar title lands on the same 12
    /// from the other direction — it measures the check-circle's ink at 11pt and gets 12.000 — which
    /// is a coincidence worth knowing about rather than a rule, and the reason both are quoted.
    static let diameterCap: CGFloat = 12
    static let inset: CGFloat = 4

    /// The pill's rule for the ring's diameter in a pill `height` tall: the ceiling, clamped so it
    /// keeps its air on a shorter pill. Surfaces whose mark is not sized by the pill (a card row sets
    /// its own diameter) do not use this.
    static func diameter(forHeight height: CGFloat) -> CGFloat {
        max(0, min(diameterCap, height - 2 * inset))
    }

    /// The mark's tint while something is running. One constant: the pill's running badge
    /// (`CollapsedContentView.color(for: .busy)`), the menubar's mark and the card's rows all read
    /// this, so the orange beside the ring and the orange on the ring are one statement.
    static let runningTint = NSColor.systemOrange

    /// The mark's tint when nothing is running: a dim neutral, so a quiet wing still reads as
    /// *present* without competing with the badges. It is in the same family as the card's
    /// subordinate tones (its placeholders are white α0.32, its context line α0.5) — and, crucially,
    /// it is far enough from `runningTint` in both hue and brightness that "running" survives on the
    /// tint alone when Reduce Motion has taken the rotation away.
    static let restingTint = NSColor.white.withAlphaComponent(0.40)

    /// The one construction of the mark's shape: an arc whose **outer edge** lands on `diameter`, so
    /// the mark is sized by the space it occupies rather than by its centre-line — which is the only
    /// way its outer edge can be compared with the disc it stands in for. Both hosts go through this
    /// (the live view strokes it, the image renderer strokes the same path into a canvas), so a change
    /// to the shape lands on all four surfaces at once and no surface can quietly keep an older one.
    static func arcPath(diameter: CGFloat, angle: CGFloat, center: NSPoint) -> NSBezierPath {
        let radius = (diameter - strokeWidth(forDiameter: diameter)) / 2
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: angle,
            endAngle: angle - (360 - gapDegrees),
            clockwise: true
        )
        path.lineWidth = strokeWidth(forDiameter: diameter)
        path.lineCapStyle = .round
        return path
    }

    /// The mark as an `NSImage`, for the two surfaces that cannot host a view: the menubar title's
    /// attachment and the dropdown's session rows. Always the running tint — see `restingTint`.
    ///
    /// **Its canvas and its diameter are both load-bearing.** The canvas is the check-circle's image
    /// *box* at `pointSize`, because that is what the menubar's attachment bounds and its baseline
    /// nudge were computed against, and what `contextDetailItem` measures to lay the dropdown's detail
    /// row under the session name. The diameter is that circle's measured **ink** — 12.000pt at the
    /// title's 11pt, 14.000 at a row's 13pt — because that is the disc the eye compares it with, so a
    /// busy row stays the same size as the idle, waiting and error rows beside it. The filled spinner
    /// this replaced kept the same pair of numbers for the same two reasons; the difference is that
    /// they are now measured from the symbol rather than assumed, and that the shape inside them is the
    /// one mark this app draws.
    static func image(pointSize: CGFloat, angle: CGFloat) -> NSImage {
        let geometry = markGeometry(pointSize: pointSize)
        let path = arcPath(
            diameter: geometry.diameter,
            angle: angle,
            center: NSPoint(x: geometry.canvas.width / 2, y: geometry.canvas.height / 2)
        )
        return NSImage(size: geometry.canvas, flipped: false) { _ in
            runningTint.setStroke()
            path.stroke()
            return true
        }
    }

    /// The size `image(pointSize:angle:)` returns an image at. A layout that has to reserve the mark's
    /// width — the dropdown's detail row, aligning its text under the session name rather than under
    /// the glyph — asks for it here instead of duplicating the measurement.
    static func canvasSize(pointSize: CGFloat) -> NSSize {
        markGeometry(pointSize: pointSize).canvas
    }

    /// Outer diameter of the ink of a `*.circle.fill` status glyph at a configuration — the disc a ring
    /// stands in for. Used by the surfaces that size their own mark instead of taking the pill's rule:
    /// the card rows.
    ///
    /// `fittedTo` is the box the surface draws that glyph into, when it draws it smaller than its own
    /// image: a row's glyph view is `islandRowGlyphSize` across and `.scaleProportionallyDown` shrinks
    /// the 13pt image (a 16pt box) to fit, so the disc the eye actually sees there is the measured ink
    /// scaled by that fit — 13.125pt, not the 14pt a dropdown row draws, and not the pill's 12. Without
    /// it a busy row's mark would be a visibly different size from the idle, waiting and error discs in
    /// the rows beside it, which is the one thing that column may not do.
    static func discDiameter(symbol: String, pointSize: CGFloat, weight: NSFont.Weight, fittedTo box: CGFloat? = nil) -> CGFloat {
        let measured = measure(GlyphKey(symbol: symbol, pointSize: pointSize, weight: weight.rawValue))
        guard let box, measured.box.width > box else { return measured.ink }
        return measured.ink * box / measured.box.width
    }

    // MARK: Measurement

    /// The disc the mark stands in for: the check-circle, which is the circle *every* `*.circle.fill`
    /// status glyph draws and therefore the disc the menubar's mark and a card row both replace.
    ///
    /// Not the error triangle, deliberately: its ink is wider (14.875pt at 13pt semibold against the
    /// circles' 14.000), it is the one status whose mark is not a disc, and the filled spinner this
    /// replaced ignored it too.
    private static let discSymbol = "checkmark.circle.fill"

    private struct GlyphKey: Hashable {
        let symbol: String
        let pointSize: CGFloat
        let weight: CGFloat
    }

    /// The measured box and ink of each distinct symbol configuration, computed once. Geometry is
    /// constant for a given (symbol, pointSize, weight) and measuring it is a render plus a pixel scan
    /// at 8×, so repeating it every spinner frame would be absurd — the same reason the old spinner
    /// memoized its geometry, kept where the rest of the measurement now lives.
    private static var measuredDiscs: [GlyphKey: (box: NSSize, ink: CGFloat)] = [:]

    /// Share of the image box a disc's ink occupies, as a fallback for the day a symbol cannot be
    /// measured: the low end of what this machine measures (0.8571 at 11pt, 0.8750 at 13pt). Better a
    /// slightly small ring than a zero-width one.
    private static let discInkFallbackRatio: CGFloat = 0.857

    private static func markGeometry(pointSize: CGFloat) -> (canvas: NSSize, diameter: CGFloat) {
        let measured = measure(GlyphKey(symbol: discSymbol, pointSize: pointSize, weight: NSFont.Weight.medium.rawValue))
        return (canvas: measured.box, diameter: measured.ink)
    }

    private static func measure(_ key: GlyphKey) -> (box: NSSize, ink: CGFloat) {
        if let cached = measuredDiscs[key] { return cached }
        let cfg = NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: NSFont.Weight(rawValue: key.weight))
        let box = symbolImageSize(key.symbol, cfg: cfg)
        let measured = (box: box, ink: visualGlyphDiameter(symbol: key.symbol, cfg: cfg) ?? box.width * discInkFallbackRatio)
        measuredDiscs[key] = measured
        return measured
    }

    /// Size of a symbol's image, i.e. its box rather than its ink: `checkmark.circle.fill` at 11pt
    /// medium is a 14pt box around 12pt of ink, at 13pt a 16pt box around 14. Both that box and that
    /// ink are read off the real symbol in `discDiameter`/`markGeometry` rather than assumed, so the
    /// mark cannot drift from the discs beside it if a symbol's artwork changes.
    private static func symbolImageSize(_ symbol: String, cfg: NSImage.SymbolConfiguration) -> NSSize {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return NSSize(width: 14, height: 14)
        }
        return (base.withSymbolConfiguration(cfg) ?? base).size
    }

    /// Diameter of a glyph's circle, measured from its opaque bounds so different SF Symbols can be
    /// compared regardless of their image padding.
    private static func visualGlyphDiameter(symbol: String, cfg: NSImage.SymbolConfiguration) -> CGFloat? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let image = base.withSymbolConfiguration(cfg) ?? base
        let scale: CGFloat = 8
        let px = Int((max(image.size.width, image.size.height) * scale).rounded())
        guard px > 0,
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: px * px * 4)
        var minX = px, maxX = -1, minY = px, maxY = -1
        for y in 0..<px { for x in 0..<px where ptr[(y * px + x) * 4 + 3] > 128 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        } }
        guard maxX >= 0, maxY >= 0 else { return nil }
        return CGFloat(max(maxX - minX + 1, maxY - minY + 1)) / scale
    }
}

/// The island's one tick source. Every live ring on the island subscribes while it is playing and
/// unsubscribes the moment it stops, so a card holding four busy rows plus the pill behind them costs
/// **one** 0.06s timer rather than five: the pill's mark used to be one timer for the whole app, and
/// per-row marks must not turn that into one per row. Each tick reads the angle once
/// (`IslandRing.angle(at:)`) and hands the same number to every subscriber, so all of them are in phase
/// by construction and none can drift.
///
/// The menubar is deliberately **not** a subscriber: its tick drives `NSImage` swaps that `AppDelegate`
/// owns, and it runs whenever anything is busy rather than only while a window is up. Its phase still
/// matches, because it reads the same function of the clock.
private final class IslandRingTicker {

    static let shared = IslandRingTicker()

    private var timer: Timer?
    private var subscribers: [ObjectIdentifier: (CGFloat) -> Void] = [:]

    /// The handler must capture its view weakly: this class is the only thing holding it, and a ring
    /// must never be what keeps a view alive.
    func subscribe(_ view: IslandActivityView, handler: @escaping (CGFloat) -> Void) {
        subscribers[ObjectIdentifier(view)] = handler
        start()
    }

    func unsubscribe(_ view: IslandActivityView) {
        subscribers.removeValue(forKey: ObjectIdentifier(view))
        if subscribers.isEmpty { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: IslandRing.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The ticker exists only while somebody is playing. A quiet island costs nothing at all — no
    /// timer, and the marks are simply drawn still.
    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let angle = IslandRing.angle(at: Date())
        // A snapshot, because a handler whose gate has closed unsubscribes itself from inside this
        // loop (`ringTick` → `updateMotion` → `stopTicking`) — mutating the dictionary mid-iteration
        // would be a crash, and that is exactly the case the tick is meant to catch.
        for handler in Array(subscribers.values) { handler(angle) }
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
/// It is drawn as vector paths so it stays crisp at every angle — the same construction, from the
/// same `IslandRing.arcPath`, that the menubar title and the dropdown rows render as images. Every
/// running mark in the app is now this ring; what it is deliberately **not** is any *other* shape in
/// its neighbourhood. A filled disc would be: the menubar's mark used to be one (a filled disc with a
/// rotating wedge knocked out), and every badge glyph on the pill still is (`…circle.fill` is a disc
/// with a knocked-out mark) — so a filled disc here would be an oversized copy of the orange badge
/// beside it, i.e. a badge that lost its number. A hollow ring with a gap is a different shape class:
/// it reads as "working" at a glance, it lets the pill's black through the middle of it, and it
/// cannot be mistaken for a badge. That is the part of the old argument that still holds, and it is
/// the reason the ring — not a disc-shaped spinner — is the mark the menubar and the dropdown were
/// given.
///
/// **Its size, and what it costs, are `IslandRing.diameterCap`'s to state** — 12pt on the pill, so the
/// ring's outer edge lands on the badge glyphs' 12pt of ink and the two silhouettes match to the
/// harness's 0.3pt (`silhouetteMatch`). What is worth repeating here is the consequence for *this*
/// surface: the 12pt is a ceiling on the flank's layout, the flank width is derived from it
/// (`CollapsedContentView.requiredLeftFlankWidth`), and every other surface measures its own
/// equivalent from the symbol it stands in for instead.
///
/// The pill's mark carries no number and is not inflated for presence: 63pt² of ink against the filled
/// glyph's ~99pt² disc, which is the right hierarchy for the one mark on the pill that carries no
/// count — hue and motion earn the attention instead. (The caps this replaced were 24pt — 75% of the
/// pill's height, 2.1× a glyph's ink mass, so it read as the pill's headline while being its least
/// informative element — and then 14pt, which matched the glyphs' *box* by putting the ring's
/// centre-line on their ink. Every one of those was chosen off a ramp rendered from this code, now at
/// 11/12/13/14pt: 11 would be 1pt *under* the glyph and its gap falls to 2.5 stroke widths, so there
/// is nothing to trade.)
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
///     and **there is nothing subscribed at all**: that is the user's rule and the CPU rule at
///     once. A ticker to hold a mark still would be a timer spent on nothing.
///  2. **Reduce Motion.** `NSWorkspace.accessibilityDisplayShouldReduceMotion` holds
///     the ring at its resting angle instead of turning it; the tint still says
///     which of the two states it is, so nothing is lost. This is the choice
///     CodeIsland makes with its pulsing badge, and the setting is re-read when the
///     system announces it changed. Every surface that draws this mark honours it the same
///     way now — the menubar's and the dropdown's images are held at the resting angle too, and
///     the menubar stops its own timer rather than repainting a still image 16.7 times a second
///     (`AppDelegate.updateSpinner`).
///  3. **the mark must be on screen.** For the pill that is the panel's `present()`/`hide()` — the
///     only two places the island is ordered in or out — and for a card row it is those two *and*
///     the card being open (`IslandPanel.rowsOnScreen`), because a row parked at alpha 0 behind the
///     collapsed pill is not a row anyone can see. Either way `onScreen` is set on the way past, so
///     a ring nobody can see never keeps the shared ticker subscribed. The tick re-checks the same
///     flags, so the two cannot drift apart in the other direction either.
private final class IslandActivityView: NSView, IslandFlankElement {

    /// Every number about the ring's *shape* — its gap, its stroke, its cadence and its tints — lives
    /// in `IslandRing`, because the menubar title and the dropdown rows draw this same mark as an
    /// image and must not be able to drift from the view. What is left here is what only the *view*
    /// knows: whether it is running, whether anyone can see it, and how big it is where it stands.
    ///
    /// The ring has no width constant of its own either: it contributes its diameter to the flank
    /// (`CollapsedContentView.requiredLeftFlankWidth`), the *air* around it comes from that flank's
    /// clearance budget, and `IslandRing.inset` is what pins its leading edge. A separate "ring plus
    /// its air" width existed only while the ring had the flank to itself, and leaving it here would
    /// have been a constant that lied about what the flank holds.

    /// The mark's diameter when the surface sets it, instead of the pill's height rule deriving it.
    /// The card's rows use it: their glyph column is a fixed `islandRowGlyphSize` box, and the mark
    /// inside it has to match the discs that box draws for every other status (see
    /// `IslandRowView.ringDiameter`). The pill leaves it nil and takes `IslandRing.diameter(forHeight:)`.
    var markDiameter: CGFloat? {
        didSet { if markDiameter != oldValue { needsDisplay = true } }
    }

    /// Whether a session is running. The caller sets this from the same count that
    /// fills the orange badge, so the two can only ever agree. It drives both
    /// channels at once — the tint and the motion — which is what keeps a running
    /// mark and a quiet one from ever looking the same.
    var running = false {
        didSet {
            guard running != oldValue else { return }
            // The tint changed, so the mark must be redrawn whether or not it is
            // also about to start or stop turning.
            needsDisplay = true
            updateMotion()
        }
    }

    /// What the ring is drawn in: the running tint or the resting one, and nothing
    /// else — this is the single expression of "which state is the mark in".
    private var tint: NSColor { running ? IslandRing.runningTint : IslandRing.restingTint }

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

    private var angle = IslandRing.restingAngle
    private var workspaceObservers: [NSObjectProtocol] = []

    /// How far the **pill's** mark sits below the geometric centre, in points. The badges' ink and the
    /// ring's box are both centred, but the ring is a hollow stroke and the digits beside it are solid,
    /// so on the collapsed pill — and only there, on the eye's measure — the mark reads a couple of
    /// points high. A card row's mark is centred in a fixed glyph column against the row's other discs
    /// and takes no nudge (`markDiameter` is what tells the two hosts apart: set only by a row).
    private var pillMarkDrop: CGFloat { markDiameter == nil ? Self.pillMarkDropPoints : 0 }
    private static let pillMarkDropPoints: CGFloat = 0.5

    /// Drawn in the standard, unflipped space, like the menubar's mark, so the same
    /// sign of rotation turns both clockwise.
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
        // Leave the shared ticker the moment this mark goes away: `stopTicking` is the only
        // unsubscribe, and a deallocated view never gets another chance to call it.
        stopTicking()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
    }

    /// Width for layout: the mark's own diameter at this height, so a shorter pill
    /// gets a smaller mark rather than one clipped to the pill's edge — or the diameter the
    /// surface fixed for it, when the mark is not sized by a pill at all (a card row).
    func flankWidth(atHeight height: CGFloat) -> CGFloat {
        markDiameter ?? IslandRing.diameter(forHeight: height)
    }

    /// The three gates on the *motion* — the mark itself is never hidden. Something
    /// running, motion allowed, and the mark actually on screen. `IslandRing.restingAngle` is
    /// where a ring that is not playing is held (see `updateMotion`).
    private var shouldPlay: Bool {
        running
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && onScreen
    }

    /// Start or stop turning. `shouldPlay` is the only thing that decides, and it is re-checked on
    /// every tick as well as whenever one of its three inputs changes, so a quiet mark is drawn but
    /// never moves and is never subscribed to the shared ticker. This is the CPU rule and the state
    /// rule meeting.
    private func updateMotion() {
        if shouldPlay {
            startTicking()
        } else {
            stopTicking()
            // A ring that is not playing — reduced motion, nothing running, or a mark
            // that has just come back on screen — is put back to its resting angle
            // rather than left wherever the last tick happened to stop it. A gap
            // frozen at an arbitrary angle reads as a spinner that has stalled; a
            // gap centred on 12 o'clock reads as a mark that is deliberately still.
            if angle != IslandRing.restingAngle {
                angle = IslandRing.restingAngle
                needsDisplay = true
            }
        }
    }

    /// Subscribe to the island's one tick source rather than starting a timer of our own:
    /// a card holding several busy rows and the pill behind them costs one timer, not one per
    /// mark (see `IslandRingTicker`). The ticker stops itself when the last mark leaves.
    private func startTicking() {
        IslandRingTicker.shared.subscribe(self) { [weak self] angle in
            self?.ringTick(angle)
        }
    }

    private func stopTicking() {
        IslandRingTicker.shared.unsubscribe(self)
    }

    /// One step, handed in by the shared ticker: the angle is the same number on every ring in the
    /// app. The gates are re-checked here and not only where the state changed, so the ticker and
    /// the view's own state cannot drift apart — a mark whose state said "stop" between two ticks
    /// stops on the tick instead of drawing one more frame, and unsubscribes itself while doing it.
    private func ringTick(_ angle: CGFloat) {
        guard shouldPlay else {
            updateMotion()
            return
        }
        if self.angle != angle {
            self.angle = angle
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = markDiameter ?? IslandRing.diameter(forHeight: bounds.height)
        guard diameter > 0 else { return }
        // The same path the image renderer strokes into its canvas — one construction, so the mark
        // in the menubar and the mark in a row cannot be two different drawings.
        let ring = IslandRing.arcPath(diameter: diameter, angle: angle,
                                      center: NSPoint(x: bounds.midX, y: bounds.midY - pillMarkDrop))
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
    /// The last-update stamp, in line 1's right slot immediately right of the age
    /// (`5h36m · 2m`). Its own field because it must keep its measured width at
    /// the trailing edge while the folder name truncates in what is left.
    private let stampLabel = NSTextField(labelWithString: "")
    /// The alert's mark, at the row's leading edge. Inert — the card's `hitTest`
    /// hands clicks to the row view itself, so nothing here needs to claim or
    /// refuse one.
    private let alertMark = IslandAlertMark(frame: .zero)
    /// The row's running mark: the same ring the pill's left flank draws (`IslandRing`), in the
    /// row's status-glyph column. It replaced a static orange `arrow.clockwise.circle.fill`, which
    /// said "running" with a shape that cannot move; a row whose session is running now carries the
    /// app's one running mark, turning like every other instance of it.
    ///
    /// `running` is the only state it is ever in here, so the ring's dim `restingTint` — the state the
    /// pill's mark takes when nothing is running — is unreachable on this surface: a row exists because
    /// its session *is* in one of the four states, and a row whose session stopped running is pointed
    /// at a different mark entirely (`configure`). Under Reduce Motion this surface is an orange ring
    /// held still, never a grey one.
    private let ring = IslandActivityView(frame: .zero)
    private var tracking: NSTrackingArea?
    private var pid: Int32?
    private var hasContext = false
    private var hasStamp = false
    private var hasTitleText = false
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    /// The alert's mark on this row, or nil when this row is not the one the alert
    /// is about. Set from the panel (`IslandPanel.applyAlertMark`), which is the
    /// only thing that knows.
    var alert: IslandRowAlert? {
        didSet {
            guard alert != oldValue else { return }
            alertMark.alert = alert
            alertMark.isHidden = alert == nil
        }
    }

    /// Whether this row is really on screen — the panel is up *and* the card is open — forwarded to
    /// the ring, which must not keep the shared ticker subscribed for a mark nobody can see. The
    /// panel owns this; it is the only thing that knows.
    var onScreen = false {
        didSet { ring.onScreen = onScreen }
    }

    /// Outer diameter of the row's running mark: the disc it stands in for **as this row draws that
    /// disc**. Its glyph box is `islandRowGlyphSize` across and `.scaleProportionallyDown` shrinks
    /// the `islandRowGlyphPointSize` symbol image (a 16pt box) into it, so the disc the eye sees is
    /// the measured ink scaled by that fit — 13.125pt, not the 14pt a dropdown row draws and not the
    /// pill's 12. Anything else and a busy row's mark would be a visibly different size from the idle,
    /// waiting and error discs in the rows beside it, which is the one thing this column may not do.
    ///
    /// Measured from the idle symbol in this row's own vocabulary, so the reference cannot drift from
    /// what the row actually draws, and memoized in `IslandRing` — one render plus one pixel scan, once.
    private static let ringDiameter: CGFloat = {
        let reference = appearance(for: .idle).symbol ?? "checkmark.circle.fill"
        return IslandRing.discDiameter(symbol: reference,
                                       pointSize: islandRowGlyphPointSize,
                                       weight: islandRowGlyphWeight,
                                       fittedTo: islandRowGlyphSize)
    }()

    /// Number of stacked lines this row currently shows — the folder always, the
    /// title when it has one, the context readout when that is on. The card sizes
    /// the row from this, and `layout()` stacks exactly these lines. The
    /// last-update stamp is not a line: it lives in line 1's right slot.
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

        nameLabel.font = NSFont.systemFont(ofSize: islandCardBaseFontSize, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail

        // The title is real content, so it stays at the name's size — only its
        // weight and alpha set it below the folder name and above the age.
        titleLabel.font = NSFont.systemFont(ofSize: islandCardBaseFontSize, weight: .regular)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        titleLabel.lineBreakMode = .byTruncatingTail

        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: islandCardSecondaryFontSize, weight: .regular)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        durationLabel.alignment = .right

        // The context line is deliberately subordinate to both the name (12.5 /
        // full white) and the age (11 / white 0.55): 11pt regular at white 0.5,
        // dimmer still for the placeholders.
        contextLabel.font = NSFont.systemFont(ofSize: islandCardSecondaryFontSize, weight: .regular)
        contextLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        contextLabel.lineBreakMode = .byTruncatingTail

        // The stamp borrows the age's font, because it sits in the same right slot and
        // the two have to measure and align as one; its tone is one step below the
        // age's white 0.55 so the pair is never read as a single number.
        stampLabel.font = NSFont.monospacedDigitSystemFont(ofSize: islandCardSecondaryFontSize, weight: .regular)
        stampLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        stampLabel.alignment = .right
        stampLabel.lineBreakMode = .byTruncatingTail

        // One field per line is the row's contract, so no field is ever allowed
        // to wrap onto the next line: each truncates at its tail instead. This is
        // belt-and-braces — `layout()` already gives every field a single-line
        // frame — but it makes the contract hold even if a frame were mis-sized.
        for label in [nameLabel, titleLabel, durationLabel, contextLabel, stampLabel] {
            label.usesSingleLineMode = true
        }

        addSubview(glyph)
        addSubview(nameLabel)
        addSubview(titleLabel)
        addSubview(durationLabel)
        addSubview(contextGlyph)
        addSubview(contextLabel)
        addSubview(stampLabel)
        addSubview(alertMark)
        addSubview(ring)
        titleLabel.isHidden = true
        contextGlyph.isHidden = true
        contextLabel.isHidden = true
        stampLabel.isHidden = true
        alertMark.isHidden = true
        // Set once here and never again: the mark is not sized by a pill, it is sized to the disc the
        // row draws beside it (see `ringDiameter`).
        ring.markDiameter = Self.ringDiameter
        ring.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(name: String, title: String?, status: SessionStatus, duration: String, pid: Int32?, context: IslandContext?, stamp: String) {
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
        // The row's status mark: a tinted SF Symbol for three of the four states and the app's one
        // running mark for the fourth. `configure` is called every time a row is rebuilt — including
        // on a *recycled* view pointed at a different session — so this is where the ring is started
        // and stopped, and a recycled row can never keep turning for the session it used to show.
        let appearance = Self.appearance(for: status)
        let isRunning = appearance.symbol == nil
        ring.isHidden = !isRunning
        ring.running = isRunning
        glyph.isHidden = isRunning
        glyph.image = appearance.symbol.flatMap { islandSymbolImage(symbol: $0, color: appearance.color) }

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
        // Cleared as well as hidden: `configure` also runs on a recycled view, so an
        // empty stamp must not leave the previous session's age in the field. The
        // separator is part of this field, not a gap in the layout, so it can never
        // survive on its own at the end of the age.
        hasStamp = !stamp.isEmpty
        stampLabel.stringValue = hasStamp ? islandAgeStampSeparator + stamp : ""
        stampLabel.isHidden = !hasStamp
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

        // The alert's mark: the row's whole height less its margin top and bottom,
        // so it follows a taller row and reads as marking the row rather than one
        // of its lines. Flipped, so y counts down from the top like everything else
        // here, and x is the leading padding the glyph column's inset already
        // reserves.
        alertMark.frame = NSRect(
            x: islandAlertMarkInset,
            y: islandAlertMarkVerticalInset,
            width: islandAlertMarkWidth,
            height: max(0, bounds.height - islandAlertMarkVerticalInset * 2)
        )

        // Line 1: status glyph, folder name, and the right slot, which holds the
        // session's age and — when the session has been updated since it was made
        // — its last-update stamp. The folder has the line to itself, so it is
        // never truncated for a title: it simply fills the room the slot leaves.
        glyph.frame = NSRect(x: islandRowLeadingInset, y: nameCenterY - islandRowGlyphSize / 2,
                             width: islandRowGlyphSize, height: islandRowGlyphSize)
        // The running mark takes exactly the glyph's box — same column, same centre, same size — so a
        // row switching between busy and any other state moves nothing and a busy row is not a
        // differently-sized row.
        ring.frame = glyph.frame
        // The stamp is anchored by its own right edge, so its measured width appears
        // to its left and it never leaves the row's trailing inset. It carries the
        // separator in its text, so the two numbers are laid out as one string here
        // and can never drift apart or end up separated by a truncating folder.
        let stampWidth = hasStamp ? islandLabelWidth(for: stampLabel) : 0
        let stampSize = stampLabel.intrinsicContentSize
        stampLabel.frame = NSRect(
            x: bounds.width - islandRowTrailingInset - stampWidth,
            y: nameCenterY - stampSize.height / 2,
            width: stampWidth,
            height: stampSize.height
        )
        let durationSize = durationLabel.intrinsicContentSize
        // Right-aligned age. Its width comes from the text's *unclipped* need,
        // not the bare advance — otherwise the cell clips the trailing glyph
        // inside the label (`5h36m` loses ~0.8pt off the `m`). Anchoring the
        // frame's right edge keeps the alignment, so the extra room appears to
        // its left, which costs the folder name the same hair via `nameWidth`
        // below. With no stamp that edge is the row's trailing inset, exactly as
        // before the stamp existed; with one it is the stamp's left side less the
        // separator gap.
        let durationWidth = islandLabelWidth(for: durationLabel)
        let durationRight = hasStamp ? stampLabel.frame.minX - islandAgeStampGap : bounds.width - islandRowTrailingInset
        durationLabel.frame = NSRect(
            x: durationRight - durationWidth,
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
                // shifts. The line is the context's alone: the stamp belongs to
                // line 1's right slot, so nothing here competes for width.
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
        // The card's hover wash, shared with the alert's button (`islandHoverWash…`): a row under the
        // pointer and the button under the pointer are the same treatment, so the card has one hover
        // idiom. This is what the button's ground *returns to*.
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: islandHoverWashDX, dy: islandHoverWashDY),
            xRadius: islandHoverWashRadius,
            yRadius: islandHoverWashRadius
        )
        NSColor.white.withAlphaComponent(islandHoverWashAlpha).setFill()
        path.fill()
    }

    /// The row's mark for a status: a tinted SF Symbol, or `nil` for the running state, whose mark is
    /// the ring (`IslandRing`) rather than a symbol. The four statuses no longer share one drawing
    /// technique, deliberately — the ring is a live turning mark, and its shape says "running" where a
    /// static glyph could only ever *state* it.
    ///
    /// The busy entry still names a colour — `IslandRing.runningTint`, the constant the ring is stroked
    /// with — rather than leaving a hole in the row's status → colour vocabulary. It is not consumed
    /// today (the ring draws its own tint, and the busy glyph is nil), which is exactly why it must
    /// point at the ring's constant: if a busy row ever needs that colour, there is only one orange it
    /// could be.
    private static func appearance(for status: SessionStatus) -> (symbol: String?, color: NSColor) {
        switch status {
        case .busy: return (nil, IslandRing.runningTint)
        case .waiting: return ("questionmark.circle.fill", .systemBlue)
        case .idle: return ("checkmark.circle.fill", .systemGreen)
        case .error: return ("exclamationmark.triangle.fill", .systemRed)
        }
    }
}

// MARK: - Action row

/// The alert's way out: the card's one button, `Hide` — a shape that exists in order to be clicked.
///
/// **Every number is this card's** (see the constants above for the full accounting, including what the
/// resting ground cost). In short: a quiet way out, trailing, under the content, hiding without acting —
/// with the type, the tone, the ground, the hover and the height all taken from something this card
/// already draws. The one genuinely new number in the whole button is the *resting tone of an actionable
/// label* (α0.55): every other alpha here belongs to text that cannot be pressed.
///
/// **Only opacity moves on hover**, never geometry: the ground doubles from half a wash to the wash
/// (`islandActionButtonRestingFillAlpha` → `islandHoverWashAlpha`) and the label steps one rung of the
/// card's own ladder (α0.55 → α0.7). Both channels are carried by *views* (`fill`, `label`) rather than
/// interpolated in `draw`, because AppKit can animate a view's alpha and cannot animate a colour it is
/// about to paint: the label is pure white with its tone held as the view's alpha, and the ground is a
/// layer whose alpha is the tone itself.
///
/// **Not a session row.** No `onSelect`, no pointing hand — its affordance is its own ground and its
/// hover is the card's row wash. (The bubble's corner ✕ does add a pointing hand; that is that
/// surface's idiom, and this button is not a link to anything.)
///
/// Its width is `width`; its height is the card's, not its own — the card lays it out at
/// `summaryRowHeight`, so the action row cannot be one height for the budget and another on screen.
private final class IslandCardButton: NSView {

    /// Clicked. Answered by the *host*, with the same dismissal a row click uses and without the focus
    /// (`IslandPanel.onHideRequested` → `IslandHost.collapse()`): this button hides the card without
    /// acting on the session, and the card is on every screen.
    var onActivate: (@MainActor () -> Void)?

    /// The button's label font: the card's subordinate size at regular weight (see the constants).
    static let font = NSFont.systemFont(ofSize: islandCardSecondaryFontSize, weight: .regular)

    /// The button's width: its label's **unclipped** need (`islandLabelWidth`) plus the card's own 8pt
    /// either side. Not the bare glyph advance — this is a label whose frame is derived from its own
    /// text, which is exactly the case that helper exists for: the cell lays the text out a couple of
    /// points inside the frame and clips at the edge, so a frame at the advance shaves the trailing `e`
    /// (measured: `Hide` at 11pt needs 28.181 where the advance is 24.500).
    ///
    /// No height here: the card lays the action row out at `summaryRowHeight`.
    static let width: CGFloat = {
        let label = NSTextField(labelWithString: islandActionButtonLabel)
        label.font = font
        return islandLabelWidth(for: label) + 2 * islandActionButtonHorizontalPadding
    }()

    private let fill = NSView()
    private let label = NSTextField(labelWithString: islandActionButtonLabel)
    private var tracking: NSTrackingArea?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            applyHover()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill.wantsLayer = true
        // The layer's colour is plain white and its **alpha is the tone** (half a wash at rest, the wash
        // on hover), so one animatable number carries the ground and there is no second alpha to keep in
        // step. Its geometry is the row wash's (`islandHoverWash…`), applied as a layer instead of a path.
        fill.layer?.backgroundColor = NSColor.white.cgColor
        fill.layer?.cornerRadius = islandHoverWashRadius
        fill.alphaValue = islandActionButtonRestingFillAlpha
        addSubview(fill)

        // Pure white, with the 0.55/0.7 carried by this view's alpha — the label's own colour is then one
        // thing that never changes, and the hover is a single animatable number.
        label.font = Self.font
        label.textColor = .white
        label.alphaValue = islandActionButtonForegroundAlpha
        label.alignment = .center
        label.usesSingleLineMode = true
        addSubview(label)

        toolTip = islandActionButtonTooltip
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        // The wash's own inset, so the button's ground is visibly the same treatment a row takes.
        fill.frame = bounds.insetBy(dx: islandHoverWashDX, dy: islandHoverWashDY)
        let labelWidth = islandLabelWidth(for: label)
        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(
            x: (bounds.width - labelWidth) / 2,
            y: (bounds.height - labelSize.height) / 2,
            width: labelWidth,
            height: labelSize.height
        )
    }

    /// The hover transition: two alphas, the file's own curve, nothing else — no scale, no pressed state,
    /// no focus ring.
    private func applyHover() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = islandActionButtonHoverDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            fill.animator().alphaValue = hovering ? islandHoverWashAlpha : islandActionButtonRestingFillAlpha
            label.animator().alphaValue = hovering ? islandActionButtonHoverForegroundAlpha : islandActionButtonForegroundAlpha
        }
    }

    /// Hover by tracking area, the same as the card's rows and the bubble's ✕. The panel's *poll* exists
    /// for the island's outer rect (the window frame animates, so a tracking area there synthesises bogus
    /// enter/exit pairs); a subview inside the card is what both of this app's other hover-highlighted
    /// controls use, and this is the third.
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

    /// Swallow the press — the card's blank area toggles the island, and a press that started here must
    /// never reach it — and act on release *inside*, so dragging off the button cancels it. The bubble's
    /// `CloseButton` is the in-repo precedent for both.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    // The panel is a non-key, non-activating window, so without this the first click is delivered
    // nowhere and the button is silently dead while its hover still works.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        label.font = NSFont.systemFont(ofSize: islandCardSecondaryFontSize, weight: .regular)
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

// MARK: - Alert mark

/// The alert's mark: one saturated rule at the leading edge of the row the alert
/// is about, and nothing else.
///
/// **Why a rule, and not a wash.** The card already has two background treatments
/// and neither could be reused or extended:
///
///  - the row's hover wash (white α0.09, `IslandRowView.draw`) *is* the pointer's
///    own affordance. A marked row would read as hovered while the pointer is
///    somewhere else entirely, and a row that was both hovered and marked could not
///    say which of the two it was;
///  - a wash in the alert's own colour was rejected because it puts a tinted ground
///    under text whose whole hierarchy is built out of alpha — the name at full
///    white, the title at α0.7, the age at α0.55, the context line at α0.5. Raising
///    the ground raises every line's effective brightness by the same amount, so the
///    row's four-level ordering wobbles by exactly the wash's worth. It would also
///    double-encode the state the status glyph already states, next to it.
///
/// A rule in the leading padding touches no text's ground, sits in the one column of
/// a row nothing else is drawn in, and says only what the alert actually knows:
/// *this* row. That is also why it carries no symbol and no count — the mark is about
/// identity, and the row's glyph already carries the state.
///
/// **The pop.** The mark is the one thing in the island allowed to overshoot, and it
/// is small enough to carry it: a 3pt rule growing from 35% of its height with a
/// ~7% overshoot reads as *arriving* without any part of the card moving twice. One
/// "pop", spent on the row rather than on the window: the card has one open curve for
/// both its reasons to open (hover and alert, differing only in duration), while the
/// punch lives on the four points that tell the user *which* session moved. A spring on
/// the window's frame would have to be a `CASpringAnimation` on a window frame, which is
/// exactly the kind of thing AppKit makes awkward (the animator proxy owns that
/// animation) — and it would put the overshoot on the biggest surface for the smallest
/// reason.
private final class IslandAlertMark: NSView {

    /// The alert this mark is showing: its tint and its generation. **Everything is
    /// keyed on the generation** — the tint is only what the rule is drawn with — so
    /// a poll tick that re-applies the same alert cannot restart the pop by
    /// construction (colour equality is not what "the same alert" means, and a
    /// dynamic `NSColor` is not guaranteed to compare equal to a second access of
    /// itself), while an alert that re-arms on this very row pops again because its
    /// generation differs.
    var alert: IslandRowAlert? {
        didSet {
            guard alert?.generation != oldValue?.generation else {
                // The same alert: at most a repaint of the rule.
                if alert?.tint != oldValue?.tint { needsDisplay = true }
                return
            }
            needsDisplay = true
            if alert == nil {
                layer?.removeAnimation(forKey: islandAlertMarkPopKey)
            } else {
                play()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Just for the pop: the rule itself is drawn, like the row's hover wash and
        // every other surface in this file.
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// **Reduce Motion takes the pop and leaves the rule.** The rule is the
    /// information — which session just moved — so it is drawn either way; only the
    /// overshoot is decorative, and that is what the setting removes. This is the
    /// same split `IslandActivityView` makes with the ring's rotation, and the flag
    /// is read here rather than observed: unlike the ring's ticker this animation is
    /// one-shot and half a second long, so there is no continuing motion for a
    /// settings change to have to stop.
    private func play() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spring = islandSpring(response: 0.3, dampingFraction: 0.65)
        spring.keyPath = "transform.scale.y"
        // From a short rule, to exactly the height it was laid out at: the model
        // value is never touched, so the animation can be removed at any point
        // without the mark moving.
        spring.fromValue = islandAlertMarkPopScale
        spring.toValue = 1
        layer?.add(spring, forKey: islandAlertMarkPopKey)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tint = alert?.tint, bounds.width > 0, bounds.height > 0 else { return }
        tint.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.width / 2,
            yRadius: bounds.width / 2
        ).fill()
    }
}

/// What a row is told about the alert: the tint to mark it in, and which alert it
/// belongs to. Split out so the row and the mark can key their work on the
/// *identity* rather than on the colour — see `IslandAlertMark.alert`.
struct IslandRowAlert: Equatable {
    let tint: NSColor
    let generation: Int
}

/// Height the mark springs up from, as a share of its own height.
private let islandAlertMarkPopScale: CGFloat = 0.35
private let islandAlertMarkPopKey = "islandAlertPop"

/// A `CASpringAnimation` stated the way the spring is actually described —
/// `response` in seconds and `dampingFraction` — and converted to the two numbers
/// macOS 13 can be given. `CASpringAnimation.response`/`dampingFraction` only exist
/// from macOS 14, while `stiffness`/`damping`/`mass` have been there since 10.11, and
/// this app builds for 13; so the response is turned into stiffness and the damping
/// fraction into damping for a unit mass, which is the textbook conversion. Kept in
/// one place so the spring's intent stays the number in the caller rather than the
/// two derived constants nobody can check by eye.
private func islandSpring(response: TimeInterval, dampingFraction: CGFloat) -> CASpringAnimation {
    let mass: CGFloat = 1
    let omega = 2 * CGFloat.pi / CGFloat(response)
    let spring = CASpringAnimation()
    spring.mass = mass
    spring.stiffness = mass * omega * omega
    spring.damping = 4 * CGFloat.pi * mass * dampingFraction / CGFloat(response)
    return spring
}

// MARK: - Symbol helpers

private func islandSymbolImage(symbol: String, color: NSColor, pointSize: CGFloat = islandRowGlyphPointSize) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: islandRowGlyphWeight)
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

    /// Fired with the clicked row's pid, from whichever screen's island was clicked. Set by the app
    /// delegate; the host is only a pass-through for it (`rowActivated`).
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

    /// Collapse every island — the menubar calls this as its menu opens, so no island anywhere sits in
    /// the menu's way; `rowActivated` calls it when a row is clicked on any screen; and the alert's `Hide`
    /// button calls it (`hideRequested`), so one click folds them all. One primitive for all three, because
    /// all three are the user dismissing the island *with the pointer inside it* — which is why they latch
    /// (`IslandPanel.hoverLatched`) and why the alert's third exit, `dismissAlert`, does not come through
    /// here.
    func collapse() {
        for panel in panels { panel.collapse() }
    }

    /// A row was clicked on one screen's island: fold **every** screen's island — ending any alert with
    /// it — and then hand the pid to the session focus.
    ///
    /// Host-owned on purpose. The reminder is shown on every screen, so answering it on one is answering
    /// it: folding only the clicked panel would leave the other display's card open for the rest of
    /// `bubbleSeconds`, still marking a row the user has already dealt with. The fold goes through
    /// `collapse()`, the same path the menubar takes, so the panel's hover latch (`hoverLatched`) covers
    /// this dismissal too — the pointer is inside the island the user just clicked, and without the latch
    /// the hover poll would re-open the card 0.35s later.
    private func rowActivated(pid: Int32?) {
        collapse()
        onSelectSession?(pid)
    }

    /// The alert's `Hide` button was pressed on one screen: **dismiss without acting.** Every screen's
    /// island folds (`collapse()`), and nothing is focused — the agent keeps waiting on a request the user
    /// has only hidden. The same call the row click makes *minus* its `onSelectSession`, which is the whole
    /// difference between the two buttons-of-exit on this card.
    private func hideRequested() {
        collapse()
    }

    /// Open every screen's island on a session transition, and fold it back after
    /// `seconds`. The same fan-out as `update`, for the same reason: the alert is
    /// about a session, not about a display, so both screens say the same thing —
    /// an island that stayed folded on one screen while the other showed the alert
    /// would be a contradiction on a two-display desk.
    ///
    /// Deliberately not remembered: retiring a panel folds it (a display change
    /// mid-alert ends the alert on the remaining screens too), and the alternative
    /// was worse — replaying it onto a display that has just been plugged in would
    /// open a card on a screen the user is not looking at, about a transition they
    /// have plausibly already seen.
    func alert(name: String, kind: IslandAlertKind, pid: Int32?, seconds: TimeInterval) {
        for panel in panels { panel.alert(name: name, kind: kind, pid: pid, seconds: seconds) }
    }

    /// The alert's **reason** is gone — the user answered the prompt, or the session went back to work —
    /// so the card retracts, on every panel that is showing *that* alert and no other. Wired to
    /// `monitor.onDismiss`, beside the bubble's dismissal, so the two reminders now retract in step.
    ///
    /// Matched by the session's folder **display name**, which is what `SessionMonitor.onDismiss` carries
    /// and what `AppDelegate.dismissBubble` matches the bubble on. A new alert replaces the old one, so only
    /// one alert exists at a time and the looseness of a name match cannot bite.
    ///
    /// **This exit must not become `collapse()`, and `collapse()` must not become this.** Here the pointer
    /// can be anywhere — the user is in a terminal — so the retract hands the card back to the hover machine
    /// exactly as the alert's own timer does (`IslandPanel.retractAlert(named:)` → `endAlert`): an
    /// unattended card folds on the ordinary 0.35s deadline, and a card somebody is pointing at stays up.
    /// `collapse()` is for the two exits where the pointer is inside the island by construction — the `Hide`
    /// button and a row click — and which therefore latch the hover open off. Merging the two loses one
    /// behaviour whichever way it is merged: with a latch here, a card the user is reading would freeze
    /// open; without one there, the poll would re-open a card they just dismissed.
    func dismissAlert(named name: String) {
        for panel in panels { panel.retractAlert(named: name) }
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
            panel.onRowActivated = { [weak self] pid in self?.rowActivated(pid: pid) }
            panel.onHideRequested = { [weak self] in self?.hideRequested() }
            return panel
        }
        // Re-apply the current state so a rebuild does not blank the islands.
        for panel in panels { panel.update(rows: lastRows, enabled: lastEnabled) }
    }
}