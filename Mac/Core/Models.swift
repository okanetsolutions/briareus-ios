// What the client API answers with, read into the shapes the screens use. Unknown fields ride along in `raw`.
import Foundation

// MARK: - Shared helpers

extension JSON {
    /// A number that is a whole number within C `int` range, as the Windows client's `json_int_or` reads one; nil otherwise.
    var int32: Int? {
        guard let n = number, n.isFinite, n == n.rounded(.down), n >= -2147483648.0, n <= 2147483647.0 else { return nil }
        return Int(n)
    }
    /// A number cut toward zero, as C's `(int)` cast reads one (7.9 is 7); nil for anything that is not a finite number.
    var truncatedInt: Int? {
        guard let n = number, n.isFinite else { return nil }
        return Int(max(-2147483648.0, min(2147483647.0, n.rounded(.towardZero))))
    }
    /// A string, or null when `value` is nil.
    static func string(orNull value: String?) -> JSON { value.map(JSON.string) ?? .null }
}

extension String {
    /// ASCII lower case only, as the C client's `str_fold`: logins and label names compare this way.
    var asciiFolded: String {
        String(String.UnicodeScalarView(unicodeScalars.map { s in
            (65...90).contains(s.value) ? Unicode.Scalar(s.value + 32)! : s
        }))
    }
    /// The first character upper-cased when it is ASCII, as `str_capitalized`.
    var asciiCapitalized: String {
        guard let first = unicodeScalars.first, (97...122).contains(first.value) else { return self }
        return String(Unicode.Scalar(first.value - 32)!) + String(unicodeScalars.dropFirst())
    }
    /// Without leading and trailing spaces, tabs, line breaks, form feeds and vertical tabs, as `str_trim`.
    var cTrimmed: String {
        let space: Set<UInt32> = [0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B]
        var scalars = Substring(self).unicodeScalars[...]
        while let f = scalars.first, space.contains(f.value) { scalars = scalars.dropFirst() }
        while let l = scalars.last, space.contains(l.value) { scalars = scalars.dropLast() }
        return String(String.UnicodeScalarView(scalars))
    }
    /// Byte order, as C's `strcmp`.
    func bytesPrecede(_ other: String) -> Bool { utf8.lexicographicallyPrecedes(other.utf8) }
}

/// Logins and label names are compared folded: GitHub hands the same person back in either case. Nil reads as "".
func foldEqual(_ a: String?, _ b: String?) -> Bool { (a ?? "").asciiFolded.utf8.elementsEqual((b ?? "").asciiFolded.utf8) }

/// The array a list answer holds under `key`, or the answer itself when it is the array.
func listOf(_ answer: JSON, _ key: String) -> JSON { answer.isArray ? answer : answer[key] }

// MARK: - Projects

struct Project: Equatable, Sendable {
    var repo: String
    var label: String?

    init(repo: String, label: String? = nil) { self.repo = repo; self.label = label }
    init?(_ j: JSON) {
        guard let repo = j["repo"].string else { return nil }
        self.repo = repo; label = j["label"].string
    }
    var json: JSON { ["repo": .string(repo), "label": .string(orNull: label)] }
    /// The label when it has one, else the repository name.
    var title: String { (label ?? "").isEmpty ? repo : label! }

    /// The `projects` answer (the object or its bare array); nil when it holds no list.
    static func parseList(_ value: JSON) -> [Project]? {
        let list = value.isArray ? value : value["projects"]
        guard let items = list.array else { return nil }
        return items.compactMap(Project.init)
    }
    static func json(_ projects: [Project]) -> JSON { .array(projects.map(\.json)) }
}

// MARK: - Sessions

/// A conversation as the server sent it. The object is kept whole, so saved lists round-trip.
struct Session: Equatable, Sendable {
    var raw: JSON

    /// Needs a string id and status.
    init?(_ j: JSON) {
        guard j["id"].string != nil, j["status"].string != nil else { return nil }
        raw = j
    }
    /// Wraps any object unchecked, as the ▶ Run helpers read rows of a `sessions` answer.
    init(raw: JSON) { self.raw = raw }

    var id: String { raw["id"].string ?? "" }
    var repo: String? { raw["repo"].string }
    var status: String { raw["status"].string ?? "" }
    var model: String? { raw["model"].nonEmpty }
    var provider: String? { raw["provider"].nonEmpty }
    var displayTitle: String { raw["title"].nonEmpty ?? "New conversation" }
    var isActive: Bool { ["queued", "preparing", "running", "starting"].contains(status) }
    var liveInput: Bool { raw["liveInput"].is(true) }
    var queued: JSON { raw["queued"] }
    var reviewLoopOn: Bool { !raw["reviewLoop"].isNull }
    /// The server arms the review loop only on sessions started from scratch on a task.
    var canReviewLoop: Bool {
        if status == "closed" { return false }
        for flag in ["reviewBranch", "qaBranch", "autoClose", "loopParentId", "local", "orchestrator"] where raw[flag].isSet { return false }
        return true
    }
    /// A review round waiting for verdicts: a loop's round or a hand-started review. Nil without one.
    var heldTriage: JSON? {
        for candidate in [raw["reviewTriage"], raw["reviewLoop"]["triage"]] where !candidate.isNull && candidate["findings"].count > 0 {
            return candidate
        }
        return nil
    }
    /// The pull request this conversation works on, once it has one; nil without (the C client's 0).
    var pullNumber: Int? {
        let n = raw["prStatus"]["number"].number ?? raw["startedOnPr"].number
        guard let n, n >= 1, n.isFinite else { return nil }
        return Int(min(n, 2147483647))
    }
    /// Whether it was started on issue `number`: such a session is named by its prompt's first line, `Issue #N: title`.
    func onIssue(_ number: Int) -> Bool {
        guard let t = raw["title"].string, number >= 1 else { return false }
        return t.utf8.starts(with: "Issue #\(number):".utf8)
    }

    /// The `sessions` answer (the object or its bare array); nil when it holds no list.
    static func parseList(_ value: JSON) -> [Session]? {
        let list = value.isArray ? value : value["sessions"]
        guard let items = list.array else { return nil }
        return items.compactMap(Session.init)
    }
    static func json(_ sessions: [Session]) -> JSON { .array(sessions.map(\.raw)) }
}

// MARK: - Findings

/// A conversation holding a review round, by its index in the list it came from.
struct HeldRound: Equatable, Sendable {
    var index: Int
    var held: JSON
}

extension Session {
    /// The review round a conversation holds for a decision, as the Windows client's Findings screen queues them: a loop's round
    /// or a hand-started review, even one whose every finding was deleted. Nil without one.
    var heldRound: JSON? {
        let loop = raw["reviewLoop"]["triage"]
        if loop.isObject { return loop }
        let standalone = raw["reviewTriage"]
        // (A ternary with `nil` would read as JSON.null, since JSON is nil-literal expressible.)
        return standalone.isObject ? .some(standalone) : .none
    }
    /// The conversations holding a round, the oldest hold first, as the Windows client lists them. Equal holds keep the list's order.
    static func heldRounds(_ sessions: [Session]) -> [HeldRound] {
        func at(_ held: JSON) -> String { held["heldAt"].string ?? "" }
        var rounds: [HeldRound] = []
        for (i, s) in sessions.enumerated() {
            guard let held = s.heldRound else { continue }
            var k = rounds.count
            while k > 0, at(held).bytesPrecede(at(rounds[k - 1].held)) { k -= 1 }
            rounds.insert(HeldRound(index: i, held: held), at: k)
        }
        return rounds
    }
    /// The pull request a round is about, as a link: the conversation's own when that is the same pull request, and built
    /// from the number otherwise (a conversation that moved on to another pull request still holds this round). A round without
    /// a number has the conversation's link, or nil.
    func heldRoundPRURL(_ held: JSON) -> String? {
        let pr = raw["prStatus"]
        let heldNumber = heldRoundPRNumber(held)
        if let url = pr["url"].nonEmpty {
            if heldNumber == nil { return url }
            if let n = pr["number"].truncatedInt, n == heldNumber { return url }
        }
        guard let heldNumber else { return nil }
        return "https://github.com/\(repo ?? "")/pull/\(heldNumber)"
    }
}

/// The pull request number a round was left on; nil without one.
func heldRoundPRNumber(_ held: JSON) -> Int? {
    guard let n = held["prNumber"].number, n >= 1, n.isFinite else { return nil }
    return Int(min(n, 2147483647))
}
/// A hand-started review says whose pull request it is; a loop round is always the user's, and takes verdicts.
func heldRoundIsMine(_ held: JSON) -> Bool {
    if !held["standalone"].isSet { return true }
    return held["mine"].is(true)
}
/// What `complete_findings` answered, in the Windows client's words; `danger` is set when the verdicts led nowhere.
func triageOutcomeText(_ outcome: JSON) -> (text: String, danger: Bool) {
    if outcome["completed"].isSet {
        if let pr = outcome["prNumber"].int32, pr != 0 { return ("Review completed; what it found stays on PR #\(pr) for its author.", false) }
        return ("Review completed; what it found stays on the pull request for its author.", false)
    }
    if outcome["converged"].isSet { return ("Verdicts recorded; nothing was left to fix, so code-approved was added and the loop converged.", false) }
    if outcome["approved"].isSet { return ("Verdicts recorded; nothing was left to fix, so code-approved was added.", false) }
    if outcome["fixing"].isSet { return ("Verdicts recorded; a fix session is running.", false) }
    if outcome["reviewing"].isSet { return ("Verdicts recorded; nothing was left to fix, but the branch had moved, so the new commits are being reviewed.", false) }
    if outcome["deferred"].isSet { return ("Verdicts recorded; nothing was left to fix, but the branch had moved. The new commits are reviewed once the session settles idle.", false) }
    return ("Verdicts recorded, but no fix session started. The session\u{2019}s log says why.", true)
}
/// The Findings screen's subtitle: "nothing is waiting", or how many reviews and pull requests wait for a decision.
func findingsSubtitle(rounds: Int, pullRequests: Int) -> String {
    if rounds == 0 { return "nothing is waiting" }
    if pullRequests == rounds { return "\(rounds) review\(rounds == 1 ? "" : "s") waiting for a decision" }
    return "\(rounds) reviews on \(pullRequests) pull request\(pullRequests == 1 ? "" : "s") waiting for a decision"
}

// MARK: - Transcript

struct Event: Equatable, Sendable {
    var raw: JSON
    var seq: Int
    var kind: String
    var t: String?
    var text: String?
    var name: String?
    var summary: String?
    var question: String?
    /// The arrays as sent; nil when the field is not an array.
    var options: JSON?
    var attachments: JSON?
    var costUsd: Double?
    var durationMs: Double?
    /// Nil when unset (the C client's -1).
    var isError: Bool?

    /// Needs a string kind and a numeric sequence.
    init?(_ j: JSON) {
        guard let kind = j["kind"].string, let seq = j["seq"].truncatedInt else { return nil }
        raw = j; self.seq = seq; self.kind = kind
        t = j["t"].string; text = j["text"].string; name = j["name"].string
        summary = j["summary"].string; question = j["question"].string
        options = j["options"].isArray ? .some(j["options"]) : .none
        attachments = j["attachments"].isArray ? .some(j["attachments"]) : .none
        costUsd = j["costUsd"].number; durationMs = j["durationMs"].number
        isError = j["isError"].bool
    }
    /// Tool events carry their detail in `summary`; other kinds use `text`.
    var detail: String? { text ?? summary }
    /// Status and workspace setup output are server plumbing, not part of the conversation.
    var isVisible: Bool {
        if kind == "status" { return false }
        return text != nil || question != nil || kind == "tool" || kind == "tool_error" || kind == "result"
    }
    /// When the server logged it; nil without a readable time.
    var time: Date? { boardDateParse(t) }
}

/// Cursor and transcript have one lifetime: saved events restore both, and an empty transcript starts at zero.
struct Transcript: Equatable, Sendable {
    private(set) var events: [Event] = []
    private(set) var cursor = 0

    init() {}
    /// Appends every event of a JSON array not already held (the first copy of a sequence wins), sorted by sequence,
    /// and advances the cursor. Anything that is not an array adds nothing.
    mutating func append(_ value: JSON) {
        var seen = Set(events.map(\.seq))
        var added = false
        for item in value.items {
            guard let e = Event(item), !seen.contains(e.seq) else { continue }
            seen.insert(e.seq); events.append(e); added = true
        }
        if added { events.sort { $0.seq < $1.seq } }
        let last = events.last?.seq ?? 0
        if last > cursor { cursor = last }
    }
    var json: JSON { .array(events.map(\.raw)) }
}

// MARK: - Dates

/// GitHub's timestamps come with and without fractional seconds; seconds since 1970, UTC. Nil when unreadable.
func boardDateEpoch(_ value: String?) -> Int? {
    guard let value else { return nil }
    let p = Array(value.utf8)
    var i = 0
    func at(_ k: Int) -> UInt8 { k < p.count ? p[k] : 0 }
    func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    func digits(_ count: Int) -> Int? {
        var v = 0
        for k in 0..<count {
            let c = at(i + k)
            guard isDigit(c) else { return nil }
            v = v * 10 + Int(c - 48)
        }
        i += count
        return v
    }
    func take(_ c: Character) -> Bool { let ok = at(i) == c.asciiValue!; i += 1; return ok }

    guard let y = digits(4), take("-"), let mo = digits(2), take("-"), let d = digits(2) else { return nil }
    guard at(i) == UInt8(ascii: "T") || at(i) == UInt8(ascii: "t") || at(i) == UInt8(ascii: " ") else { return nil }
    i += 1
    guard let h = digits(2), take(":"), let mi = digits(2) else { return nil }
    var s = 0
    if at(i) == UInt8(ascii: ":") { i += 1; guard let v = digits(2) else { return nil }; s = v }
    if at(i) == UInt8(ascii: ".") || at(i) == UInt8(ascii: ",") {
        i += 1
        guard isDigit(at(i)) else { return nil }
        while isDigit(at(i)) { i += 1 }
    }
    var offset = 0
    if at(i) == UInt8(ascii: "Z") || at(i) == UInt8(ascii: "z") { i += 1 }
    else if at(i) == UInt8(ascii: "+") || at(i) == UInt8(ascii: "-") {
        let sign = at(i) == UInt8(ascii: "-") ? -1 : 1
        i += 1
        guard let oh = digits(2) else { return nil }
        var om = 0
        if at(i) == UInt8(ascii: ":") { i += 1 }
        if isDigit(at(i)) { guard let v = digits(2) else { return nil }; om = v }
        offset = sign * (oh * 3600 + om * 60)
    } else { return nil }
    guard i == p.count else { return nil }
    guard (1...12).contains(mo), (1...31).contains(d), h <= 23, mi <= 59, s <= 60 else { return nil }
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset
}
/// GitHub's timestamps come with and without fractional seconds. UTC; the fraction is dropped. Nil when unreadable.
func boardDateParse(_ value: String?) -> Date? { boardDateEpoch(value).map { Date(timeIntervalSince1970: TimeInterval($0)) } }

private func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
    let y = year - (m <= 2 ? 1 : 0)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}
