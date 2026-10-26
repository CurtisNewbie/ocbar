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
        if pct >= critical {
            band = .critical
        } else if pct >= warn {
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

struct SessionInfo: Equatable {
    let id: String
    var status: SessionStatus
    var projectDir: String
    var clientPID: Int32? = nil
    /// Optional display title from the session JSON `title` field.
    var sessionTitle: String? = nil
    /// Session creation timestamp in milliseconds (session JSON `time.created`).
    var createdAt: TimeInterval = 0
    /// Context-window usage, present only when the feature is enabled and known.
    var context: SessionContext? = nil
}

func formatDurationLabel(sinceMS: TimeInterval, nowMS: TimeInterval) -> String {
    guard sinceMS > 0 else { return "" }
    let minutes = max(0, Int((nowMS - sinceMS) / 60_000))
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
    return "\(m)m"
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
