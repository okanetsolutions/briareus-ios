// The 📊 Usage screen's numbers and words, as the Windows client puts them: the usage
// ledger's totals, its buckets, its breakdowns and the window and filters a reading is narrowed by.
import Foundation

enum Usage {
    // MARK: Numbers

    static func num(_ u: JSON, _ key: String) -> Double { u[key].number ?? 0 }
    static func count(_ u: JSON, _ key: String) -> Int { u[key].truncatedInt ?? 0 }
    static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    /// fmtTokens: "21599.7M", "80.5M", "93.0k", "999".
    static func tokens(_ n: Double) -> String {
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1000 { return String(format: "%.1fk", n / 1000) }
        return String(format: "%.0f", n)
    }
    /// fmtCost: one price, and a `+` when some turns carry none, so the total is a floor. Nil when nothing was priced.
    static func cost(_ u: JSON, _ key: String = "costUsd") -> String? {
        guard let usd = u[key].number else { return nil }
        return formatCost(usd) + (count(u, "unpricedTurns") != 0 ? "+" : "")
    }
    static func costOrDash(_ u: JSON) -> String { cost(u) ?? "\u{2014}" }
    static func costNote(_ u: JSON) -> String {
        let unpriced = count(u, "unpricedTurns"), turns = count(u, "turns")
        if unpriced != 0 { return "\(unpriced) of \(turns) turn\(plural(turns)) could not be priced" }
        return u["costUsd"].isNull ? "no turn carries a price" : "every turn priced"
    }
    static func durationOrDash(_ ms: Double) -> String { ms > 0 ? formatDurationMs(ms) : "\u{2014}" }

    // MARK: Dates

    private static func date(_ key: String?, needDay: Bool) -> (Date, Bool)? {
        guard let key else { return nil }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1].prefix(2)), (1...12).contains(m) else { return nil }
        var d = 1
        if needDay, parts.count >= 3, let day = Int(parts[2].prefix(2)) { d = day == 0 ? 1 : day }
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let when = cal.date(from: c) else { return nil }
        return (when, true)
    }
    private static func format(_ when: Date, _ pattern: String, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale; f.timeZone = TimeZone(identifier: "UTC"); f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = pattern
        return f.string(from: when)
    }
    /// "2026-08" or "2026-08-03" as the axis names it: "Aug 2026", "Aug 3".
    static func bucketName(_ key: String?, month: Bool, locale: Locale = .current) -> String {
        guard let (when, _) = date(key, needDay: true) else { return key ?? "" }
        return format(when, month ? "MMM yyyy" : "MMM d", locale)
    }
    /// "August 2026".
    static func monthName(_ key: String?, locale: Locale = .current) -> String {
        guard let (when, _) = date(key, needDay: false) else { return key ?? "" }
        return format(when, "MMMM yyyy", locale)
    }

    // MARK: Windows

    static let periods: [(id: String, label: String)] = [
        ("month", "This month"), ("prev", "Last month"), ("all", "All time"),
        ("today", "Today"), ("7d", "Last 7 days"), ("30d", "Last 30 days"),
    ]
    /// What the window is called: the server's month by its own calendar, all time, or the span of its buckets.
    static func windowName(_ u: JSON, periodLabel: String, locale: Locale = .current) -> String {
        let period = u["period"].string
        if period == "all" { return "all time" }
        if period == "month" || period == "prev" { return monthName(u["month"].string, locale: locale) }
        let buckets = u["buckets"].items
        guard let first = buckets.first, let last = buckets.last else { return periodLabel }
        let a = bucketName(first["date"].string, month: false, locale: locale), b = bucketName(last["date"].string, month: false, locale: locale)
        return a == b ? a : "\(a) \u{2013} \(b)"
    }

    // MARK: Labels

    /// The Windows client's ACTIVITY_LABELS: what each kind of session is called on its row.
    static let activities: [(id: String, label: String)] = [
        ("chat", "💬 Chat"), ("preview", "▶ Run"), ("code-review", "⌕ Code review"),
        ("issue", "▶ Issue"), ("qa", "🔍 QA"), ("orchestrator", "🧭 Orchestrator"),
        ("worker", "👷 Worker"), ("zeus", "⚡ Zeus"), ("analyst", "🔬 Analyst"),
        ("pr-body-summary", "✎ PR body summary"), ("test-sheet", "📋 Test sheet"),
        ("test-run", "🎬 Test run"), ("solve-conflicts", "🔀 Solve conflicts"),
        ("fix-checks", "🧪 Fix failing checks"), ("implement-feedback", "🛠 Implement feedback"),
        ("custom-feedback", "✍ Give feedback"), ("delete-self-comments", "🧹 Delete my comments"),
    ]
    static func activityLabel(_ id: String?) -> String {
        guard let id, !id.isEmpty, id != "unknown" else { return "Unattributed" }
        return activities.first { $0.id == id }?.label ?? id
    }
    static func modelLabel(_ m: JSON) -> String {
        let model = m["model"].nonEmpty ?? "unknown"
        if let provider = m["provider"].nonEmpty { return "\(model) (\(provider))" }
        return model
    }

    // MARK: Filters

    enum Filter: Int, CaseIterable {
        case project, model, activity, provider, account, session
        var param: String { ["project", "model", "activity", "provider", "account", "session"][rawValue] }
        var plural: String { ["projects", "models", "activities", "providers", "accounts", "sessions"][rawValue] }
        /// The key of `options` its choices are listed under.
        var options: String { plural }
        /// The project and model pickers tick several; the others take one.
        var multi: Bool { self == .project || self == .model }
        /// The list of the payload a breakdown row of it is in.
        var rows: String { self == .project ? "projects" : self == .activity ? "activities" : self == .provider ? "providers" : "models" }
    }
    static func optionKey(_ o: JSON) -> String { o["key"].string ?? "" }
    static func optionLabel(_ f: Filter, _ o: JSON) -> String {
        if f == .model { return modelLabel(o) }
        let label = o["label"].nonEmpty
        if f == .activity { return activityLabel(optionKey(o)) }
        if f == .project && o["gone"].is(true) { return "\(label ?? optionKey(o)) (removed)" }
        return label ?? optionKey(o)
    }
    /// The key a breakdown row filters by.
    static func rowKey(_ f: Filter, _ r: JSON) -> String {
        switch f {
        case .activity: return r["activity"].nonEmpty ?? "unknown"
        case .provider: return r["provider"].nonEmpty ?? "unknown"
        default: return optionKey(r)
        }
    }

    // MARK: Rings

    /// shareSeries: the first four rows that spent get a colour slot each (0–3), every other row that spent is summed into
    /// Other (slot 4), and under three slices there is no ring at all. `slots` is each row's slot, nil for none.
    struct Ring: Equatable {
        var slices: [(share: Double, slot: Int)]
        var slots: [Int?]
        static func == (a: Ring, b: Ring) -> Bool {
            a.slots == b.slots && a.slices.map(\.share) == b.slices.map(\.share) && a.slices.map(\.slot) == b.slices.map(\.slot)
        }
    }
    static let seriesSlots = 4
    static func shareSeries(_ rows: [JSON]) -> Ring? {
        let total = rows.reduce(0) { $0 + num($1, "totalTokens") }
        guard total > 0 else { return nil }
        var slots = [Int?](repeating: nil, count: rows.count)
        var slices: [(share: Double, slot: Int)] = []
        var spent = 0, tail = 0.0
        for (i, r) in rows.enumerated() {
            let t = num(r, "totalTokens")
            guard t > 0 else { continue }
            if spent < seriesSlots { slots[i] = spent; slices.append((t / total, spent)) } else { slots[i] = seriesSlots; tail += t }
            spent += 1
        }
        if tail > 0 { slices.append((tail / total, seriesSlots)) }
        guard slices.count >= 3 else { return nil }
        return Ring(slices: slices, slots: slots)
    }

    // MARK: Bars

    /// The buckets the server's calendar has reached: none after `today` (its month for a monthly chart).
    static func visibleBuckets(_ u: JSON) -> [JSON] {
        let month = u["unit"].string == "month"
        var ahead = u["today"].string ?? ""
        if month { ahead = String(ahead.prefix(7)) }
        return u["buckets"].items.filter { b in
            guard !ahead.isEmpty, let d = b["date"].string else { return true }
            return !ahead.bytesPrecede(d)
        }
    }
    /// What hovering a column says: "Aug 3: 1.2M tok · 4 turns · $1.20", or "no usage".
    static func barTip(_ b: JSON, month: Bool, locale: Locale = .current) -> String {
        let name = bucketName(b["date"].string, month: month, locale: locale)
        let turns = count(b, "turns")
        guard turns != 0 else { return "\(name): no usage" }
        var s = "\(name): \(tokens(num(b, "totalTokens"))) tok \u{00B7} \(turns) turn\(plural(turns))"
        if let c = cost(b) { s += " \u{00B7} \(c)" }
        return s
    }

    // MARK: Insights

    /// "$1.23" (and a `+` when some turns are unpriced) of an insight, or a dash.
    static func insightCost(_ u: JSON, _ key: String) -> String {
        guard let v = u["insights"][key].number else { return "\u{2014}" }
        return formatCost(v) + (count(u, "unpricedTurns") != 0 ? "+" : "")
    }
    static func pricingCoverage(_ u: JSON) -> (value: String, sub: String) {
        let turns = count(u, "turns"), priced = turns - count(u, "unpricedTurns")
        let pct = turns != 0 ? Int(Double(priced) * 100.0 / Double(turns) + 0.5) : 0
        return ("\(pct)%", "\(priced) of \(turns) turns priced")
    }
    /// How the window compares with the one before; nil without a comparison.
    static func comparisonLine(_ u: JSON, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        let prev = u["comparison"]
        guard prev.isObject else { return nil }
        let from = num(prev, "from"), to = num(prev, "to")
        let a = formatDateAbbrev(Date(timeIntervalSince1970: (from / 1000).rounded(.towardZero)), locale: locale, timeZone: timeZone)
        let b = formatDateAbbrev(Date(timeIntervalSince1970: ((to - 1) / 1000).rounded(.towardZero)), locale: locale, timeZone: timeZone)
        var line = "Compared with \(a) \u{2013} \(b)\(prev["partial"].is(true) ? " (matching elapsed time)" : ""): "
        let keys = ["costUsd", "totalTokens", "sessions"], names = ["Cost", "Tokens", "Sessions"]
        for k in 0..<3 {
            if k > 0 { line += " \u{00B7} " }
            guard let old = prev[keys[k]].number, let now = u[keys[k]].number else { line += "\(names[k]): unavailable"; continue }
            if old == 0 { line += "\(names[k]): \(now != 0 ? "new usage (previously zero)" : "unchanged")"; continue }
            let pct = (now - old) / old * 100
            line += "\(names[k]): \(pct > 0 ? "+" : "")\(String(format: "%.1f", pct))%"
        }
        if count(u, "unpricedTurns") != 0 || count(prev, "unpricedTurns") != 0 { line += " \u{00B7} cost comparison is partial" }
        return line
    }
}

/// The window and the picks a reading is narrowed by.
struct UsageQuery: Equatable {
    var period = 0
    var picks: [Usage.Filter: [String]] = [:]

    var periodID: String { Usage.periods[period].id }
    var periodLabel: String { Usage.periods[period].label }
    var anyPick: Bool { picks.values.contains { !$0.isEmpty } }
    func picked(_ f: Usage.Filter) -> [String] { picks[f] ?? [] }
    func isPicked(_ f: Usage.Filter, _ key: String) -> Bool { picked(f).contains(key) }

    mutating func clear(_ f: Usage.Filter) { picks[f] = nil }
    mutating func clearAll() { picks = [:] }
    /// A picker's choice: the multi pickers toggle it; the others take it alone. False when nothing changed.
    @discardableResult
    mutating func choose(_ f: Usage.Filter, _ key: String) -> Bool {
        var list = picked(f)
        if f.multi {
            if let i = list.firstIndex(of: key) { list.remove(at: i) } else { list.append(key) }
        } else {
            if list.contains(key) { return false }
            list = [key]
        }
        picks[f] = list.isEmpty ? nil : list
        return true
    }
    /// A breakdown row's pick: the same one twice comes back out, so a row is a toggle.
    mutating func only(_ f: Usage.Filter, _ key: String) {
        let same = picked(f) == [key]
        picks[f] = same ? nil : [key]
    }

    /// The arguments of `usage_all`: the window, and each pick (an array for the pickers that take several).
    var args: JSON {
        var a: JSON = ["period": .string(periodID)]
        for f in Usage.Filter.allCases {
            let list = picked(f)
            guard let first = list.first else { continue }
            a[f.param] = f.multi ? JSON(list) : .string(first)
        }
        return a
    }
    var key: String { args.serialized() }

    /// What a pick is called: whatever the options call it now, else its key.
    func pickLabel(_ f: Usage.Filter, _ key: String, options: JSON) -> String {
        if let o = options[f.options].items.first(where: { Usage.optionKey($0) == key }) { return Usage.optionLabel(f, o) }
        return f == .activity ? Usage.activityLabel(key) : key
    }
    func picksLabel(_ f: Usage.Filter, options: JSON) -> String {
        picked(f).map { pickLabel(f, $0, options: options) }.joined(separator: ", ")
    }
    /// "All projects ▾", "2 models ▾" or the pick's name.
    func buttonText(_ f: Usage.Filter, options: JSON) -> String {
        let n = picked(f).count
        if n == 0 { return "All \(f.plural) \u{25BE}" }
        if f.multi && n > 1 { return "\(n) \(f.plural) \u{25BE}" }
        return "\(picksLabel(f, options: options)) \u{25BE}"
    }
    /// The header's subtitle: the window, then each filter, or how many projects ran, then the turns.
    func subtitle(_ u: JSON, options: JSON, locale: Locale = .current) -> String {
        var s = Usage.windowName(u, periodLabel: periodLabel, locale: locale)
        var picked = false
        for f in Usage.Filter.allCases where !self.picked(f).isEmpty {
            s += " \u{00B7} only \(picksLabel(f, options: options))"
            picked = true
        }
        if !picked {
            let active = u["projects"].items.filter { Usage.count($0, "turns") != 0 }.count
            s += " \u{00B7} \(active) project\(Usage.plural(active)) with usage"
        }
        let turns = Usage.count(u, "turns")
        s += " \u{00B7} \(turns) turn\(Usage.plural(turns))"
        return s
    }
}
