import AppKit
import Foundation

enum SessionStatus: String {
    case idle, busy, waiting, error
}

/// Context-window usage for a session, derived from its most recent completed
/// assistant turn and the model's usable ceiling. `limit` is nil when the
/// model's limit info is unknown; `fraction` is nil when `limit` is nil/0.
struct SessionContext: Equatable {
    var used: Int
    var limit: Int?
    var fraction: Double?
}

// MARK: - Context-usage presentation

/// How context usage is rendered; mirrors the UserDefaults key
/// `ocbar.contextUsageDisplay`.
enum ContextDisplayMode: String, CaseIterable {
    case percent
    case tokens
    case both

    var displayName: String {
        switch self {
        case .percent: return "Percent"
        case .tokens: return "Tokens used"
        case .both: return "Percent + tokens"
        }
    }
}

/// Severity band for a session's context usage. One vocabulary for the colour
/// and glyph both surfaces paint with, so the menubar detail row and the island
/// row can never disagree about what "in the red" looks like.
enum ContextBand: String {
    case none
    case warn
    case critical
    /// No completed turn yet, or the model's limit is unknown.
    case unknown

    /// The band glyph. Nil out of band and for placeholders, matching the
    /// dropdown (which draws nothing there).
    var glyph: String? {
        switch self {
        case .warn: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .none, .unknown: return nil
        }
    }

    /// Band colour exactly as the menubar detail row paints it. The island
    /// dims the neutral cases against its dark card; the warning colours are
    /// deliberately identical on both surfaces.
    var menuColor: NSColor {
        switch self {
        case .critical: return .systemRed
        case .warn: return .systemOrange
        case .none: return .labelColor
        case .unknown: return .tertiaryLabelColor
        }
    }

    /// Whether the value sits in the warn/critical band — the state the menu
    /// additionally renders its percent semibold for.
    var inBand: Bool { self == .warn || self == .critical }
}

/// Display-ready context usage for one session.
enum ContextUsageContent: Equatable {
    /// No completed turn yet, or the model's limit is unknown. Carries the exact
    /// placeholder sentence the dropdown shows, so the island repeats it rather
    /// than inventing a second wording.
    case placeholder(String)
    /// Pre-formatted token count and percent (`12k / 200k tokens`, `6%`).
    case usage(tokensText: String, percentText: String)
}

/// Thresholds, wording and banding for one session's context usage, resolved
/// once so every surface renders the same dialect.
struct ContextUsagePresentation: Equatable {
    let content: ContextUsageContent
    let band: ContextBand

    /// The dropdown's two placeholder sentences, reused verbatim by the island.
    static let noCompletedTurn = "Context — no completed turn yet"
    static let unknownLimit = "Context unknown — model limit unavailable"

    /// `warn` and `critical` are absolute token counts, not percentages.
    init(context: SessionContext?, warn: Int, critical: Int) {
        guard let context else {
            content = .placeholder(Self.noCompletedTurn)
            band = .unknown
            return
        }
        // A non-positive limit is as good as unknown: `fraction` is nil for it
        // by construction, and dividing by it would be undefined.
        guard let limit = context.limit, limit > 0 else {
            content = .placeholder(Self.unknownLimit)
            band = .unknown
            return
        }
        let pct = Self.percent(used: context.used, limit: limit, fraction: context.fraction)
        if context.used >= critical {
            band = .critical
        } else if context.used >= warn {
            band = .warn
        } else {
            band = .none
        }
        content = .usage(
            tokensText: "\(compactTokens(context.used)) / \(compactTokens(limit)) tokens",
            percentText: "\(pct)%"
        )
    }

    private static func percent(used: Int, limit: Int, fraction: Double?) -> Int {
        if let fraction {
            return min(100, max(0, Int((fraction * 100).rounded())))
        }
        return min(100, max(0, Int((Double(used) / Double(limit) * 100).rounded())))
    }

    /// The single-line rendering for a display mode. The island uses this
    /// directly; the menu composes the same pieces as an attributed string so it
    /// can take the percent semibold in band.
    func displayText(_ display: ContextDisplayMode) -> String {
        switch content {
        case .placeholder(let text):
            return text
        case .usage(let tokensText, let percentText):
            switch display {
            case .percent: return percentText
            case .tokens: return tokensText
            case .both: return "\(tokensText) · \(percentText)"
            }
        }
    }
}

/// Compact token formatter: `1_234 → "1.2k"`, `32_000 → "32k"`, ≥1M → `"1M"`.
func compactTokens(_ value: Int) -> String {
    if value >= 1_000_000 {
        let millions = Double(value) / 1_000_000
        return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
    }
    if value >= 1_000 {
        let thousands = Double(value) / 1_000
        return thousands == thousands.rounded() ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
    }
    return "\(value)"
}

// MARK: - Pending question forms

/// The last answer row of a field that allows free text, and the reason a field is
/// never a dead end. It is a row like any other, not a mode switch in the chrome.
let islandQuestionOtherLabel = "Other…"

/// What the block says for a form it cannot answer — a field type outside the
/// card's set (`number`, `integer`, `external`), named rather than hidden.
let islandQuestionUnsupportedText = "Answer in terminal"

/// One row the card draws for a form field's answer: a server option, the card's own
/// `Yes`/`No` pair for a boolean, or the trailing `Other…` row that swaps the field
/// for a text field.
struct QuestionOption: Equatable {
    /// The option's own value, which is what a `multiselect` answer carries.
    let value: String
    let label: String
    /// The server's explanatory line, drawn dim under the label.
    let detail: String?
    /// `Other…`, which is not a value but a mode of the field.
    let isOther: Bool
    /// A boolean field's value for this row; nil for every other kind.
    let flag: Bool?
}

/// What a field's answer is, in the three shapes the card can actually produce.
enum QuestionAnswer: Equatable {
    case text(String)
    /// A boolean field's answer, and the only answer that is never "empty".
    case flag(Bool)
    case list([String])

    /// The reply's JSON value, in the shape the contract names per field type.
    var jsonValue: Any {
        switch self {
        case .text(let value): return value
        case .flag(let value): return value
        case .list(let values): return values
        }
    }

    /// Whether this counts as answered for `Send`'s gate: a typed answer must be
    /// non-empty, and a multiselect must carry at least one value.
    var isEmpty: Bool {
        switch self {
        case .text(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .flag: return false
        case .list(let values): return values.isEmpty
        }
    }
}

/// The four ways a field can be drawn. `unsupported` exists so the card can still
/// name a form it cannot answer instead of dropping fields silently.
enum QuestionFieldKind: Equatable {
    case text
    case flag
    case list
    case unsupported
}

/// One field of a pending form, resolved into what the card draws.
struct QuestionField: Equatable {
    let key: String
    /// The field's short title, else its full question text.
    let heading: String
    let required: Bool
    let kind: QuestionFieldKind
    /// Answer rows, `Other…` last. Empty for a field the card cannot render.
    let options: [QuestionOption]

    /// Whether `Other…` is the last row: only a text field can carry a typed answer.
    var allowsText: Bool { kind == .text && (options.last?.isOther ?? false) }
}

/// One pending form, resolved to the card's own model. Built from the server's
/// `Form.Info` by `pendingQuestion(from:)`.
struct PendingQuestion: Equatable {
    let id: String
    /// The session blocked on it — the reply's path segment, which is the form's
    /// own session and not necessarily the root row it is drawn under.
    let sessionID: String
    let fields: [QuestionField]
    /// Every field can be drawn and answered on the card. A form with even one
    /// field outside that set is named instead of half-answered: the reply carries
    /// the form's whole answer set, so a partial one is a guaranteed rejection.
    let answerable: Bool
    /// The server payload's own bytes. A form re-asked under the same id with
    /// different fields is a different question; an identical one is the same.
    let payload: String
}

/// The card's heading for a field: its short title, else the question itself.
private func questionHeading(title: String?, description: String?, key: String) -> String {
    for candidate in [title, description] {
        let text = (candidate ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !text.isEmpty { return text }
    }
    return key
}

/// The pure seam: one server form entry to the block the card renders.
///
/// Every decision the card's content depends on lives here — which field types it
/// can answer, the order of the option rows, `Other…` last, the heading fallback,
/// and whether the form is answerable at all — so it can be pinned without a view.
func pendingQuestion(from json: [String: Any]) -> PendingQuestion? {
    guard let id = json["id"] as? String,
          let sessionID = json["sessionID"] as? String,
          let rawFields = json["fields"] as? [[String: Any]], !rawFields.isEmpty else { return nil }
    let fields = rawFields.compactMap(questionField(from:))
    guard !fields.isEmpty else { return nil }
    let payload = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return PendingQuestion(
        id: id,
        sessionID: sessionID,
        fields: fields,
        answerable: fields.allSatisfy { $0.kind != .unsupported },
        payload: payload
    )
}

private func questionField(from json: [String: Any]) -> QuestionField? {
    guard let key = json["key"] as? String else { return nil }
    let heading = questionHeading(
        title: json["title"] as? String,
        description: json["description"] as? String,
        key: key
    )
    let required = (json["required"] as? Bool) ?? false
    let rawOptions = json["options"] as? [[String: Any]] ?? []
    // Absent `custom` behaves as allowed; only an explicit `false` refuses free text.
    let custom = (json["custom"] as? Bool) ?? true

    func options(_ flag: Bool? = nil) -> [QuestionOption] {
        rawOptions.compactMap { option in
            guard let value = option["value"] as? String else { return nil }
            let label = (option["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
            let detail = (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A boolean answer is a JSON bool, so the option's own value has to be read as one.
            let truthy = ["true", "1", "yes"].contains(value.lowercased())
            return QuestionOption(value: value, label: label, detail: detail, isOther: false,
                                  flag: flag.map { _ in truthy })
        }
    }

    let kind: QuestionFieldKind
    var rows: [QuestionOption]
    switch json["type"] as? String {
    case "string":
        kind = .text
        rows = options()
        if custom {
            rows.append(QuestionOption(value: "", label: islandQuestionOtherLabel,
                                       detail: nil, isOther: true, flag: nil))
        } else if rows.isEmpty {
            return QuestionField(key: key, heading: heading, required: required,
                                 kind: .unsupported, options: [])
        }
    case "boolean":
        kind = .flag
        rows = options(true)
        if rows.isEmpty {
            rows = [
                QuestionOption(value: "true", label: "Yes", detail: nil, isOther: false, flag: true),
                QuestionOption(value: "false", label: "No", detail: nil, isOther: false, flag: false)
            ]
        }
    case "multiselect":
        // Free text has no meaning for a list answer, so `Other…` is a text field's row only.
        kind = .list
        rows = options()
        if rows.isEmpty { return QuestionField(key: key, heading: heading, required: required,
                                              kind: .unsupported, options: []) }
    default:
        return QuestionField(key: key, heading: heading, required: required,
                             kind: .unsupported, options: [])
    }
    return QuestionField(key: key, heading: heading, required: required, kind: kind, options: rows)
}

struct SessionInfo: Equatable {
    let id: String
    var status: SessionStatus
    var projectDir: String
    var clientPID: Int32? = nil
    /// Optional display title from the session JSON `title` field.
    var sessionTitle: String? = nil
    /// Session creation timestamp in milliseconds (session JSON `time.created`).
    var createdAt: TimeInterval = 0
    /// Last-update timestamp in milliseconds (session JSON `time.updated`), 0
    /// when the payload carries none. It is the same read the monitor already
    /// does to decide visibility, so the card's last-touch stamp costs no extra
    /// request.
    var updatedAt: TimeInterval = 0
    /// Context-window usage, present only when the feature is enabled and known.
    var context: SessionContext? = nil
    /// How many of this root's descendants are running right now — the sessions
    /// the `task` tool spawned (and anything those spawned in turn). Zero when
    /// nothing but the root itself is working.
    ///
    /// Free to compute: `poll` already asks for `/api/session/active` and already
    /// walks the `parentID` tree to decide the root's status, so the count is
    /// those two sets intersected minus the root. The root is excluded because it
    /// is in `active` for its own turn — a session thinking by itself runs zero
    /// subagents.
    ///
    /// Not capped here: what will not fit on screen is the renderer's problem,
    /// not the monitor's.
    var runningSubagents: Int = 0
    /// Pending question forms this root is blocked on (its own or a descendant's),
    /// oldest first in the server's own order. The monitor keeps the payload it
    /// already fetched; the card draws the first one.
    var questions: [PendingQuestion] = []
}

/// `5h36m` / `3h` / `12m` — the card's and the menu's one duration form.
func durationText(minutes: Int) -> String {
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
    return "\(m)m"
}

func formatDurationLabel(sinceMS: TimeInterval, nowMS: TimeInterval) -> String {
    guard sinceMS > 0 else { return "" }
    let minutes = max(0, Int((nowMS - sinceMS) / 60_000))
    return durationText(minutes: minutes)
}

/// The row's last-touch stamp: how long since the session was updated, or "now".
///
/// No "ago": the stamp sits immediately right of the session's age in line 1's
/// right slot (`5h36m · 2m`), so it is a second number in one right-aligned
/// column of times, not a sentence of its own — one unit, one font, no words.
/// The first minute still gets `now` rather than `0m`, which would read as a
/// broken clock.
///
/// Empty in two cases. No `time.updated` at all, and — the subtle one — a
/// session that has never been updated since it was created: its updated
/// timestamp is just the creation one, so the stamp would repeat the age beside
/// it (`3h12m · 3h12m`). Only a real update earns the second number.
func formatStampLabel(updatedMS: TimeInterval, createdMS: TimeInterval, nowMS: TimeInterval) -> String {
    guard updatedMS > 0 else { return "" }
    guard updatedMS - createdMS >= 60_000 else { return "" }
    let minutes = max(0, Int((nowMS - updatedMS) / 60_000))
    return minutes == 0 ? "now" : durationText(minutes: minutes)
}

/// The folder a session belongs to, as the menubar and the island identify it:
/// the project directory's last path component, or a short id tail when there
/// is no usable directory.
func sessionFolderName(for session: SessionInfo) -> String {
    if !session.projectDir.isEmpty && session.projectDir != "/" {
        return URL(fileURLWithPath: session.projectDir).lastPathComponent
    }
    return session.id.isEmpty ? "session" : String(session.id.suffix(6))
}

/// A session's title with runs of whitespace collapsed to single spaces, or nil
/// when it has none. A title is shown on a single line, so newlines and stray
/// tabs must not survive into it.
func flattenedSessionTitle(_ session: SessionInfo) -> String? {
    let cleaned = (session.sessionTitle ?? "")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return cleaned.isEmpty ? nil : cleaned
}

enum AggregateStatus {
    case none, busy, idle, error
}

struct AppState {
    var sessions: [SessionInfo] = []

    /// The OpenCode server **tree**'s CPU (the server plus the descendants it spawned), as a share of
    /// **one core** — the raw ratio, so it can read past 100, and 100 is one core rather than the
    /// machine. The pill's `CPUUnit` decides which unit is drawn (`100 / ncpu` for machine percent).
    /// Nil means unknown: the feature is
    /// off, or this tick had no honest reading. It is a **readout and nothing else** — the island's
    /// running mark keeps reading only `counts[.busy] > 0`, because high CPU is not a session that
    /// is running (a server idling on a big session, or its own tool subprocesses, is not work).
    var serviceCPU: Double?

    var aggregate: AggregateStatus {
        if sessions.isEmpty { return .none }
        if sessions.contains(where: { $0.status == .error }) { return .error }
        if sessions.contains(where: { $0.status == .idle }) { return .idle }
        return .busy
    }
}

struct SSEEvent {
    let type: String
    let data: String
}
