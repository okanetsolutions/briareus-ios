// The words and numbers the screens show, as the Windows client formats them. Colours are the UI's: it maps a finding's
// severity, a session's status, a review verdict and a check's result to its palette.
import Foundation

// MARK: - Findings

/// The short badge text for a finding's severity; anything unknown reads as medium. (The UI colours CRIT and HIGH as
/// danger, LOW as muted and MED as a warning.)
func findingSeverityLabel(_ severity: String?) -> String {
    switch (severity ?? "").asciiFolded {
    case "critical": return "CRIT"
    case "high": return "HIGH"
    case "low": return "LOW"
    default: return "MED"
    }
}
/// The verdicts a finding takes, by their API spelling, and the titles their buttons show.
let findingDecisionIds = ["fix", "optional", "dismissed"]
let findingDecisionTitles = ["Fix", "Optional", "Dismiss"]
/// The index of a verdict's API spelling; nil for one this app does not know (the C client's -1).
func findingDecisionIndex(_ decision: String?) -> Int? { decision.flatMap { findingDecisionIds.firstIndex(of: $0) } }

// MARK: - Rows

/// "Status · model", or the status alone without a model.
func sessionSubtitle(_ session: Session) -> String {
    let status = session.status.asciiCapitalized
    guard let model = session.model else { return status }
    return "\(status) \u{00B7} \(model)"
}
/// "@ana, @bo +2": up to `limit` logins, then how many more.
func people(_ logins: [String], limit: Int) -> String {
    var s = logins.prefix(max(limit, 0)).map { "@\($0)" }.joined(separator: ", ")
    if logins.count > limit { s += " +\(logins.count - limit)" }
    return s
}
/// The state a linked issue or pull request row names after its title, or nil for none. (The UI colours draft and not
/// planned as warnings, open as success and closed as secondary.)
func linkedStateText(_ link: BoardLink) -> String? {
    if link.draft { return "draft" }
    if link.notPlanned { return "not planned" }
    if link.state == "open" { return "open" }
    if link.state == "closed" { return "closed" }
    return nil
}

// MARK: - Working indicator

private let workingGlyphs = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}", "\u{273B}", "\u{2736}", "\u{2733}", "\u{2722}"]
private let workingVerbs = ["Working", "Thinking", "Reasoning", "Tinkering", "Crafting", "Pondering"]
/// The spinner's glyph, cycling every ten ticks.
func workingGlyph(_ tick: Int) -> String { workingGlyphs[((tick % 10) + 10) % 10] }
/// The spinner's verb, changing every 25 ticks. Division truncates toward zero, so -24...24 all read "Working".
func workingVerb(_ tick: Int) -> String { workingVerbs[((tick / 25) % 6 + 6) % 6] }

// MARK: - Times

private func formatter(_ format: String?, locale: Locale, timeZone: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.locale = locale; f.timeZone = timeZone
    if let format { f.dateFormat = format } else { f.dateStyle = .none; f.timeStyle = .short }
    return f
}
/// The clock alone for today, else "MMM d, clock", in the user's locale. The offset is that of the date itself, not today's.
func formatEventTime(_ when: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    let clock = formatter(nil, locale: locale, timeZone: timeZone).string(from: when)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    if calendar.isDate(when, inSameDayAs: now) { return clock }
    return "\(formatter("MMM d", locale: locale, timeZone: timeZone).string(from: when)), \(clock)"
}
/// "MMM d, yyyy" in the user's locale.
func formatDateAbbrev(_ when: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    formatter("MMM d, yyyy", locale: locale, timeZone: timeZone).string(from: when)
}
/// "now", "5m ago" … "2y ago"; a time ahead has no "ago".
func formatRelative(_ when: Date, now: Date = Date()) -> String {
    let diff = now.timeIntervalSince(when).rounded(.towardZero)   // whole seconds, as time_t
    let suffix = diff >= 0 ? " ago" : ""
    let d = abs(diff)
    func n(_ unit: Double) -> Int { Int(d / unit) }
    if d < 60 { return "now" }
    if d < 3600 { return "\(n(60))m\(suffix)" }
    if d < 86400 { return "\(n(3600))h\(suffix)" }
    if d < 7 * 86400 { return "\(n(86400))d\(suffix)" }
    if d < 30 * 86400 { return "\(n(7 * 86400))w\(suffix)" }
    if d < 365 * 86400 { return "\(n(30 * 86400))mo\(suffix)" }
    return "\(n(365 * 86400))y\(suffix)"
}
/// The two largest units: "1h 1m", "1m 0s", "59s". Negative reads as zero.
func formatDurationMs(_ ms: Double) -> String {
    let total = ms.isFinite ? max(0, Int((ms / 1000).rounded(.towardZero))) : 0
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}
/// "m:ss"; negative reads as zero.
func formatClock(_ seconds: Int) -> String {
    let s = max(seconds, 0)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Numbers

/// Token counts as the Windows client abbreviates them: 999, 1.0k, 19.1M, 21.6B. From where one decimal rounds up to 1000 of
/// the smaller unit, the larger unit is used.
func formatTokens(_ n: Double) -> String {
    if n >= 999.95e6 { return String(format: "%.1fB", n / 1e9) }
    if n >= 999.95e3 { return String(format: "%.1fM", n / 1e6) }
    if n >= 1e3 { return String(format: "%.1fk", n / 1e3) }
    return n.isFinite ? String(Int(n.rounded(.towardZero))) : "0"
}
/// "$33.35".
func formatCost(_ usd: Double) -> String { String(format: "$%.2f", usd) }
/// Whole kilobytes rounded up (at least 1 KB), or megabytes with one decimal from 1 MB.
func formatFileSize(_ bytes: Int) -> String {
    if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0)) }
    let kb = (max(bytes, 0) + 1023) / 1024
    return "\(max(kb, 1)) KB"
}
