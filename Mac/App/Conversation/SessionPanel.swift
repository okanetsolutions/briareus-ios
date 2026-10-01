// The dashboard's `#pr-panel` (screen_panel.c): the 272px column on the right of a conversation with its pull request,
// commits, reviews and findings, each finding with its verdict buttons, and under them the session's context usage with
// the compaction controls. The conversation hands it the session's latest record (`Navigator.panelSession`).
import AppKit
import SwiftUI

struct SessionPanel: View {
    var session: JSON
    @ObservedObject private var store = Store.shared
    @State private var pr: JSON = .null
    @State private var findings: JSON = []
    @State private var error: String?
    @State private var deciding: String?
    @State private var commitsOpen = false
    @State private var findingsOpen = true
    /// The pull request read: its project and number, nil until the session has one.
    @State private var pull: PullKey?
    @State private var loadTick = 0

    struct PullKey: Equatable { var repo: String; var number: Int }

    private var record: Session { Session(raw: session) }

    /// The pull request the panel shows, or none; a session that links one later gets its sections then.
    private var wantedPull: PullKey? {
        guard let repo = record.repo, let number = record.pullNumber, store.supports("pull") else { return nil }
        return PullKey(repo: repo, number: number)
    }

    /// Whether a session has anything for this column to show.
    @MainActor
    static func wanted(_ session: Session) -> Bool {
        if session.pullNumber != nil && session.repo != nil && Store.shared.supports("pull") { return true }
        let raw = session.raw
        return sessionContextSize(raw) != nil || sessionUsageRowsPresent(raw) || compactShown(raw) || autoCompactShown(raw) || instructionsShown(raw)
    }

    @MainActor private static func canOp(_ operation: String) -> Bool { Store.shared.supports(operation) && Store.shared.canManage }
    @MainActor private static func autoCompactShown(_ raw: JSON) -> Bool { (raw["autoCompactAt"].number ?? 0) > 0 && canOp("rename") }
    @MainActor private static func instructionsShown(_ raw: JSON) -> Bool {
        (raw["compactTakesInstructions"].is(true) || raw["compactInstructions"].nonEmpty != nil) && canOp("rename")
    }
    @MainActor private static func compactShown(_ raw: JSON) -> Bool {
        (raw["canCompact"].is(true) || raw["compacting"].is(true)) && canOp("compact")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let pull { prSection(pull) }
                usageSection(afterPR: pull != nil)
            }
            .padding(.horizontal, Theme.sidebarMargin)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.sidebar)
        .onAppear { adoptPull() }
        .onChange(of: wantedPull) { _, _ in adoptPull() }
        .task(id: pull.map { "\($0.repo)#\($0.number)" } ?? "") {
            guard pull != nil else { return }
            await poll(every: 30) { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await load() } }
    }

    private func adoptPull() {
        let next = wantedPull
        guard next != pull else { return }
        pull = next
        pr = .null; findings = []; error = nil
    }

    // MARK: Reading

    private func cacheKey(_ p: PullKey) -> String { "pull:\(p.repo)#\(p.number)" }

    private func load() async -> APIError? {
        guard let p = pull, deciding == nil else { return nil }
        if pr.isNull, let saved = store.cache.value(cacheKey(p)) {
            pr = saved["pr"]; findings = saved["findings"].isArray ? saved["findings"] : []
        }
        do {
            let answer = try await store.call("pull", ["repo": .string(p.repo), "pr": JSON(p.number)])
            guard pull == p else { return nil }
            pr = answer["pr"]; error = nil
            if store.supports("findings") {
                if let f = try? await store.call("findings", ["repo": .string(p.repo), "pr": JSON(p.number)]), pull == p {
                    findings = f["findings"].isArray ? f["findings"] : []
                }
            }
            save()
            return nil
        } catch {
            if error.isCancellation { return APIError(.cancelled) }
            self.error = errorText(error)
            save()
            return error as? APIError
        }
    }
    private func save() {
        guard let p = pull, !pr.isNull else { return }
        let key = cacheKey(p)
        var saved: JSON = ["pr": pr, "findings": findings, "row": .null]
        if let old = store.cache.value(key), !old["row"].isNull { saved["row"] = old["row"] }
        store.cache.store(saved, key)
    }
    private func decide(_ key: String, _ decision: String?) {
        guard deciding == nil, let p = pull else { return }
        deciding = key
        Task {
            do {
                let answer = try await store.call("finding_decision", ["repo": .string(p.repo), "pr": JSON(p.number), "key": .string(key),
                                                                       "decision": .string(orNull: decision)])
                findings = answer["findings"].isArray ? answer["findings"] : findings
                save()
            } catch { if !error.isCancellation { self.error = errorText(error) } }
            deciding = nil
        }
    }

    // MARK: Pull request

    /// `text-[12px] tracking-wide text-muted`, the panel's section labels; the folding ones carry ▸/▾.
    @ViewBuilder private func sectionLabel(_ text: String, fold: (() -> Void)? = nil, open: Bool = false) -> some View {
        Rule().padding(.vertical, 10)
        Group {
            if let fold {
                Button(action: fold) {
                    Text("\(open ? "\u{25BE}" : "\u{25B8}") \(text)").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(text).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private func link<Label: View>(_ url: String?, @ViewBuilder label: () -> Label) -> some View {
        if isSafeWebURL(url) {
            Button { openWebURL(url) } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        } else { label() }
    }

    @ViewBuilder private func prSection(_ p: PullKey) -> some View {
        Text("Pull request").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).padding(.bottom, 12)
        if let error, pr.isNull { Text(error).font(Theme.footnote).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8) }
        if pr.isNull {
            if error == nil { Text("Loading\u{2026}").font(Theme.footnote).foregroundStyle(Theme.muted).padding(.vertical, 8) }
        } else {
            prDetails(p)
        }
    }

    @ViewBuilder private func prDetails(_ p: PullKey) -> some View {
        let url = pr["url"].string
        link(url) {
            Text(pr["title"].string ?? "Pull request #\(p.number)").font(Theme.bodySemibold).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `#70` and the state tag.
        let state = pr["state"].string
        let draft = pr["draft"].is(true)
        let stateColor = state == "merged" ? Theme.accent : state == "closed" ? Theme.danger : draft ? Theme.muted : Theme.ok
        HStack(spacing: 8) {
            link(url) { Text("#\(p.number)").font(Theme.caption).foregroundStyle(Theme.muted) }
            Badge(text: panelStateText(pr), color: stateColor, background: Theme.sidebar)
            Spacer(minLength: 0)
        }
        .frame(height: 20).padding(.top, 6)
        // `+1579 −129 · 8 files · 11 commits`
        let add = pr["additions"].number, del = pr["deletions"].number
        let files = pr["changedFiles"].number ?? 0, commits = pr["commits"].number ?? 0
        if add != nil || del != nil {
            HStack(spacing: 0) {
                Text("+\(Int((add ?? 0).rounded(.towardZero)))").foregroundStyle(Theme.ok).padding(.trailing, 4)
                Text("\u{2212}\(Int((del ?? 0).rounded(.towardZero)))").foregroundStyle(Theme.danger)
                Text(" \u{00B7} \(Int(files.rounded(.towardZero))) files \u{00B7} \(Int(commits.rounded(.towardZero))) commits")
                    .foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(Theme.caption).frame(height: 20)
        }
        Button("View PR") { Navigator.shared.push(.pull(repo: p.repo, number: p.number, stack: nil, summary: nil)) }
            .dashButton(.bordered).padding(.top, 6)
        // Commits (N)
        let commitList = pr["commitList"].items
        if !commitList.isEmpty {
            sectionLabel("Commits (\(commits > 0 ? Int(commits) : commitList.count))", fold: { commitsOpen.toggle() }, open: commitsOpen)
            if commitsOpen {
                ForEach(Array(commitList.enumerated()), id: \.offset) { _, cm in
                    HStack(spacing: 6) {
                        Text(String((cm["sha"].string ?? "").prefix(7))).font(Theme.monoCaption2).foregroundStyle(Theme.muted)
                        link(cm["url"].string) {
                            Text(cm["message"].string ?? "").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 20)
                }
            }
        }
        // Reviews
        sectionLabel("Reviews")
        let reviews = pr["reviews"].items
        ForEach(Array(reviews.enumerated()), id: \.offset) { _, r in
            let st = r["state"].string
            let mark = st == "approved" ? "\u{2713}" : st == "changes_requested" ? "\u{2717}" : "\u{25CB}"
            Text("\(mark) \((st ?? "").replacingOccurrences(of: "_", with: " "))").font(Theme.caption).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.tail).padding(.bottom, 2)
        }
        if reviews.isEmpty { Text("\u{25CB} none yet").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
        // Findings (N · all fixed)
        if store.supports("findings") { findingsSection() }
    }

    @ViewBuilder private func findingsSection() -> some View {
        let list = findings.items
        let fixed = list.filter { $0["fixed"].is(true) }.count
        sectionLabel(panelFindingsLabel(count: list.count, fixed: fixed), fold: { findingsOpen.toggle() }, open: findingsOpen)
        if findingsOpen {
            if list.isEmpty { Text("No findings reported").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
            ForEach(Array(list.enumerated()), id: \.offset) { i, f in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        let severity = f["severity"].string
                        let color = severityColor(severity)
                        Text(findingSeverityLabel(severity)).font(Theme.tinySemibold).foregroundStyle(color)
                            .padding(.horizontal, 4).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.sidebar))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color == Theme.muted ? Theme.line : color, lineWidth: 1))
                            .fixedSize()
                        link(f["url"].string) {
                            Text(f["title"].string ?? "Finding").font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                        if f["fixed"].is(true) { Text("\u{2713} fixed").font(Theme.caption2).foregroundStyle(Theme.ok).fixedSize() }
                    }
                    .frame(height: 20)
                    if store.supports("finding_decision"), let key = f["key"].string, store.canManage {
                        let current = f["decision"].string
                        Segments(titles: findingDecisionTitles, selected: findingDecisionIndex(current)) { d in
                            // The same pick twice clears it, as the dashboard does.
                            decide(key, current == findingDecisionIds[d] ? nil : findingDecisionIds[d])
                        }
                        .disabled(deciding != nil)
                        .padding(.top, 4)
                    } else {
                        Spacer().frame(height: 4)
                    }
                }
                .padding(.top, i > 0 ? 8 : 0)
            }
        }
    }

    // MARK: Context usage

    /// The bar's colours, keyed on the category names claude's /context report uses; deferred and buffer rows and unknown
    /// categories go grey, free space the near-background grey of the track.
    private static func contextColor(_ name: String?) -> Color {
        let n = (name ?? "").asciiFolded
        if n == "free space" { return Theme.line }
        if n.contains("deferred") || n.contains("autocompact") { return Color(nsColor: NSColor(hex: 0x55524C)) }
        let colors: [String: UInt32] = ["messages": 0x6D9EF7, "system prompt": 0xE06C75, "system tools": 0xD98A3F, "mcp tools": 0x4FAE72,
                                        "skills": 0xC96F9E, "memory files": 0x5FAE5F, "custom agents": 0x8F7EE8, "context": 0x6D9EF7]
        return Color(nsColor: NSColor(hex: colors[n] ?? 0x8A867C))
    }

    /// `flex justify-between text-[12px] text-muted`: the label, and the value in ink at the right.
    private func usageRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
        }
        .font(Theme.caption).frame(height: 18).padding(.bottom, 2)
    }

    private func op(_ operation: String, _ extra: JSON? = nil) {
        var info: [String: Any] = ["id": record.id, "operation": operation]
        if let extra { info["extra"] = extra }
        post(.conversationSessionOperation, info)
    }

    /// The dashboard's `usageSection`: how much of the model's window is used, as a bar split into claude's /context
    /// categories when the server has them and used-vs-free otherwise, then what the session consumed, and the compaction
    /// controls.
    @ViewBuilder private func usageSection(afterPR: Bool) -> some View {
        let raw = session, cu = raw["contextUsage"], u = sessionUsage(raw)
        let context = sessionContextSize(raw)
        let active = record.isActive, compacting = raw["compacting"].is(true)
        let clear = SessionPanel.canOp("clear") && raw["kind"].string == "devchat" && !active && !compacting
        let autoShown = SessionPanel.autoCompactShown(raw), keepShown = SessionPanel.instructionsShown(raw), compact = SessionPanel.compactShown(raw)
        if context != nil || sessionUsageRowsPresent(raw) || compact || autoShown || keepShown {
            if afterPR { Rule().padding(.vertical, 10) }
            // "Context usage", with the Auto-compact checkbox at the right of the same line.
            HStack(spacing: 6) {
                Text("Context usage").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if autoShown {
                    let at = raw["autoCompactAt"].number ?? 0
                    let on = raw["autoCompact"].is(true)
                    Button { op("rename", ["autoCompact": .bool(!on)]) } label: {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3).fill(on ? Theme.accent : Theme.field)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? Theme.accent : Theme.lineStrong, lineWidth: 1))
                                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.onAccent) } }
                                .frame(width: 12, height: 12)
                            Text("Auto-compact \(Int((at / 1000 + 0.5).rounded(.down)))k").font(Theme.caption).foregroundStyle(Theme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 20).padding(.bottom, 4)
            // Instructions (accented by a ✓ while some are set), Compact and Clear.
            if keepShown || compact || clear {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    if keepShown {
                        Button(raw["compactInstructions"].nonEmpty != nil ? "Instructions \u{2713}" : "Instructions") { editInstructions() }
                            .dashButton(.bordered)
                    }
                    if compact {
                        Button(compacting ? "Compacting\u{2026}" : "Compact") {
                            if Dialogs.confirm("Compact this conversation?", "Summarizes the conversation to free context. This uses the provider and may incur usage.", continueLabel: "Compact") {
                                op("compact")
                            }
                        }
                        .dashButton(.bordered).disabled(compacting)
                    }
                    // Takes the transcript off the screen only: the agent's context and the stored log stay as they are.
                    if clear {
                        Button("Clear") {
                            if Dialogs.confirm("Clear the transcript?", "Hides the transcript so far from this chat. Nothing is deleted and the agent's context is unchanged.", continueLabel: "Clear") {
                                op("clear")
                            }
                        }
                        .dashButton(.bordered)
                    }
                }
                .padding(.bottom, 8)
            }
            if let context {
                usageRow("Context", contextHeadline(used: context.used, window: context.window))
                // Categories come from the claude /context probe; the other providers still get a bar, just an undivided one.
                let cats = cu["categories"].items.filter { $0["tokens"].number != nil }
                let segments: [(Color, Double)] = !cats.isEmpty
                    ? cats.map { (SessionPanel.contextColor($0["name"].string), $0["pct"].number ?? 0) }
                    : context.window > 0 ? [(SessionPanel.contextColor("context"), context.used / context.window * 100),
                                            (SessionPanel.contextColor("free space"), 100 - context.used / context.window * 100)] : []
                if !segments.isEmpty {
                    ContextBar(segments: segments).frame(height: 6).padding(.top, 2).padding(.bottom, 6)
                }
                ForEach(Array(cats.enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 3).fill(SessionPanel.contextColor(c["name"].string)).frame(width: 8, height: 8)
                            .padding(.trailing, 6)
                        Text(c["name"].string ?? "").foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(formatTokens(c["tokens"].number ?? 0)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                        Text(String(format: "%.1f%%", c["pct"].number ?? 0)).foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(Theme.caption).frame(height: 18)
                }
            }
            usageRows(raw: raw, cu: cu, u: u, hasContext: context != nil)
        }
    }

    @ViewBuilder private func usageRows(raw: JSON, cu: JSON, u: JSON, hasContext: Bool) -> some View {
        let rows = sessionUsageRowsPresent(raw) || u["sessions"].number != nil || cu["compactedAt"].string != nil
        if rows {
            if hasContext { Rule().padding(.vertical, 6) }
            if let v = u["inputTokens"].number { usageRow("Input tokens", formatTokens(v)) }
            if let v = u["outputTokens"].number { usageRow("Output tokens", formatTokens(v)) }
            if let v = u["durationMs"].number { usageRow("Agent time", formatDurationMs(v)) }
            if let v = u["costUsd"].number {
                // `+`: some turns carry no price at all, so the total is a floor.
                usageRow("Cost", String(format: "$%.2f", v) + ((u["unpricedTurns"].number ?? 0) > 0 ? "+" : ""))
            }
            // An orchestrator's figures cover its workers, a task's the reviews its loop ran.
            if let v = u["sessions"].number, v > 0 {
                let n = Int(v.rounded(.towardZero))
                usageRow("Includes", "\(n) session\(n == 1 ? "" : "s") it started")
            }
            if cu["source"].string == "codex" {
                if let v = cu["cachedInputTokens"].number { usageRow("Thread cached input", formatTokens(v)) }
                if let v = cu["reasoningOutputTokens"].number { usageRow("Thread reasoning output", formatTokens(v)) }
                if let t = boardDateParse(cu["at"].string) { usageRow("Context updated", formatEventTime(t)) }
            }
            if let t = boardDateParse(cu["compactedAt"].string) { usageRow("Last compact", formatEventTime(t)) }
        }
    }

    private func editInstructions() {
        let current = session["compactInstructions"].string ?? ""
        guard let text = Dialogs.text("Compaction instructions", label: "What every compaction of this session must keep (empty clears them):",
                                      okLabel: "Save", current: current) else { return }
        let trimmed = text.cTrimmed
        if trimmed != current { op("rename", ["compactInstructions": .string(trimmed)]) }
    }
}

/// `flex h-1.5 overflow-hidden rounded-full bg-sunken`, one segment per category.
private struct ContextBar: View {
    var segments: [(Color, Double)]
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    s.0.frame(width: g.size.width * CGFloat(min(max(s.1, 0), 100)) / 100)
                }
                Spacer(minLength: 0)
            }
            .background(Theme.sunken)
            .clipShape(Capsule())
        }
    }
}
