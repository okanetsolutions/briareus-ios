// The 📊 Dashboard: what every project spent over a window, as the web dashboard's home pane draws it from the usage
// ledger (`GET /usage/all`). The totals as tiles, tokens and cost per day or month as bars, the most expensive sessions,
// and the spend by project, activity, provider and model, each with a ring of its share of the tokens. The window and
// six filters narrow every number on the page; a row of a breakdown is a filter too. Reading it needs an Admin token.
import SwiftUI

private typealias MeasuredFont = FDKit.MeasuredFont

// MARK: - Model

@MainActor
final class DashboardModel: ObservableObject {
    /// The window is a preference, kept while the app runs; the filters are not, so a fresh visit shows everything.
    private static var period = 0

    @Published var query = UsageQuery(period: DashboardModel.period)
    /// The payload on screen, and the query it answered: a pick shows the loader until its own answer lands.
    @Published private(set) var data: JSON?
    private var dataKey: String?
    /// What the pickers offer, from the last payload: the whole window's, never the pick's.
    @Published private(set) var options: JSON?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var task: Task<APIError?, Never>?
    private var generation = 0

    init() { restore() }

    /// The payload drawn: only the one that answered the current window and picks.
    var shown: JSON? { data != nil && dataKey == query.key ? data : nil }

    private func restore() {
        guard let saved = Store.shared.cache.value("usage:\(query.periodID)"), saved.isObject else { return }
        data = saved; dataKey = query.key
        if saved["options"].isObject { options = saved["options"] }
    }

    @discardableResult
    func load() -> Task<APIError?, Never>? {
        task?.cancel(); task = nil
        generation += 1
        guard Store.shared.supports("usage_all") else { loading = false; return nil }
        let gen = generation, args = query.args, key = query.key, picked = query.anyPick, period = query.periodID
        loading = true
        let t = Task { [weak self] () -> APIError? in
            guard let self else { return nil }
            var failure: APIError?
            do {
                let answer = try await Store.shared.call("usage_all", args, timeout: 60)
                guard gen == self.generation else { return nil }
                guard answer.isObject else { throw APIError(.nonJSON) }
                self.data = answer; self.dataKey = key
                if answer["options"].isObject { self.options = answer["options"] }
                if !picked { Store.shared.cache.store(answer, "usage:\(period)") }
                self.error = nil
            } catch {
                guard gen == self.generation, !error.isCancellation else { return nil }
                self.error = errorText(error)
                failure = error as? APIError ?? APIError(.nonJSON)
            }
            self.loading = false
            self.task = nil
            return failure
        }
        task = t
        return t
    }
    /// A poll's tick: a read under way answers it.
    func tick() async -> APIError? {
        if task != nil { return nil }
        return await load()?.value
    }
    func stop() { task?.cancel(); task = nil; generation += 1; loading = false }

    /// A new window or pick: straight to the loader, so the page never reads as the old pick's, and ask again.
    func repick() { error = nil; load() }

    func pickPeriod() {
        let items = Usage.periods.enumerated().map { FDKit.Menu.Item(title: $0.element.label, checked: $0.offset == query.period) }
        guard let chosen = FDKit.Menu.show(items), chosen != query.period else { return }
        DashboardModel.period = chosen
        query.period = chosen
        repick()
    }
    /// One picker's menu: All, then the window's options. The project and model pickers tick several; the others take one.
    func pickFilter(_ f: Usage.Filter) {
        let menuCap = 60   // the window's sessions can run to thousands
        let list = (options ?? .null)[f.options].items
        let listed = min(list.count, menuCap)
        var items = [FDKit.Menu.Item(title: "All \(f.plural)", checked: query.picked(f).isEmpty)]
        if !list.isEmpty { items.append(.separatorItem) }
        let first = items.count
        for o in list.prefix(listed) {
            items.append(.init(title: Usage.optionLabel(f, o), checked: query.isPicked(f, Usage.optionKey(o))))
        }
        if listed < list.count { items.append(.init(title: "\(list.count - listed) more \(f.plural); a shorter window lists them", enabled: false)) }
        if list.isEmpty { items.append(.init(title: "No usage in this period", enabled: false)) }
        guard let chosen = FDKit.Menu.show(items) else { return }
        if chosen == 0 {
            if query.picked(f).isEmpty { return }
            query.clear(f)
        } else if chosen >= first && chosen - first < listed {
            if !query.choose(f, Usage.optionKey(list[chosen - first])) { return }
        } else { return }
        repick()
    }
    func clearFilters() { query.clearAll(); repick() }
    func pickRow(_ f: Usage.Filter, _ row: JSON) { query.only(f, Usage.rowKey(f, row)); repick() }
    func openTopSession(_ r: JSON) {
        guard let id = r["key"].nonEmpty else { return }
        // The ledger knows the id, title and project; the conversation reads the rest itself.
        var raw: JSON = ["id": .string(id), "status": "idle", "repo": .string(orNull: r["repo"].string)]
        if let label = r["label"].nonEmpty, label != id { raw["title"] = .string(label) }
        Navigator.shared.push(.conversation(id: id, session: raw))
    }
}

// MARK: - Screen

struct DashboardScreen: View {
    @StateObject private var model = DashboardModel()
    @ObservedObject private var store = Store.shared
    @State private var width: CGFloat = 0

    private var subtitle: String? {
        guard let u = model.shown else { return nil }
        return model.query.subtitle(u, options: model.options ?? .null)
    }
    private var buttons: [HeaderButton] {
        guard store.supports("usage_all") else { return [] }
        return [
            HeaderButton(glyph: Glyph.symbol(0xE787), label: "\(model.query.periodLabel) \u{25BE}", tip: "The window every number on this page is over") {
                model.pickPeriod()
            },
            HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the usage ledger again", enabled: !model.loading) { model.load() },
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "\u{1F4CA} Dashboard", subtitle: subtitle, buttons: buttons)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 14)
                    content
                }
                .padding(.horizontal, Theme.paneMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await poll(every: 60) { await model.tick() } }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.load() }
    }

    @ViewBuilder private var content: some View {
        if !store.supports("usage_all") {
            Text(adminNeeded).font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Color.clear.frame(height: 12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                filters
                Color.clear.frame(height: 14)
                page
            }
            .fdReadWidth($width)
        }
    }

    private var adminNeeded: String {
        let listed = store.routes.contains { $0.path == "/usage/all" || $0.path == "usage/all" }
        guard listed else { return "This server does not offer the usage ledger (GET /usage/all) on its client API. Update the server to see the dashboard here." }
        return "The dashboard reads every project's spend, which needs an Admin token, and this device's token is \(store.device?.permission ?? "unknown"). Create an Admin token on the web dashboard under Settings \u{2192} Devices and clients and connect with it."
    }

    /// The pickers, as the dashboard's selects, and Clear filters.
    private var filters: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Usage.Filter.allCases, id: \.self) { f in
                Button(model.query.buttonText(f, options: model.options ?? .null)) { model.pickFilter(f) }
                    .dashButton(.bordered).disabled(model.options == nil)
            }
            Button("Clear filters") { model.clearFilters() }.dashButton(.bordered).disabled(!model.query.anyPick)
        }
    }

    @ViewBuilder private var page: some View {
        let w = max(width, 1)
        if let u = model.shown {
            if let error = model.error { Notice(message: error); Color.clear.frame(height: 10) }
            if Usage.count(u, "turns") == 0 {
                // An empty window still lists the projects, at zero: "which projects ran nothing?" is the question left.
                Color.clear.frame(height: 18)
                Text(verbatim: "No usage recorded in \(Usage.windowName(u, periodLabel: model.query.periodLabel))\(model.query.anyPick ? " for these filters" : "").")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                Color.clear.frame(height: 18)
                Insights(u: u, width: w, open: model.openTopSession)
                ProjectCard(model: model, u: u, width: w)
                Color.clear.frame(height: 16)
            } else {
                let month = u["unit"].string == "month"
                StatTiles(width: w, tiles: [
                    ("Cost", Usage.costOrDash(u), Usage.costNote(u)),
                    ("Tokens", Usage.tokens(Usage.num(u, "totalTokens")),
                     "\(Usage.tokens(Usage.num(u, "inputTokens"))) in \u{00B7} \(Usage.tokens(Usage.num(u, "outputTokens"))) out"),
                    ("Sessions", "\(Usage.count(u, "sessions"))", "\(Usage.count(u, "turns")) turn\(Usage.plural(Usage.count(u, "turns")))"),
                    ("Agent time", Usage.durationOrDash(Usage.num(u, "durationMs")), "summed over every turn"),
                ])
                BucketChart(u: u, metric: "totalTokens", title: month ? "Tokens per month" : "Tokens per day", width: w)
                Insights(u: u, width: w, open: model.openTopSession)
                ProjectCard(model: model, u: u, width: w)
                SimpleCard(model: model, u: u, filter: .activity, width: w)
                SimpleCard(model: model, u: u, filter: .provider, width: w)
                SimpleCard(model: model, u: u, filter: .model, width: w)
                Color.clear.frame(height: 16)
            }
        } else if let error = model.error {
            NoticeBox(message: error)
            Color.clear.frame(height: 12)
        } else {
            Text("Loading the usage ledger\u{2026}").font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity)
            Color.clear.frame(height: 12)
        }
    }
}

// MARK: - Cards

/// The dashboard's `.card`: raise on a line, 12px corners, 12px above and below the content and 14px (or `side`) beside it.
private struct UsageCard<Content: View>: View {
    var side: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, side).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A row of stat tiles: the label, the figure, and the line under it, four across (two on a narrow pane).
private struct StatTiles: View {
    var width: CGFloat
    var tiles: [(label: String, value: String, sub: String)]
    var body: some View {
        let cols = width >= 640 ? 4 : 2
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: cols)), id: \.self) { start in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<cols, id: \.self) { k in
                        if start + k < tiles.count {
                            let t = tiles[start + k]
                            VStack(alignment: .leading, spacing: 0) {
                                Text(t.label).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                                Text(t.value).font(Theme.stat).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail).padding(.top, 4)
                                Text(t.sub).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raise))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// bucketChart: one bar per bucket the server's calendar has reached, `metric` high; hovering a bar names its bucket in the
/// chart's heading, as the web's title tooltip does. Nothing at all when there is nothing to plot.
private struct BucketChart: View {
    var u: JSON
    var metric: String
    var title: String
    var width: CGFloat
    @State private var hovered: Int?

    static func plots(_ u: JSON, _ metric: String) -> Bool {
        let visible = Usage.visibleBuckets(u)
        return !visible.isEmpty && visible.map { Usage.num($0, metric) }.max()! > 0
    }

    var body: some View {
        let visible = Usage.visibleBuckets(u)
        let max = visible.map { Usage.num($0, metric) }.max() ?? 0
        if !visible.isEmpty && max > 0 {
            let month = u["unit"].string == "month"
            let all = u["buckets"].count
            let every = month ? (all > 12 ? 3 : 1) : 7
            let iw = Swift.max(width - 28, 1), gap: CGFloat = 2, plot: CGFloat = 112, labelW: CGFloat = 70
            let n = CGFloat(visible.count)
            let bw = (iw - gap * (n - 1)) / n
            let labelH = MeasuredFont.caption2.lineHeight
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 12)
                UsageCard {
                    HStack(spacing: 8) {
                        Text(title).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                        if let h = hovered, h < visible.count {
                            Text(Usage.barTip(visible[h], month: month)).font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(height: MeasuredFont.caption.lineHeight + 2)
                    Color.clear.frame(height: 10)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { k, b in
                            let left = (CGFloat(k) * (bw + gap)).rounded(.towardZero)
                            let right = Swift.max((CGFloat(k) * (bw + gap) + bw).rounded(.towardZero), left + 1)
                            bar(value: Usage.num(b, metric), max: max, width: right - left, plot: plot, on: hovered == k)
                                .onHover { inside in if inside { hovered = k } else if hovered == k { hovered = nil } }
                                .offset(x: left)
                            // A label under every nth column, and none that would run off the right edge.
                            if k % every == 0 && (k == 0 || iw - left >= labelW) {
                                Text(Usage.bucketName(b["date"].string, month: month)).font(Theme.caption2).foregroundStyle(Theme.muted)
                                    .lineLimit(1).fixedSize()
                                    .offset(x: left, y: plot + 4)
                            }
                        }
                    }
                    .frame(width: iw, height: plot + 4 + labelH, alignment: .topLeading)
                }
            }
        }
    }

    private func bar(value: Double, max: Double, width: CGFloat, plot: CGFloat, on: Bool) -> some View {
        let h = value > 0 && max > 0 ? Swift.max((CGFloat(value / max) * plot).rounded(), 3) : 0
        let color = on ? Theme.accent : Theme.accent.opacity(0.75)
        let rounded = !(width < 8 || h < 8)
        return ZStack(alignment: .bottom) {
            Rectangle().fill(on ? Theme.ink.opacity(0.04) : Color.clear)
            if h > 0 {
                // `rounded-t-[4px]`: only the top is rounded.
                UnevenRoundedRectangle(topLeadingRadius: rounded ? 4 : 0, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                       topTrailingRadius: rounded ? 4 : 0, style: .circular)
                    .fill(color).frame(height: h)
            }
        }
        .frame(width: width, height: plot)
        .contentShape(Rectangle())
    }
}

/// homeInsights: the averages, how the window compares with the one before, cost per bucket and the costliest sessions.
private struct Insights: View {
    var u: JSON
    var width: CGFloat
    var open: (JSON) -> Void
    var body: some View {
        let ins = u["insights"]
        let coverage = Usage.pricingCoverage(u)
        let month = u["unit"].string == "month"
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 12)
            StatTiles(width: width, tiles: [
                ("Cost / session", Usage.insightCost(u, "costPerSession"), "within this selection"),
                ("Cost / turn", Usage.insightCost(u, "costPerTurn"), "within this selection"),
                ("Average turn duration", ins["averageDurationMs"].number.map(formatDurationMs) ?? "\u{2014}",
                 "\(Usage.count(ins, "timedTurns")) turns with timing"),
                ("Pricing coverage", coverage.value, coverage.sub),
            ])
            if let line = Usage.comparisonLine(u) {
                Text(line).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if BucketChart.plots(u, "costUsd") {
                BucketChart(u: u, metric: "costUsd", title: month ? "Cost per month" : "Cost per day", width: width)
            } else {
                Text("No priced spend to plot in this selection.").font(Theme.caption).foregroundStyle(Theme.muted).padding(.top, 12)
            }
            SessionsCard(u: u, width: width, open: open)
        }
    }
}

private struct SessionsCard: View {
    var u: JSON
    var width: CGFloat
    var open: (JSON) -> Void
    var body: some View {
        let rows = u["topSessions"].items
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 12)
                UsageCard(side: 12) {
                    Text("Most expensive sessions in this selection").font(Theme.footnote).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("Top 10 by known cost. Deleted sessions retain their usage but cannot be reopened.").font(Theme.caption)
                        .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    UsageTable(table: table(rows), width: width - 24)
                }
            }
        }
    }
    private func table(_ rows: [JSON]) -> TableSpec {
        var t = TableSpec(heads: ["Session", "Turns", "Tokens", "Cost"], aligns: [.leading, .trailing, .trailing, .trailing])
        t.headFont = .footnoteSemibold; t.headColor = Theme.ink; t.rowHeight = 52
        t.fixed = [0, 15, 15, 15]
        for r in rows {
            var d = t.row()
            d.cells = [r["label"].nonEmpty ?? Usage.optionKey(r), "\(Usage.count(r, "turns"))", Usage.tokens(Usage.num(r, "totalTokens")), Usage.costOrDash(r)]
            d.colors[0] = Theme.accent
            d.fonts = Array(repeating: .subheadline, count: 4)
            d.sub = r["repo"].string ?? ""
            d.action = { open(r) }
            t.rows.append(d)
        }
        return t
    }
}

// MARK: - Breakdowns

/// The categorical series colours, the only place a hue means which one: four slots and the tail's grey.
private func seriesColor(_ slot: Int) -> Color {
    let hex: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0x807B71]
    return Color(nsColor: NSColor(hex: hex[min(slot, Usage.seriesSlots)]))
}

/// The ring of each row's share of the tokens and its caption, `132px` square.
private struct ShareRing: View {
    var ring: Usage.Ring
    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                // The web's 100-unit viewBox: radius 40, stroke 13, a 2-unit gap of surface between the arcs, starting at twelve.
                let scale = size.width / 100, gap = 2.0 / (2 * Double.pi * 40) * 360
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var at = 0.0
                for s in ring.slices {
                    let sweep = Swift.max(s.share * 360 - gap, 0)
                    let start = -90 + at * 360
                    var path = Path()
                    path.addArc(center: center, radius: (40 * scale).rounded(), startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
                    ctx.stroke(path, with: .color(seriesColor(s.slot)), style: StrokeStyle(lineWidth: (13 * scale).rounded(), lineCap: .butt))
                    at += s.share
                }
            }
            .frame(width: 132, height: 132)
            Text("share of tokens").font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 132)
        }
    }
}

/// breakdownCard: the heading, then the ring beside the table on a wide pane and above it on a narrow one.
private struct Breakdown: View {
    var heading: String
    var ring: Usage.Ring?
    var table: TableSpec
    var width: CGFloat
    var body: some View {
        let iw = width - 28
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 12)
            UsageCard {
                Text(heading).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                Color.clear.frame(height: 6)
                if let ring, iw >= 720 {
                    HStack(alignment: .top, spacing: 20) {
                        ShareRing(ring: ring)
                        UsageTable(table: table, width: iw - 152)
                    }
                } else {
                    if let ring { ShareRing(ring: ring).frame(maxWidth: .infinity); Color.clear.frame(height: 16) }
                    UsageTable(table: table, width: iw)
                }
            }
        }
    }
}

/// The columns every breakdown ends with: sessions, turns, tokens in / out, (total,) time and cost.
private func usageCells(_ u: JSON, total: Bool) -> [String] {
    var c = ["\(Usage.count(u, "sessions"))", "\(Usage.count(u, "turns"))",
             "\(Usage.tokens(Usage.num(u, "inputTokens"))) / \(Usage.tokens(Usage.num(u, "outputTokens")))"]
    if total { c.append(Usage.tokens(Usage.num(u, "totalTokens"))) }
    c.append(Usage.durationOrDash(Usage.num(u, "durationMs")))
    c.append(Usage.costOrDash(u))
    return c
}

private struct ProjectCard: View {
    @ObservedObject var model: DashboardModel
    var u: JSON
    var width: CGFloat
    var body: some View {
        let rows = u["projects"].items
        if !rows.isEmpty {
            let ring = Usage.shareSeries(rows)
            Breakdown(heading: "By project", ring: ring, table: table(rows, ring), width: width)
        }
    }
    private func table(_ rows: [JSON], _ ring: Usage.Ring?) -> TableSpec {
        var t = TableSpec(heads: ["Project", "Sessions", "Turns", "Tokens in / out", "Total tokens", "Time", "Cost"],
                          aligns: [.leading, .trailing, .trailing, .trailing, .leading, .trailing, .trailing])
        t.fixed = [0, 0, 0, 0, 26, 0, 0]
        let max = Swift.max(1, rows.map { Usage.num($0, "totalTokens") }.max() ?? 1)
        for (i, p) in rows.enumerated() {
            var d = t.row()
            let label = p["label"].nonEmpty ?? "unknown"
            let gone = p["gone"].is(true)
            d.cells = [gone ? "\(label) (removed)" : label] + usageCells(p, total: true)
            // A project that ran nothing, or one no longer in Settings, is greyed out; it still adds up into the totals.
            if gone || Usage.count(p, "turns") == 0 { d.colors = Array(repeating: Theme.muted, count: t.heads.count) }
            // The bar wears its slice's colour, which ties it to the ring; with no ring it is the accent, magnitude alone.
            d.barColumn = 4; d.bar = Usage.num(p, "totalTokens") / max
            d.barColor = ring?.slots[i].map(seriesColor) ?? Theme.accent
            d.on = model.query.isPicked(.project, Usage.optionKey(p))
            d.action = { model.pickRow(.project, p) }
            t.rows.append(d)
        }
        return t
    }
}

/// The activity, provider and model cards: a swatch on each row for its slice, and the row as a filter.
private struct SimpleCard: View {
    @ObservedObject var model: DashboardModel
    var u: JSON
    var filter: Usage.Filter
    var width: CGFloat
    var body: some View {
        let rows = u[filter.rows].items
        if !rows.isEmpty {
            let ring = Usage.shareSeries(rows)
            Breakdown(heading: filter == .activity ? "By activity" : filter == .provider ? "By provider" : "By model",
                      ring: ring, table: table(rows, ring), width: width)
        }
    }
    private func table(_ rows: [JSON], _ ring: Usage.Ring?) -> TableSpec {
        let isModel = filter == .model
        var heads = [filter == .activity ? "Activity" : isModel ? "Model" : "Provider"]
        var aligns: [HorizontalAlignment] = [.leading]
        if isModel { heads.append("Provider"); aligns.append(.leading) }
        heads += ["Sessions", "Turns", "Tokens in / out", "Time", "Cost"]
        aligns += Array(repeating: .trailing, count: 5)
        var t = TableSpec(heads: heads, aligns: aligns)
        for (i, r) in rows.enumerated() {
            var d = t.row()
            switch filter {
            case .activity:
                let a = r["activity"].nonEmpty
                d.cells = [Usage.activityLabel(a ?? "unknown")]
                if a == nil { d.colors[0] = Theme.muted }
            case .provider:
                let p = r["provider"].nonEmpty
                d.cells = [p ?? "unknown"]; d.fonts[0] = .monoSmall
                if p == nil { d.colors[0] = Theme.muted }
            default:
                d.cells = [r["model"].nonEmpty ?? "unknown", r["provider"].nonEmpty ?? "\u{2014}"]
                d.fonts[0] = .monoSmall; d.colors[1] = Theme.muted
            }
            d.cells += usageCells(r, total: false)
            d.swatch = ring?.slots[i].map(seriesColor)
            d.on = model.query.isPicked(filter, Usage.rowKey(filter, r))
            let f = filter
            d.action = { model.pickRow(f, r) }
            t.rows.append(d)
        }
        return t
    }
}

// MARK: - Tables

/// A table being built: its heads, then rows of cells, laid out once every width is known.
private struct TableSpec {
    struct Row {
        var cells: [String] = []
        var colors: [Color]
        var fonts: [MeasuredFont]
        /// A second line under the first cell (the session table's repository).
        var sub: String?
        var swatch: Color?
        var barColumn: Int?
        var bar = 0.0
        var barColor = Theme.accent
        var on = false
        var action: (() -> Void)?
    }
    var heads: [String]
    var aligns: [HorizontalAlignment]
    /// A column's share of the width in %, else 0.
    var fixed: [Int] = []
    var headFont: MeasuredFont = .caption2
    var headColor: Color = Theme.muted
    var rowHeight: CGFloat = 30
    /// The column that takes what the others leave.
    var flex = 0
    var rows: [Row] = []

    func row() -> Row { Row(colors: Array(repeating: Theme.ink, count: heads.count), fonts: Array(repeating: .footnote, count: heads.count)) }

    /// Each column as wide as its widest cell, the fixed ones their share and the flexible one what is left (80 at least).
    func widths(_ w: CGFloat) -> [CGFloat] {
        let gap: CGFloat = 12
        var width = [CGFloat](repeating: 0, count: heads.count)
        for i in heads.indices {
            if i < fixed.count, fixed[i] > 0 { width[i] = (w * CGFloat(fixed[i]) / 100).rounded(.towardZero); continue }
            if i == flex { continue }
            var m = headFont.width(heads[i])
            for r in rows where i < r.cells.count { m = max(m, r.fonts[i].width(r.cells[i])) }
            width[i] = m
        }
        let used = width.reduce(0, +) + gap * CGFloat(heads.count - 1)
        width[flex] = max(w - used, 80)
        return width
    }
}

private struct UsageTable: View {
    var table: TableSpec
    var width: CGFloat
    var body: some View {
        let widths = table.widths(width)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ForEach(table.heads.indices, id: \.self) { i in
                    Text(table.heads[i]).font(table.headFont.font).foregroundStyle(table.headColor).lineLimit(1).truncationMode(.tail)
                        .frame(width: widths[i], alignment: Alignment(horizontal: table.aligns[i], vertical: .center))
                }
            }
            .frame(width: width, height: table.headFont.lineHeight + 10, alignment: .leading)
            ForEach(table.rows.indices, id: \.self) { r in
                TableRowView(row: table.rows[r], aligns: table.aligns, widths: widths, width: width, height: table.rowHeight)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

/// One row of a table: the cells in their columns, a swatch before the first, and in the project table a bar of its share
/// of the busiest project before the total; selected (a filter) on the sunken colour, hovered half way to it.
private struct TableRowView: View {
    var row: TableSpec.Row
    var aligns: [HorizontalAlignment]
    var widths: [CGFloat]
    var width: CGFloat
    var height: CGFloat
    @State private var hovered = false

    var body: some View {
        let cells = HStack(spacing: 12) {
            ForEach(widths.indices, id: \.self) { i in cell(i).frame(width: widths[i], height: height, alignment: Alignment(horizontal: aligns[i], vertical: .center)) }
        }
        .frame(width: width, height: height, alignment: .leading)
        .background(row.on ? Theme.sunken : hovered && row.action != nil ? Theme.sunken.opacity(0.6) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        if let action = row.action {
            Button(action: action) { cells }.buttonStyle(FDKit.LinkStyle()).onHover { hovered = $0 }
        } else { cells }
    }

    @ViewBuilder private func cell(_ i: Int) -> some View {
        let text = i < row.cells.count ? row.cells[i] : ""
        let font = row.fonts[i], color = row.colors[i]
        if i == row.barColumn {
            // `flex items-center gap-2`: the track takes what the number leaves.
            let nw = font.width(text)
            let track = widths[i] - nw - 8
            HStack(spacing: 8) {
                if track > 6 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.sunken)
                        let fw = (track * CGFloat(row.bar)).rounded()
                        if fw > 0 { Capsule().fill(row.barColor).frame(width: max(fw, 6)) }
                    }
                    .frame(width: track, height: 6)
                } else { Spacer(minLength: 0) }
                Text(text).font(font.font).foregroundStyle(color).lineLimit(1).fixedSize()
            }
        } else {
            HStack(spacing: 8) {
                if i == 0, let swatch = row.swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
                if i == 0, let sub = row.sub {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text).font(font.font).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                        Text(sub).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    }
                } else {
                    Text(text).font(font.font).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}
