// The Mac's session panel (`#pr-panel`, screen_panel.c) as a sheet: the session's runtime and branch, its pull request
// with its commits, reviews and findings (each finding with its verdict), and its context usage with the compaction
// controls. The conversation opens it from the strip over its transcript.
import SwiftUI

struct SessionDetailsSheet: View {
    @ObservedObject var model: ConversationScreenModel
    /// Opens a screen from the conversation, after the sheet has gone.
    let open: (Destination) -> Void
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var pr: JSON = .null
    @State private var findings: JSON = []
    @State private var error: String?
    @State private var deciding: String?
    /// Bumped by each read, so a slower earlier answer does not land over a newer one.
    @State private var loadSeq = 0
    /// Compact or Clear, waiting for its confirmation.
    @State private var asked: String?
    @State private var editingInstructions = false
    @State private var instructions = ""

    private struct PullKey: Equatable { var repo: String; var number: Int }

    private var record: Session { model.session }
    private var pull: PullKey? {
        guard let repo = record.repo, let number = record.pullNumber, store.supports("pull") else { return nil }
        return PullKey(repo: repo, number: number)
    }
    private func canOp(_ op: String) -> Bool { store.supports(op) && store.canManage }

    var body: some View {
        NavigationStack {
            Form {
                sessionSection
                if let pull { pullSection(pull) }
                if let pull, store.supports("findings"), !pr.isNull { findingsSection(pull) }
                usageSection
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { _ = await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
        .task(id: pull.map { "\($0.repo)#\($0.number)" } ?? "") {
            pr = .null; findings = []; error = nil
            guard pull != nil else { return }
            await poll(every: 30) { await load() }
        }
        .alert(asked.flatMap(conversationActionQuestion) ?? "",
               isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } }), presenting: asked) { action in
            Button(action == "compact" ? "Compact" : "Clear") { model.mutate(action) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Compaction instructions", isPresented: $editingInstructions) {
            TextField("What every compaction must keep", text: $instructions, axis: .vertical)
            Button("Save") {
                let trimmed = instructions.cTrimmed
                if trimmed != (record.raw["compactInstructions"].string ?? "") { model.mutate("rename", ["compactInstructions": .string(trimmed)]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Empty clears them.") }
    }

    // MARK: Session

    private var sessionSection: some View {
        let s = record
        return Section("Session") {
            LabeledContent("Status") { StatusLabel(status: s.conversationState) }
            let runtime = [s.provider, s.model, s.raw["effort"].nonEmpty].compactMap { $0 }.joined(separator: " \u{00B7} ")
            if !runtime.isEmpty { LabeledContent("Runtime", value: runtime) }
            if let branch = s.raw["branch"].nonEmpty {
                LabeledContent("Branch") { Text(branch).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            }
            LabeledContent("Workspace", value: conversationChipText(s, .workspace))
            if store.supports("review_loop") && (s.canReviewLoop || s.reviewLoopOn) {
                let loop = s.raw["reviewLoop"]
                LabeledContent("Review loop", value: !s.reviewLoopOn ? "Off" : loop["rounds"].truncatedInt.map { "On \u{00B7} round \($0)" } ?? "On")
            }
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Pull request

    private func cacheKey(_ p: PullKey) -> String { "pull:\(p.repo)#\(p.number)" }

    private func load() async -> APIError? {
        guard let p = pull, deciding == nil else { return nil }
        loadSeq += 1
        let seq = loadSeq
        if pr.isNull, let saved = store.cache.value(cacheKey(p)) {
            pr = saved["pr"]; findings = saved["findings"].isArray ? saved["findings"] : []
        }
        do {
            let answer = try await store.call("pull", ["repo": .string(p.repo), "pr": JSON(p.number)])
            guard pull == p, seq == loadSeq else { return nil }
            pr = answer["pr"]; error = nil
            if store.supports("findings"),
               let f = try? await store.call("findings", ["repo": .string(p.repo), "pr": JSON(p.number)]), pull == p, seq == loadSeq {
                findings = f["findings"].isArray ? f["findings"] : []
            }
            save()
            return nil
        } catch {
            if error.isCancellation { return APIError(.cancelled) }
            guard pull == p, seq == loadSeq else { return nil }
            self.error = errorText(error)
            return error as? APIError
        }
    }
    /// Saved as the pull request screen saves it, keeping what that screen read beside it (its board row, stack and
    /// description).
    private func save() {
        guard let p = pull, !pr.isNull else { return }
        let key = cacheKey(p)
        var saved = store.cache.value(key).flatMap { $0.isObject ? $0 : nil } ?? [:]
        saved["pr"] = pr; saved["findings"] = findings
        store.cache.store(saved, key)
    }
    private func decide(_ key: String, _ decision: String?) {
        guard deciding == nil, let p = pull else { return }
        deciding = key
        Task {
            do {
                let answer = try await store.call("finding_decision", ["repo": .string(p.repo), "pr": JSON(p.number), "key": .string(key),
                                                                       "decision": .string(orNull: decision)])
                if pull == p {
                    findings = answer["findings"].isArray ? answer["findings"] : findings
                    save()
                }
            } catch { if pull == p, let said = failure(error) { self.error = said } }
            deciding = nil
        }
    }

    @ViewBuilder private func pullSection(_ p: PullKey) -> some View {
        Section("Pull request") {
            if let error { ErrorNotice(message: error) }
            if pr.isNull {
                if error == nil { HStack { ProgressView(); Text("Loading the pull request\u{2026}").foregroundStyle(.secondary) } }
            } else {
                prSummary(p)
            }
            Button { leave(to: .pull(repo: p.repo, number: p.number, stack: nil, summary: nil)) } label: {
                Label("View pull request", systemImage: "arrow.triangle.pull")
            }
            if store.supports("pull_files") {
                Button { leave(to: .pullFiles(repo: p.repo, number: p.number)) } label: {
                    Label("View changes", systemImage: "doc.text.magnifyingglass")
                }
            }
            if let url = safeLink(pr["url"].string ?? record.raw["prStatus"]["url"].string) {
                Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
            }
        }
        .listRowBackground(Theme.row)
        if !pr.isNull {
            let commits = pr["commitList"].items
            if !commits.isEmpty {
                Section {
                    DisclosureGroup("Commits (\(pr["commits"].truncatedInt.flatMap { $0 > 0 ? $0 : nil } ?? commits.count))") {
                        ForEach(Array(commits.enumerated()), id: \.offset) { _, cm in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(String((cm["sha"].string ?? "").prefix(7))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(firstLine(cm["message"].string)).font(.subheadline).lineLimit(2)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.row)
            }
            Section("Reviews") {
                let reviews = pr["reviews"].items
                if reviews.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(Array(reviews.enumerated()), id: \.offset) { _, r in
                    let state = r["state"].string ?? ""
                    Label {
                        HStack {
                            Text(state.replacingOccurrences(of: "_", with: " ").capitalized)
                            if let who = r["user"].nonEmpty { Text("@\(who)").foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: state == "approved" ? "checkmark.circle.fill" : state == "changes_requested" ? "xmark.circle.fill" : "circle")
                            .foregroundStyle(state == "approved" ? Theme.success : state == "changes_requested" ? Theme.danger : .secondary)
                    }
                    .font(.subheadline)
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    @ViewBuilder private func prSummary(_ p: PullKey) -> some View {
        let state = pr["state"].string
        let draft = pr["draft"].is(true)
        let color: Color = state == "merged" ? .purple : state == "closed" ? Theme.danger : draft ? .secondary : Theme.success
        VStack(alignment: .leading, spacing: 6) {
            Text(pr["title"].string ?? "Pull request #\(p.number)").font(.body.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 8) {
                Text(verbatim: "#\(p.number)").font(.caption).foregroundStyle(.secondary)
                Text(panelStateText(pr)).font(.caption.weight(.semibold)).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().stroke(color, lineWidth: 1))
                checksBadge
            }
            let add = pr["additions"].number, del = pr["deletions"].number
            if add != nil || del != nil {
                let files = Int((pr["changedFiles"].number ?? 0).rounded(.towardZero)), commits = Int((pr["commits"].number ?? 0).rounded(.towardZero))
                HStack(spacing: 4) {
                    Text(verbatim: "+\(Int((add ?? 0).rounded(.towardZero)))").foregroundStyle(Theme.success)
                    Text(verbatim: "\u{2212}\(Int((del ?? 0).rounded(.towardZero)))").foregroundStyle(Theme.danger)
                    Text(verbatim: "\u{00B7} \(files) file\(files == 1 ? "" : "s") \u{00B7} \(commits) commit\(commits == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(.vertical, 2)
    }

    /// The checks the conversation's record carries for its pull request: ✓ passed, ✗ failed, … pending.
    @ViewBuilder private var checksBadge: some View {
        let checks = record.raw["prStatus"]["checks"]
        let failed = checks["failed"].int32 ?? 0, pending = checks["pending"].int32 ?? 0, passed = checks["passed"].int32 ?? 0
        if failed > 0 { Text("\u{2717}\(failed)").font(.caption.weight(.semibold)).foregroundStyle(Theme.danger) }
        else if pending > 0 { Text("\u{2026}\(pending)").font(.caption.weight(.semibold)).foregroundStyle(Theme.warning) }
        else if passed > 0 { Text("\u{2713}\(passed)").font(.caption.weight(.semibold)).foregroundStyle(Theme.success) }
    }

    private func findingsSection(_ p: PullKey) -> some View {
        let list = findings.items
        let fixed = list.filter { $0["fixed"].is(true) }.count
        return Section(panelFindingsLabel(count: list.count, fixed: fixed)) {
            if list.isEmpty { Text("No findings reported").foregroundStyle(.secondary) }
            ForEach(Array(list.enumerated()), id: \.offset) { _, f in findingRow(f) }
        }
        .listRowBackground(Theme.row)
    }

    private func findingRow(_ f: JSON) -> some View {
        let severity = f["severity"].string
        let label = findingSeverityLabel(severity)
        let color: Color = label == "CRIT" || label == "HIGH" ? Theme.danger : label == "LOW" ? .secondary : Theme.warning
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(color)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
                if let url = safeLink(f["url"].string) {
                    Link(destination: url) { Text(f["title"].string ?? "Finding").font(.subheadline).multilineTextAlignment(.leading) }
                } else {
                    Text(f["title"].string ?? "Finding").font(.subheadline).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if f["fixed"].is(true) { Label("Fixed", systemImage: "checkmark").font(.caption2).foregroundStyle(Theme.success).fixedSize() }
            }
            if let location = findingLocation(f) {
                Text(location).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if store.supports("finding_decision"), store.canManage, let key = f["key"].string {
                let current = f["decision"].string
                HStack(spacing: 6) {
                    ForEach(Array(findingDecisionIds.enumerated()), id: \.offset) { i, id in
                        let on = current == id
                        // The same pick twice clears it, as the Mac app does.
                        Button { decide(key, on ? nil : id) } label: {
                            Text(findingDecisionTitles[i]).font(.caption.weight(.medium))
                                .foregroundStyle(on ? Color.white : .primary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(on ? Theme.accent : Theme.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    if deciding == key { ProgressView().controlSize(.small) }
                }
                .disabled(deciding != nil)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Context usage

    @ViewBuilder private var usageSection: some View {
        let raw = record.raw, cu = raw["contextUsage"], u = sessionUsage(raw)
        let context = sessionContextSize(raw)
        let compact = sessionOffersCompact(raw) && canOp("compact")
        let clear = sessionOffersClear(raw) && canOp("clear")
        let auto = sessionOffersAutoCompact(raw) && canOp("rename")
        let keep = sessionOffersCompactInstructions(raw) && canOp("rename")
        let rows = sessionUsageRowsPresent(raw) || u["sessions"].number != nil || cu["compactedAt"].string != nil
        if context != nil || rows || compact || clear || auto || keep {
            Section("Context usage") {
                if let context {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Context", value: contextHeadline(used: context.used, window: context.window))
                        let cats = cu["categories"].items.filter { $0["tokens"].number != nil }
                        let segments: [(Color, Double)] = !cats.isEmpty
                            ? cats.map { (Self.contextColor($0["name"].string), $0["pct"].number ?? 0) }
                            : context.window > 0 ? [(Self.contextColor("context"), context.used / context.window * 100)] : []
                        if !segments.isEmpty { ContextUsageBar(segments: segments).frame(height: 6) }
                        ForEach(Array(cats.enumerated()), id: \.offset) { _, c in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3).fill(Self.contextColor(c["name"].string)).frame(width: 8, height: 8)
                                Text(c["name"].string ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(formatTokens(c["tokens"].number ?? 0)).foregroundStyle(.secondary)
                                Text(String(format: "%.1f%%", c["pct"].number ?? 0)).frame(width: 48, alignment: .trailing)
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
                if let v = u["inputTokens"].number { LabeledContent("Input tokens", value: formatTokens(v)) }
                if let v = u["outputTokens"].number { LabeledContent("Output tokens", value: formatTokens(v)) }
                if let v = u["durationMs"].number { LabeledContent("Agent time", value: formatDurationMs(v)) }
                // `+`: some turns carry no price at all, so the total is a floor.
                if let v = u["costUsd"].number { LabeledContent("Cost", value: formatCost(v) + ((u["unpricedTurns"].number ?? 0) > 0 ? "+" : "")) }
                // An orchestrator's figures cover its workers, a task's the reviews its loop ran.
                if let v = u["sessions"].number, v > 0 {
                    let n = Int(v.rounded(.towardZero))
                    LabeledContent("Includes", value: "\(n) session\(n == 1 ? "" : "s") it started")
                }
                if cu["source"].string == "codex" {
                    if let v = cu["cachedInputTokens"].number { LabeledContent("Thread cached input", value: formatTokens(v)) }
                    if let v = cu["reasoningOutputTokens"].number { LabeledContent("Thread reasoning output", value: formatTokens(v)) }
                    if let t = boardDateParse(cu["at"].string) { LabeledContent("Context updated", value: formatEventTime(t)) }
                }
                if let t = boardDateParse(cu["compactedAt"].string) { LabeledContent("Last compact", value: formatEventTime(t)) }
                if auto {
                    Toggle(autoCompactLabel(raw), isOn: Binding(get: { raw["autoCompact"].is(true) },
                                                                set: { model.mutate("rename", ["autoCompact": .bool($0)]) }))
                        .disabled(!model.can)
                }
                if keep {
                    Button {
                        instructions = raw["compactInstructions"].string ?? ""
                        editingInstructions = true
                    } label: {
                        Label(raw["compactInstructions"].nonEmpty != nil ? "Compaction instructions \u{2713}" : "Compaction instructions",
                              systemImage: "text.badge.checkmark")
                    }
                    .disabled(!model.can)
                }
                if compact {
                    let compacting = raw["compacting"].is(true)
                    Button { asked = "compact" } label: {
                        Label(compacting ? "Compacting\u{2026}" : "Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(compacting || !model.can)
                }
                // Takes the transcript off the screen only: the agent's context and the stored log stay as they are.
                if clear {
                    Button { asked = "clear" } label: { Label("Clear transcript", systemImage: "eraser") }.disabled(!model.can)
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    /// The bar's colours, keyed on the category names claude's /context report uses; deferred and buffer rows and unknown
    /// categories go grey.
    private static func contextColor(_ name: String?) -> Color {
        let n = (name ?? "").asciiFolded
        if n == "free space" { return Theme.border }
        if n.contains("deferred") || n.contains("autocompact") { return Color(light: 0x55524C, dark: 0x55524C) }
        let colors: [String: UInt32] = ["messages": 0x6D9EF7, "system prompt": 0xE06C75, "system tools": 0xD98A3F, "mcp tools": 0x4FAE72,
                                        "skills": 0xC96F9E, "memory files": 0x5FAE5F, "custom agents": 0x8F7EE8, "context": 0x6D9EF7]
        let hex = colors[n] ?? 0x8A867C
        return Color(light: hex, dark: hex)
    }

    private func leave(to destination: Destination) {
        dismiss()
        open(destination)
    }

    /// An https link with a host and no credentials: the only kind the app opens.
    private func safeLink(_ url: String?) -> URL? {
        guard let url, let u = URL(string: url), u.scheme?.lowercased() == "https", u.host != nil, u.user == nil, u.password == nil else { return nil }
        return u
    }
}

/// How much of the model's window is used, one segment per category, on a track of the border colour.
private struct ContextUsageBar: View {
    let segments: [(Color, Double)]
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    s.0.frame(width: g.size.width * CGFloat(min(max(s.1, 0), 100)) / 100)
                }
                Spacer(minLength: 0)
            }
            .background(Theme.surface)
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}
