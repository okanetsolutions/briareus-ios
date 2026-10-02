// The Usage tab: what the projects spent over a window, as the Mac's 📊 Usage screen draws it from the usage ledger. An Admin
// token reads every project at once (`GET /usage/all`) over any window, narrowed by six filters, with insights and the
// costliest sessions; any other token reads each of its projects' own month (`GET /usage`), added up here. The totals
// are tiles, tokens and cost per day are bars, and each breakdown is a list of rows with a ring of its share of tokens;
// a row is a filter.
import Charts
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    /// The window is a preference, kept while the app runs; the filters are not, so a fresh visit shows everything.
    private static var period = 0

    @Published var query = UsageQuery(period: UsageModel.period)
    /// The `usage/all` payload on screen, and the query it answered: a pick shows the loader until its own answer lands.
    @Published private(set) var data: JSON?
    private var dataKey: String?
    /// What the pickers offer, from the last payload: the whole window's, never the pick's.
    @Published private(set) var options: JSON?
    /// Each project's own month, by repository, for a token without `usage/all`.
    @Published private(set) var perProject: [String: JSON] = [:]
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var generation = 0

    private var store: Store { Store.shared }
    /// Whether the token reads every project's ledger at once.
    var overall: Bool { store.supports("usage_all") }
    var available: Bool { overall || store.supports("usage") }

    init() { restore() }

    /// The payload drawn: the answer to the current window and picks, or the projects' months added up.
    var shown: JSON? {
        if overall { return data != nil && dataKey == query.key ? data : nil }
        let picked = query.picked(.project)
        let rows = ProjectsModel.shared.projects.compactMap { p -> (project: Project, usage: JSON)? in
            guard picked.isEmpty || picked.contains(p.repo), let u = perProject[p.repo] else { return nil }
            return (p, u)
        }
        return rows.isEmpty && perProject.isEmpty ? nil : PhoneUsage.combine(rows)
    }
    /// The picker's choices: the window's, or the projects this token reads.
    var pickerOptions: JSON {
        if overall { return options ?? .null }
        return ["projects": .array(ProjectsModel.shared.projects.map { ["key": .string($0.repo), "label": .string($0.title)] })]
    }
    var filters: [Usage.Filter] { overall ? Usage.Filter.allCases : [.project] }

    private func restore() {
        if overall {
            guard let saved = store.cache.value("usage:\(query.periodID)"), saved.isObject else { return }
            data = saved; dataKey = query.key
            if saved["options"].isObject { options = saved["options"] }
        } else {
            for p in ProjectsModel.shared.projects {
                if let saved = store.cache.value("usage:project:\(p.repo)"), saved.isObject { perProject[p.repo] = saved }
            }
        }
    }

    func load() async -> APIError? {
        guard available else { return nil }
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            if overall { try await loadOverall(gen) } else { try await loadProjects(gen) }
            if gen == generation { error = nil }
            return nil
        } catch {
            guard gen == generation, !error.isCancellation else { return nil }
            self.error = errorText(error)
            return error as? APIError ?? APIError(.nonJSON)
        }
    }
    private func loadOverall(_ gen: Int) async throws {
        let args = query.args, key = query.key, picked = query.anyPick, period = query.periodID
        let answer = try await store.call("usage_all", args, timeout: 60)
        guard gen == generation else { return }
        guard answer.isObject else { throw APIError(.nonJSON) }
        data = answer; dataKey = key
        if answer["options"].isObject { options = answer["options"] }
        if !picked { store.cache.store(answer, "usage:\(period)") }
    }
    /// Every project's month at once; a project that fails keeps what was read of it before, and its error is shown.
    private func loadProjects(_ gen: Int) async throws {
        if !ProjectsModel.shared.loaded || ProjectsModel.shared.projects.isEmpty { try await ProjectsModel.shared.load() }
        let repos = ProjectsModel.shared.projects.map(\.repo)
        var failure: Error?
        let answers = await withTaskGroup(of: (String, Result<JSON, Error>).self) { group in
            for repo in repos {
                group.addTask { @MainActor in
                    do { return (repo, .success(try await Store.shared.call("usage", ["repo": .string(repo)], timeout: 60))) }
                    catch { return (repo, .failure(error)) }
                }
            }
            var out: [(String, Result<JSON, Error>)] = []
            for await a in group { out.append(a) }
            return out
        }
        guard gen == generation else { return }
        var next = perProject.filter { repos.contains($0.key) }
        for (repo, result) in answers {
            switch result {
            case .success(let u) where u.isObject:
                next[repo] = u
                store.cache.store(u, "usage:project:\(repo)")
            case .success: failure = failure ?? APIError(.nonJSON)
            case .failure(let e): failure = failure ?? e
            }
        }
        perProject = next
        if let failure { throw failure }
    }

    /// A new window or pick: straight to the loader, so the page never reads as the old pick's, and ask again.
    func repick() {
        error = nil
        if overall { Task { _ = await load() } }
    }
    func setPeriod(_ p: Int) {
        guard p != query.period, Usage.periods.indices.contains(p) else { return }
        UsageModel.period = p
        query.period = p
        repick()
    }
    func choose(_ f: Usage.Filter, _ key: String?) {
        if let key { guard query.choose(f, key) else { return } }
        else { guard !query.picked(f).isEmpty else { return }; query.clear(f) }
        repick()
    }
    func clearFilters() { query.clearAll(); repick() }
    func pickRow(_ f: Usage.Filter, _ row: JSON) { query.only(f, Usage.rowKey(f, row)); repick() }
    /// The ledger knows a session's id, title and project; the conversation reads the rest itself.
    func topSession(_ r: JSON) -> (id: String, raw: JSON)? {
        guard let id = r["key"].nonEmpty else { return nil }
        var raw: JSON = ["id": .string(id), "status": "idle", "repo": .string(orNull: r["repo"].string)]
        if let label = r["label"].nonEmpty, label != id { raw["title"] = .string(label) }
        return (id, raw)
    }
}

struct UsageScreen: View {
    @StateObject private var model = UsageModel()
    @ObservedObject private var store = Store.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @Environment(\.navigate) private var navigate

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Usage")
            .toolbar { toolbar }
            .refreshable { _ = await model.load() }
            .task { await poll(every: 60) { await model.load() } }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.available {
            ToolbarItem(placement: .topBarTrailing) {
                if model.overall {
                    Menu {
                        Picker("Window", selection: Binding(get: { model.query.period }, set: { model.setPeriod($0) })) {
                            ForEach(Usage.periods.indices, id: \.self) { Text(Usage.periods[$0].label).tag($0) }
                        }
                    } label: {
                        Label(model.query.periodLabel, systemImage: "calendar")
                    }
                    .accessibilityLabel("Window: \(model.query.periodLabel)")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
    }

    /// One submenu per filter: All, then the window's choices; the project and model pickers tick several.
    private var filterMenu: some View {
        let options = model.pickerOptions
        return Menu {
            ForEach(model.filters, id: \.self) { f in
                let list = options[f.options].items
                Menu(f.plural.asciiCapitalized) {
                    Button { model.choose(f, nil) } label: { check("All \(f.plural)", model.query.picked(f).isEmpty) }
                    let cap = 60   // the window's sessions can run to thousands
                    ForEach(Array(list.prefix(cap).enumerated()), id: \.offset) { _, o in
                        let key = Usage.optionKey(o)
                        Button { model.choose(f, key) } label: { check(Usage.optionLabel(f, o), model.query.isPicked(f, key)) }
                    }
                    if list.count > cap { Text("\(list.count - cap) more \(f.plural); a shorter window lists them") }
                    if list.isEmpty { Text("No usage in this period") }
                }
            }
            if model.query.anyPick {
                Divider()
                Button(role: .destructive) { model.clearFilters() } label: { Label("Clear filters", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: model.query.anyPick ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(model.query.anyPick ? "Filters, some on" : "Filters")
    }
    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    @ViewBuilder private var content: some View {
        if !model.available {
            Text(adminNeeded).font(.callout).foregroundStyle(.secondary).listRowBackground(Theme.row)
        } else if let u = model.shown {
            page(u)
        } else if let error = model.error {
            ErrorNotice(message: error).listRowBackground(Theme.row)
        } else {
            ProgressView("Loading the usage ledger…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
        }
    }

    private var adminNeeded: String {
        "This server does not offer the usage ledger to this device. An Admin token reads every project's spend; issue one on the server with `npm run create-token`."
    }

    @ViewBuilder private func page(_ u: JSON) -> some View {
        let options = model.pickerOptions
        Section {
            if model.query.anyPick {
                ForEach(model.filters.filter { !model.query.picked($0).isEmpty }, id: \.self) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.plural.asciiCapitalized).font(.caption).foregroundStyle(.secondary)
                            Text(model.query.picksLabel(f, options: options)).font(.subheadline).lineLimit(2)
                        }
                        Spacer()
                        Button { model.choose(f, nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear the \(f.plural) filter")
                    }
                    .listRowBackground(Theme.row)
                }
            }
            if let error = model.error { ErrorNotice(message: error).listRowBackground(Theme.row) }
        } header: {
            Text(model.query.subtitle(u, options: options)).textCase(nil)
        } footer: {
            if !model.overall {
                Text("This device reads each of its projects' own spend, this month. An Admin token shows every window, filter and the costliest sessions.")
            }
        }
        if Usage.count(u, "turns") == 0 {
            Section {
                Text(verbatim: "No usage recorded in \(Usage.windowName(u, periodLabel: model.query.periodLabel))\(model.query.anyPick ? " for these filters" : "").")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                    .listRowBackground(Color.clear)
            }
            insights(u)
            projectSection(u)
        } else {
            let month = u["unit"].string == "month"
            Section {
                UsageTiles(tiles: [
                    ("Cost", Usage.costOrDash(u), Usage.costNote(u)),
                    ("Tokens", Usage.tokens(Usage.num(u, "totalTokens")),
                     "\(Usage.tokens(Usage.num(u, "inputTokens"))) in · \(Usage.tokens(Usage.num(u, "outputTokens"))) out"),
                    ("Sessions", "\(Usage.count(u, "sessions"))", "\(Usage.count(u, "turns")) turn\(Usage.plural(Usage.count(u, "turns")))"),
                    ("Agent time", Usage.durationOrDash(Usage.num(u, "durationMs")), "summed over every turn"),
                ])
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if UsageBars.plots(u, "totalTokens") {
                Section(month ? "Tokens per month" : "Tokens per day") {
                    UsageBars(u: u, metric: "totalTokens").listRowBackground(Theme.row)
                }
            }
            insights(u)
            projectSection(u)
            breakdown(u, .activity)
            breakdown(u, .provider)
            breakdown(u, .model)
        }
    }

    /// The averages, how the window compares with the one before, cost per bucket and the costliest sessions (`usage/all` only).
    @ViewBuilder private func insights(_ u: JSON) -> some View {
        if model.overall {
            let ins = u["insights"]
            let coverage = Usage.pricingCoverage(u)
            let month = u["unit"].string == "month"
            Section {
                UsageTiles(tiles: [
                    ("Cost / session", Usage.insightCost(u, "costPerSession"), "within this selection"),
                    ("Cost / turn", Usage.insightCost(u, "costPerTurn"), "within this selection"),
                    ("Average turn", ins["averageDurationMs"].number.map(formatDurationMs) ?? "—", "\(Usage.count(ins, "timedTurns")) turns with timing"),
                    ("Pricing coverage", coverage.value, coverage.sub),
                ])
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } footer: {
                if let line = Usage.comparisonLine(u) { Text(line) }
            }
            Section(month ? "Cost per month" : "Cost per day") {
                if UsageBars.plots(u, "costUsd") { UsageBars(u: u, metric: "costUsd").listRowBackground(Theme.row) }
                else { Text("No priced spend to plot in this selection.").font(.callout).foregroundStyle(.secondary).listRowBackground(Theme.row) }
            }
            let top = u["topSessions"].items
            if !top.isEmpty {
                Section {
                    ForEach(Array(top.enumerated()), id: \.offset) { _, r in topRow(r) }
                } header: {
                    Text("Most expensive sessions")
                } footer: {
                    Text("Top 10 by known cost. Deleted sessions keep their usage but cannot be reopened.")
                }
            }
        }
    }

    private func topRow(_ r: JSON) -> some View {
        let label = r["label"].nonEmpty ?? Usage.optionKey(r)
        let line = VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer(minLength: 8)
                Text(Usage.costOrDash(r)).font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Text([r["repo"].nonEmpty.map { projects.project($0)?.title ?? $0 },
                  "\(Usage.count(r, "turns")) turn\(Usage.plural(Usage.count(r, "turns")))",
                  "\(Usage.tokens(Usage.num(r, "totalTokens"))) tok"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        return Group {
            if let open = model.topSession(r) {
                Button { navigate(.conversation(id: open.id, session: open.raw)) } label: {
                    line.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the conversation")
            } else { line }
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Breakdowns

    @ViewBuilder private func projectSection(_ u: JSON) -> some View {
        let rows = u["projects"].items
        if !rows.isEmpty {
            let ring = Usage.shareSeries(rows)
            let busiest = max(1, rows.map { Usage.num($0, "totalTokens") }.max() ?? 1)
            Section("By project") {
                if let ring { UsageRing(ring: ring).listRowBackground(Theme.row) }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, p in
                    let label = p["label"].nonEmpty ?? "unknown"
                    let gone = p["gone"].is(true)
                    // A project that ran nothing, or one no longer in Settings, is greyed out; it still adds up into the totals.
                    breakdownRow(gone ? "\(label) (removed)" : label, p, dim: gone || Usage.count(p, "turns") == 0,
                                 swatch: nil, bar: (Usage.num(p, "totalTokens") / busiest, ring?.slots[i].map(usageSeriesColor) ?? Theme.accent),
                                 on: model.query.isPicked(.project, Usage.optionKey(p))) { model.pickRow(.project, p) }
                }
            }
        }
    }

    @ViewBuilder private func breakdown(_ u: JSON, _ f: Usage.Filter) -> some View {
        let rows = u[f.rows].items
        if !rows.isEmpty {
            let ring = Usage.shareSeries(rows)
            Section(f == .activity ? "By activity" : f == .provider ? "By provider" : "By model") {
                if let ring { UsageRing(ring: ring).listRowBackground(Theme.row) }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    let (name, dim) = breakdownName(f, r)
                    breakdownRow(name, r, dim: dim, swatch: ring?.slots[i].map(usageSeriesColor), bar: nil,
                                 on: model.query.isPicked(f, Usage.rowKey(f, r)),
                                 pick: model.overall ? { model.pickRow(f, r) } : nil)
                }
            }
        }
    }
    private func breakdownName(_ f: Usage.Filter, _ r: JSON) -> (String, Bool) {
        switch f {
        case .activity:
            let a = r["activity"].nonEmpty
            return (Usage.activityLabel(a ?? "unknown"), a == nil)
        case .provider:
            let p = r["provider"].nonEmpty
            return (p ?? "unknown", p == nil)
        default:
            return (Usage.modelLabel(r), r["model"].nonEmpty == nil)
        }
    }

    /// A breakdown row: its name (with its slice's swatch), the cost and tokens on the right, the counts under it, and on the
    /// project rows a bar of its share of the busiest. Tapping it filters by it; tapping it again clears that.
    private func breakdownRow(_ name: String, _ r: JSON, dim: Bool, swatch: Color?, bar: (Double, Color)?, on: Bool,
                              pick: (() -> Void)?) -> some View {
        let line = VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 9, height: 9) }
                Text(name).font(.subheadline.weight(.medium)).foregroundStyle(dim ? .secondary : .primary).lineLimit(2)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Usage.costOrDash(r)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(dim ? .secondary : .primary)
                    Text("\(Usage.tokens(Usage.num(r, "totalTokens"))) tok").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if on { Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Filtered by this") }
            }
            if let bar {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface)
                        if bar.0 > 0 { Capsule().fill(bar.1).frame(width: max(g.size.width * bar.0, 6)) }
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            Text(counts(r)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        return Group {
            if let pick {
                Button(action: pick) { line.contentShape(Rectangle()) }.buttonStyle(.plain)
                    .accessibilityHint(on ? "Clears this filter" : "Shows only this")
            } else { line }
        }
        .listRowBackground(on ? Theme.row(selected: true) : Theme.row)
    }
    private func counts(_ u: JSON) -> String {
        let s = Usage.count(u, "sessions"), t = Usage.count(u, "turns")
        return "\(s) session\(Usage.plural(s)) · \(t) turn\(Usage.plural(t)) · \(Usage.tokens(Usage.num(u, "inputTokens"))) in / \(Usage.tokens(Usage.num(u, "outputTokens"))) out · \(Usage.durationOrDash(Usage.num(u, "durationMs")))"
    }
}

// MARK: - Pieces

/// The categorical series colours, the only place a hue means which one: four slots and the tail's grey.
private func usageSeriesColor(_ slot: Int) -> Color {
    let hex: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0x807B71]
    let h = hex[min(max(slot, 0), Usage.seriesSlots)]
    return Color(light: h, dark: h)
}

/// Stat tiles two across: the label, the figure, and the line under it.
private struct UsageTiles: View {
    var tiles: [(label: String, value: String, sub: String)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(t.value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                    Text(t.sub).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One bar per bucket the server's calendar has reached; touching a bar names it above the chart.
private struct UsageBars: View {
    var u: JSON
    var metric: String
    @State private var selected: Date?

    static func plots(_ u: JSON, _ metric: String) -> Bool {
        Usage.visibleBuckets(u).contains { Usage.num($0, metric) > 0 }
    }

    var body: some View {
        let month = u["unit"].string == "month"
        let points = Usage.visibleBuckets(u).compactMap { b -> (date: Date, value: Double, bucket: JSON)? in
            PhoneUsage.bucketDate(b["date"].string).map { ($0, Usage.num(b, metric), b) }
        }
        let unit: Calendar.Component = month ? .month : .day
        let picked = selected.flatMap { s in points.first { Calendar.current.isDate($0.date, equalTo: s, toGranularity: unit) } }
        VStack(alignment: .leading, spacing: 8) {
            Text(picked.map { Usage.barTip($0.bucket, month: month) } ?? "Touch a bar for its figures")
                .font(.caption).foregroundStyle(picked == nil ? .secondary : .primary).lineLimit(1)
            Chart(points, id: \.date) { p in
                BarMark(x: .value(month ? "Month" : "Day", p.date, unit: unit), y: .value(metric == "costUsd" ? "Cost" : "Tokens", p.value))
                    .foregroundStyle(picked == nil || picked?.date == p.date ? Theme.accent : Theme.accent.opacity(0.35))
                    .cornerRadius(3)
            }
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(metric == "costUsd" ? formatCost(d) : Usage.tokens(d)) } }
                }
            }
            .chartXAxis {
                // A label on the buckets themselves, at most six: automatic ticks on a short window fall between
                // days and repeat each one's name.
                AxisMarks(values: stride(from: 0, to: points.count, by: max(1, (points.count + 5) / 6)).map { points[$0].date }) { _ in
                    AxisValueLabel(format: month ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 160)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric == "costUsd" ? "Cost over time" : "Tokens over time")
        .accessibilityValue(points.map { Usage.barTip($0.bucket, month: month) }.joined(separator: ", "))
    }
}

/// The ring of each row's share of the tokens.
private struct UsageRing: View {
    var ring: Usage.Ring
    var body: some View {
        VStack(spacing: 6) {
            Chart(Array(ring.slices.enumerated()), id: \.offset) { _, s in
                SectorMark(angle: .value("Share", s.share), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .foregroundStyle(usageSeriesColor(s.slot))
            }
            .frame(width: 120, height: 120)
            Text("share of tokens").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}
