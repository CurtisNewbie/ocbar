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
    /// How many subagent sessions this root is running right now, straight from
    /// the monitor (`SessionInfo.runningSubagents`). Zero for a session working on
    /// its own turn, which is the common case and must render as it always did.
    let subagents: Int
    /// The pending question forms this session is blocked on, oldest first. The card
    /// draws the head one as a block under this row and folds every other session
    /// away; empty means this row is an ordinary session row.
    let questions: [PendingQuestion]
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
/// different amounts — the left holds the ring, the running count and the server-CPU readout
/// (116.7pt of content plus clearance), the right holds the three remaining states (130) — and
/// taking the smaller for the right would be the one thing this pill may not do: the right
/// flank would be under-provisioned, and `place` trims an overrun at the capsule edge
/// *silently*, so a fourteen-session finished count would be drawn as `1`. Symmetry at the
/// smaller width would also be no symmetry at all, since the left's content would then decide
/// the width anyway. So both wings are 130 and the spare room on the left is the price of a
/// balanced capsule.
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
/// How far a band glyph rides above its slot centre. Both the warn triangle and
/// the critical octagon read half a point low against the text at this size.
private let islandBandGlyphRise: CGFloat = 0.5

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

/// The alert's footer button, `Hide`: a quiet way out, in the card's permanent footer row, **left of the
/// gear**, hiding the card without acting on the session. What it is drawn with, in this card's own terms:
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
///  - **height** is not the button's at all: it is laid out at the card's own short-row height
///    `summaryRowHeight` (the `+k more` footnote's 24) — the height of the footer it shares with the gear,
///    so a control row and the fold's row sit on the same line of the card's rhythm;
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
/// every other element on this card is text or a status glyph, and this is now one of two shapes that
/// exist in order to be clicked — and it buys the one thing type alone could not say.
let islandActionButtonLabel = "Hide"
/// The tooltip, and the second half of it is what this card actually does: hiding leaves the card with
/// one way back, which is hovering the island again.
let islandActionButtonTooltip = "Hide this card. The session keeps waiting — hover the island to bring it back."
/// The question card's `Hide`, which is **not** the alert's. It latches that form off until it settles
/// or a new form becomes the head, so the alert's "hover the island to bring it back" would be false
/// on this card — the terminal is the way back.
let islandQuestionHideButtonTooltip = "Hide this question. It stays pending — answer it in the terminal."
/// The question card's other footer control, immediately **left of `Hide`**: one reply carries the
/// form's whole answer set, so this is the card's only submit. It borrows `Hide`'s every number — the
/// size, the tone ladder, the ground, the hover — because a second quiet control with a ladder of its
/// own is how a card ends up with two kinds of quiet. What is its own is the label and its gate.
let islandSendButtonLabel = "Send"
let islandSendButtonTooltip = "Send these answers to the session"
/// Why it is not pressable. `Send` is held back until every required field has an answer, so a click
/// cannot bounce off the server.
let islandSendButtonDisabledTooltip = "Answer every required question first"
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
/// A control that cannot be pressed: the inert end of the card's ladder, below the age's 0.55 and the
/// footnote's 0.5, so a held-back `Send` reads as *waiting on you* rather than as another line of text.
private let islandCardDisabledAlpha: CGFloat = 0.3
/// The file's own micro duration — the one `present()`'s fade-in uses — on the file's own curve.
private let islandActionButtonHoverDuration: TimeInterval = 0.15

/// The card's footer gear: the way into the dropdown menu while the menubar item is hidden, and the one
/// control on **every** card, alert or not. It never moves — `IslandCardView.layout` measures its trailing
/// edge from the card's trailing inset — so an alert's `Hide` arriving beside it reflows nothing to its right
/// and the gear is in the same place on both cards.
///
/// **Every tone is `Hide`'s, borrowed rather than re-derived**: same footer row, same wash
/// (`islandHoverWash…`), same resting ground (`islandActionButtonRestingFillAlpha`), same two alphas
/// (`islandActionButtonForegroundAlpha` → `…HoverForegroundAlpha`), same micro duration. A second quiet
/// control with a ladder of its own is exactly how a card ends up with two kinds of quiet. What is its own is
/// only what a glyph needs and a label does not: the symbol and its size.
let islandSettingsSymbolName = "gearshape.fill"
/// **12pt, one step above the card's subordinate 11.** The footer's type is 11, but a hollow SF Symbol drawn
/// at its text's point size reads smaller than the text beside it — the same reason a card row's 12.5pt name
/// takes a 13pt glyph. At 12, `gearshape.fill` measures a **15 × 15pt box around 13.0pt of ink**, and a session
/// row's disc draws 13.125 — so the gear is the same apparent size as the marks on the rows above it, which is
/// the one size this card's marks agree on.
private let islandSettingsGlyphPointSize: CGFloat = 12
/// Medium, not the row glyphs' semibold: this is footer-tier chrome beside an α0.55 label, and the heavier
/// weight would make the card's least important control its brightest mark.
private let islandSettingsGlyphWeight: NSFont.Weight = .medium
/// What the gear is, for VoiceOver. It carries no tooltip: its shape is the whole label. `Hide` needs one
/// because a bare word cannot say what pressing it does; a gear cannot say anything else.
let islandSettingsAccessibilityLabel = "Settings"

/// The card's one line when it has **nothing to list**. These are the dropdown's own words for the same
/// situation (`AppDelegate`'s menu, which adds `No OpenCode sessions` when no session qualifies), repeated
/// here rather than hoisted into a shared constant: the island's card and the dropdown are the app's two ways
/// to read the session list, and an empty ocbar has to say the same thing on both. Reword them together.
let islandEmptyStateText = "No OpenCode sessions"

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

/// Air a list of `count` session rows carries **between** its rows: `(count - 1) × gap`, never
/// negative, so a single row (and the empty line that stands in for none) pays nothing at all.
/// One source of truth for the same three readers `islandRowHeight` has — the card's layout, the
/// card's own height, and the height budget — because a gap the frame pays and the stack does not
/// is a clipped row, and the reverse is a strip of the card's background left open under the
/// footer.
func islandRowGaps(count: Int, gap: CGFloat) -> CGFloat {
    CGFloat(max(count - 1, 0)) * gap
}

/// A row's tooltip for the subagents its session is running, or nil when there
/// are none.
///
/// It exists for the one thing the row's tally cannot say: line 1's right slot
/// draws at most two glyphs, so at `IslandRowView.tallyCeiling` the row shows
/// `9+` and means "ten or more". The exact count has to be said somewhere, and a
/// tooltip is the only place in this row with room for it — it costs the folder
/// name no width, it adds no line, and it cannot truncate. Nil rather than an
/// empty string when there are none: the row it is set on is recycled, and a row
/// with no tally must carry no tooltip at all.
func islandSubagentTally(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1 ? "1 subagent running" : "\(count) subagents running"
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
/// bare two-digit running count + the server-CPU readout at its provisioned width + the gaps
/// between them, `CollapsedContentView.standInCapsuleMinWidth` = 258) is *wider than both*. That is the
/// silent-failure shape this pill is built to avoid: `place` centres what it can and the view's
/// mask trims the rest, so the finished count would be drawn as `1`.
///
/// The floor is now **wider than the 240 cap**, so it wins everywhere: `max` lifts every share to
/// it, and the fraction and the cap only ever matter if the content floor shrinks back under them.
/// That is the honest state, not a bug — the readout is a fixed 72.1pt of provision and the block
/// has to hold it — but it means the capsule's size is now a property of the *content*, and this
/// function is its only override.
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

/// Width the card aims for while it is **answering a question**: the block's prose — its wrapped
/// question, its option labels and their descriptions — gets the 140pt this buys over the hover
/// card before it has to truncate. 720 read as too wide on the built-in display, and the question wraps
/// at 640 without the card reading as a panel. The hover card keeps 500 (`islandExpandedCardTargetWidth`)
/// because that number is sized for session titles, and a wider one there would only add black.
let islandQuestionCardTargetWidth: CGFloat = 640

/// Share of the target screen's width the card may take before it stops growing.
/// A guard rather than a live constraint here — it only binds on screens narrower
/// than ~625pt (~800pt for the 640pt question card), and the attached displays are
/// 1512pt and 1920pt.
private let expandedWidthFraction: CGFloat = 0.8

/// Width the expanded card takes on a screen `screenWidth` wide: the target for the card's state
/// (500, or `islandQuestionCardTargetWidth` while it is asking), bounded by `expandedWidthFraction`
/// of the screen so a small display degrades instead of overflowing, and never narrower than `floor`
/// (the collapsed capsule the card grows out of — 445pt on the built-in display, where the target
/// 500pt still wins, so nothing about the card changes; the floor's own threshold moves from
/// a ~470pt screen to a ~556pt one, below which the card is as wide as the pill it grew from).
func islandExpandedCardWidth(screenWidth: CGFloat, floor: CGFloat, target: CGFloat) -> CGFloat {
    max(floor, min(target, screenWidth * expandedWidthFraction))
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
    /// Air between two adjacent session rows, and **only** there — a list of n rows pays
    /// `(n - 1)` of these (`islandRowGaps`), never one above the first row (the top edge has
    /// `contentTop` for that) and never one below the last (the footer follows the last row
    /// directly, which is what keeps the `+k more` footnote hanging off the list it closes).
    ///
    /// It is part of the budget, not a detail of the layout, because the card's height is
    /// `contentTop + rows + gaps + chrome`. Counting the rows and not the gaps would leave the
    /// frame shorter than `layout()` and clip the last row; and `visibleCount` would call a list
    /// that the gaps alone push past the edge a fit — one row too many, the exact off-by-one the
    /// budget exists to prevent. The collapsed pill is not a list of these rows at all, so this is
    /// the expanded card's number (`IslandPanel.islandRowGap`) and only that.
    let rowGap: CGFloat
    let summaryRowHeight: CGFloat
    /// Height of the card's footer row — `summaryRowHeight`, because the gear makes it permanent. Chrome
    /// like the folded summary, so it comes off the list budget the same way: a card always owes one row's
    /// worth to its footer, and the gear (or an alert's `Hide` beside it) can never be pushed past the
    /// bottom of the screen by a fold that was computed without it. It used to be 0 on a card with no
    /// `Hide` button; that case is gone, and the budget now pays it always.
    let actionRowHeight: CGFloat
    /// Content on the card that is not a session row and not the footer — today, the
    /// question block under the waiting row (below the `+k more` footnote). Chrome for the same reason the footer
    /// is: the block is the card's, the rows are the list's, and a budget that
    /// ignored the block would let the list push it off the bottom of the screen.
    let extraContentHeight: CGFloat
    /// Tallest row in the list, so the budget can always hold one.
    let tallestRowHeight: CGFloat
    /// Share of the usable height the list may take.
    let fraction: CGFloat

    /// Points the visible session rows may use: the smaller of
    ///  - a share of the screen's usable height, so the card never takes over
    ///    the display even where there is room for it, and
    ///  - the distance from the top edge to the bottom of the usable area, less
    ///    the chrome, the summary row and the footer. The card hangs from the
    ///    very top, so this is the term that stops it running past the bottom of
    ///    any screen or over the Dock.
    /// The summary's and the footer's heights come out of that *ceiling* but never
    /// out of the budget itself, so neither folding a list nor the footer's
    /// controls ever costs a visible session row.
    var rowBudget: CGFloat {
        let soft = visibleFrame.height * fraction
        let hard = screenFrame.maxY - visibleFrame.minY - contentTop - bottomPadding - summaryRowHeight
            - actionRowHeight - extraContentHeight
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
            // A row after the first costs its height *and* the gap above it, because both are what
            // the card will spend on it — see `rowGap`.
            let cost = count > 0 ? rowGap + height : height
            if count > 0, used + cost > rowBudget { break }
            used += cost
            count += 1
        }
        return count
    }

    /// Total card height for a set of visible rows. The card reports the same
    /// number from the views it holds, so frame and layout agree.
    func cardHeight(forRowHeights heights: [CGFloat], folded: Bool) -> CGFloat {
        var height = contentTop + heights.reduce(0, +)
            + islandRowGaps(count: heights.count, gap: rowGap)
            + actionRowHeight + extraContentHeight
        if folded { height += summaryRowHeight }
        return height + bottomPadding
    }

    /// Whether that card still clears the bottom of the usable area.
    func fits(forRowHeights heights: [CGFloat], folded: Bool) -> Bool {
        screenFrame.maxY - cardHeight(forRowHeights: heights, folded: folded) >= visibleFrame.minY
    }
}

/// What the user has picked across the question card, shared by every screen's panel.
///
/// It lives on the `IslandHost` because the card is shown on every display: a selection
/// made on one panel has to be what the others draw, and `Send`'s gate has to reach the
/// same verdict everywhere. Keyed on the form's id and the field's key, which is the only
/// identity the server gives a question.
///
/// **Answers are dropped when the form's payload changes or it settles** (the host prunes
/// against each tick's rows): a form re-asked under the same id with different fields is a
/// different question, and a settled one has nothing left to answer.
struct IslandQuestionState: Equatable {
    var answers: [String: [String: QuestionAnswer]] = [:]
    /// The typed text of a list field's open `Other…` row, by form and field key. A list answer is a
    /// set of picked values, so the string being typed is not part of it until it is confirmed; it
    /// lives here because the card is on every screen and both have to draw the same field.
    var drafts: [String: [String: String]] = [:]
    /// The forms a reply is in flight for. `Send` is held back on **every** screen while a form is in
    /// here: one form is one write, so a second click on another display must not become a second reply.
    var submitting: Set<String> = []
    /// The form the user hid. It asks nothing — no card of its own, no unprompted open —
    /// until it settles and a different form becomes the head, which is what "Hide folds
    /// without answering" has to mean when the form is still pending on the server.
    var hidden: String?
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

// MARK: - Question fold preference

/// How long a question card stays on its own, as a list of choices the reader validates against.
/// `never` is the default and is not in the list: it is the absence of a deadline, not a duration.
///
/// The timer is **not** the hover machine's: a question card must not fold because the pointer left —
/// it was not opened by the pointer. It folds this long after it took the card, and nothing pauses it.
let islandQuestionFoldOptions = [5, 10, 20, 30, 60]
private let islandQuestionFoldKey = "ocbar.questionFold"
private let islandQuestionFoldNever = "never"

/// The question card's fold deadline, or nil for never. Read at use time (the panel arms it when a
/// form takes the card), so a menu pick applies to the next form rather than the next launch — the
/// same rule `islandHoverDelay()` and the feature gates follow. A value outside the list is a
/// hand-edited default and reads as never, never as "fold immediately".
func islandQuestionFold() -> TimeInterval? {
    guard let raw = UserDefaults.standard.string(forKey: islandQuestionFoldKey),
          let seconds = Int(raw), islandQuestionFoldOptions.contains(seconds) else { return nil }
    return TimeInterval(seconds)
}

/// Write side, validated like the hover delay's: an illegal number is dropped, not stored.
func setIslandQuestionFold(seconds: Int?) {
    guard let seconds else {
        UserDefaults.standard.set(islandQuestionFoldNever, forKey: islandQuestionFoldKey)
        return
    }
    guard islandQuestionFoldOptions.contains(seconds) else { return }
    UserDefaults.standard.set(String(seconds), forKey: islandQuestionFoldKey)
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
/// **With the menubar item hidden this is the app's only surface**, which is why it no longer waits for a
/// session to exist: `enabled` alone keeps the panel up (`update`), and a zero-session island is a pill
/// with no counts (a dim, still ring and no badges) over a card whose one line says
/// `No OpenCode sessions`. With both surfaces gated on a session, an empty ocbar would have had no
/// settings and no Quit.
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

    /// An answer was picked on this card. Answered by the host, which owns the shared answer set and
    /// pushes it back to every panel: the card is on every screen, and a selection made on one has to
    /// be the selection the others draw.
    var onQuestionAnswer: (@MainActor (String, String, QuestionAnswer) -> Void)?

    /// `Send` was pressed: the form together with **every** field's answer. Answered by the host, which
    /// forwards the one reply to the monitor.
    var onSubmitQuestion: (@MainActor (PendingQuestion, [String: QuestionAnswer]) -> Void)?

    /// `Hide` on a question card, carrying the form it is about. The host records the dismissal so the
    /// question is not asked again until it settles or a different form arrives, and folds every screen:
    /// hiding on one screen has to hide it on all of them, exactly as the alert's `Hide` does.
    var onQuestionHidden: (@MainActor (String) -> Void)?

    /// The in-progress typed text of a list field's `Other…` row. Shared like the answers: the other
    /// screen draws the same field in the same state.
    var onQuestionDraft: (@MainActor (String, String, String) -> Void)?

    /// Enter in a list field's `Other…` row: the typed string is added to the picked values.
    var onQuestionCommit: (@MainActor (String, String, String) -> Void)?

    /// Leave a field's text row without answering it: its typed answer or draft is dropped, so the
    /// options come back. The picked values of a list field are untouched.
    var onQuestionClear: (@MainActor (String, String) -> Void)?

    /// A question's fold deadline arrived for that form. **Not a dismissal:** the form stays pending
    /// and answerable, so the whole host only folds this showing, without latching the form off.
    var onQuestionFoldReached: (@MainActor (String) -> Void)?

    /// Fired when the card's footer gear is clicked: the way into the dropdown menu while the menubar item
    /// is hidden. Answered by the app delegate, which owns the one `NSMenu` — the island does not know what
    /// the menu holds.
    ///
    /// **Panel-local on purpose**, unlike the two callbacks above: the menu is one object for the app, not
    /// one per screen, so there is nothing to fan out and the host is a pure pass-through
    /// (`IslandHost.onSettingsRequested`). Nothing is collapsed here either — opening the menu collapses
    /// every island itself (`NSMenuDelegate.menuWillOpen`), so a fold on this path would only do it twice.
    var onSettingsRequested: (@MainActor () -> Void)?

    /// Whether the card is currently in its expanded state.
    var isExpanded: Bool { expandedState }

    /// Whether a question card is **on screen** right now: a form is pending and the card is expanded.
    /// The host reads it to leave a card open on a row click — the user is about to answer, and folding
    /// would take the question, the selections and the field position with it (`IslandHost.rowActivated`).
    var hasQuestionCardUp: Bool { questionArmed && expandedState }

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
    ///
    /// **`enabled` alone keeps the island up; an empty list is a state, not an absence.** The menubar item
    /// is hidden while the island is on, so ordering the panel out whenever there is nothing to list would
    /// leave the app with no UI at all — the card's empty line says `No OpenCode sessions` and its footer
    /// gear still reaches the menu. Only `!enabled` (and `retire()`, for a display that is gone) takes the
    /// panel off screen.
    ///
    /// `serviceCPU` rides along with the rows rather than through a second entry point: it is one more
    /// thing the pill draws on the same tick, and a separate push would let the two land out of order.
    /// `cpuUnit` rides with it for the same reason and one more: it is pushed on **every** tick even
    /// when it has not changed, because it is the only way a unit-only change (same `serviceCPU`) can
    /// reach the readout and repaint it before the next 2s sample.
    func update(rows newRows: [IslandRow], enabled: Bool, serviceCPU: Double?, cpuUnit: CPUUnit, questionState: IslandQuestionState) {
        guard enabled else {
            hide()
            return
        }
        ensurePanel()
        rows = newRows
        self.serviceCPU = serviceCPU
        self.cpuUnit = cpuUnit
        self.questionState = questionState
        // The fold and the rows it renders, from the same helper the alert's own arm/end use: the card's
        // listed set is derived from the state that scopes it (`recomputeFold`), and the question form —
        // like `alertArmed` — is one of its inputs, so it has to be resolved before anything measures
        // the card.
        let questionBefore = question?.id
        let contentChanged = refoldCard()
        // The footer's controls after the fold: `Hide` and `Send` exist per the card's *state*, and the
        // footer's height is the same 24 either way, so this is a layout question and not a height one.
        let actionRowChanged = syncActionRow()
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
        } else if contentChanged || actionRowChanged, expandedState {
            // The card's content changed while it was open — the fold moved, or every row went away and
            // the empty line took their place — so it grows or shrinks downwards with its top edge
            // anchored. `actionRowChanged` no longer moves the height (the footer is there either way), so
            // that half is a no-op today: `resizeOpenCard` → `setFrame` returns early when the frame is
            // already the target. It is kept because the `Hide` button's arrival is still a layout change
            // inside the open card, and the fold usually moves on the same tick.
            resizeOpenCard()
        }
        // An alert armed before its row existed opens the card on the first tick that has one.
        if alertArmed, !expandedState, !rows.isEmpty {
            setExpanded(true, animated: true, duration: alertExpandDuration)
        }
        // **A pending question takes the card by itself, once per form.** Unprompted like an alert —
        // the user did not hover — and on every screen, because the host fans this tick out to all of
        // them. `autoOpenedQuestionID` is what keeps a card the user put away (`Hide`, the fold deadline, the
        // menubar opening) folded while that same form is still pending; a queued form is a new id and
        // takes the card again.
        if let question, question.id != autoOpenedQuestionID, visible, !rows.isEmpty {
            autoOpenedQuestionID = question.id
            if !expandedState {
                setExpanded(true, animated: true, duration: alertExpandDuration)
            }
        }
        // The form is gone and nothing replaced it: the card folds. `collapse()` is not this — the
        // pointer may be anywhere, and a card the user is reading should stay readable — so it is the
        // hover machine's decision, exactly as an alert's own timer ends (`endAlert`).
        if questionBefore != nil, question == nil, expandedState {
            endQuestion()
        }
        armQuestionTimer()
    }

    /// Force the card back to its collapsed state — the host calls this when the menubar menu opens, so
    /// the island never sits in the menu's way, **when a row is clicked on a card that is not asking**,
    /// and when the alert's `Hide` button is pressed on any screen, so one click folds them all. An
    /// alert in flight dies with it: all three are the user answering the reminder. A question card is
    /// the exception the host makes on purpose (`IslandHost.rowActivated`) — its `Hide` still comes here,
    /// because hiding a form *is* dismissing it.
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

    /// The question's fold deadline arrived on this panel: fold **this showing** and leave the form
    /// pending, so the card asks again the next time it is shown. Nothing is latched against the form
    /// here — that is `Hide`'s job. Called on every panel by the host, one deadline serving all of them.
    ///
    /// The fold holds until the pointer leaves (`hoverLatched`): the deadline is not the pointer's,
    /// and a poll that re-opened the card a moment later would make it the pointer's after all.
    func foldQuestion(_ formID: String) {
        guard question?.id == formID else { return }
        questionWork?.cancel()
        questionWork = nil
        questionFoldFormID = nil
        guard expandedState else { return }
        hoverLatched = true
        setExpanded(false, animated: true)
    }

    /// The fold preference changed: give the showing the new deadline instead of the old one. A
    /// deadline is armed per showing, and `armQuestionTimer` only arms what is on screen, so clearing
    /// it here is enough — the next tick (or the next open) arms from the new value.
    func rearmQuestionDeadline() {
        questionWork?.cancel()
        questionWork = nil
        questionFoldFormID = nil
        armQuestionTimer()
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
        // The footer first, then the rows: `Hide` joins the permanent footer row while an alert is armed (and
        // leaves it with the alert), so the card's chrome has to be settled before the fold is measured —
        // and an alert landing on an already-open card has to lay that row out rather than push a button
        // past its bottom edge.
        // And the rows with it: the card is now about one session, so the list is re-derived here —
        // this is also what makes a re-arm on a *different* session swap the row, while a re-arm on
        // the same one is a no-op here and lands entirely on the mark below.
        let contentChanged = refoldCard()
        let chromeChanged = syncActionRow()
        // Mark first, expand second: the mark lives inside a row that the
        // expansion is still fading in, so the two arrive together instead of one
        // after the other.
        applyAlertMark()
        // The scoped list moves an open card's height (the footer's own 24 does not — it is always there),
        // so this is one resize, top edge anchored, whenever either half changed. `chromeChanged` only ever
        // re-lays the footer's contents out.
        if chromeChanged || contentChanged { resizeOpenCard() }

        // Nothing on screen yet, **or nothing to put on it**. The rows for this session arrive on the
        // render tick that follows the transition, so this arms and returns rather than waiting, and the
        // tail of `update` opens the card on the first tick that has one. An empty list is that same case
        // even on a visible island: an alert must never open a card about a session it cannot show, so it
        // waits for its row exactly as an off-screen island does — and the timer ends it regardless if the
        // row never comes.
        guard visible, !rows.isEmpty else { return }
        // Already open because the pointer is on it. The mark, the narrowed list and the timer are then the
        // whole alert: the frame has nowhere else to move, and replaying the open would restart the fade for
        // no reason.
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

    /// Adopt the host's shared answer set. Pushed on every tick and again the moment any screen
    /// answers, because that is what makes two displays draw one selection.
    func applyQuestionState(_ state: IslandQuestionState) {
        guard state != questionState else { return }
        questionState = state
        // `hidden` is an input to the fold, exactly as `alertArmed` is, so the fold is re-derived
        // here rather than left to the next poll tick.
        let contentChanged = refoldCard()
        if syncActionRow() || contentChanged { resizeOpenCard() }
        card?.needsLayout = true
    }

    // MARK: - Private state

    private var panel: NSPanel?
    private var card: IslandCardView?
    private var collapsedView: CollapsedContentView?
    private var rowViews: [IslandRowView] = []

    private var rows: [IslandRow] = []
    /// The server's own CPU for this tick, passed through to the pill with the rows. Nil = unknown:
    /// the feature is off, or there was no honest reading. **One-core percent** — the unit the
    /// sampler publishes; `cpuUnit` is what turns it into the drawn unit.
    private var serviceCPU: Double?
    /// Which unit that value is drawn in, pushed with it on every tick. Stored on the panel so a pill
    /// rebuilt after a display change comes back with the same unit.
    private var cpuUnit: CPUUnit = .stored
    /// The prefix of the card's *listed* rows that fits the height budget, and how many were
    /// folded into the summary. Both are recomputed every tick from the current
    /// screen, and are the single source of truth for the card's layout, the
    /// window frame and the summary text — and the listed set is itself derived there
    /// from the alert (`recomputeFold`), so an armed alert's one row and the
    /// `+k more` count that replaces the rest come off the same calculation.
    private var visibleRows: [IslandRow] = []
    private var foldedCount = 0
    /// The question form on the card — the head of the pending queue, oldest first —
    /// and the ranked row it is drawn under. Both come from `recomputeFold`'s one
    /// ranked list, exactly as the alert's scope does, so the card, its frame and its
    /// `+k more` count cannot disagree about which session is asking.
    private var question: PendingQuestion?
    private var questionQueueCount = 0
    /// Which of the form's fields the card is showing. Panel-local: each screen is its
    /// own reading position, while the answers themselves are shared (they are the
    /// one thing that has to agree everywhere).
    private var questionFieldIndex = 0
    /// Room the question block has on this screen before the card's footer would leave the usable
    /// area, derived with the fold (`questionBlockRoom`). The budget pays the block this number and the
    /// block measures itself against the same one, so a tall question scrolls inside it.
    private var questionBlockRoomHeight: CGFloat = .greatestFiniteMagnitude
    /// What the user has picked, as the host last pushed it. Every panel draws the same
    /// set, every card's `Send` gate is computed from it, and the block's text field takes its
    /// contents from the same two places (`answers` and `drafts`).
    private var questionState = IslandQuestionState()
    /// Whether this panel holds the keyboard for a free-text answer. The card takes it in one place
    /// (`focusQuestionText`) and gives it back in one (`releaseQuestionKeyboard`); this is what stops
    /// a tick that merely redraws the block from re-taking it.
    private var questionKeyHeld = false
    /// The form this panel has already opened itself for. The unprompted open happens **once per
    /// form**, not once per tick: a card the user dismissed — `Hide`, the fold deadline, the menubar
    /// opening — must stay folded while that form is still pending. A queued form has a new id, so it
    /// takes the card again.
    private var autoOpenedQuestionID: String?
    /// The question's own fold deadline, and which form it was armed for. Deliberately outside
    /// `expandWork`/`collapseWork` (the hover machine's, which `cancelPending` clears on every
    /// expansion): a question card's fate is its form's, not the pointer's. Armed per **showing** —
    /// clearing it is what gives the next one a fresh deadline.
    private var questionWork: DispatchWorkItem?
    private var questionFoldFormID: String?

    /// Whether a form is on the card. The question card is held by its form exactly as an alert
    /// card is held by its alert: the hover poll may not fold it, a blank click may not, and the
    /// footer carries `Hide`.
    private var questionArmed: Bool { question != nil }
    private var lastSignature: String?
    private var expandedState = false
    private var visible = false
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var hoverTimer: Timer?

    /// **A dismissal latches the hover open off until the pointer leaves.** Set by `collapse()` — the
    /// menubar opening and a row click on a card that is not asking — and released in exactly three
    /// situations: the pointer is *seen* outside the hover rect (`evaluateHover`, the only thing that can
    /// observe what the latch is waiting for), anything else opens the card (`setExpanded(true)` — an
    /// alert is new information the user has not answered, not the poll second-guessing a dismissal), and
    /// the panel leaving or returning to screen (`hide`/`present`, so a latch set while the island was off
    /// screen cannot stick to it).
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
    /// The air the card keeps **below its last child**, which is the footer row — the same one step every
    /// edge of the card uses.
    ///
    /// The bottom used to pay a *second* step — `bottomPaddingWithoutActionRow`, another 8 — on every card
    /// with no `Hide` button under its last row, because there the last session row sat 8 above a bottom
    /// edge rounded up to 18 while the top edge paid two steps (the cutout — or `rowInset` — plus
    /// `islandExpandedTopPadding`), so the card read heavy at the top and pinched at the bottom. **That
    /// step is gone with the footer**: every card now holds a row between its last session row and the
    /// edge, which is the argument the alert's card always made, so the bottom is one step for every card
    /// and the conditional made the same number with a name for a case that no longer exists.
    private let bottomPadding: CGFloat = 8
    /// Air between two adjacent session rows in the **expanded** card, so a list of back-to-back rows
    /// reads as a list rather than as stripes. It exists only *between* rows: nothing above the first
    /// (the top edge already pays `islandExpandedTopPadding` plus the cutout) and nothing below the last
    /// (the footer follows it directly, which is what keeps the folded `+k more` line a footnote of the
    /// list it closes instead of a second block of its own).
    ///
    /// **6, against rows of 30/44/58 and the card's 8pt unit.** The range is bounded on both sides by the
    /// grouping the list has to read at: the gap *inside* a group must be smaller than the 8 between the
    /// group and the card's edge, or every row gets an edge of its own and a five-row list becomes five
    /// one-row cards; and it must still separate a 58pt row from its neighbour, which is where it stops
    /// being invisible. So 8 is rejected outright (it *is* the edge, and the card's padding rhythm stops
    /// saying which gap means what), and 4 is rejected as too quiet at the three-line row — it survives
    /// only at 30. 6 is the one step between them: 6 at the pixel, 2 clear of the thing it must not
    /// equal, and it costs a full six-row list 30pt, still inside the budget the fold already keeps.
    ///
    /// **The expanded value only.** The collapsed card's rows are the same views (the pill just hides
    /// them), so this is pushed to the card as 0 while folded — see `applyAppearance` — and the collapsed
    /// geometry, which `hoverLatched` and `islandExpandedTopPadding` both reason about, does not move.
    private let islandRowGap: CGFloat = 6
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

    /// The expanded card sizes itself from the content it actually holds — rows (or the one line that
    /// stands in for them when there are none), plus the folded summary, plus the footer — and
    /// `IslandCardView.layout()` positions those same views, so the window frame and the layout can never
    /// disagree. Its width is the derived target, bounded by the target screen.
    private func frame(expanded: Bool, metrics: ScreenMetrics) -> NSRect {
        let collapsed = collapsedSize(metrics: metrics)
        let size: NSSize
        if expanded {
            let height = card?.contentHeight
                ?? (contentTop(for: metrics) + islandRowOneLineHeight + actionRowHeight + bottomPadding)
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
    /// collapsed capsule. The only input that varies is the target: a card that is
    /// asking takes `islandQuestionCardTargetWidth`, everything else the hover card's 500.
    private func expandedCardWidth(collapsedWidth: CGFloat, metrics: ScreenMetrics) -> CGFloat {
        islandExpandedCardWidth(
            screenWidth: metrics.screen.frame.width,
            floor: collapsedWidth,
            target: questionArmed ? islandQuestionCardTargetWidth : islandExpandedCardTargetWidth
        )
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
            // "not a session row and not a footer control" — the card's margins, and the inert `+k more`
            // footnote and empty-state line, which this same path claims because `hitTest` deliberately lets
            // both fall through. On a hover card that is the way out (the pointer is on the card because the
            // user put it there), but an unprompted card has one way out and it is visible: `Hide`. Folding
            // on a stray click would end the reminder silently — `setExpanded(false)` neither latches the
            // hover open off nor ends the alert, so the card would sit armed and unseen, or, if the pointer
            // happened to stay inside the collapsed hover rect, pop back 0.35s later off the 0.15s poll:
            // one click, two outcomes. It is made no click at all. Clicking a *collapsed* card to open it
            // still works — while an alert is armed only `collapse()` folds the card, and that ends the
            // alert, so this guard only ever refuses the fold. A question card makes the same argument for
            // the same reason: its exits are `Hide` and its form settling.
            guard !((self.alertArmed || self.questionArmed) && self.expandedState) else { return }
            self.setExpanded(!self.expandedState, animated: true)
        }
        // The footer's gear — the one control on every card, alert or not. Answered one layer up, by the
        // app delegate, which owns the single menu; **nothing is folded here**, because the menu being about
        // to open collapses every island itself (`NSMenuDelegate.menuWillOpen`), and a fold on this path
        // would only do it twice.
        card.settingsButton.onActivate = { [weak self] in
            self?.onSettingsRequested?()
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
    /// has to be told about. A card armed while the island is off screen — or while there is nothing to list at
    /// all — lands here with no rows and scopes on the first tick that has the row (`update`).
    private func recomputeFold(metrics: ScreenMetrics) {
        let ranked = Self.attentionRanked(rows)
        resolveQuestion(in: ranked)
        // The rows this card is allowed to list, and the sessions already folded away before the budget is
        // applied — 0, or the rest of the list when one row is pinned out of it.
        let listed: [IslandRow]
        let foldedAway: Int
        if let focused = questionScopedIndex(in: ranked) ?? alertScopedIndex(in: ranked) {
            listed = [ranked[focused]]
            foldedAway = ranked.count - 1
        } else {
            listed = ranked
            foldedAway = 0
        }
        let heights = listed.map(Self.rowHeight(for:))
        // A question scopes the card to its asking row, and its `+k more` tail is shown when anything
        // folded behind it — so this is the room the block actually has, computed once and read by
        // both the budget and the block (`questionBlockHeight`, `syncQuestion`).
        questionBlockRoomHeight = questionBlockRoom(for: metrics, rows: heights, tail: foldedAway > 0)
        let budget = listBudget(for: metrics, tallestRowHeight: heights.max() ?? islandRowOneLineHeight)
        visibleRows = Array(listed.prefix(budget.visibleCount(forRowHeights: heights)))
        foldedCount = max(0, foldedAway + listed.count - visibleRows.count)
    }

    /// The head of the pending question queue: the oldest form of the first ranked row
    /// that carries one, and its position. Resolved here because it is the fold's other
    /// input — a pending question scopes the card exactly as an armed alert does, and
    /// **outranks it**: the form is the one thing that has to be answered.
    ///
    /// Panel-local state (`questionFieldIndex`) is reset when the form changes, so a
    /// queued form never opens on the field the previous one was left on.
    private func resolveQuestion(in ranked: [IslandRow]) {
        // **Arrival order, not row order.** Rows are attention-ranked, so the session that asked last
        // can rank above one that asked first; the card must still stay on the question already waiting
        // for an answer. The monitor stamps each form when it first sees it.
        var head: PendingQuestion?
        var total = 0
        for row in ranked {
            for form in row.questions {
                total += 1
                if head == nil || form.arrival < head!.arrival { head = form }
            }
        }
        // A hidden form asks nothing at all — not a later one in the queue behind it, which would
        // make `Hide` step to the next question instead of putting the card away.
        if let hidden = questionState.hidden, head?.id == hidden { head = nil }
        if head?.id != question?.id {
            // The form changed: the card opens on this form's first field. A reply in flight for the
            // previous one is the host's to release — the server settles a form as a whole.
            questionFieldIndex = 0
        }
        question = head
        questionQueueCount = total
    }

    /// Where the asking row sits in the ranked list. Nil when nothing is pending, which
    /// is what hands the card back to the whole list (or to an alert).
    private func questionScopedIndex(in ranked: [IslandRow]) -> Int? {
        guard let question else { return nil }
        return ranked.firstIndex { row in row.questions.contains { $0.id == question.id } }
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
            bottomPadding: bottomPadding,
            rowGap: islandRowGap,
            summaryRowHeight: summaryRowHeight,
            actionRowHeight: actionRowHeight,
            extraContentHeight: questionBlockHeight(for: metrics),
            tallestRowHeight: tallestRowHeight,
            fraction: listHeightFraction
        )
    }

    /// Room the question block has on this screen: from the card's top edge to the bottom of the
    /// usable area, less the top inset, the rows this card must show, the folded tail, the footer and
    /// the bottom padding. It is the block's share of `IslandListBudget.rowBudget`'s `hard` term, and
    /// the one place the block is clamped — a tall question scrolls its options inside what is left
    /// instead of pushing the footer past the bottom of the screen. One row on a question card, by
    /// `recomputeFold`'s scope; a hover card spends none of it (`extraContentHeight` is zero there).
    private func questionBlockRoom(for metrics: ScreenMetrics, rows: [CGFloat], tail: Bool) -> CGFloat {
        let usable = metrics.screen.frame.maxY - metrics.screen.visibleFrame.minY
        return max(0, usable - contentTop(for: metrics)
            - rows.reduce(0, +) - islandRowGaps(count: rows.count, gap: islandRowGap)
            - (tail ? summaryRowHeight : 0) - actionRowHeight - bottomPadding)
    }

    /// Height of the card's footer row: the card's own short-row height, `summaryRowHeight` — the same 24
    /// the folded `+k more` row uses — and now **always**, because the footer is always there. It carries
    /// the settings gear on every card and `Hide` joins it only while an alert is armed, so the row is
    /// chrome every budget pays rather than a row an alert adds. It is a row *of this card*, so it takes the
    /// card's rhythm rather than a height of its own, and the panel's copy and the card's
    /// (`IslandCardView.actionRowHeight`) come from that one number.
    private var actionRowHeight: CGFloat { summaryRowHeight }

    /// Add or remove the alert's `Hide` button **in the card's footer**, and report whether the chrome
    /// changed.
    ///
    /// The footer itself is permanent (`IslandCardGearButton` sits at its trailing edge on every card); what
    /// an alert adds is its way out, left of the gear. The rule is unchanged: a hover-opened card needs no
    /// `Hide` — moving the pointer away already folds it — so an explicit control there would be a button
    /// whose only function is what leaving does for free, and the alert is the one card the user did not ask
    /// for, which is exactly when a quiet way out is worth a button. What has changed is that the button no
    /// longer *creates* its row: the footer is there with or without it, so this moves no number the card's
    /// height is made of — only which controls the row lays out.
    @discardableResult
    private func syncActionRow() -> Bool {
        guard let card else { return false }
        var changed = false
        // `Hide` belongs to every card the user did not ask for: an alert's, and a question's
        // ("Hide folds without answering"). A hover card still needs none — moving the pointer away
        // already folds it.
        if alertArmed || questionArmed {
            if card.actionButton == nil {
                let button = IslandCardButton()
                button.onActivate = { [weak self] in
                    guard let self else { return }
                    // A question card's dismissal has to say *which* form not to ask about again;
                    // the alert's is the shared fold alone. Both are host-owned for the row click's
                    // reason: the card is on every screen, and hiding it on one hides it on all.
                    if let question = self.question {
                        self.releaseQuestionKeyboard()
                        self.onQuestionHidden?(question.id)
                    } else {
                        self.onHideRequested?()
                    }
                }
                // New views start in step with the current state, without animating, exactly as a new
                // row does (`rebuildRows`): a card that changes while open must not flash.
                button.alphaValue = expandedState ? 1 : 0
                card.addSubview(button)
                card.actionButton = button
                changed = true
            }
            // The card can turn from an alert's into a question's and back on one panel (or between
            // ticks), so the promise the tooltip makes is re-set with it: a question's `Hide` latches
            // the form off, and hovering would not bring it back.
            card.actionButton?.toolTip = questionArmed
                ? islandQuestionHideButtonTooltip
                : islandActionButtonTooltip
        } else if let button = card.actionButton {
            button.removeFromSuperview()
            card.actionButton = nil
            changed = true
        }

        // `Send` is the question card's alone, and it is held back rather than removed: the footer
        // must not reflow each time the last required answer lands.
        if questionArmed {
            if let button = card.sendButton {
                button.isEnabled = canSendCurrentQuestion
            } else {
                let button = IslandCardButton(text: islandSendButtonLabel,
                                              tooltip: islandSendButtonTooltip,
                                              disabledTooltip: islandSendButtonDisabledTooltip)
                button.onActivate = { [weak self] in self?.submitQuestion() }
                button.isEnabled = canSendCurrentQuestion
                button.alphaValue = expandedState ? 1 : 0
                card.addSubview(button)
                card.sendButton = button
                changed = true
            }
        } else if let button = card.sendButton {
            button.removeFromSuperview()
            card.sendButton = nil
            changed = true
        }
        return changed
    }

    /// Resize an open card to its current height, top edge anchored, without touching hover state. One
    /// thing changes that height now: the fold — a row count moving, or the empty line standing in for a
    /// list that has gone. The footer's 24 is in every card and the `Hide` button rides inside it, so an
    /// alert adds and removes nothing that this has to pay for.
    private func resizeOpenCard() {
        guard visible, expandedState, let card else { return }
        let metrics = currentMetrics()
        card.contentTop = contentTop(for: metrics)
        // Open, so the list keeps its gap: this path only ever runs for a card already expanded.
        card.rowGap = islandRowGap
        // One step on the bottom in both states — the footer holds the last row off the edge either way —
        // so this is the same number `applyAppearance` pushes, kept here because a card can also be open
        // while this runs.
        card.bottomPadding = bottomPadding
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
                // Answered by the host rather than here: one screen's row click has to end an alert's
                // reminder on *every* screen (the other display's card would otherwise sit open for the
                // rest of the alert's seconds), and only the host can reach the other panels. It also
                // carries the hover latch the panel needs when it *does* fold, since the pointer is
                // inside this island by construction — see `IslandHost.rowActivated`, and its
                // question-card exception beside it.
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
                stamp: row.stamp,
                subagents: row.subagents
            )
        }
        card.rowViews = rowViews
        rebuildSummary(in: card)
        rebuildEmptyState(in: card)
        // A row built on this tick has to inherit the current visibility along with everything
        // else, or the ring on a freshly built busy row would start before anyone could see it.
        updateRowOnScreen()

        // New views start visible; keep them in step with the current state
        // without animating, so a poll tick never flashes the list.
        let alpha: CGFloat = expandedState ? 1 : 0
        for view in rowViews where view.alphaValue != alpha {
            view.alphaValue = alpha
        }
        if let empty = card.emptyStateView, empty.alphaValue != alpha {
            empty.alphaValue = alpha
        }
        if let question = card.questionView, question.alphaValue != alpha {
            question.alphaValue = alpha
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

    /// Add or drop the one inert line the card shows when it has **no session rows at all**.
    ///
    /// The card must never be bare padding: with the menubar item hidden the island is the app's only
    /// surface, so an empty ocbar has to say *why* the card is empty rather than draw an empty box under a
    /// gear. It is one `rowHeight` tall and the card's height comes from that same number
    /// (`IslandCardView.emptyStateHeight`), so this is content like any other row — created and removed by
    /// this one path, alpha-synced like a row's — and never a special case in the frame.
    ///
    /// Called from `rebuildRows` and from `refoldCard` (which runs it on every fold, ahead of the row
    /// signature). **Reports whether the card's content changed**, because the line is not a row: it can
    /// arrive on a fold the row signature calls a no-op, and the open card still has to be resized for it.
    @discardableResult
    private func rebuildEmptyState(in card: IslandCardView) -> Bool {
        guard visibleRows.isEmpty else {
            guard card.emptyStateView != nil else { return false }
            card.emptyStateView?.removeFromSuperview()
            card.emptyStateView = nil
            return true
        }
        guard card.emptyStateView == nil else { return false }
        let view = IslandEmptyStateView(frame: .zero)
        // The alpha is set on creation, not left to `rebuildRows`: this can be created on a fold that path
        // does not run, and a folded card keeps its content views at alpha 0 (see `applyAppearance`) — an
        // unsynced line would draw inside the collapsed pill.
        view.alphaValue = expandedState ? 1 : 0
        card.addSubview(view)
        card.emptyStateView = view
        return true
    }

    /// The block the card draws for the head question, or nil when nothing is asking.
    ///
    /// One construction feeds both the view and the height the card budgets
    /// (`questionBlockHeight` → `IslandListBudget`), so what is measured and what is
    /// drawn cannot drift — the same rule the row heights and the empty line follow.
    ///
    /// The queue's position is always `1`: a settled form leaves the server's list, and
    /// the card only ever draws the head, so `1 of 3` is literally where the shown form
    /// sits in the queue.
    private func questionContent() -> IslandQuestionView.Content? {
        guard let question else { return nil }
        let fields = question.fields
        let index = fields.indices.contains(questionFieldIndex) ? questionFieldIndex : 0
        let field = fields.isEmpty ? nil : fields[index]
        let answers = questionState.answers[question.id] ?? [:]
        let textMode = field.map { isTyping($0) } ?? false
        return IslandQuestionView.Content(
            formID: question.id,
            body: field?.body ?? "",
            fieldIndex: index,
            fieldCount: fields.count,
            queueIndex: 1,
            queueCount: questionQueueCount,
            field: field,
            answerable: question.answerable,
            steppable: fields.count > 1,
            answers: answers,
            textEntry: textMode,
            text: field.map { textMode ? typedText($0) : "" } ?? ""
        )
    }

    /// Whether the card is drawing a field's text field: a text field's own rule (`Other…` picked, or
    /// its only row), or a list field whose `Other…` row is open — there the typed string is a draft
    /// until Enter adds it, so it cannot be read off the answer.
    private func isTyping(_ field: QuestionField) -> Bool {
        guard let question else { return false }
        if field.kind == .list { return questionState.drafts[question.id]?[field.key] != nil }
        return field.showsTextEntry(answer: questionState.answers[question.id]?[field.key])
    }

    /// What the text field shows: the typed answer itself, or a list field's unconfirmed draft.
    private func typedText(_ field: QuestionField) -> String {
        guard let question else { return "" }
        if field.kind == .list { return questionState.drafts[question.id]?[field.key] ?? "" }
        guard case .text(let value)? = questionState.answers[question.id]?[field.key] else { return "" }
        return value
    }

    /// Height the question block costs the card right now. Zero when nothing is
    /// asking, which is every card that is not a question card.
    ///
    /// The width is the block's **own** text column — the card's derived width less the same two insets
    /// `IslandCardView.layout` gives it — because the question wraps and the height it wraps to depends
    /// on it. Measuring at the card's width rather than at a nominal one is what keeps the budget and the
    /// placed frame the same number on a narrow screen, where the clamp makes the card narrower too.
    private func questionBlockHeight(for metrics: ScreenMetrics) -> CGFloat {
        questionContent().map {
            IslandQuestionView.height(for: $0, width: questionBlockWidth(for: metrics),
                                      maxHeight: questionBlockRoomHeight)
        } ?? 0
    }

    /// The question block's text column on this screen: the expanded card's derived width less the block's
    /// leading and trailing insets, the two numbers `IslandCardView.layout` places it with.
    private func questionBlockWidth(for metrics: ScreenMetrics) -> CGFloat {
        let collapsed = collapsedSize(metrics: metrics)
        return max(0, expandedCardWidth(collapsedWidth: collapsed.width, metrics: metrics)
            - islandRowTextInset - islandRowTrailingInset)
    }

    /// Add, refresh or drop the question block under the waiting row, and report
    /// whether the card's height changed so an open card can be resized.
    ///
    /// Content like the empty line, and created/removed by this one path: it is not a
    /// row, it has no glyph column and its height is its own — so the card reads it
    /// from `questionView`, and nothing here goes through the row signature.
    @discardableResult
    private func syncQuestion() -> Bool {
        guard let card else { return false }
        guard let content = questionContent() else {
            guard let view = card.questionView else { return false }
            view.removeFromSuperview()
            card.questionView = nil
            syncQuestionKeyboard()
            return true
        }
        let view: IslandQuestionView
        if let existing = card.questionView {
            view = existing
        } else {
            view = IslandQuestionView(frame: .zero)
            // The alpha is set on creation, not left to `rebuildRows`: this can be created on a fold the
            // row path does not run, and a folded card keeps its content views at alpha 0.
            view.alphaValue = expandedState ? 1 : 0
            view.onOption = { [weak self] option in self?.selectOption(option) }
            view.onText = { [weak self] text in self?.textEntered(text) }
            view.onStep = { [weak self] delta in self?.stepField(delta) }
            view.onCommitText = { [weak self] text in self?.commitQuestionText(text) }
            view.onCancelText = { [weak self] in self?.cancelQuestionText() }
            card.addSubview(view)
            card.questionView = view
        }
        let changed = view.configure(content, width: questionBlockWidth(for: currentMetrics()),
                                     maxHeight: questionBlockRoomHeight)
        // The block is what shows and hides the text field, so every rebuild is also a chance to give
        // the keyboard back — a field step, a commit, a settle or a payload change.
        syncQuestionKeyboard()
        return changed
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
        // The one-core percentage with its fractional part still on it, plus the unit it is drawn in:
        // the format, the caps and the display deadbands all live in `CPUUnit`, and the view applies
        // them. Set on every tick — the unit is what lets a menu pick repaint without a new sample.
        collapsedView?.cpuUnit = cpuUnit
        collapsedView?.cpu = serviceCPU
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
        setFrame(frame(expanded: false, metrics: metrics), display: false, animated: false)
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
        // An alert cannot outlive the card it was showing: a disabled island has no card to open one on,
        // and a panel being retired is a screen that is gone. (An empty list is no longer one of the
        // reasons to hide — the card says so instead, see `update` — so this is the only place an alert
        // dies with the panel.)
        clearAlert()
        // The question's deadline dies with the panel too: it would otherwise fold a card that is not
        // on screen, and its dismissal belongs to whoever sees the question next.
        questionWork?.cancel()
        questionWork = nil
        questionFoldFormID = nil
        // Off screen, no form has been "already opened": a question that is still pending when the
        // island comes back takes the card again, the way an armed alert does.
        autoOpenedQuestionID = nil
        // A dismissal latch dies with the panel too: it latches the *hover* open off, and there is
        // nothing to hover once the island is off screen — leaving it set would make a returning island
        // ignore the pointer that is still sitting where it was.
        hoverLatched = false
        cancelPending()
        stopHoverTimer()
        expandedState = false
        // An off-screen card holds no keyboard: a disabled island or a retired display hands the
        // terminal its typing back exactly as a fold does.
        releaseQuestionKeyboard()
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
        // A fold ends the card's one keyboard moment wherever it came from (the deadline, `Hide`,
        // the menubar); the terminal gets its typing back here rather than on the next tick.
        syncQuestionKeyboard()
        // Before the guard: the card's rows follow `expandedState` whether or not this panel is up,
        // and a row's mark must stop the moment the card starts closing rather than at the next tick.
        updateRowOnScreen()
        guard visible else { return }
        let metrics = currentMetrics()
        let time = duration ?? animationDuration
        applyAppearance(expanded: value, metrics: metrics, animated: animated, duration: time)
        let target = frame(expanded: value, metrics: metrics)
        setFrame(target, display: true, animated: animated, duration: time)
    }

    /// The window is sized to its visible bounds, so the same frame change that
    /// grows the capsule also governs hit-testing — no click monitor needed.
    private func applyAppearance(expanded: Bool, metrics: ScreenMetrics, animated: Bool, duration: TimeInterval? = nil) {
        guard let card, let collapsedView else { return }
        card.cornerRadius = cornerRadius(expanded: expanded, metrics: metrics)
        // Flush against the top edge: the card's own `draw` squares the top corners on every
        // display — see there for why the shape does not vary with the screen.
        card.contentTop = expanded ? contentTop(for: metrics) : rowInset
        // The gap is the expanded card's alone — the same rule as the top step above, and for the same
        // reason: the collapsed card still holds these rows, so anything that moves them is a change to
        // the pill's geometry, which `hoverLatched` is measured in. See `islandRowGap`.
        card.rowGap = expanded ? islandRowGap : 0
        // One step on the bottom in both states: the footer (`actionRowHeight`) sits between the last
        // session row and the edge whether or not an alert's `Hide` is in it, so the bottom no longer has
        // an expanded-only step to mirror the top's.
        card.bottomPadding = bottomPadding
        card.rowViews = rowViews
        card.needsLayout = true

        collapsedView.notched = metrics.notched
        collapsedView.notchWidth = metrics.notchWidth

        let collapsedAlpha: CGFloat = expanded ? 0 : 1
        let rowsAlpha: CGFloat = expanded ? 1 : 0
        // Everything the card holds that is not the collapsed pill: the rows, the empty line that stands in
        // for them when there are none, the folded summary, and the footer's two controls — so the gear is
        // invisible with the rows when the card is folded, and nothing in the footer can be clicked there
        // either (`IslandCardView.hitTest` gates on the same alpha).
        var contentViews: [NSView] = rowViews
        if let empty = card.emptyStateView { contentViews.append(empty) }
        if let question = card.questionView { contentViews.append(question) }
        if let summary = card.summaryView { contentViews.append(summary) }
        contentViews.append(card.settingsButton)
        if let actionButton = card.actionButton { contentViews.append(actionButton) }
        if let sendButton = card.sendButton { contentViews.append(sendButton) }
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

    /// Move the panel's window to `target` — **always through the animator proxy, including the moves
    /// that are not meant to take time** (`animated: false` is a zero-duration animation, never a direct
    /// `setFrame`).
    ///
    /// That is not a stylistic choice. A direct `setFrame` does **not** cancel a frame animation already
    /// in flight: the animation's next step writes its old target back over the new frame, so the window
    /// finishes where the animation was always going. That is a real bug this surface shipped — a fold
    /// landing inside the open's 0.3s (`collapse()` from a row click, the `Hide` button, or the menubar
    /// opening) switched the surface back to the collapsed pill while the window kept growing to the
    /// **expanded** frame, leaving a full-size black card with nothing on it but the ring and the running
    /// count floating in the middle, and no row anywhere. Starting an animation — of any length — is what
    /// cancels the previous one.
    ///
    /// The instant path deliberately has no "already there" guard: while an animation to *another* target
    /// is running, the frame may sit exactly on `target` for a moment, and returning early there would be
    /// the one case that leaves the stale animation alive.
    private func setFrame(_ target: NSRect, display: Bool, animated: Bool, duration: TimeInterval? = nil) {
        guard let panel else { return }
        if animated, panel.frame == target { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? (duration ?? animationDuration) : 0
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().setFrame(target, display: display)
        }
    }

    /// Resize an open card (the fold moved, or the rows went away and the empty line took their place).
    /// Animated, because the card is on screen and a height change is information the user is reading; the
    /// animator is what makes it supersede any open/fold still in flight (see `setFrame`).
    private func animateFrame(to target: NSRect) {
        setFrame(target, display: true, animated: true, duration: 0.25)
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
        // **An alert's or a question's card is not the hover poll's to fold.** That poll runs every
        // 0.15s and the pointer is usually *outside* the island when such a card opens — that is what
        // an unprompted expansion is — so without this guard the card would be folded one
        // `hoverCloseDelay` after it opened and nobody would ever read it. While either is up, its own
        // deadline owns the fold and hands the card back here when it ends (`endAlert`/`endQuestion`).
        // Expansion is deliberately not guarded: unless a dismissal has latched the hover open off
        // (`hoverLatched`), the poll may still open the card mid-alert, it just may not close it.
        guard !alertArmed, !questionArmed, expandedState, collapseWork == nil else { return }
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

    // MARK: - Question

    /// The field the card is on, or the form's first when the index is out of date.
    private var currentField: QuestionField? {
        guard let question else { return nil }
        return question.fields.indices.contains(questionFieldIndex)
            ? question.fields[questionFieldIndex]
            : question.fields.first
    }

    /// One click on an option row. `Other…` is not a value: for a text field it starts the field's text
    /// mode with an empty answer, for a list field it opens a draft the typed string is added from.
    /// Either way the block draws its text field on the very next configuration.
    private func selectOption(_ option: QuestionOption) {
        guard let question, let field = currentField else { return }
        // Picking a row is also how the text row closes: the answer it was holding is replaced rather
        // than left behind with the rows hidden.
        if isTyping(field) { onQuestionClear?(question.id, field.key) }
        if option.isOther {
            if field.kind == .list {
                // A list's picked values stay untouched while the draft is open: `Other…` adds to
                // them on confirm, it does not replace them.
                onQuestionDraft?(question.id, field.key, "")
            } else {
                onQuestionAnswer?(question.id, field.key, .text(""))
            }
            // The text field exists only after that push has been drawn — and only on the screen that
            // was clicked, which is why the keyboard is taken here and not by the block.
            DispatchQueue.main.async { [weak self] in self?.focusQuestionText() }
            return
        }
        switch field.kind {
        case .flag:
            onQuestionAnswer?(question.id, field.key, .flag(option.flag ?? false))
        case .list:
            // A multiselect accumulates: the same row again takes the value back out.
            var values = currentList(of: field.key, formID: question.id)
            if let index = values.firstIndex(of: option.value) {
                values.remove(at: index)
            } else {
                values.append(option.value)
            }
            onQuestionAnswer?(question.id, field.key, .list(values))
        case .text, .unsupported:
            onQuestionAnswer?(question.id, field.key, .text(option.value))
        }
        // A single choice is the whole answer, so the card moves on by itself. A multiselect stays put:
        // its rows accumulate, and stepping away after one pick would turn the second pick into a walk
        // back. Nothing here sends — the footer's `Send` is the only write.
        if field.kind != .list, question.fields.indices.contains(questionFieldIndex + 1) {
            stepField(1)
        }
    }

    private func currentList(of key: String, formID: String) -> [String] {
        guard case .list(let values) = questionState.answers[formID]?[key] else { return [] }
        return values
    }

    /// A keystroke in the free-text field. A text field's answer **is** the text, so every keystroke
    /// is the answer and a render tick that arrives mid-word cannot lose it. A list field's typed
    /// string is a draft instead: Enter adds it to the picked values, so it is held apart.
    private func textEntered(_ text: String) {
        guard let question, let field = currentField else { return }
        if field.kind == .list {
            onQuestionDraft?(question.id, field.key, text)
        } else {
            onQuestionAnswer?(question.id, field.key, .text(text))
        }
    }

    /// Enter on a list field's `Other…` row: the typed string is **added** to the picked values, and
    /// the field goes back to its rows. An empty draft only closes the row.
    private func commitQuestionText(_ text: String) {
        guard let question, let field = currentField, field.kind == .list else { return }
        onQuestionCommit?(question.id, field.key, text)
    }

    /// Escape in the free-text row: back to the field's options. A text field's answer **is** its text, so
    /// dropping the answer is what returns the rows; a list field's draft is dropped and the values
    /// already picked stay. A field with no rows of its own has nothing to go back to, and refuses.
    private func cancelQuestionText() {
        guard let question, let field = currentField, isTyping(field) else { return }
        guard field.options.contains(where: { !$0.isOther }) else { return }
        onQuestionClear?(question.id, field.key)
    }

    /// A chevron: step to the next or previous field of the same form. Only the field index moves —
    /// answers already given stay where they are, keyed on the form and field.
    private func stepField(_ delta: Int) {
        guard let question else { return }
        let next = questionFieldIndex + delta
        guard question.fields.indices.contains(next) else { return }
        questionFieldIndex = next
        let heightChanged = syncQuestion()
        if heightChanged { resizeOpenCard() } else { card?.needsLayout = true }
    }

    /// The answers picked for the head form, dropping empty ones: a required field with an empty typed
    /// answer is not an answer, and a field left empty is not sent at all.
    private func answersForSubmission(_ question: PendingQuestion) -> [String: QuestionAnswer] {
        let picked = questionState.answers[question.id] ?? [:]
        var answers: [String: QuestionAnswer] = [:]
        for field in question.fields {
            guard let answer = picked[field.key], !answer.isEmpty else { continue }
            answers[field.key] = answer
        }
        return answers
    }

    /// Whether `Send` may be pressed: every required field carries a non-empty answer, the form can be
    /// answered here at all, and no reply is already in flight for it — on **any** screen, since the
    /// guard lives in the host's shared state (`IslandQuestionState.submitting`).
    private var canSendCurrentQuestion: Bool {
        guard let question, question.answerable, !questionState.submitting.contains(question.id) else { return false }
        let picked = questionState.answers[question.id] ?? [:]
        return question.fields.allSatisfy { field in
            guard field.required else { return true }
            return !(picked[field.key]?.isEmpty ?? true)
        }
    }

    /// `Send`: one reply carrying every field's answer. The form does not leave this card here — the
    /// monitor's reply completion is what drops it from the rows, so the card can only ever fold once
    /// the server has answered or refused. The in-flight guard is the host's, so every screen's
    /// `Send` is held back by the one click.
    private func submitQuestion() {
        guard let question, canSendCurrentQuestion else { return }
        releaseQuestionKeyboard()
        onSubmitQuestion?(question, answersForSubmission(question))
    }

    /// Take the keyboard for the free-text answer — the card's **only** keyboard moment. The panel is
    /// a non-activating window that can become key (`IslandWindow.canBecomeKey`), so this accepts
    /// typing without pulling the app in front of the terminal; everything else here is pointer-only.
    private func focusQuestionText() {
        guard let panel, let entry = card?.questionView?.textEntry else { return }
        panel.makeKey()
        if panel.makeFirstResponder(entry) { questionKeyHeld = true }
    }

    /// Give the keyboard back, because the card's one keyboard moment is over. Resigning key is what
    /// returns typing to the terminal this non-activating panel took it from; the panel itself stays
    /// on screen, only its key status and first responder go.
    private func releaseQuestionKeyboard() {
        guard questionKeyHeld else { return }
        questionKeyHeld = false
        panel?.makeFirstResponder(nil)
        panel?.resignKey()
    }

    /// Reconcile the keyboard with what the card is actually showing. The block hides its text field
    /// whenever text mode ends — a commit, a field step, `Hide`, a settle, a payload change — and the
    /// card folds for its deadline; in every one of those the terminal must get its typing back.
    private func syncQuestionKeyboard() {
        guard questionKeyHeld else { return }
        guard expandedState, card?.questionView?.isTextEntryVisible == true else {
            releaseQuestionKeyboard()
            return
        }
    }

    /// The last pending form settled: the card is no longer the question's. Hand it back to the hover
    /// machine exactly as an alert's own timer does (`endAlert`), so an unattended card folds on the
    /// ordinary deadline while a card somebody is pointing at stays readable.
    private func endQuestion() {
        questionWork?.cancel()
        questionWork = nil
        questionFoldFormID = nil
        evaluateHover()
    }

    /// Arm (or re-arm) the question's own fold deadline for this showing.
    ///
    /// Once per showing and never extended: the pointer does not touch it. This card was not opened by
    /// the pointer, so it does not close because of it — `ocbar.questionFold` says how long it gets and
    /// nothing else moves that deadline. A queued form has its own id, so it takes a fresh one, and so
    /// does a card the deadline folded when the pointer brings it back (`foldQuestion`).
    private func armQuestionTimer() {
        guard let question, expandedState, let seconds = islandQuestionFold() else {
            questionWork?.cancel()
            questionWork = nil
            questionFoldFormID = nil
            return
        }
        guard questionFoldFormID != question.id else { return }
        questionFoldFormID = question.id
        questionWork?.cancel()
        let formID = question.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.question?.id == formID else { return }
            self.onQuestionFoldReached?(formID)
        }
        questionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
        // The alert's `Hide` button goes with the alert — it exists only while one is armed — and the footer it sat
        // in does not, so that alone moves no height and only re-lays the footer's contents out. What can still
        // move an open card here is the *rows*: the scoped list becomes the whole list again. And it is not a
        // fold either: `endAlert` and `retractAlert` leave the card to the hover machine, which is what makes
        // this the one exit that shrinks an open card rather than closing it. (`collapse` folds first, so this
        // is a no-op there — `resizeOpenCard` is guarded on `expandedState`, and the restored rows come back
        // invisibly for the next open.)
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
    ///
    /// **The empty line is reconciled before the signature and outside it**, because the signature signs the
    /// *rows* and this line is exactly what a card with no rows has instead of them. Left inside it, a card
    /// born with no rows never gets one: `rebuildRows` is the only caller of `rebuildEmptyState` and it sits
    /// behind the signature guard, while the empty signature (`"0\u{2}"`) is stable and has usually been
    /// recorded already — that is the ordinary launch: `IslandHost.rebuild` runs from `init` and pushes
    /// `enabled: false` (its `lastEnabled` initial value) into the fresh panels, whose `hide()` → `refoldCard`
    /// records the empty signature **with no card in existence** (`rebuildRows` returns on its own `guard let
    /// card`), and the first tick that does have a card computes the same signature and is told nothing
    /// changed. Its arrival is content changing — it moves the height — so it is reported like a row change.
    /// Cost on a fold that needs nothing: one guard over an empty row list and one nil check.
    @discardableResult
    private func refoldCard() -> Bool {
        recomputeFold(metrics: currentMetrics())
        var emptyChanged = false
        if let card { emptyChanged = rebuildEmptyState(in: card) }
        // The question block is content like the empty line and outside the row
        // signature: the signature signs the *rows*, and a selection or a field step
        // changes no row at all.
        let questionChanged = syncQuestion()
        let signature = Self.signature(for: visibleRows, folded: foldedCount)
        if signature != lastSignature {
            lastSignature = signature
            rebuildRows()
            return true
        }
        return emptyChanged || questionChanged
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
///
/// It holds four kinds of child: the session rows, the inert `+k more` footnote, the inert line that stands
/// in for the rows when there are none, and the footer's two controls — the settings gear, which is always
/// there, and the alert's `Hide`, which joins it.
private final class IslandCardView: NSView {
    var onClick: (@MainActor () -> Void)?
    var rowViews: [IslandRowView] = [] {
        didSet { needsLayout = true }
    }
    /// The inert `+k more` row, when the list was folded. Never part of
    /// `rowViews`: `hitTest` below hands clicks to session rows and to the footer's
    /// controls in their own frames, and never to this, so a click on the summary
    /// falls through to the card's expand/collapse toggle like any other blank part
    /// of the card.
    var summaryView: IslandSummaryView? {
        didSet { needsLayout = true }
    }
    /// The inert line the card shows when it has **no session rows at all** (`No OpenCode sessions`). Owned by
    /// the panel, which is what knows there is nothing to list (`IslandPanel.rebuildEmptyState`), and inert for
    /// the summary's reason: `hitTest` never names it, so a click on it falls through to the card's toggle.
    /// Its height is `emptyStateHeight` — one row's — which `contentHeight` and `layout()` both read.
    var emptyStateView: IslandEmptyStateView? {
        didSet { needsLayout = true }
    }
    /// The alert's `Hide` button, in the footer's row **left of the gear**. Nil unless an alert is armed
    /// (`IslandPanel.syncActionRow`), and deliberately not part of `rowViews`: it is the summary row's
    /// opposite, in that it *does* claim exactly its own frame in `hitTest` while the summary claims nothing.
    var actionButton: IslandCardButton? {
        didSet { needsLayout = true }
    }
    /// The question card's `Send`, immediately **left of `Hide`**, in the same footer row. It exists
    /// only while a form is on the card, and it is disabled until every required field has an answer
    /// (`IslandPanel.canSendCurrentQuestion`) — a control held back, never a control that vanishes.
    var sendButton: IslandCardButton? {
        didSet { needsLayout = true }
    }
    /// The question block under the waiting row, when a form is pending. Owned by the panel
    /// (`IslandPanel.syncQuestion`): it is content, not chrome, and it sits below the `+k more` footnote
    /// and above the footer. Inert itself — `hitTest` descends into it so its options and chevrons get
    /// their clicks — and its height is `height`, the number the panel budgets.
    var questionView: IslandQuestionView? {
        didSet { needsLayout = true }
    }
    /// The footer's gear, and the card's only control that is **always** there. Created here rather than
    /// injected: it is not data — the panel does not decide whether the card has settings — so the card owns it
    /// the way it owns its corner radius, and the panel only wires `onActivate` (`IslandPanel.makePanel`).
    ///
    /// Its frame comes from `layout`: trailing edge on the card's trailing inset, the footer's full height, its
    /// width measured from the glyph (`IslandCardGearButton.width`). Nothing about it depends on the rows, the
    /// fold or the alert, which is what keeps it still while everything above it moves.
    let settingsButton = IslandCardGearButton(frame: .zero)
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
    /// Air between two adjacent session rows — **between them only**, so n rows carry
    /// `islandRowGaps(count: n, gap: rowGap)` of it (`contentHeight` and `layout()` both take their
    /// number from that one function).
    ///
    /// Defaults to 0 and is pushed back to 0 while the card is collapsed (`IslandPanel.applyAppearance`),
    /// because the rows live here in both states — the collapsed pill hides them, it does not remove
    /// them — and the collapsed card's own geometry is load-bearing: its rows keep `rowInset` (8) so they
    /// sit inside the collapsed rect, which is what `hoverLatched` reasons about (see
    /// `islandExpandedTopPadding`). Moving a hidden row would still be invisible on screen, and that is
    /// exactly how it would eventually be read as the visible one.
    var rowGap: CGFloat = 0 {
        didSet { if rowGap != oldValue { needsLayout = true } }
    }
    var contentTop: CGFloat = 0 {
        didSet { if contentTop != oldValue { needsLayout = true } }
    }
    var cornerRadius: CGFloat = 12 {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // First child, so every other view this card gains sits above it. It is the card's own furniture, not
        // its content, which is why it is built here and not by the panel.
        addSubview(settingsButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Height a row view needs, from the lines it currently shows.
    private func height(of view: IslandRowView) -> CGFloat {
        rowHeight + CGFloat(max(view.lineCount, 1) - 1) * rowHeightPerExtraLine
    }

    /// Height of the line that stands in for the rows when there are none: **one row's**, because it *is* one
    /// row — a single line of text in the rows' own column, one `rowHeight` tall. `contentHeight` and
    /// `layout()` both take their number from here, so the card's frame and its layout cannot disagree about
    /// the empty card either.
    private var emptyStateHeight: CGFloat { rowHeight }

    /// Height the card needs for the content it currently holds. The panel sizes
    /// the window from this and `layout()` positions the very same views with the
    /// same heights, so the two can never disagree — one source of truth for the
    /// expanded height. With no rows, that is the empty-state line **if the card
    /// has one**.
    var contentHeight: CGFloat {
        var total = contentTop + rowViews.reduce(0) { $0 + height(of: $1) }
        // The air between the rows, which is the same sum `layout()` steps over between frames — the
        // frame and the stack of rows cannot disagree about a mixed-height list, gaps included.
        total += islandRowGaps(count: rowViews.count, gap: rowGap)
        // The line is counted only when it is on the card — `emptyStateView != nil`, the same predicate
        // `layout()` places it under — and not merely when the row list is empty. Those two diverge for as
        // long as a card can exist without its line, and counting a line `layout()` will not place is the
        // whole bug: it budgeted `emptyStateHeight` here while `layout()` left `y` alone, so `footerY`
        // landed one row above the card's bottom edge and the gear floated there over an empty gap.
        if rowViews.isEmpty, emptyStateView != nil { total += emptyStateHeight }
        // The `+k more` footnote is the list's last element, so it follows the rows and sits above the
        // question block — the same order `layout()` places them in.
        if summaryView != nil { total += summaryRowHeight }
        // The question block sits between that footnote and the footer, and its own height includes the
        // air above it — `layout()` advances by exactly this number.
        if let questionView { total += questionView.height }
        total += actionRowHeight
        return total + bottomPadding
    }

    /// Height of the card's footer row: **always** the card's short-row height, the same 24 the `+k more`
    /// footnote is laid out at. It used to exist only while the alert's `Hide` button did; the gear makes it
    /// permanent, so the number no longer depends on `actionButton` at all — and the panel budgets for it from
    /// the same constant (`IslandPanel.actionRowHeight`).
    private var actionRowHeight: CGFloat { summaryRowHeight }

    // Anything not claimed by a row toggles the island.
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Route every click explicitly: a visible row claims its own clicks, the
    // footer's controls claim theirs, and the rest of the card claims the remainder
    // (so clicks on the collapsed status dots still toggle, without relying on
    // responder-chain forwarding). The summary and the empty-state line are
    // deliberately not candidates, so they stay inert as rows; the two footer
    // controls are, but only inside their own frames — the card's blank area must
    // keep toggling the island everywhere else (`onClick` itself refuses that
    // toggle while an alert is armed, which is where the alert's one-way-out is
    // kept, not here).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // **The gear first, and before the alert's refusal below.** It has to work while an alert is armed:
        // `Hide` is that alert's answer, and settings are not an answer to anything — the card's blank area is
        // the one place that deliberately stops toggling then. Same rule as the button: the view itself, not
        // its `hitTest`, so a click never descends into the glyph.
        //
        // **The alpha gate is load-bearing here, not a formality.** While the card is collapsed the window is
        // the pill's frame, and on an *empty* card the footer starts at `contentTop` (8) in a 24/32pt capsule —
        // so the gear's frame can lie inside the collapsed bounds. It is alpha 0 there because every fold goes
        // through `applyAppearance` with the gear in `contentViews`, and this gate is what turns that into "the
        // click falls through to the pill's toggle". A collapsed gear that kept its alpha would be a dead
        // 31 × 24 hole in the island.
        if settingsButton.alphaValue > 0.5, settingsButton.frame.contains(local) {
            return settingsButton
        }
        if let actionButton, actionButton.alphaValue > 0.5, actionButton.frame.contains(local) {
            // The button itself, not `actionButton.hitTest`: its frame is the target, and letting AppKit
            // descend one level further would hand the click to the label inside it, which does nothing.
            return actionButton
        }
        if let sendButton, sendButton.alphaValue > 0.5, sendButton.frame.contains(local) {
            return sendButton
        }
        for view in rowViews.reversed() where view.alphaValue > 0.5 && view.frame.contains(local) {
            return view
        }
        // The question block, descended into: its option rows, chevrons and text field are the
        // controls, and a click on its blank parts must not fall through to the card's toggle — the
        // block is a form, not padding.
        if let questionView, questionView.alphaValue > 0.5, questionView.frame.contains(local) {
            return questionView.hitTest(local) ?? questionView
        }
        return self
    }

    override func layout() {
        super.layout()
        let inset = rowInset
        let width = max(0, bounds.width - inset * 2)
        var y = contentTop
        for (index, view) in rowViews.enumerated() {
            // Each row is as tall as the lines it shows, so a list mixes heights.
            let h = height(of: view)
            view.frame = NSRect(x: inset, y: y, width: width, height: h)
            y += h
            // Between rows, and only there: the last row is followed straight by the `+k more` footnote
            // (which closes the list), the question block, or the footer, and none of them is a session
            // the list is separating.
            if index < rowViews.count - 1 { y += rowGap }
        }
        if rowViews.isEmpty, let emptyStateView {
            // The line that stands in for an empty list, in the rows' own column — so its text starts
            // exactly where a folder name would, rather than under the status glyph that is not there. One
            // row tall, and `emptyStateHeight` is the same number `contentHeight` counted for it.
            emptyStateView.frame = NSRect(x: inset, y: y, width: width, height: emptyStateHeight)
            y += emptyStateHeight
        }
        if let summaryView {
            // The folded tail closes the list, immediately under its last row and above the question
            // block — so a clipped `Other…` row never reads as a fourth option.
            summaryView.frame = NSRect(x: inset, y: y, width: width, height: summaryRowHeight)
            y += summaryRowHeight
        }
        if let questionView {
            // Under the list (and its tail), in the waiting row's **text column** — the block belongs to
            // the row above it rather than to the list, and its own leading air is inside `height`.
            let qInset = islandRowTextInset
            questionView.frame = NSRect(
                x: qInset,
                y: y,
                width: max(0, bounds.width - qInset - islandRowTrailingInset),
                height: questionView.height
            )
            y += questionView.height
        }
        // The footer closes the card: the last row, under everything, with no divider above it — the card's
        // own placement, and it keeps the controls out of the rows' vertical rhythm rather than pretending to
        // be one of them.
        //
        // **The gear is the fixed point in it**: measured from the card's trailing inset, so it sits at the
        // same x on a hover card, an alert card and an empty one, and `Hide` arriving beside it moves nothing
        // to its right. The footer's height is the card's short row in both states.
        let footerY = y
        settingsButton.frame = NSRect(
            x: bounds.width - inset - IslandCardGearButton.width,
            y: footerY,
            width: IslandCardGearButton.width,
            height: actionRowHeight
        )
        // `Hide` keeps the footer's trailing end but now sits **left of the gear**, one of the card's own
        // column gaps away (`islandRowGlyphGap`), on the same row: the gear is the card's one permanent
        // control, and the alert's way out queues up behind it rather than taking its corner.
        if let actionButton {
            let width = IslandCardButton.width
            actionButton.frame = NSRect(
                x: bounds.width - inset - IslandCardGearButton.width - islandRowGlyphGap - width,
                y: footerY,
                width: width,
                height: actionRowHeight
            )
        }
        // `Send` sits left of `Hide` — the order the footer reads in: the answer, then the way out.
        if let sendButton {
            let width = IslandCardButton.width(for: islandSendButtonLabel)
            let right = actionButton.map { $0.frame.minX }
                ?? (bounds.width - inset - IslandCardGearButton.width)
            sendButton.frame = NSRect(
                x: right - islandRowGlyphGap - width,
                y: footerY,
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
    /// flank, the running slot's **bare count**, the server-CPU readout, the gaps between them and the
    /// same clearance the wings use. This is the floor `islandStandInCapsuleWidth` puts under its
    /// screen share; without it the share's own 160pt floor is narrower than the block, and the last
    /// count would be trimmed at the capsule's edge — a wrong count, silently, on a small external
    /// display.
    ///
    /// The running slot is the one item here that costs a count and no glyph, which is why the block is
    /// 19pt narrower than it was while that slot still carried a glyph. The readout adds its gap and
    /// its provisioned width on top — **258** with the readout, 178 without — and it is counted here
    /// **even when its gate is off**: this is a floor, and the tail air on a cutout-less display costs
    /// nothing, whereas making it move with the gate would need a rebuilt window for no visible gain.
    /// It is now above `islandStandInCapsuleWidth`'s 240 cap, so on a display with no cutout the floor
    /// is what sets the capsule everywhere and the cap never binds.
    static let standInCapsuleMinWidth: CGFloat = {
        let items = 2 + badgeStatuses.count
        let content = IslandRing.diameterCap
            + CGFloat(badgeStatuses.count - 1) * twoDigitBadgeWidth
            + twoDigitCountWidth
            + cpuGap + IslandCPUView.widestWidth
        let gaps = CGFloat(items - 1) * groupGap
        return (content + gaps + 2 * minFlankClearance + flankMargin).rounded(.up)
    }()

    /// Width of **both** flanks of the notched pill. Symmetry sets it: it is the wider of the
    /// two sides' content requirements, and both sides get it. See `islandFlank` for why the
    /// smaller (one-digit) reading of the right flank is not an option — `place` trims an
    /// overrun at the capsule edge silently, and a wrong count is the one thing this pill may
    /// not do. Every extra point sits over the menubar strip either side of the cutout.
    static let flankWidth: CGFloat = max(requiredLeftFlankWidth, requiredRightFlankWidth)

    /// What the **left** flank's content costs at its widest: the ring, the gap, the running slot's
    /// two-digit **count**, then the server-CPU readout and its own gap. No glyph in that sum any
    /// more — the ring is the running mark, so the count is drawn bare (`show(_:count:in:)`). The
    /// flank is wider than this once symmetry is taken into account, and this is the width its
    /// content is centred against (`leftContentInset`).
    ///
    /// 12 + 6 + 18.565 + 8 + 72.150 = **116.714**, and `serviceCPUWidth` is 0 when the readout's gate
    /// is off (36.565, exactly what this was before it existed). The 72.150 is the **readout's
    /// provision**, not one unit's typical string: it is `max` over both `CPUUnit`s (see
    /// `cpuReadoutWidth`), so switching the unit cannot move any of these numbers.
    private static var leftContentWidth: CGFloat {
        IslandRing.diameterCap + groupGap + twoDigitCountWidth + serviceCPUWidth
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
    /// running slot's glyph moved the ring 37 → 47 in one step, and it stayed there while the flank
    /// held nothing but the ring and the count. Every move since is the readout's *existence* or its
    /// ink, never a count: 47 → 27 when it was first provisioned, → 13 when the label grew the
    /// `CPU · ` prefix, → 11 at the 9.5pt provision (`round((130 − 107.301) / 2)`), → **7** when it
    /// grew the decimal — `round((130 − 116.714) / 2)`, the readout's width going 62.737 → 72.150. It
    /// is a fixed offset in every state, which is what this number is for, not the value itself.
    static var leftContentInset: CGFloat {
        ((flankWidth - leftContentWidth) / 2).rounded()
    }

    /// Space between the running count and the CPU readout. **Not `groupGap`**: 6 means "same
    /// group", and the readout is not part of the ring+count pair. It is not a `place` gap either —
    /// `place` uses one gap per region — so the 8 is carried by `cpuReadoutInset` itself (and by
    /// `standInCapsuleMinWidth`, where the block's own gaps are `groupGap`s).
    static let cpuGap: CGFloat = 8

    /// The gate for the readout, read from `UserDefaults` — the same key, and the same default
    /// (**on**), as `AppDelegate` (the menu) and `SessionMonitor` (the sampling). The view needs its
    /// own copy because it sizes the flank the readout sits in, and it has to do that without being
    /// told: `flankWidth` is a launch-geometry constant.
    static var cpuEnabled: Bool {
        (UserDefaults.standard.object(forKey: "ocbar.serviceCPU") as? Bool) ?? true
    }

    /// Width the readout is **provisioned** at: the wider of the two units' widest strings, measured —
    /// **`CPU · 100.0%` (72.150pt)** for `machine`, against **`CPU · 999%` (62.737pt)** for `core`.
    /// The machine string wins by 9.413pt, so the provision is exactly what it was before the unit
    /// became a setting: no inset, no flank and no capsule number moves. The alternative — one
    /// provision per unit, swapped with it — is a display change the pill may not make.
    ///
    /// This is the one number that may not be optimistic — `place` zeroes the gap first, then clamps
    /// the block's leading edge (moving the ring, the left flank's only landmark) and `masksToBounds`
    /// trims the rest, so a provision at a typical reading would draw `CPU · 100.0%` as `CPU · 10`:
    /// the `%` is in the last 12.5pt of the string. Which is also why the core unit draws a whole
    /// number: a decimal on its three digits would measure wider than this and demand a wider flank.
    /// It is a fixed width, not the label's own, so the flank does not move when the value does.
    static var cpuReadoutWidth: CGFloat { IslandCPUView.widestWidth }

    /// What the readout costs the flank when its gate is on: the gap plus the provisioned width.
    /// Zero when off, so `requiredLeftFlankWidth` is 43 and `leftContentInset` 47 again — the pill's
    /// geometry before the readout existed, to the point.
    private static var serviceCPUWidth: CGFloat { cpuEnabled ? cpuGap + cpuReadoutWidth : 0 }

    /// Where the readout starts inside the left flank: `leftContentInset` + the ring + `groupGap` +
    /// the two-digit count + `cpuGap` — 7 + 12 + 6 + 18.565 + 8 = 51.565 → **52**. 0 when the gate
    /// is off (nothing is placed there).
    ///
    /// It is a **second pinned inset**, not a third element in the ring+count block: the readout is
    /// always present while the feature is on, so it is a landmark in its own right, and hitching it
    /// to the count's block would slide it 18.57pt every time a session started or stopped.
    static var cpuReadoutInset: CGFloat {
        guard cpuEnabled else { return 0 }
        return (leftContentInset + IslandRing.diameterCap + groupGap + twoDigitCountWidth + cpuGap).rounded()
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

    /// Least width the left flank needs: the running ring, the gap, that slot's two-digit count and the
    /// CPU readout with its gap, with the clearance on both sides — the same formula as the right
    /// flank's, over what this side holds.
    /// 12 + 6 + 18.565 + 8 + 72.150 = 116.714 of content, so it rounds up to **123** (43 without the
    /// readout) — 9pt more than the 114 the readout cost before it carried its decimal. The 72.150 is
    /// the provision for **both** units (the machine string is the wider), so the unit setting moves
    /// none of these numbers.
    ///
    /// It is still below the right flank's 130, which is what keeps the wings unchanged: the pill's
    /// wings stay the same width (`islandFlank` is the wider of the two, and the right's 130 still
    /// binds), so this number only sets where the content sits inside the wing. It closes on that
    /// ceiling as the left flank gains elements — 123 leaves **7** before it would bind, and that is
    /// the number to watch before adding another one here. What it *must* not do is overrun: `place` trims an overrun at
    /// the capsule edge silently, and a two-digit count that got trimmed would be a wrong fact.
    static let requiredLeftFlankWidth: CGFloat = {
        (leftContentWidth + 2 * minFlankClearance + flankMargin).rounded(.up)
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

    /// The OpenCode server tree's CPU as a share of **one core** (`0…999`, fractional) — the unit the
    /// sampler publishes in, whichever unit is drawn; nil = unknown (its gate is off, or this tick had
    /// no honest reading). Unknown means the element draws nothing *and* costs nothing, which is why it
    /// is a `didSet` of its own rather than a fifth badge: the count's dictionary and the server's CPU
    /// are two different facts about two different things.
    var cpu: Double? {
        didSet {
            guard cpu != oldValue else { return }
            applyCPU()
            needsLayout = true
        }
    }

    /// **Which unit that one-core number is drawn in** (`CPUUnit`). Its own `didSet` rather than
    /// riding on `cpu`'s: a unit pick republishes the *same* `Double`, so the value's equality guard
    /// would swallow it and the pill would keep drawing the old unit's string until the next 2s
    /// sample. Here the change repaints the readout directly. Seeded from the stored pick, so a pill
    /// built by a screen change draws the right unit before the first tick reaches it.
    var cpuUnit: CPUUnit = .stored {
        didSet {
            guard cpuUnit != oldValue else { return }
            applyCPU()
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
    /// The server's CPU, in the left flank past the running count. Always present while its gate is
    /// on — like the ring, and for the same reason: an element that comes and goes drags everything
    /// beside it.
    private let cpuReadout = IslandCPUView(frame: .zero)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(activity)
        cpuReadout.isHidden = true
        addSubview(cpuReadout)
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

    /// Push the server's CPU and the unit it is drawn in into the readout, and nothing else.
    ///
    /// **It must never touch `activity.running`.** The ring answers "is a session running", which is
    /// `counts[.busy] > 0` and only that: a server tree at half a core — `5.0%` of this machine,
    /// `50%` of a core — with every session idle is a busy process, not a session that is working, and
    /// a readout that turned the mark orange would make the pill's one running statement say two things.
    ///
    /// The unit goes in **first** and on every call, because it is what makes the same one-core
    /// `Double` draw a different string: `IslandCPUView.unit`'s setter repaints from the value it
    /// already holds, and the value's own equality guard then has nothing left to do. That is the
    /// whole mechanism by which a unit-only menu pick repaints on its tick.
    private func applyCPU() {
        cpuReadout.unit = cpuUnit
        cpuReadout.value = cpu
        cpuReadout.isHidden = cpu == nil
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
            let leftRegion = NSRect(x: 0, y: 0, width: cutoutStart, height: bounds.height)
            place(leftItems, in: leftRegion,
                  alignment: .pinned(inset: Self.leftContentInset))
            // The readout is its **own** pinned element, not a third item in the block above, and it
            // is placed whether or not there is a reading: its inset is fixed, so a tick with no
            // honest sample (or no count beside it) changes nothing that is drawn. Two pinned insets
            // because the left flank has two always-present elements, and the readout must not
            // inherit the count's reflow — the count comes and goes, this does not.
            place([cpuReadout], in: leftRegion, alignment: .pinned(inset: Self.cpuReadoutInset))
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
            // Last, after the running count, and only while its gate is on: with the gate off the
            // block has to be exactly what it was — a zero-width element would still cost this
            // region one `groupGap`.
            if Self.cpuEnabled { items.append(cpuReadout) }
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

    /// The line box an 11pt count asks for — **14pt**, the height `layout()` centres in the badge, measured
    /// from the font below rather than typed in. `IslandCPUView` reads it because the two flanks are handed
    /// one region rect: from the height alone it can work out where the count's top edge, and therefore its
    /// baseline, falls.
    static let countLineHeight: CGFloat = {
        let label = NSTextField(labelWithString: "0")
        label.font = numberFont
        return label.intrinsicContentSize.height
    }()

    /// Where the count's baseline falls, measured from the top of the box the badge is given: the count
    /// label's top edge (half of what is left of `height` over its line box), then one ascent — a single line
    /// of text is drawn with its baseline exactly one ascent below the top of its frame. **This is what puts
    /// the CPU readout on the count's line**: centring each label in its own box aligns two boxes' middles,
    /// and the boxes are 14pt and 12pt, so no centre can be a shared baseline.
    static func countBaseline(atHeight height: CGFloat) -> CGFloat {
        (height - countLineHeight) / 2 + numberFont.ascender
    }

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
        // The height is `countLineHeight` — the same number `countBaseline(atHeight:)` is derived from — so
        // the baseline the CPU readout aligns to is the one this label is actually drawn on.
        let labelHeight = Self.countLineHeight
        numberLabel.frame = NSRect(
            x: markerOffset,
            y: (bounds.height - labelHeight) / 2,
            width: islandLabelWidth(for: numberLabel),
            height: labelHeight
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

// MARK: - The server's CPU

/// **What the readout's percentage is a percentage *of*.** The sampler publishes **one** number:
/// the tree's share of **one core**, `0…999`. Every value that reaches the pill is in that unit, and
/// this enum is the only place that turns it into ink — `machine` divides by the logical core count
/// and draws one decimal, `core` draws the share itself as a whole number.
///
/// **Why it is a setting.** "50%" means two very different loads depending on the denominator: a
/// fifth of this 10-core machine, or half of one core — and the second is the number somebody
/// watching a single-threaded build thinks in. The question is the user's, so it is a menu pick. What
/// may **not** move with it is the pill: the flank is provisioned for the wider of the two strings
/// (`IslandCPUView.widestWidth`), which is why the formats below differ and why neither may be
/// widened without widening the pill.
enum CPUUnit: String, CaseIterable {

    /// Percentage of the whole machine: every logical core busy reads `100.0`.
    case machine
    /// Percentage of one core: `100` is one core saturated, and a tree can read past it.
    case core

    /// **Default `machine`** — the unit the setting was added with, and the one the pill is already
    /// provisioned at (`CPU · 100.0%` is the widest string either unit draws, so the default costs
    /// nothing in geometry). Stored beside the readout's on/off gate (`ocbar.serviceCPU`), and read by
    /// the pill and the menu from here so the two cannot disagree about the key or the default.
    static let defaultsKey = "ocbar.cpuUnit"

    static var stored: CPUUnit {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let unit = CPUUnit(rawValue: raw) else { return .machine }
        return unit
    }

    /// Menu wording, sentence case like every other pick in the dropdown. The submenu's parent
    /// ("Server CPU") already names the subject, so the items only have to name the denominator.
    var displayName: String {
        switch self {
        case .machine: return "Percent of machine"
        case .core: return "Percent of one core"
        }
    }

    /// The machine denominator, read once from the same process info the sampler's one-core
    /// contract is stated against: one machine point is `cores` one-core points.
    static let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// The published one-core share, in this unit's own scale.
    func scaled(_ oneCorePercent: Double) -> Double {
        switch self {
        case .core: return oneCorePercent
        case .machine: return oneCorePercent / Self.cores
        }
    }

    /// The highest value this unit can draw, and therefore the value the flank is provisioned at.
    /// `core`'s ceiling is the sampler's own clamp (`999`, three digits); `machine`'s `100.0` is the
    /// point where every logical core is busy. Both are the hardware's ceiling, not a four-digit
    /// allowance, so the pill can never draw a percentage the machine cannot produce.
    var cap: Double {
        switch self {
        case .machine: return 100.0
        case .core: return 999
        }
    }

    /// How still the number is held: the shown value only moves when the target is this far from it.
    ///
    /// **Both cases are the same physical statement — 3 one-core points — and both are three display
    /// steps**, because `shown` is held at the unit's own precision (`roundedToStep`). Neither number
    /// is arbitrary: the rule is unchanged from the readout's first version, when the text moved in
    /// whole one-core percent and the constant *was* `3`. One machine point on this 10-core box is 10
    /// one-core points, so `0.3` machine percent is those same 3. Both failures it exists to prevent
    /// are next door: `30` one-core points (or `3.0` machine percent) would freeze the readout — an
    /// idle server would never move it — and `1`/`0.1` would accept every tick's drift and rewrite
    /// the digit each time, which reads as a glitch rather than a measurement.
    var deadband: Double {
        switch self {
        case .machine: return 0.3
        case .core: return 3
        }
    }

    /// Where the readout stops being quiet — **half a core, whichever unit is drawn**: `50` one-core
    /// percent, `50 / cores` machine percent (**5.0** here, 6.25 on an 8-core Mac). That is exactly
    /// what the one-core `50` said, so the ink starts where it always did: "this tree is using more
    /// than half of one core". A fixed machine percent that "reads as busy" (say 10) was rejected
    /// because it is not the same statement on two machines — a tenth of a core on an 8-core box, a
    /// quarter of one here — and this readout exists to be comparable at a glance. The price is that
    /// the machine case is machine-dependent *by rule*: it reads the same `cores` the machine unit
    /// divides by.
    var attentionThreshold: Double {
        switch self {
        case .machine: return 50 / Self.cores
        case .core: return 50
        }
    }

    /// The value the label will actually draw: rounded to the unit's own step — a whole number for
    /// `core`, a tenth for `machine`. The readout holds this rather than the fraction, so its
    /// deadband counts *display steps* (three in either unit) and its tint is decided from the same
    /// number the text shows, instead of from a fraction the text has already rounded away.
    func roundedToStep(_ value: Double) -> Double {
        switch self {
        case .machine: return (value * 10).rounded() / 10
        case .core: return value.rounded()
        }
    }

    /// The string for one published value, in this unit's format.
    ///
    /// **Why the formats differ.** `machine` draws one decimal because 100 points of scale is coarse:
    /// a mostly-idle server has to stay a visible `0.3%`/`0.5%` rather than a `0` or a `1` that reads
    /// as a rounding error. `core` draws a whole number because its scale already runs to three
    /// digits (`999`), so resolution is not the problem — and a decimal on those three digits
    /// (`999.0%`) would be wider than the machine's widest string and would therefore widen the
    /// flank's shared provision, a display change this pill may not make. The provision is the wider
    /// of the two (`CPU · 100.0%`), and neither format may grow into a string that would be trimmed.
    func text(forScaled value: Double) -> String {
        switch self {
        case .machine: return String(format: "CPU · %.1f%%", value)
        case .core: return String(format: "CPU · %.0f%%", value)
        }
    }

    /// The same string from the raw, one-core value the pill is handed.
    func string(_ oneCorePercent: Double?) -> String {
        guard let oneCorePercent else { return "" }
        return text(forScaled: min(scaled(oneCorePercent), cap))
    }
}

/// The OpenCode **server tree's** CPU — the server process and the descendants it spawns — in the
/// collapsed pill's left flank, labelled: **`CPU · 1.6%`** (a share of the whole machine, one
/// decimal) or **`CPU · 16%`** (a share of one core, a whole number), depending on the `CPUUnit` the
/// user picked. One published number in, one of those two strings out — see `CPUUnit` for why the
/// formats differ and why the provision is the wider of them.
///
/// **The number this view holds is always one-core percent.** `ServiceCPUSampler` publishes the
/// tree's raw share of a single core, `0…999`, already smoothed and clamped; `value` is exactly
/// that, in every unit. Where the number comes from is `session-monitoring.md`'s business.
///
/// **The prefix ships.** The flank also carries the running count, and an unlabelled `1.6%` beside
/// it asked the reader to guess which number was the sessions and which the process; the earlier
/// version left `CPU` out on the grounds that it is 24.6pt of ink to label a 29.0pt value, and the
/// maintainer rejected that trade — a readout nobody can name is not a readout. So the label is
/// spent, `CPU` is capitals, and the separator is `·`
/// (U+00B7 middle dot) rather than a dash: one space either side, and nothing that could read as a
/// minus sign against a percentage.
///
/// It stays **one run, one tint** — no dimmer prefix. Two tones in a 9.5pt string that never exceeds
/// 72.1pt would cost a second attributed run and buy a contrast the eye cannot resolve at this
/// size; the prefix is part of the reading, not a caption for it.
///
/// The `%` is still not optional, and for the same reason it always was: the pill already carries
/// bare counts to the left of this, so a trailing `1.6` (or `16`) with no sign would be a third
/// count. The `%` is what says the number is a measurement.
///
/// No glyph, and never a tint from the pill's status colours: one mark per flank is the ring, and
/// colour on this flank belongs to statuses.
///
/// **It never drives the ring.** High CPU is not a running session — see
/// `CollapsedContentView.applyCPU()`.
///
/// The number is the whole process tree, so CPU spent in the server's own tool subprocesses
/// (`bash`, `git`, a test run) **is** counted here — a session in the middle of a build shows the
/// build. A child that daemonizes out of the tree stops contributing.
private final class IslandCPUView: NSView, IslandFlankElement {

    /// 9.5pt, medium, tabular: smaller than the 11pt counts because it is a detail *about* them rather
    /// than a peer, and monospaced digits so it cannot jitter as the value changes.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

    /// **The widest string either unit can draw**, measured: `CPU · 100.0%` — 72.150pt at 9.5pt
    /// medium — against the core unit's `CPU · 999%` at 62.737pt. The machine string wins, so the
    /// readout's provision *and therefore the whole pill* are exactly what they were before the
    /// setting existed; a unit that needed more than this would be a display change and is not
    /// allowed (see `CPUUnit.text(forScaled:)` for why the core unit has no decimal).
    ///
    /// Measured through `islandLabelWidth`, so the digits cannot be shaved and the geometry cannot
    /// drift from what is drawn. The prefix is in here because it is drawn: it is part of the string,
    /// not a label the layout may clip out of the provision. The provision lives in
    /// `CollapsedContentView.cpuReadoutWidth`; this constant is the measurement it is made of.
    static let widestWidth: CGFloat = {
        CPUUnit.allCases.map { unit -> CGFloat in
            let label = NSTextField(labelWithString: unit.text(forScaled: unit.cap))
            label.font = font
            return islandLabelWidth(for: label)
        }.max() ?? 0
    }()

    /// The **one-core** share the caller published (`0…999`, fractional); nil = unknown. The unit is
    /// not part of the value — it is `unit` below, and only the drawing changes when it does.
    var value: Double? {
        didSet {
            guard value != oldValue else { return }
            updateShown()
        }
    }

    /// Which unit the readout draws, and a change here **repaints on its own**. The caller pushes the
    /// same one-core `Double` when only the unit moved, so `value`'s equality guard would swallow it
    /// and the old unit's string would stay up until the next 2s sample; `repaintInNewUnit` is what
    /// makes the menu pick land on this tick. Seeded from the stored pick so a view built by a screen
    /// change already draws the right unit.
    var unit: CPUUnit = .stored {
        didSet {
            guard unit != oldValue else { return }
            repaintInNewUnit()
        }
    }

    /// The value actually drawn — **in `unit`'s scale and at its precision** (a whole one-core percent,
    /// or machine percent to a tenth), held that way so the deadband counts display steps and the tint
    /// is decided from the number the text shows, so the text and its tint can never be about different
    /// numbers.
    private var shown: Double? {
        didSet {
            guard shown != oldValue else { return }
            applyShown()
        }
    }

    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Self.font
        label.textColor = NSColor.white.withAlphaComponent(0.50)
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The label's ink width, and **0 while unknown** — nothing is drawn then, so the element must not
    /// cost the flank anything either. Never the provisioned width: this is the element answering for
    /// what it draws, and the *provision* lives in `CollapsedContentView.cpuReadoutWidth`.
    func flankWidth(atHeight height: CGFloat) -> CGFloat {
        shown == nil ? 0 : islandLabelWidth(for: label)
    }

    /// **The readout sits on the count's baseline, not in a box of its own.** Both flanks are handed the same
    /// region rect (`CollapsedContentView.place`), so the count's baseline is
    /// `IslandMarkerGroup.countBaseline(atHeight:)` — the 14pt count line box centred in that height plus the
    /// 11pt ascent — and this label's frame is dropped by its own 9.5pt ascent to meet it. Font metrics plus
    /// the height it was given, and nothing about the string: a hidden readout draws nothing and moves nothing.
    ///
    /// This replaced a `labelRaise` of 0.1875pt — an eye-anchor measured at 9pt and scaled (0.25 × 0.75) to
    /// 9.5pt. It was correcting for two boxes centred independently: their middles can line up, their baselines
    /// cannot, and it left the readout **0.64pt** high. There is no residual nudge now, and none is wanted:
    /// the correction is the derivation.
    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(
            x: 0,
            y: IslandMarkerGroup.countBaseline(atHeight: bounds.height) - Self.font.ascender,
            width: islandLabelWidth(for: label),
            height: size.height
        )
    }

    private func updateShown() {
        guard let target = value else {
            shown = nil
            return
        }
        // The cap, the step and the deadband all belong to the unit that is being drawn, because
        // `shown` is held in that unit's scale and at that unit's precision: a pid reuse or a bogus
        // delta must not draw a string wider than the flank is provisioned for, and a comparison
        // across two units would hold the wrong amount still.
        let capped = unit.roundedToStep(min(unit.scaled(target), unit.cap))
        if let current = shown, abs(capped - current) < unit.deadband { return }
        shown = capped
    }

    /// Re-draw what is already held, in a different unit. The held number is in the *old* unit's
    /// scale, so it is not a placeholder for the new one: drop it (which clears the string, so no
    /// frame can show the previous unit) and apply the target again from scratch — deadband included,
    /// because the first frame in a new unit is not a step in the old one.
    private func repaintInNewUnit() {
        shown = nil
        updateShown()
    }

    private func applyShown() {
        // **The decimal separator is always `.`.** `String(format:)` takes no locale, so a machine
        // whose language uses a decimal comma still draws `1.6%` — the dot is part of the string, not
        // a formatting preference, and a `,` beside a `·` separator would be two marks doing the same
        // job. Tabular digits are what keep the width from moving as the value changes. The format
        // itself (`1.6` vs `16`) is `CPUUnit`'s, per unit.
        label.stringValue = shown.map { unit.text(forScaled: $0) } ?? ""
        label.isHidden = shown == nil
        // **Attention is ink, not colour.** The pill's colours belong to statuses (and the ring), so
        // anything but plain white here would be a third vocabulary: the readout is white at its
        // normal weight (α0.92) once it is drawing `CPUUnit.attentionThreshold` or more — half a core
        // in whichever unit is drawn (`5.0` machine percent here, `50` one-core percent) — and the
        // quiet α0.50 below it. `shown` is in the same unit as that threshold, so the ink and the
        // number cannot be about different amounts of work.
        label.textColor = NSColor.white.withAlphaComponent((shown ?? 0) >= unit.attentionThreshold ? 0.92 : 0.50)
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
    /// How many subagents this session is running, in line 1's right slot
    /// immediately **left of the age** — the treatment picked off a rendered
    /// sheet (`candidate-f-orange-slot`), and the row's only number that is not a
    /// time.
    ///
    /// **Digits only, in the mark's own orange** — no glyph, no `×`, no circle.
    /// The colour is what makes the number legible as *this* fact: the slot it
    /// joins already carries two white times (`5h36m · 2m`), so a third white
    /// number would read as a third time, while an orange one reads as the ring
    /// it shares its tint with (`IslandRing.runningTint`). It is the pill's own
    /// idiom — a bare count beside the ring — moved into the row's right slot.
    ///
    /// **The slot is a constant 26.56pt (`tallySlotWidth`), and it is taken only
    /// when there is a tally.** Reserving it on every row would move *today's*
    /// folder name for every session with no subagents — the common case, which
    /// must stay pixel-identical — so the slot exists only where the number does.
    /// What that costs is one change on one row, the moment a session's workers
    /// start or stop: the folder name's box grows or shrinks by 26.56pt and may
    /// gain or lose its ellipsis. Nothing else moves: the age and the stamp are
    /// anchored to the row's trailing inset, so `5h36m · 2m` sits exactly where it
    /// always did with the tally inserted to its left, and a tally going 1 → 9 →
    /// `9+` reflows nothing at all (tabular figures; the slot is measured to the
    /// widest string).
    private let tallyLabel = NSTextField(labelWithString: "")
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
    /// Band of the context line currently shown, so `layout` can lift a band glyph
    /// (`islandBandGlyphRise`) without re-reading the presentation.
    private var contextBand: ContextBand?
    private var hasStamp = false
    /// Whether line 1 is carrying a tally this time round. `configure` sets it for every row,
    /// recycled or not, and `layout` is the only reader — so a row that loses its tally also loses
    /// the 26.56pt slot and its folder name gets that width back in the same pass.
    private var hasTally = false
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

    // The tally's type and its two widths, all measured off the row's own fonts rather than assumed.
    /// The card's subordinate size at the weight every count in this app is drawn at
    /// (`IslandMarkerGroup.numberFont` is the same construction at 11), so the pill's
    /// counts and a row's tally are one kind of number.
    private static let tallyFont = NSFont.monospacedDigitSystemFont(
        ofSize: islandCardSecondaryFontSize,
        weight: .semibold
    )

    /// Width of the widest tally, `9+`, as the cell needs to draw it: `islandLabelWidth`
    /// gives **18.56pt**, where the bare advances add up to 13.2. A frame at the advance
    /// shaves the `+` — the same clipping the age's `m` lost before `islandLabelWidth`
    /// existed, so this is measured, not added up.
    private static let tallyTextWidth: CGFloat = {
        let reference = NSTextField(labelWithString: "\(tallyCeiling)+")
        reference.font = tallyFont
        return islandLabelWidth(for: reference)
    }()

    /// What the tally takes out of line 1: its own text plus the card's one column gap.
    /// **26.56pt** — the folder name's box gives up exactly this while a tally shows
    /// (373.78 → 347.22 on a 500pt card carrying `5h36m · 2m`), and gives up nothing when
    /// it does not (see `tallyLabel` for why the slot is not reserved).
    private static let tallySlotWidth = tallyTextWidth + islandRowGlyphGap

    /// The largest tally drawn as digits — ten and above read `9+`, which is the widest
    /// string and the reason the slot is measured to it. Nine itself stays exact; the cap
    /// only ever hides the difference between ten and more, and the exact count is the
    /// row's tooltip (`islandSubagentTally`).
    private static let tallyCeiling = 9

    /// A tally's text: the number up to nine, `9+` above it, and never a nought — zero is
    /// not drawn at all (`hasTally`), so it is clamped here rather than trusted.
    private static func tallyText(_ count: Int) -> String {
        count > tallyCeiling ? "\(tallyCeiling)+" : String(max(0, count))
    }

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

        // The tally borrows the card's subordinate size at the weight every count in this app is drawn
        // at (`IslandMarkerGroup.numberFont` is 11pt semibold tabular), and the mark's own orange: the
        // number is the running state's, so it may not be a colour of its own. Right-aligned inside a
        // fixed-width field, so `3` sits where `9+` would end and the age never has to move for either.
        tallyLabel.font = Self.tallyFont
        tallyLabel.textColor = IslandRing.runningTint
        tallyLabel.alignment = .right

        // One field per line is the row's contract, so no field is ever allowed
        // to wrap onto the next line: each truncates at its tail instead. This is
        // belt-and-braces — `layout()` already gives every field a single-line
        // frame — but it makes the contract hold even if a frame were mis-sized.
        for label in [nameLabel, titleLabel, durationLabel, contextLabel, stampLabel, tallyLabel] {
            label.usesSingleLineMode = true
        }

        addSubview(glyph)
        addSubview(nameLabel)
        addSubview(titleLabel)
        addSubview(durationLabel)
        addSubview(contextGlyph)
        addSubview(contextLabel)
        addSubview(stampLabel)
        addSubview(tallyLabel)
        addSubview(alertMark)
        addSubview(ring)
        titleLabel.isHidden = true
        contextGlyph.isHidden = true
        contextLabel.isHidden = true
        stampLabel.isHidden = true
        tallyLabel.isHidden = true
        alertMark.isHidden = true
        // Set once here and never again: the mark is not sized by a pill, it is sized to the disc the
        // row draws beside it (see `ringDiameter`).
        ring.markDiameter = Self.ringDiameter
        ring.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(name: String, title: String?, status: SessionStatus, duration: String, pid: Int32?, context: IslandContext?, stamp: String, subagents: Int) {
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
        // The tally exists only where the mark does, and that is a colour decision rather than a
        // convenience: the number is drawn in `IslandRing.runningTint`, so on a row whose glyph column
        // carries a green check, a blue question mark or a red triangle it would claim "running" in the
        // running colour for a session that is not running. The card has one mark per row and the monitor
        // ranks those states above busy (`SessionMonitor.poll`), so a row that trades its ring for a
        // question mark trades the tally with it. Both are forced off here, from the same `isRunning` the
        // ring is hidden on, so a recycled view can never keep the session it used to show: no stale
        // number, no stale tooltip, and `hasTally` false means `layout` puts the 26.56pt slot back into
        // the name.
        hasTally = isRunning && subagents > 0
        tallyLabel.isHidden = !hasTally
        tallyLabel.stringValue = hasTally ? Self.tallyText(subagents) : ""
        // `9+` is the one thing the slot cannot say, so the exact count rides the tooltip — the row's
        // only surface with room for it that costs the folder name no width.
        toolTip = hasTally ? islandSubagentTally(subagents) : nil

        hasContext = context != nil
        contextBand = context?.band
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
        // The tally, immediately left of the age and inside the same right slot, so the two times keep
        // their trailing anchor and stay one reading (`5h36m · 2m`) whether or not a tally precedes them.
        // Its field is the width of the widest tally and its text is right-aligned in it, so `3` ends
        // where `9+` would — nothing here is measured from the current number, which is what makes the
        // age's x a constant for every tally.
        if hasTally {
            let tallySize = tallyLabel.intrinsicContentSize
            tallyLabel.frame = NSRect(
                x: durationLabel.frame.minX - Self.tallySlotWidth,
                y: nameCenterY - tallySize.height / 2,
                width: Self.tallyTextWidth,
                height: tallySize.height
            )
        }
        // The folder name ends where line 1's right slot begins: at the tally when there is one, at the
        // age when there is not — which is the pre-tally geometry exactly, so a row without a tally is
        // pixel-identical to the row this feature found.
        let slotLeft = hasTally ? tallyLabel.frame.minX : durationLabel.frame.minX
        let nameWidth = max(0, slotLeft - islandRowGlyphGap - islandRowTextInset)
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
                let glyphRise = contextBand?.inBand == true ? islandBandGlyphRise : 0
                contextGlyph.frame = NSRect(x: islandRowLeadingInset, y: centreYValue - islandRowGlyphSize / 2 - glyphRise,
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

// MARK: - Footer

/// The alert's way out: the card's `Hide` button — a shape that exists in order to be clicked.
///
/// **Every number is this card's** (see the constants above for the full accounting, including what the
/// resting ground cost). In short: a quiet way out, in the footer, left of the gear, hiding without acting —
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
/// `summaryRowHeight`, so the footer cannot be one height for the budget and another on screen.
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
    /// No height here: the card lays the button out at the footer's `summaryRowHeight`.
    static func width(for label: String) -> CGFloat {
        let reference = NSTextField(labelWithString: label)
        reference.font = font
        return islandLabelWidth(for: reference) + 2 * islandActionButtonHorizontalPadding
    }

    static let width: CGFloat = width(for: islandActionButtonLabel)

    /// Whether the button can be pressed. A disabled button drops to the card's inert tone and swallows
    /// the click — the label is still there, because a control that vanishes when it cannot be used
    /// leaves the footer reflowing under the pointer.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            applyTone(animated: false)
            toolTip = isEnabled ? tooltipEnabled : tooltipDisabled
        }
    }

    private let fill = NSView()
    private let label: NSTextField
    private let tooltipEnabled: String?
    private let tooltipDisabled: String?
    private var tracking: NSTrackingArea?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            applyTone(animated: true)
        }
    }

    init(text: String = islandActionButtonLabel,
         tooltip: String? = islandActionButtonTooltip,
         disabledTooltip: String? = nil) {
        label = NSTextField(labelWithString: text)
        tooltipEnabled = tooltip
        tooltipDisabled = disabledTooltip
        super.init(frame: .zero)
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

        toolTip = tooltip
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
    /// no focus ring. A disabled button keeps both tones where they are.
    private func applyTone(animated: Bool) {
        let ground = (hovering && isEnabled) ? islandHoverWashAlpha : islandActionButtonRestingFillAlpha
        let ink: CGFloat = isEnabled
            ? (hovering ? islandActionButtonHoverForegroundAlpha : islandActionButtonForegroundAlpha)
            : islandCardDisabledAlpha
        guard animated else {
            fill.alphaValue = ground
            label.alphaValue = ink
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = islandActionButtonHoverDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            fill.animator().alphaValue = ground
            label.animator().alphaValue = ink
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
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    // The panel is a non-key, non-activating window, so without this the first click is delivered
    // nowhere and the button is silently dead while its hover still works.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card's settings gear: the footer's trailing control, and the way into the dropdown menu while the
/// menubar item is hidden. It is the one thing on **every** card, empty, hovered or alerting — which is why
/// it is asked for by `IslandCardView` itself and only *wired* by the panel.
///
/// **A glyph instead of a word, and nothing else about it is new.** Its ground, its wash, its two alphas and
/// its hover duration are `IslandCardButton`'s constants (see the block at the top of the file): a second
/// quiet control with a tone ladder of its own would give the card two kinds of quiet. It is the footer's
/// peer, not its louder sibling, and `Hide` stands beside it on the same row sharing the same treatment.
///
/// **No pointing hand.** The card's rows are the only things here that lead somewhere (`resetCursorRects` on
/// `IslandRowView`); a control in this card's footer says so with its ground, exactly as `Hide` does. The
/// bubble's ✕ is the other surface's idiom and stays there.
///
/// **It keeps working while an alert is armed.** `IslandCardView.hitTest` claims it before the card's own
/// blank area, whose toggle deliberately refuses the fold then: `Hide` is that alert's answer, and settings
/// are not an answer to anything.
private final class IslandCardGearButton: NSView {

    /// Clicked. Answered by the app delegate (`IslandPanel.onSettingsRequested` → `IslandHost` →
    /// `showMenuFromIsland`), which owns the one menu; nothing is folded here, because the menu opening does
    /// that itself.
    var onActivate: (@MainActor () -> Void)?

    /// The glyph, already white: its tone is carried by the image view's alpha, exactly as `Hide`'s tone is
    /// its label's — so the hover is one animatable number and the artwork never changes.
    private static let glyphImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: islandSettingsGlyphPointSize, weight: islandSettingsGlyphWeight)
        guard let base = NSImage(systemSymbolName: islandSettingsSymbolName, accessibilityDescription: nil) else { return nil }
        return islandTinted(base.withSymbolConfiguration(config) ?? base, color: .white)
    }()

    /// The gear's width: the **measured** glyph box plus the card's own 8pt either side — the same derivation
    /// `IslandCardButton.width` uses for its label, and for the same reason (a frame at a bare advance clips
    /// the glyph). Measured, not assumed: `gearshape.fill` at 12pt is a 15pt box, so the hit target is 31 × 24
    /// — comfortably larger than the 24pt row it stands in, while its ink stays at a session row's disc size.
    ///
    /// The fallback is a row glyph's box rather than zero: a missing symbol must not leave the footer's only
    /// permanent control a narrow hole with nothing in it.
    static let width: CGFloat = {
        (glyphImage?.size.width ?? islandRowGlyphSize) + 2 * islandActionButtonHorizontalPadding
    }()

    private let fill = NSView()
    private let glyph = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            applyHover()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The ground is `Hide`'s, layer for layer: plain white with its **alpha as the tone**, at the wash's own
        // geometry, so the two footer controls cannot be the same treatment only by eye.
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.white.cgColor
        fill.layer?.cornerRadius = islandHoverWashRadius
        fill.alphaValue = islandActionButtonRestingFillAlpha
        addSubview(fill)

        glyph.image = Self.glyphImage
        glyph.imageScaling = .scaleNone
        glyph.alphaValue = islandActionButtonForegroundAlpha
        addSubview(glyph)

        setAccessibilityLabel(islandSettingsAccessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        fill.frame = bounds.insetBy(dx: islandHoverWashDX, dy: islandHoverWashDY)
        // The glyph's own box, centred. No nudge: `gearshape.fill` is symmetric inside its box, so unlike the
        // pill's ring there is nothing for the eye to correct here.
        let size = Self.glyphImage?.size ?? .zero
        glyph.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// `Hide`'s transition exactly: two alphas, the file's own curve, nothing else — no scale, no pressed state,
    /// no focus ring.
    private func applyHover() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = islandActionButtonHoverDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            fill.animator().alphaValue = hovering ? islandHoverWashAlpha : islandActionButtonRestingFillAlpha
            glyph.animator().alphaValue = hovering ? islandActionButtonHoverForegroundAlpha : islandActionButtonForegroundAlpha
        }
    }

    /// Hover by tracking area, like the card's rows and `Hide` beside it. The panel's *poll* is only for the
    /// island's outer rect, where a tracking area fights the window's frame animation.
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

    /// Swallow the press — the card's blank area toggles the island, and a press that started here must never
    /// reach it — and act on release *inside*, so dragging off the gear cancels it, exactly as `Hide` does.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onActivate?()
    }

    // The panel is a non-key, non-activating window: without this the first click is delivered nowhere and the
    // gear is silently dead while its hover still works.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Empty state

/// The card's one line when there is **nothing to list**: `No OpenCode sessions`, the words the dropdown uses
/// for the same situation.
///
/// It is styled as a row's line 1 at the dim end of the card's ladder — the folder name's own font, size and
/// column (12.5 medium, `islandRowTextInset`) at white α0.5, the tone of the context line and the `+k more`
/// footnote — because the one thing it must not read as is a row: full white is a session's name, and α0.5 is
/// how this card says *absent*. Nothing is dimmed further and nothing is added: an empty state that whispers
/// is a bug report, and one that dresses up is a fake row.
///
/// **Inert, like the summary.** It is never in `IslandCardView.rowViews` and `hitTest` never names it, so a click
/// on it falls through to the card's toggle; it has no `onSelect`, no mark, no hover and no pointing hand.
private final class IslandEmptyStateView: NSView {

    private let label = NSTextField(labelWithString: islandEmptyStateText)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: islandCardBaseFontSize, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.5)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        // A row's line 1: its text column, its trailing inset, its line centred the way a one-line row centres
        // its folder name.
        let size = label.intrinsicContentSize
        label.frame = NSRect(
            x: islandRowTextInset,
            y: (bounds.height - size.height) / 2,
            width: max(0, bounds.width - islandRowTextInset - islandRowTrailingInset),
            height: size.height
        )
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

// MARK: - Question block

/// The question block's own geometry. It sits under the waiting session's row, in that row's text
/// column, and is the only content on the card that is neither a row nor chrome.
///
/// `topGap` is the block's air above itself and is **part of its height**, not the card's `rowGap`:
/// the block is not a row, and `rowGap` exists to separate rows.
private let islandQuestionTopGap: CGFloat = 8
private let islandQuestionNavHeight: CGFloat = 20
private let islandQuestionGap: CGFloat = 4

/// Height of one line of `font` as the cell lays it out, rounded up — the height a wrapped label's frame
/// has to hold for its last line to be drawn rather than clipped.
private func islandLineHeight(_ font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
}

/// Height one line of `font` takes in a label **cell**. The base tier's cell adds nothing to the font's
/// own line box; the 11pt tier's adds a point (measured), so a frame measured from font metrics alone
/// would clip a two-line detail's last line.
private func islandLabelLineHeight(_ font: NSFont) -> CGFloat {
    let cell = NSTextFieldCell(textCell: "Ag")
    cell.font = font
    return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 1000, height: 100)).height)
}

/// Height `text` wraps to at `width`, capped at `maxLines` — the block's one way of turning prose into a
/// frame height. The cap is what stops a long question or option detail from growing the card past the
/// lines it actually draws, and the same helper measures the header, the options and their rows.
private func islandWrappedHeight(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    let measured = (text as NSString).boundingRect(
        with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font]
    ).height
    let lines = min(maxLines, max(1, Int((measured / islandLineHeight(font)).rounded())))
    return islandLabelLineHeight(font) * CGFloat(lines)
}

/// The block's three type tiers, as font objects: the question/option label at the card's base size,
/// and the option detail and queue counter at its subordinate one. `height(for:)` measures
/// with these same fonts, so a line counted and a line drawn cannot come from two different faces.
private let islandQuestionTitleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
/// Option labels keep the card's base size: the question is the block's heading, and the rows under it
/// are answers — the same size for both would leave the card with no head.
private let islandQuestionOptionLabelFont = NSFont.systemFont(ofSize: islandCardBaseFontSize, weight: .regular)
private let islandQuestionSecondaryFont = NSFont.systemFont(ofSize: islandCardSecondaryFontSize, weight: .regular)
private let islandQuestionQueueFont = NSFont.monospacedDigitSystemFont(ofSize: islandCardSecondaryFontSize, weight: .regular)
private let islandQuestionTitleLineHeight = islandLabelLineHeight(islandQuestionTitleFont)
private let islandQuestionOptionLabelLineHeight = islandLabelLineHeight(islandQuestionOptionLabelFont)
private let islandQuestionSecondaryLineHeight = islandLabelLineHeight(islandQuestionSecondaryFont)

/// Padding above and below an option row's text. With no separator between rows this is the whole gap
/// between one option's text and the next, and it is a few points more than the 6pt it shipped with so
/// a row does not read as cramped at 640pt.
private let islandQuestionOptionVerticalPadding: CGFloat = 8
/// Air between an option's label and its description. The two are one answer, and without it the
/// description reads as a second label of the same weight.
private let islandQuestionOptionLabelGap: CGFloat = 3
/// Air between an option row's text and the row's own edges, on both sides. The checkmark keeps its own
/// trailing column; this is what stops the label butting the edge under the row's hover wash.
private let islandQuestionOptionTextInset: CGFloat = 6
/// Most the options may take before they scroll. The card's list budget owns how tall the card may get
/// and pays the block's whole height (`IslandListBudget.extraContentHeight`); this is the block's own
/// cap inside that, and the budget's clamp (`IslandPanel.questionBlockRoom`) may take it lower still.
/// **Four two-line options** — an ordinary question's three plus its `Other…` — work out as
/// 4 × (2 × 8 padding + 15 label + 2 × 14 detail) = 236, so an ordinary form shows every option and
/// nothing is half-clipped before the scrollbar takes over.
private let islandQuestionOptionsMaxHeight: CGFloat =
    4 * (islandQuestionOptionVerticalPadding * 2 + islandQuestionOptionLabelLineHeight + 2 * islandQuestionSecondaryLineHeight)
private let islandQuestionEmptyLineHeight: CGFloat = 15
/// Height of the free-text answer field: one **label-only** option row, so `Other…` swapping the rows
/// for the field never moves the card by a hair.
private let islandQuestionTextHeight: CGFloat =
    islandQuestionOptionVerticalPadding * 2 + islandQuestionOptionLabelLineHeight
private let islandQuestionStepButtonSize: CGFloat = 20
/// Shown inside the card's one editable field before anything is typed. Without it the block would
/// open a caret on black with nothing saying what it is for.
private let islandQuestionTextPlaceholder = "Type an answer…"

/// The pending question, drawn under the waiting session's row: the question itself wrapped to three
/// lines, the field stepper (`‹ 1 / 2 ›`) and the field's answer rows —
/// or, for a form the card cannot answer, one dim line saying so.
///
/// **Every control lives in this one view**, which is why the card's `hitTest` descends into it
/// instead of claiming it whole: the option rows, the chevrons and the free-text field are the things
/// that get clicked, and the parts of the block between them must swallow the click rather than fall
/// through to the card's open/close toggle.
///
/// The block is **content, not a row**: it has no status glyph, no age and no click-to-focus, and its
/// selected answers live outside it (the host's `IslandQuestionState`), so a render tick repaints the
/// block without owning anything the user has picked.
private final class IslandQuestionView: NSView, NSTextFieldDelegate {

    /// Everything the block draws, as one value: it is what `configure` compares, so a tick that
    /// changes nothing touches no view.
    struct Content: Equatable {
        let formID: String
        /// The question itself — the field's full text — drawn as the block's one heading line and
        /// wrapped to three lines.
        let body: String
        let fieldIndex: Int
        let fieldCount: Int
        /// This form's position among all pending forms (`1 of 3`), oldest first.
        let queueIndex: Int
        let queueCount: Int
        let field: QuestionField?
        /// Whether every field can be drawn and answered here. False draws the one dim line.
        let answerable: Bool
        /// Whether the chevrons do anything. False draws them inert — the card still shows which
        /// field it is on and how many there are.
        let steppable: Bool
        /// Whether the stepper's row is drawn at all. A one-field form cannot be stepped, so the row
        /// leaves both the drawing and the block's height rather than sitting there inert.
        var showsStepper: Bool { fieldCount > 1 }
        /// The form's answers so far, by field key. Selection is drawn from these, so the block
        /// owns no state of its own and two screens cannot show two answers.
        let answers: [String: QuestionAnswer]
        /// Whether the block draws the field's text field instead of its answer rows.
        let textEntry: Bool
        /// What that text field holds: the typed answer of a text field, or a list field's
        /// unconfirmed draft.
        let text: String

        /// The rows the block draws: the field's options, less `Other…` while its text field is open.
        /// The typed row takes `Other…`'s place, so the list cannot offer to open what is already open,
        /// and every other option stays on screen for the user to see and pick.
        var answerRows: [QuestionOption] {
            let rows = field?.options ?? []
            return textEntry ? rows.filter { !$0.isOther } : rows
        }
    }

    /// The form's height for the state it is in, at the text column `width` it will be laid out in.
    /// The panel reads this for the card's own height (`IslandCardView.contentHeight`) and the block's
    /// `layout()` steps by these same helpers, so the frame and the drawing cannot disagree.
    ///
    /// `maxHeight` is the room the card's budget leaves the block (`IslandPanel.questionBlockRoom`).
    /// It clamps the answer area, which then scrolls inside what is left, so a long question on a short
    /// screen degrades to a scrolling list instead of pushing the card's footer off the bottom.
    static func height(for content: Content, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let textWidth = headerTextWidth(content, width: width)
        let header = islandWrappedHeight(content.body, font: islandQuestionTitleFont, width: textWidth, maxLines: 3)
        guard content.answerable, content.field != nil else {
            return islandQuestionTopGap + header
                + islandQuestionGap + islandQuestionEmptyLineHeight
        }
        // The stepper's row and its gap are chrome only while there is more than one field to step to.
        let chrome = islandQuestionTopGap + header + islandQuestionGap
            + (content.showsStepper ? islandQuestionNavHeight + islandQuestionGap : 0)
        // Text mode adds a row under the options rather than replacing them: the user still sees what
        // else the field offers, and picking one is the way back out of typing.
        let rows = content.answerRows
        let textRow = content.textEntry ? islandQuestionGap + islandQuestionTextHeight : 0
        let optionsBlock = rows.isEmpty ? 0
            : min(optionsHeight(rows, width: width),
                  islandQuestionOptionsMaxHeight,
                  max(0, maxHeight - chrome - textRow))
        return chrome + optionsBlock + textRow
    }

    /// Width the header's one line may use: the block's own width, less the `2 of 3` counter when the
    /// queue has one. The counter sits at the line's trailing end, so the text stops before it — the
    /// same reservation `layout()` makes.
    private static func headerTextWidth(_ content: Content, width: CGFloat) -> CGFloat {
        guard content.queueCount > 1 else { return width }
        return max(0, width - queueWidth(content) - islandRowGlyphGap)
    }

    /// Width the `2 of 3` counter needs, from the label's own cell — the same `islandLabelWidth` the
    /// layout uses, so reserving the space and drawing in it cannot cut a glyph.
    private static func queueWidth(_ content: Content) -> CGFloat {
        guard content.queueCount > 1 else { return 0 }
        let label = NSTextField(labelWithString: "\(content.queueIndex) of \(content.queueCount)")
        label.font = islandQuestionQueueFont
        return islandLabelWidth(for: label)
    }

    private static func optionsHeight(_ options: [QuestionOption], width: CGFloat) -> CGFloat {
        options.reduce(0) { $0 + optionHeight($1, width: width) }
    }

    /// The block's current height, for the card's layout and `contentHeight`. Both read this one
    /// property, so the frame the panel animates to and the layout it draws are the same height.
    var height: CGFloat { content.map { Self.height(for: $0, width: width, maxHeight: maxHeight) } ?? 0 }

    /// The block's three interactions. The panel answers each with a state change; the block itself
    /// holds nothing the user picked.
    var onOption: (@MainActor (QuestionOption) -> Void)?
    var onText: (@MainActor (String) -> Void)?
    var onStep: (@MainActor (Int) -> Void)?
    /// Enter in a list field's `Other…` row: the typed string is added to the picked values.
    var onCommitText: (@MainActor (String) -> Void)?
    /// Escape in the text row: back to the field's options. A text-only field has no rows to go back
    /// to, so the panel refuses this there.
    var onCancelText: (@MainActor () -> Void)?

    /// The free-text answer field, for the panel to make first responder: the card's one keyboard
    /// moment. It is a subview from the start and merely hidden, so taking the keyboard never waits on
    /// a view being built.
    var textEntry: NSView { textField }

    /// Whether the text field is on screen right now — what the panel holds its keyboard ownership to.
    var isTextEntryVisible: Bool { !textField.isHidden }

    private var content: Content?
    /// The text column the block is measured at, set by `configure` from the panel's derived card width.
    /// The header and the option rows wrap, so their height is a function of this, and the card's budget
    /// and `height` have to measure the same width or they would disagree about a line.
    private var width: CGFloat = 0
    /// Room the block may fill, handed down from the card's budget (`IslandPanel.questionBlockRoom`).
    /// Deliberately not part of `Content`: the room belongs to the card, not to the form, and the same
    /// form on a short screen gets a shorter one.
    private var maxHeight: CGFloat = .greatestFiniteMagnitude
    /// The option set currently built into `optionViews`. A change here is the only thing that
    /// rebuilds those views — a selection or a keystroke must not remove a view out from under the
    /// click or the keystroke that caused it.
    private var optionsKey: String?
    /// The question itself, drawn as the block's one heading line, wrapped to three lines and truncated
    /// there.
    private let bodyLabel = NSTextField(labelWithString: "")
    private let unsupportedLabel = NSTextField(labelWithString: islandQuestionUnsupportedText)
    private let queueLabel = NSTextField(labelWithString: "")
    private let counterLabel = NSTextField(labelWithString: "")
    private let previousButton = IslandQuestionStepButton(symbol: "chevron.left")
    private let nextButton = IslandQuestionStepButton(symbol: "chevron.right")
    private let scroll = NSScrollView()
    private let optionsDocument = FlippedView()
    private let textField = NSTextField()
    private var optionViews: [IslandQuestionOptionView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // The question's own white: the bright line is what the user is being asked, and the card's
        // existing α0.92 tone carries it without a new alpha. It wraps to three lines and truncates
        // there rather than running the card taller than the list budget pays for.
        bodyLabel.font = islandQuestionTitleFont
        bodyLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.usesSingleLineMode = false
        bodyLabel.maximumNumberOfLines = 3
        // `usesSingleLineMode` alone does not turn wrapping on: the cell's own `wraps` is what makes the
        // frame's height hold several lines and the last one end in an ellipsis.
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.isScrollable = false
        addSubview(bodyLabel)

        // The dim line for a form the card cannot answer: a sibling of the header, not a mode.
        unsupportedLabel.font = islandQuestionSecondaryFont
        unsupportedLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        unsupportedLabel.usesSingleLineMode = true
        unsupportedLabel.isHidden = true
        addSubview(unsupportedLabel)

        // `2 of 3`: which form of the queue this is, at the header line's trailing edge. It
        // only exists when something is queued behind this one.
        queueLabel.font = islandQuestionQueueFont
        queueLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        queueLabel.alignment = .right
        queueLabel.usesSingleLineMode = true
        queueLabel.isHidden = true
        addSubview(queueLabel)

        // `1 / 2`: which field of this form. Between the chevrons, at the card's subordinate size,
        // tabular so stepping never shifts it.
        counterLabel.font = islandQuestionQueueFont
        counterLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        counterLabel.usesSingleLineMode = true
        counterLabel.isHidden = true
        addSubview(counterLabel)

        previousButton.isHidden = true
        nextButton.isHidden = true
        previousButton.onStep = { [weak self] in self?.onStep?(-1) }
        nextButton.onStep = { [weak self] in self?.onStep?(1) }
        addSubview(previousButton)
        addSubview(nextButton)

        // The free-text answer: borderless, on the card's own ground, so it reads as one more line of
        // the form rather than as a system control dropped onto it. It exists from the start and is
        // hidden, so taking the keyboard never has to build a view first.
        textField.font = NSFont.systemFont(ofSize: islandCardBaseFontSize, weight: .regular)
        textField.textColor = .white
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.isEditable = true
        textField.placeholderString = islandQuestionTextPlaceholder
        textField.delegate = self
        textField.isHidden = true
        addSubview(textField)

        // Options scroll inside the block rather than clipping: a form with twelve options is a
        // form, and the card's height stays the card's.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.documentView = optionsDocument
        scroll.isHidden = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Point the block at a form state, measured at `width` — the text column the card will lay it out
    /// in — and clamped to `maxHeight`, the room the card's budget leaves it. Returns whether the
    /// block's **height** changed, which is the one thing the card has to act on; a repaint inside the
    /// same height is the block's own.
    @discardableResult
    func configure(_ new: Content, width newWidth: CGFloat, maxHeight newMaxHeight: CGFloat) -> Bool {
        let heightChanged = content.map { Self.height(for: $0, width: width, maxHeight: maxHeight) }
            != Self.height(for: new, width: newWidth, maxHeight: newMaxHeight)
        guard content != new || newWidth != width || newMaxHeight != maxHeight else { return false }
        content = new
        width = newWidth
        maxHeight = newMaxHeight

        bodyLabel.stringValue = new.body
        queueLabel.isHidden = new.queueCount <= 1
        queueLabel.stringValue = "\(new.queueIndex) of \(new.queueCount)"
        unsupportedLabel.isHidden = new.answerable
        let field = new.answerable ? new.field : nil
        // One field has nothing to step to: the row — both chevrons and the counter — is not drawn at
        // all, and `height(for:)` leaves its height out of the block's own arithmetic too.
        let showsNav = field != nil && new.showsStepper
        counterLabel.isHidden = !showsNav
        counterLabel.stringValue = "\(new.fieldIndex + 1) / \(max(new.fieldCount, 1))"
        previousButton.isHidden = !showsNav
        nextButton.isHidden = !showsNav
        previousButton.isEnabled = new.steppable && new.fieldIndex > 0
        nextButton.isEnabled = new.steppable && new.fieldIndex + 1 < new.fieldCount

        // `Other…` swaps the answer rows for the text field. The rows stay built and hidden: removing
        // them here would delete the very view whose click is on the stack. What to draw is the
        // panel's call (`Content.textEntry`) — a list field's unconfirmed draft is not in its answer.
        let textMode = new.textEntry
        scroll.isHidden = new.answerRows.isEmpty
        textField.isHidden = !textMode
        // `Other…` is hidden while its own text row is open: the typed row stands where it was, and the
        // remaining options keep their places above it.
        for (option, view) in zip(field?.options ?? [], optionViews) {
            view.isHidden = textMode && option.isOther
        }
        if textMode, textField.stringValue != new.text {
            textField.stringValue = new.text
        }
        rebuildOptionsIfNeeded(new)
        applySelections(new)
        needsLayout = true
        return heightChanged
    }

    private func optionsKey(for content: Content) -> String {
        let values = content.field?.options
            .map { "\($0.value)\u{1}\($0.label)\u{1}\($0.detail ?? "")" }
            .joined(separator: "\u{2}") ?? ""
        return "\(content.formID)\u{3}\(content.field?.key ?? "")\u{3}\(values)"
    }

    private func rebuildOptionsIfNeeded(_ content: Content) {
        let key = optionsKey(for: content)
        guard key != optionsKey else { return }
        optionsKey = key
        for view in optionViews { view.removeFromSuperview() }
        optionViews = []
        // A new field is read from its first option: an offset carried over from the previous field
        // would open it halfway down.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        guard let field = content.field, content.answerable else { return }
        for option in field.options {
            let view = IslandQuestionOptionView(frame: .zero)
            view.configure(option: option, selected: false)
            view.onSelect = { [weak self] in self?.onOption?(option) }
            optionsDocument.addSubview(view)
            optionViews.append(view)
        }
    }

    private func applySelections(_ content: Content) {
        guard let field = content.field, content.answerable else { return }
        let answer = content.answers[field.key]
        for (option, view) in zip(field.options, optionViews) {
            view.configure(option: option, selected: field.isSelected(option, answer: answer))
        }
    }

    /// A keystroke is the answer: the panel stores it, which is what survives the render ticks.
    func controlTextDidChange(_ obj: Notification) {
        onText?(textField.stringValue)
    }

    /// Enter confirms a list field's `Other…` row; nothing else in the block reads the keyboard, and
    /// every other command falls through to the field's own behaviour.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onCancelText?()
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        // The typed answer is already recorded keystroke by keystroke (and a list's draft is committed
        // here), so Enter is the form's own "next": it moves to the following field rather than leaving
        // the user to find the chevron with the keyboard still held.
        onCommitText?(textField.stringValue)
        onStep?(1)
        return true
    }

    override func layout() {
        super.layout()
        var y = islandQuestionTopGap
        let fullWidth = max(0, bounds.width)
        let content = self.content

        // The header: the question itself wrapped to three lines. `2 of 3` takes the line's trailing
        // end, so the text width stops before it rather than running under it — the same reservation
        // `height(for:)` measures with.
        let headerWidth = content.map { Self.headerTextWidth($0, width: fullWidth) } ?? fullWidth
        if let content {
            let bodyHeight = islandWrappedHeight(content.body, font: islandQuestionTitleFont,
                                                 width: headerWidth, maxLines: 3)
            bodyLabel.frame = NSRect(x: 0, y: y, width: headerWidth, height: bodyHeight)
            y += bodyHeight
        }
        if let content, content.queueCount > 1 {
            let queueWidth = Self.queueWidth(content)
            let queueHeight = queueLabel.intrinsicContentSize.height
            queueLabel.frame = NSRect(x: max(0, fullWidth - queueWidth),
                                      y: islandQuestionTopGap + (islandQuestionTitleLineHeight - queueHeight) / 2,
                                      width: queueWidth, height: queueHeight)
        }
        y += islandQuestionGap

        guard let content, content.answerable, let field = content.field else {
            let size = unsupportedLabel.intrinsicContentSize
            unsupportedLabel.frame = NSRect(x: 0, y: y + (islandQuestionEmptyLineHeight - size.height) / 2,
                                            width: fullWidth, height: size.height)
            return
        }

        if content.showsStepper {
            let navY = y
            previousButton.frame = NSRect(x: 0, y: navY + (islandQuestionNavHeight - islandQuestionStepButtonSize) / 2,
                                          width: islandQuestionStepButtonSize, height: islandQuestionStepButtonSize)
            let counterWidth = islandLabelWidth(for: counterLabel)
            let counterSize = counterLabel.intrinsicContentSize
            counterLabel.frame = NSRect(x: islandQuestionStepButtonSize + islandQuestionGap,
                                        y: navY + (islandQuestionNavHeight - counterSize.height) / 2,
                                        width: counterWidth, height: counterSize.height)
            nextButton.frame = NSRect(x: counterLabel.frame.maxX + islandQuestionGap,
                                      y: previousButton.frame.minY,
                                      width: islandQuestionStepButtonSize, height: islandQuestionStepButtonSize)
            y += islandQuestionNavHeight + islandQuestionGap
        }

        let rows = content.answerRows
        let textRow = content.textEntry ? islandQuestionGap + islandQuestionTextHeight : 0
        let rowsHeight = Self.optionsHeight(rows, width: fullWidth)
        // `y` is the block's chrome; the options take the smaller of their own height, the block's cap
        // and whatever of the card's room is left — the text row's own height included, so a clamped
        // block scrolls instead of clipping.
        let visibleOptionsHeight = min(rowsHeight, islandQuestionOptionsMaxHeight,
                                       max(0, maxHeight - y - textRow))
        scroll.frame = NSRect(x: 0, y: y, width: fullWidth, height: visibleOptionsHeight)
        optionsDocument.frame = NSRect(x: 0, y: 0, width: fullWidth, height: rowsHeight)
        // The text field follows the rows it was opened from, on the same column, so the options stay
        // visible and clickable under the pointer while the answer is typed.
        // The typed row starts where the option labels start, not at the row's edge: it stands in the
        // list, so its text has to sit on the same left edge as the rows above it.
        textField.frame = NSRect(x: IslandQuestionOptionView.textLeftInset,
                                 y: y + visibleOptionsHeight + (content.textEntry ? islandQuestionGap : 0),
                                 width: max(0, fullWidth - IslandQuestionOptionView.textLeftInset * 2),
                                 height: islandQuestionTextHeight)
        var optionY: CGFloat = 0
        for (option, view) in zip(field.options, optionViews) where !view.isHidden {
            let h = Self.optionHeight(option, width: fullWidth)
            view.frame = NSRect(x: 0, y: optionY, width: fullWidth, height: h)
            optionY += h
        }
    }

    /// One option row's height at `width`: its one-line label plus a detail of 0, 1 or 2 wrapped lines,
    /// with the row's air above and below. The block's options height and `layout()` both call it, so a
    /// mixed list of one- and two-line rows cannot drift from the height the card budgets.
    private static func optionHeight(_ option: QuestionOption, width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - IslandQuestionOptionView.textColumnInset)
        let detail = option.detail.map {
            islandWrappedHeight($0, font: islandQuestionSecondaryFont, width: textWidth, maxLines: 2)
        } ?? 0
        return islandQuestionOptionVerticalPadding * 2 + islandQuestionOptionLabelLineHeight
            + (detail > 0 ? islandQuestionOptionLabelGap : 0) + detail
    }
}

/// A flipped container for the scroll's document: options stack from the top down, like everything
/// else in this file.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One answer row inside the question block: the option's label, its dim explanatory line, and a
/// checkmark at the trailing edge when it is the picked answer.
///
/// It is a **row of a form**, not a session row: same hover wash (`islandHoverWash…`) and the same
/// pointing hand, because both are the card's one way of saying "this is clickable", but no status
/// glyph, no age, and a selection mark instead of a focus action.
private final class IslandQuestionOptionView: NSView {
    var onSelect: (@MainActor () -> Void)?

    /// The checkmark, created once so the block can reserve its column and measure an option's text box
    /// against the same width the row draws in.
    private static let markImage = islandSymbolImage(
        symbol: "checkmark", color: NSColor.white.withAlphaComponent(0.9), pointSize: 10
    )
    /// The trailing column the checkmark occupies. Reserved on every row of a field, so a selection
    /// appearing or moving changes no label's width — only which row carries the tick.
    static let markColumnWidth: CGFloat = (markImage?.size.width ?? 0) + islandRowGlyphGap
    /// The row's text box begins `islandQuestionOptionTextInset` in from each side and ends before the
    /// checkmark's column. Both the row's own layout and the block's height arithmetic read this one sum.
    static let textColumnInset: CGFloat = markColumnWidth + markTrailingInset + islandQuestionOptionTextInset
    /// Where a row's text starts, shared with the block's free-text row so the typed line sits on the
    /// same left edge as the labels above it.
    static let textLeftInset: CGFloat = islandQuestionOptionTextInset
    /// Air between the tick and the row's trailing edge. Wider than the text's leading inset so the
    /// mark reads as sitting inside the row rather than against its edge.
    static let markTrailingInset: CGFloat = 14

    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let mark = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = islandQuestionOptionLabelFont
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        addSubview(label)

        // The server's explanatory line wraps to two lines and truncates there: a detail is worth more
        // than one clipped line at 640pt, but not an unbounded row height the budget cannot predict.
        detail.font = islandQuestionSecondaryFont
        detail.textColor = NSColor.white.withAlphaComponent(0.5)
        detail.lineBreakMode = .byTruncatingTail
        detail.usesSingleLineMode = false
        detail.maximumNumberOfLines = 2
        detail.cell?.wraps = true
        detail.cell?.isScrollable = false
        detail.isHidden = true
        addSubview(detail)

        mark.image = Self.markImage
        mark.imageScaling = .scaleNone
        mark.isHidden = true
        addSubview(mark)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(option: QuestionOption, selected: Bool) {
        label.stringValue = option.label
        label.textColor = NSColor.white.withAlphaComponent(selected ? 1 : 0.7)
        detail.stringValue = option.detail ?? ""
        detail.isHidden = option.detail == nil
        mark.isHidden = !selected
        toolTip = option.isOther ? "Type an answer instead of picking one" : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let textX = islandQuestionOptionTextInset
        let textWidth = max(0, bounds.width - Self.textColumnInset)
        let labelHeight = islandQuestionOptionLabelLineHeight
        if detail.isHidden {
            label.frame = NSRect(x: textX, y: (bounds.height - labelHeight) / 2,
                                 width: textWidth, height: labelHeight)
        } else {
            let detailHeight = islandWrappedHeight(detail.stringValue, font: islandQuestionSecondaryFont,
                                                   width: textWidth, maxLines: 2)
            label.frame = NSRect(x: textX, y: islandQuestionOptionVerticalPadding,
                                 width: textWidth, height: labelHeight)
            detail.frame = NSRect(x: textX,
                                  y: islandQuestionOptionVerticalPadding + labelHeight
                                      + islandQuestionOptionLabelGap,
                                  width: textWidth, height: detailHeight)
        }
        let markSize = mark.image?.size ?? .zero
        // The tick keeps the same air from the row's trailing edge as the text keeps from its leading
        // one, so a selected row does not look like it is spilling out of the card.
        mark.frame = NSRect(x: bounds.width - markSize.width - Self.markTrailingInset,
                            y: (bounds.height - markSize.height) / 2,
                            width: markSize.width, height: markSize.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // Claim the click so it never reaches the card's blank-area toggle.
    override func mouseDown(with event: NSEvent) { onSelect?() }

    // The panel is non-key and non-activating, so the first click would otherwise be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: islandHoverWashDX, dy: islandHoverWashDY),
            xRadius: islandHoverWashRadius,
            yRadius: islandHoverWashRadius
        )
        NSColor.white.withAlphaComponent(islandHoverWashAlpha).setFill()
        path.fill()
    }
}

/// A chevron that steps the card between a form's fields. Inert (`isEnabled` false) at either end and
/// while there is one field: drawn dim rather than hidden, so the field counter never sits between
/// two holes.
private final class IslandQuestionStepButton: NSView {
    var onStep: (@MainActor () -> Void)?

    private let glyph = NSImageView()

    override var isFlipped: Bool { true }

    init(symbol: String) {
        super.init(frame: .zero)
        glyph.image = islandSymbolImage(symbol: symbol, color: NSColor.white.withAlphaComponent(0.55), pointSize: 10)
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        alphaValue = islandCardDisabledAlpha
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var isEnabled = false {
        didSet { alphaValue = isEnabled ? 1 : islandCardDisabledAlpha }
    }

    override func layout() {
        super.layout()
        let size = glyph.image?.size ?? .zero
        glyph.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onStep?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    /// Fired when the card's footer gear is clicked, on whichever screen's island it was. Set by the app
    /// delegate, which owns the one menu (`showMenuFromIsland`).
    ///
    /// **A pure pass-through, and deliberately not host-owned like the two above.** The menu is one object
    /// for the whole app rather than one per screen, so there is nothing to fan out; and nothing is
    /// collapsed here — the menu opening collapses every island itself
    /// (`NSMenuDelegate.menuWillOpen`), so a `collapse()` on this path would only do it twice.
    var onSettingsRequested: (@MainActor () -> Void)?

    /// One form's whole answer set, from whichever screen's card pressed `Send`. Answered by the app
    /// delegate, which hands it to the monitor's one reply path — the monitor owns the HTTP, the auth
    /// and what a refusal means.
    var onReplyQuestion: (@MainActor (PendingQuestion, [String: QuestionAnswer]) -> Void)?

    /// What the user has picked, shared by every panel (`IslandQuestionState`), and the payload each
    /// pending form had on the previous tick, so a form re-asked under the same id is recognised as a
    /// different question.
    private var questionState = IslandQuestionState()
    private var questionPayloads: [String: String] = [:]

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
    func update(rows: [IslandRow], enabled: Bool, serviceCPU: Double?, cpuUnit: CPUUnit) {
        lastRows = rows
        lastEnabled = enabled
        lastServiceCPU = serviceCPU
        lastCPUUnit = cpuUnit
        pruneQuestionState(rows: rows)
        for panel in panels {
            panel.update(rows: rows, enabled: enabled, serviceCPU: serviceCPU, cpuUnit: cpuUnit,
                         questionState: questionState)
        }
    }

    /// Forget what belongs to a question that is gone or is no longer the same question.
    ///
    /// The answer set is keyed on the form's id, and the server can re-ask a form under the same id with
    /// different fields — a different question, so its old answers must not survive. A settled form
    /// simply disappears from the list, which drops its entry the same way. `hidden` is released when
    /// the hidden form settles, so the next queued form asks for the card.
    ///
    /// A form appearing for the first time (or re-asked) is seeded with the answers the server already
    /// gave it (`PendingQuestion.defaultAnswers`) — a required field with a `default` would otherwise
    /// hold `Send` back forever, waiting for the user to re-pick what the server already picked.
    private func pruneQuestionState(rows: [IslandRow]) {
        var live: [String: String] = [:]
        for row in rows {
            for question in row.questions { live[question.id] = question.payload }
        }
        let previous = questionPayloads
        questionPayloads = live
        for formID in Set(questionState.answers.keys).union(questionState.drafts.keys) {
            guard previous[formID] != live[formID] else { continue }
            questionState.answers[formID] = nil
            questionState.drafts[formID] = nil
        }
        // A reply that resolved, or a form that left the rows or changed under one, releases its guard.
        questionState.submitting = questionState.submitting.filter {
            previous[$0] == live[$0] && live[$0] != nil
        }
        if let hidden = questionState.hidden, live[hidden] == nil {
            questionState.hidden = nil
        }
        // After the prune, so the seed is not what the payload check then throws away.
        for row in rows {
            for question in row.questions where questionState.answers[question.id] == nil {
                let seeded = question.defaultAnswers
                guard !seeded.isEmpty else { continue }
                questionState.answers[question.id] = seeded
            }
        }
    }

    /// Answer one field of one form. Stored here, on the host, because the card is on every screen: the
    /// selection has to be the same one every panel draws, and `Send`'s gate the same verdict.
    private func answer(formID: String, fieldKey: String, answer: QuestionAnswer) {
        questionState.answers[formID, default: [:]][fieldKey] = answer
        pushQuestionState()
    }

    /// The typed text of a list field's open `Other…` row. Shared like an answer: the field has to read
    /// the same on both screens, and confirming is what turns it into a picked value.
    private func draft(formID: String, fieldKey: String, text: String) {
        questionState.drafts[formID, default: [:]][fieldKey] = text
        pushQuestionState()
    }

    /// Enter on a list field's `Other…` row: the typed string is **added** to the picked values, never
    /// put in their place, and the field returns to its rows. One push, so no screen sees the value
    /// arrive and the text field linger.
    private func commitDraft(formID: String, fieldKey: String, text: String) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [String] = []
        if case .list(let picked)? = questionState.answers[formID]?[fieldKey] { values = picked }
        if !typed.isEmpty, !values.contains(typed) { values.append(typed) }
        questionState.answers[formID, default: [:]][fieldKey] = .list(values)
        questionState.drafts[formID]?[fieldKey] = nil
        if questionState.drafts[formID]?.isEmpty == true { questionState.drafts[formID] = nil }
        pushQuestionState()
    }

    /// `Send` on any screen: **one wall per form, for the whole app.** The guard lives here beside the
    /// answers rather than on the panel that was clicked, because the card is on every display — two
    /// panels each holding their own flag could both post the same reply.
    private func submitQuestion(_ question: PendingQuestion, answers: [String: QuestionAnswer]) {
        guard !questionState.submitting.contains(question.id) else { return }
        questionState.submitting.insert(question.id)
        pushQuestionState()
        onReplyQuestion?(question, answers)
    }

    /// The question card's `Hide`: **fold without answering.** The form stays pending on the server, so
    /// the dismissal is recorded against its id — the card does not ask about it again, on any screen,
    /// until it settles or another form becomes the head.
    private func hideQuestion(_ formID: String) {
        questionState.hidden = formID
        collapse()
        pushQuestionState()
    }

    /// A question's fold deadline arrived on one screen: **fold that showing on every screen, and
    /// nothing else.** The form is not dismissed — it stays pending and answerable, and asking again is
    /// what the next showing does — which is the whole difference between this and `hideQuestion`.
    private func foldQuestion(_ formID: String) {
        for panel in panels { panel.foldQuestion(formID) }
    }

    /// `ocbar.questionFold` changed: every showing re-arms from the new value, so a menu pick applies
    /// to the card that is up rather than to the next form.
    func rearmQuestionDeadline() {
        for panel in panels { panel.rearmQuestionDeadline() }
    }

    private func pushQuestionState() {
        for panel in panels { panel.applyQuestionState(questionState) }
    }

    /// Leave a field's text row: the typed answer and the unconfirmed draft both go, which is what puts
    /// the field's options back. Picked values of a list field are its answer, not its draft, and stay.
    private func clearQuestionText(formID: String, fieldKey: String) {
        questionState.answers[formID]?[fieldKey] = nil
        questionState.drafts[formID]?[fieldKey] = nil
        pushQuestionState()
    }

    /// Collapse every island — the menubar calls this as its menu opens, so no island anywhere sits in
    /// the menu's way; `rowActivated` calls it when a row is clicked on any screen (unless a question card
    /// is up); and the alert's `Hide` button calls it (`hideRequested`), so one click folds them all. One
    /// primitive for all three, because all three are the user dismissing the island *with the pointer
    /// inside it* — which is why they latch (`IslandPanel.hoverLatched`) and why the alert's third exit,
    /// `dismissAlert`, does not come through here.
    func collapse() {
        for panel in panels { panel.collapse() }
    }

    /// A row was clicked on one screen's island: hand the pid to the session focus, and fold every
    /// screen's island — **unless a question card is up.**
    ///
    /// Host-owned on purpose. The reminder is shown on every screen, so answering it on one is answering
    /// it: folding only the clicked panel would leave the other display's card open for the rest of
    /// `bubbleSeconds`, still marking a row the user has already dealt with. The fold goes through
    /// `collapse()`, the same path the menubar takes, so the panel's hover latch (`hoverLatched`) covers
    /// this dismissal too — the pointer is inside the island the user just clicked, and without the latch
    /// the hover poll would re-open the card 0.35s later.
    ///
    /// **A question card is the exception, and focus is not.** The user is about to answer, so folding
    /// would take the question, the selections and the field position away in one click; the row still
    /// focuses the session through the same `onSelectSession`, which touches none of the shared question
    /// state and none of its deadline. The alert's row click keeps both halves — that rule is the alert's
    /// own (`docs/island-alert.md`) and is not this one.
    private func rowActivated(pid: Int32?) {
        if !panels.contains(where: { $0.hasQuestionCardUp }) {
            collapse()
        }
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
    private var lastServiceCPU: Double?
    private var lastCPUUnit: CPUUnit = .stored
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
            // The one panel callback with no host behaviour behind it: the menu is one object, so this
            // travels straight up and nothing is folded on the way (`onSettingsRequested`).
            panel.onSettingsRequested = { [weak self] in self?.onSettingsRequested?() }
            // The question card's three answers are all host-owned for the row click's reason: what
            // the user picks has to be what the other screen draws, and Send is one reply for a card
            // shown on every display.
            panel.onQuestionAnswer = { [weak self] formID, fieldKey, answer in
                self?.answer(formID: formID, fieldKey: fieldKey, answer: answer)
            }
            panel.onSubmitQuestion = { [weak self] question, answers in
                self?.submitQuestion(question, answers: answers)
            }
            panel.onQuestionDraft = { [weak self] formID, fieldKey, text in
                self?.draft(formID: formID, fieldKey: fieldKey, text: text)
            }
            panel.onQuestionCommit = { [weak self] formID, fieldKey, text in
                self?.commitDraft(formID: formID, fieldKey: fieldKey, text: text)
            }
            panel.onQuestionClear = { [weak self] formID, fieldKey in
                self?.clearQuestionText(formID: formID, fieldKey: fieldKey)
            }
            panel.onQuestionHidden = { [weak self] formID in
                self?.hideQuestion(formID)
            }
            panel.onQuestionFoldReached = { [weak self] formID in
                self?.foldQuestion(formID)
            }
            return panel
        }
        // Re-apply the current state so a rebuild does not blank the islands.
        for panel in panels {
            panel.update(rows: lastRows, enabled: lastEnabled, serviceCPU: lastServiceCPU,
                         cpuUnit: lastCPUUnit, questionState: questionState)
        }
    }
}
