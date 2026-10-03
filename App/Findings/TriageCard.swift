// A review round held on a conversation, as a card: each finding with its severity, place and words, a verdict and a
// comment on the user's own pull request (Reply and Delete on somebody else's), a note for the fix session, Save comments
// and Complete. The Findings tab shows it in a sheet and the conversation inline; both share what was typed.
import SwiftUI

/// What was picked and typed on a round's card before it was sent, kept while the app runs so a card closed and opened
/// again (or seen from the conversation and from the Findings tab) shows the same; and the lines a completion leaves once
/// its card is gone.
@MainActor
final class TriageDrafts: ObservableObject {
    static let shared = TriageDrafts()

    struct Round: Equatable {
        var picked: [String: String] = [:]
        var reasons: [String: String] = [:]
        var note: String?
    }
    /// What a completion came back with, for the Findings tab once the card is gone.
    struct Outcome: Identifiable, Equatable {
        var id = UUID()
        var sessionID: String
        var title: String
        var text: String
        var danger: Bool
    }

    @Published private var rounds: [String: Round] = [:]
    @Published var outcomes: [Outcome] = []

    static func key(_ session: Session, _ triage: JSON) -> String { "\(session.id)#\(triage["round"].truncatedInt ?? 0)" }
    func round(_ key: String) -> Round { rounds[key] ?? Round() }
    func update(_ key: String, _ change: (inout Round) -> Void) {
        var r = round(key)
        change(&r)
        rounds[key] = r
    }
    func drop(_ key: String) { rounds[key] = nil }
    func report(_ outcome: Outcome) {
        outcomes.removeAll { $0.sessionID == outcome.sessionID }
        outcomes.append(outcome)
    }
}

/// A finding's severity pill colour: CRIT and HIGH red, MED amber, LOW grey.
func triageSeverityColor(_ severity: String?) -> Color {
    switch findingSeverityLabel(severity) {
    case "CRIT", "HIGH": return Theme.danger
    case "LOW": return .secondary
    default: return Theme.warning
    }
}

/// Opens an https link in the browser; anything else is refused.
@MainActor func openTriageLink(_ url: String?) {
    guard safeWebURL(url), let url, let u = URL(string: url) else { return }
    UIApplication.shared.open(u)
}

struct TriageCard: View {
    let session: Session
    var done: () -> Void = {}

    @ObservedObject private var store = Store.shared
    @ObservedObject private var drafts = TriageDrafts.shared
    private enum Writing: Equatable { case complete, save, reply(String), delete(String) }
    @State private var writing: Writing?
    @State private var error: String?
    @State private var saved: (text: String, url: String?, failed: Bool)?
    @State private var info: (text: String, danger: Bool)?
    @State private var replied: [String: (url: String?, error: String?)] = [:]
    @State private var confirming = false
    @State private var deleting: JSON?
    @State private var replying: ReplyTarget?

    private struct ReplyTarget: Identifiable { var key: String; var title: String; var id: String { key } }

    var body: some View {
        if let triage = PhoneFindings.round(session) { card(triage) }
    }

    private func card(_ triage: JSON) -> some View {
        let key = TriageDrafts.key(session, triage)
        let draft = drafts.round(key)
        let takes = triageTakesVerdicts(triage), manage = store.canManage
        let canComplete = manage && store.supports("complete_findings")
        let findings = triage["findings"].items
        let fixes = PhoneFindings.fixes(triage, picked: draft.picked)
        let pr = heldRoundPRNumber(triage) ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            header(triage, key: key, takes: takes, canComplete: canComplete, empty: findings.isEmpty)
            if triage["stale"].isSet {
                Label("The branch moved after this round was reviewed: some of these may already be fixed. Completing with nothing to fix reviews the new commits instead of closing the loop.",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            if !takes || !manage {
                Text(Findings.howText(mine: takes, manage: manage, count: findings.count)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                finding(f, triage: triage, key: key, takes: takes, canComplete: canComplete)
            }
            if canComplete { footer(triage, key: key, takes: takes, fixes: fixes) }
            if let info {
                Text(info.text).font(.caption).foregroundStyle(info.danger ? Theme.danger : .secondary)
            }
            if let error { ErrorNotice(message: error) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.warning.opacity(0.4), lineWidth: 0.5))
        .disabled(writing != nil)
        .alert(triageConfirmTitle(takesVerdicts: takes, fixes: fixes), isPresented: $confirming) {
            Button(takes && fixes > 0 ? "Start the fix session" : "Complete") { complete(triage, key: key) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Findings.completePrompt(mine: takes, fixes: fixes, pr: pr).message)
        }
        .alert("Delete this finding from the review?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { f in
            Button("Delete from the review", role: .destructive) { delete(f) }
            Button("Cancel", role: .cancel) {}
        } message: { f in
            Text(Findings.deleteMessage(title: f["title"].string, pr: pr))
        }
        .sheet(item: $replying) { target in
            FindingReplySheet(title: target.title) { text in reply(key: target.key, text: text) }
        }
    }

    // MARK: Pieces

    private func header(_ triage: JSON, key: String, takes: Bool, canComplete: Bool, empty: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label(triageTitle(triage), systemImage: "flag.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.warning)
                Text(Findings.roundMeta(triage)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if takes && canComplete && !empty {
                Menu {
                    Button { setAll(triage, key: key, "fix") } label: { Label("Fix all", systemImage: "wrench.and.screwdriver") }
                    Button { setAll(triage, key: key, "") } label: { Label("Clear verdicts", systemImage: "xmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body).frame(width: 36, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel("Verdicts for every finding")
            }
        }
    }

    @ViewBuilder
    private func finding(_ f: JSON, triage: JSON, key: String, takes: Bool, canComplete: Bool) -> some View {
        let fkey = f["key"].string
        let sev = f["severity"].string
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(findingSeverityLabel(sev)).font(.caption2.weight(.bold).monospaced()).foregroundStyle(triageSeverityColor(sev))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(triageSeverityColor(sev).opacity(0.12), in: Capsule())
                    .accessibilityLabel("Severity \(sev ?? "medium")")
                Text(inlineMarkdown(f["title"].string ?? "Finding")).font(.subheadline).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let loc = findingLocation(f) {
                Button { open(f, triage) } label: {
                    Label(loc, systemImage: "arrow.up.right.square").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityHint("Opens it on GitHub")
            } else if safeWebURL(f["url"].string) {
                Button("Open on GitHub") { open(f, triage) }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if let body = f["body"].nonEmpty ?? f["description"].nonEmpty ?? f["detail"].nonEmpty {
                MarkdownText(body).font(.callout)
            }
            if let advice = Findings.parkedAdvice(f) { Text(advice).font(.caption).foregroundStyle(.secondary) }
            if let fkey, store.canManage {
                if takes {
                    if canComplete { verdictControls(f, fkey: fkey, triage: triage, key: key) }
                } else {
                    othersControls(f, fkey: fkey)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func verdictControls(_ f: JSON, fkey: String, triage: JSON, key: String) -> some View {
        let draft = drafts.round(key)
        let current = triageDecision(triage, f, picked: draft.picked)
        VerdictSegments(selected: current) { picked in
            // The same pick twice clears it.
            drafts.update(key) { $0.picked[fkey] = picked == current ? "" : picked }
            saved = nil
        }
        TextField("Comment (saved to the pull request)", text: Binding(
            get: { PhoneFindings.reason(triage, f, typed: drafts.round(key).reasons) },
            set: { text in drafts.update(key) { $0.reasons[fkey] = text }; saved = nil }), axis: .vertical)
            .lineLimit(1...4).font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }

    @ViewBuilder
    private func othersControls(_ f: JSON, fkey: String) -> some View {
        let reply = store.supports("reply_finding"), delete = store.supports("delete_finding")
        if reply || delete {
            HStack(spacing: 10) {
                if reply {
                    Button { replying = ReplyTarget(key: fkey, title: f["title"].string ?? "Finding") } label: {
                        Label(writing == .reply(fkey) ? "Replying…" : "Reply", systemImage: "arrowshape.turn.up.left")
                    }
                }
                if delete {
                    Button(role: .destructive) { deleting = f } label: {
                        Label(writing == .delete(fkey) ? "Deleting…" : "Delete", systemImage: "trash")
                    }
                }
            }
            .buttonStyle(.bordered).controlSize(.small).font(.caption)
        }
        if let rp = replied[fkey] {
            if let e = rp.error {
                Text(verbatim: "Not replied: \(e)").font(.caption).foregroundStyle(Theme.danger)
            } else if let url = rp.url {
                Button("Replied · on the pull request ↗") { openTriageLink(url) }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text("Replied").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func footer(_ triage: JSON, key: String, takes: Bool, fixes: Int) -> some View {
        if takes {
            TextField("A note for the pull request and the fix session (optional)", text: Binding(
                get: { PhoneFindings.note(triage, typed: drafts.round(key).note) },
                set: { text in drafts.update(key) { $0.note = text }; saved = nil }), axis: .vertical)
                .lineLimit(1...5).font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        }
        Button { confirming = true } label: {
            HStack(spacing: 8) {
                if writing == .complete { ProgressView().tint(.white) }
                Text(writing == .complete ? "Completing…" : triageCompleteTitle(takesVerdicts: takes, fixes: fixes))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        if takes && store.supports("save_findings") {
            Button { save(triage, key: key) } label: {
                Text(writing == .save ? "Saving…" : "Save comments").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        if takes, let line = PhoneFindings.unmarkedLine(PhoneFindings.unmarked(triage, picked: drafts.round(key).picked)) {
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
        if let saved {
            if let url = saved.url {
                Button("Saved · comment on the pull request ↗") { openTriageLink(url) }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text(saved.text).font(.caption).foregroundStyle(saved.failed ? Theme.danger : .secondary)
            }
        } else if let at = boardDateParse(triage["drafts"]["savedAt"].nonEmpty) {
            Text(verbatim: "Comments saved \(formatEventTime(at))").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func open(_ f: JSON, _ triage: JSON) {
        let url = f["url"].string
        if safeWebURL(url) { openTriageLink(url) }
        else if let pr = session.heldRoundPRURL(triage) { openTriageLink("\(pr)/files") }
    }
    private func setAll(_ triage: JSON, key: String, _ decision: String) {
        drafts.update(key) { r in
            for f in triage["findings"].items { if let k = f["key"].string { r.picked[k] = decision } }
        }
        saved = nil
    }

    /// One write at a time; what it changed is read again afterwards.
    private func send(_ kind: Writing, _ call: String, _ args: JSON, _ finish: @escaping (Result<JSON, Error>) -> Void) {
        guard writing == nil else { return }
        writing = kind
        if kind != .save { error = nil }
        var args = args
        args["sessionId"] = .string(session.id)
        Task {
            do { finish(.success(try await store.call(call, args))) }
            catch where !error.isCancellation { finish(.failure(error)) }
            catch {}
            writing = nil
        }
    }
    private func refresh() {
        let repo = session.repo
        Task {
            if let repo { try? await Store.shared.feed(repo).loadSessions(fresh: true) }
            ProjectsModel.shared.recount()
        }
    }

    private func complete(_ triage: JSON, key: String) {
        let draft = drafts.round(key)
        let args = PhoneFindings.completion(triage, picked: draft.picked, reasons: draft.reasons,
                                            note: PhoneFindings.note(triage, typed: draft.note))
        let title = session.displayTitle, sid = session.id
        send(.complete, "complete_findings", args) { result in
            switch result {
            case .success(let answer):
                drafts.drop(key)
                if Findings.completionSpeaks(answer) {
                    let line = triageOutcomeText(answer), os = answer["session"]
                    drafts.report(.init(sessionID: os["id"].nonEmpty ?? sid, title: os["title"].nonEmpty ?? title, text: line.text, danger: line.danger))
                }
                done()
                refresh()
            case .failure(let e):
                error = errorText(e)
            }
        }
    }
    private func save(_ triage: JSON, key: String) {
        let draft = drafts.round(key)
        let args = PhoneFindings.save(triage, picked: draft.picked, reasons: draft.reasons, note: PhoneFindings.note(triage, typed: draft.note))
        saved = nil
        send(.save, "save_findings", args) { result in
            switch result {
            case .success(let answer):
                let warning = answer["warning"].nonEmpty, url = answer["url"].string
                saved = (warning ?? "Saved", warning == nil && safeWebURL(url) ? url : nil, warning != nil)
            case .failure(let e):
                saved = ("Not saved: \(errorText(e))", nil, true)
            }
        }
    }
    private func reply(key fkey: String, text: String) {
        replied[fkey] = nil
        send(.reply(fkey), "reply_finding", ["key": .string(fkey), "text": .string(text)]) { result in
            switch result {
            case .success(let answer):
                let url = answer["url"].string
                replied[fkey] = (safeWebURL(url) ? url : nil, nil)
            case .failure(let e):
                replied[fkey] = (nil, errorText(e))
            }
        }
    }
    private func delete(_ f: JSON) {
        guard let fkey = f["key"].string else { return }
        info = nil
        send(.delete(fkey), "delete_finding", ["key": .string(fkey)]) { result in
            switch result {
            case .success(let answer):
                let o = Findings.deleteOutcome(answer)
                info = (o.text, o.danger)
                refresh()
            case .failure(let e):
                error = "Not deleted: \(errorText(e))"
            }
        }
    }
}

/// Fix, Optional and Dismiss as one segmented row, where the same pick twice clears it (a segmented Picker cannot).
private struct VerdictSegments: View {
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(findingDecisionIds, findingDecisionTitles)), id: \.0) { id, title in
                let on = selected == id
                Button { pick(id) } label: {
                    Text(title).font(.footnote.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(on ? color(id) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Verdict")
    }
    private func color(_ id: String) -> Color {
        switch id {
        case "fix": return Theme.accent
        case "dismissed": return Color.secondary
        default: return Theme.warning
        }
    }
}

/// Reply on a finding's thread on GitHub.
private struct FindingReplySheet: View {
    let title: String
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reply", text: $text, axis: .vertical).lineLimit(4...12).focused($focused)
                } header: {
                    Text(inlineMarkdown(title)).textCase(nil)
                } footer: {
                    Text("Posted on this finding’s own thread on the pull request.")
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Reply").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reply") { send(text.cTrimmed); dismiss() }.disabled(text.cTrimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
