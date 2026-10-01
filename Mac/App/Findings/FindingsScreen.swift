// The findings waiting for a decision across every project the device may see, as the dashboard's Findings screen
// queues them: each review round held on a conversation, grouped by the pull request it was left on. A round on the
// user's own pull request takes a verdict on every finding and is completed from here, which starts the fix session;
// a review of somebody else's is read, replied to on its findings' threads, and taken off the queue.
import SwiftUI

// MARK: - Model

@MainActor
final class FindingsModel: ObservableObject {
    struct RoundKey: Hashable { var sid: String; var round: Int }
    struct DraftKey: Hashable { var sid: String; var round: Int; var key: String }
    struct FindingKey: Hashable { var sid: String; var key: String }
    /// A finding's verdict (nil while unmarked) and comment.
    struct Draft { var decision: String?; var reason: String? }
    /// What a reply on a finding came back with.
    struct Replied { var url: String?; var error: String? }
    /// What a card says under its findings: a failed write, a save's line, a delete's line.
    struct Card { var error: String?; var saved: String?; var savedURL: String?; var savedFailed = false; var info: String?; var infoDanger = false }
    /// What a send came back with, once its card is gone.
    struct Outcome: Identifiable { var id = UUID(); var sid: String; var title: String; var text: String; var danger: Bool }
    enum WriteKind { case complete, save, reply, delete }
    struct Write { var kind: WriteKind; var sid: String; var key: String?; var title: String; var round: Int }

    @Published private(set) var projects: [Project] = []
    /// Every project's conversations, which the rounds index.
    @Published private(set) var all: [Session] = []
    @Published private(set) var rounds: [HeldRound] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published private(set) var drafts: [DraftKey: Draft] = [:]
    @Published private(set) var notes: [RoundKey: String] = [:]
    @Published private(set) var replied: [FindingKey: Replied] = [:]
    @Published private(set) var cards: [String: Card] = [:]
    @Published private(set) var outcomes: [Outcome] = []
    @Published private(set) var write: Write?

    /// The rounds whose saved drafts were taken once.
    private var seeded: Set<RoundKey> = []
    /// A completion that failed, whose card may be gone once the list is read again.
    private var unsent: (sid: String, title: String, round: Int)?
    private var cycle: Task<APIError?, Never>?
    private var generation = 0
    private var writeTask: Task<Void, Never>?

    private var store: Store { Store.shared }

    init() { restore() }

    // MARK: Rounds and their drafts

    func session(_ r: Int) -> Session { all[rounds[r].index] }
    static func roundNumber(_ held: JSON) -> Int { held["round"].int32 ?? 0 }
    /// The round a conversation holds now, by number, or nil once it left the screen: nothing is drafted or sent for a round that is gone.
    func findRound(_ sid: String, _ round: Int) -> Int? {
        rounds.indices.first { session($0).id == sid && Self.roundNumber(rounds[$0].held) == round }
    }
    var groups: [FindingsGroup] { Findings.groups(rounds, sessions: all) }

    func decision(_ sid: String, _ round: Int, _ key: String?) -> String {
        guard let key else { return "" }
        return drafts[DraftKey(sid: sid, round: round, key: key)]?.decision ?? ""
    }
    func reason(_ sid: String, _ round: Int, _ key: String?) -> String {
        guard let key else { return "" }
        return drafts[DraftKey(sid: sid, round: round, key: key)]?.reason ?? ""
    }
    func note(_ sid: String, _ round: Int) -> String { notes[RoundKey(sid: sid, round: round)] ?? "" }
    func card(_ sid: String) -> Card? { cards[sid] }
    func repliedOn(_ sid: String, _ key: String?) -> Replied? { key.flatMap { replied[FindingKey(sid: sid, key: $0)] } }

    /// An edit after a save: the "Saved" line no longer describes what is on the screen.
    private func forgetSaved(_ sid: String) {
        guard cards[sid] != nil else { return }
        cards[sid]!.saved = nil; cards[sid]!.savedURL = nil; cards[sid]!.savedFailed = false
    }
    private func outcomeSet(_ sid: String, _ title: String, _ text: String, _ danger: Bool) {
        if let i = outcomes.firstIndex(where: { $0.sid == sid }) {
            outcomes[i].title = title; outcomes[i].text = text; outcomes[i].danger = danger
            return
        }
        outcomes.append(Outcome(sid: sid, title: title.isEmpty ? "(untitled)" : title, text: text, danger: danger))
    }

    private func roundLive(_ sid: String, _ round: Int) -> Bool { findRound(sid, round) != nil }
    private func sessionLive(_ sid: String) -> Bool { rounds.indices.contains { session($0).id == sid } }
    private func findingLive(_ sid: String, _ key: String) -> Bool {
        rounds.indices.contains { session($0).id == sid && rounds[$0].held["findings"].items.contains { $0["key"].string == key } }
    }
    /// Drafts, notes and lines for a round no longer on the screen: sent from elsewhere, ruled on by an orchestrator, dropped
    /// with its conversation or pull request.
    private func prune() {
        drafts = drafts.filter { roundLive($0.key.sid, $0.key.round) }
        notes = notes.filter { roundLive($0.key.sid, $0.key.round) }
        seeded = seeded.filter { roundLive($0.sid, $0.round) }
        replied = replied.filter { findingLive($0.key.sid, $0.key.key) }
        cards = cards.filter { sessionLive($0.key) }
    }
    /// The drafts a round was saved with (Save comments) become this screen's drafts the first time the round is drawn here.
    /// Only once per round: after that what was typed here is the truth, and a poll must not put back what has since changed.
    private func seed() {
        for r in rounds.indices {
            let sid = session(r).id, held = rounds[r].held, round = Self.roundNumber(held)
            let key = RoundKey(sid: sid, round: round)
            if seeded.contains(key) { continue }
            seeded.insert(key)
            let saved = held["drafts"]
            guard saved.isObject else { continue }
            for f in held["findings"].items {
                guard let fk = f["key"].string else { continue }
                let d = saved["verdicts"][fk]
                let dk = DraftKey(sid: sid, round: round, key: fk)
                guard d.isObject, drafts[dk] == nil else { continue }
                drafts[dk] = Draft(decision: d["decision"].nonEmpty, reason: d["reason"].nonEmpty)
            }
            if let note = saved["note"].nonEmpty, notes[key] == nil { notes[key] = note }
        }
    }
    private func dropRoundDrafts(_ sid: String, _ round: Int) {
        drafts = drafts.filter { !($0.key.round == round && $0.key.sid == sid) }
        notes[RoundKey(sid: sid, round: round)] = nil
    }
    private func rebuild() {
        rounds = Session.heldRounds(all)
        prune(); seed()
    }

    // MARK: Reading

    /// A poll's tick: a read still under way answers this tick too.
    func tick() async -> APIError? {
        if cycle != nil { return nil }
        return await cycleStart().value
    }
    @discardableResult
    private func cycleStart() -> Task<APIError?, Never> {
        if let cycle { return cycle }
        let gen = generation
        let task = Task { [weak self] () -> APIError? in
            guard let self else { return nil }
            let failure = await self.runCycle(gen)
            if gen == self.generation { self.cycle = nil }
            return failure
        }
        cycle = task
        return task
    }
    /// Reads everything again now, as after a write: what the server holds is the answer to what was sent.
    func cycleNow() {
        cycle?.cancel(); cycle = nil
        generation += 1
        cycleStart()
    }
    func stop() {
        cycle?.cancel(); cycle = nil
        generation += 1
        writeTask?.cancel()
    }

    private func runCycle(_ gen: Int) async -> APIError? {
        var cycleFailed = false, projectsFailed = false
        var failure: APIError?
        var incoming: [Session] = []
        do {
            let answer = try await store.call("projects")
            guard gen == generation else { return nil }
            guard let items = Project.parseList(answer) else { throw APIError(.nonJSON) }
            projects = items
            store.cache.store(answer, "projects")
            do {
                let answer = try await store.call("sessions")
                guard gen == generation else { return nil }
                guard let list = Session.parseList(answer) else { throw APIError(.nonJSON) }
                // One list for every project; each project's own rows are saved under its key.
                for p in projects {
                    let rows = list.filter { $0.repo == p.repo }
                    store.cache.store(Session.json(rows), "sessions:\(p.repo)")
                    incoming += rows
                }
            } catch {
                guard gen == generation, !error.isCancellation else { return nil }
                // A refusal keeps what was shown before rather than emptying the cards mid-edit.
                incoming = all
                self.error = errorText(error)
                cycleFailed = true; failure = error as? APIError
            }
        } catch {
            guard gen == generation, !error.isCancellation else { return nil }
            self.error = errorText(error)
            cycleFailed = true; projectsFailed = true; failure = error as? APIError
        }
        cycleEnd(incoming: incoming, cycleFailed: cycleFailed, projectsFailed: projectsFailed)
        return failure
    }
    private func cycleEnd(incoming: [Session], cycleFailed: Bool, projectsFailed: Bool) {
        if !projectsFailed { all = incoming; rebuild() }
        if !cycleFailed { error = nil }
        loaded = true
        // A completion that failed because its round is no longer held has no card left to carry its error.
        if let u = unsent {
            if let e = cards[u.sid]?.error, findRound(u.sid, u.round) == nil {
                let title = all.first { $0.id == u.sid }?.displayTitle ?? u.title
                outcomeSet(u.sid, title, "Not sent: \(e)", true)
                cards[u.sid]?.error = nil
            }
            unsent = nil
        }
        recount()
    }
    /// projects_recount_findings: the sidebar's ⚑ counts what was saved again.
    private func recount() {
        let list = ProjectsModel.shared.projects.isEmpty ? projects : ProjectsModel.shared.projects
        ProjectsModel.shared.findingsWaiting = Findings.waiting(projects: list) { store.cache.value($0) }
        post(.findingsRecount)
    }
    /// What was saved opens at once; the server is asked for the rest.
    private func restore() {
        guard let saved = store.cache.value("projects"), let items = Project.parseList(saved) else { return }
        projects = items
        var sessions: [Session] = []
        for p in items {
            guard let list = store.cache.value("sessions:\(p.repo)"), let rows = Session.parseList(list) else { continue }
            sessions += rows
        }
        all = sessions
        loaded = true
        rebuild()
    }

    // MARK: Writing

    var busy: Bool { write != nil }
    func writing(_ kind: WriteKind, _ sid: String, _ key: String? = nil) -> Bool {
        guard let w = write, w.kind == kind, w.sid == sid else { return false }
        return key == nil || w.key == key
    }
    /// One write at a time; the card it is on says what is happening until the answer comes.
    private func start(_ kind: WriteKind, _ operation: String, _ session: Session, round: Int, key: String?, args: JSON) {
        guard write == nil else { return }
        let w = Write(kind: kind, sid: session.id, key: key, title: session.displayTitle, round: round)
        write = w
        var args = args
        args["sessionId"] = .string(session.id)
        if cards[session.id] != nil {
            if kind != .reply { cards[session.id]!.error = nil }
            if kind == .delete { cards[session.id]!.info = nil }
        }
        writeTask = Task { [weak self] in
            do {
                let answer = try await Store.shared.call(operation, args)
                self?.finish(w, answer: answer, failure: nil)
            } catch {
                if error.isCancellation { self?.write = nil; return }
                self?.finish(w, answer: nil, failure: errorText(error))
            }
        }
    }
    private func finish(_ w: Write, answer: JSON?, failure: String?) {
        write = nil
        let sid = w.sid
        var card = cards[sid] ?? Card()
        switch w.kind {
        case .complete:
            if let r = answer {
                dropRoundDrafts(sid, w.round)
                // A dismissal of somebody else's review says nothing more; anything else is worth a line once the card is gone.
                if Findings.completionSpeaks(r) {
                    let os = r["session"]
                    let line = triageOutcomeText(r)
                    outcomeSet(os["id"].nonEmpty ?? sid, os["title"].nonEmpty ?? w.title, line.text, line.danger)
                }
            } else {
                card.error = failure
                unsent = (sid, w.title, w.round)
            }
            cards[sid] = card
            cycleNow()
        case .save:
            if let r = answer {
                let warning = r["warning"].nonEmpty, url = r["url"].string
                card.saved = warning ?? "Saved"; card.savedFailed = warning != nil
                card.savedURL = warning == nil && safeWebURL(url) ? url : nil
            } else {
                card.saved = "Not saved: \(failure ?? "")"; card.savedFailed = true; card.savedURL = nil
            }
            cards[sid] = card
        case .reply:
            let fk = FindingKey(sid: sid, key: w.key ?? "")
            var rp = replied[fk] ?? Replied()
            if let r = answer {
                let url = r["url"].string
                rp.error = nil; rp.url = safeWebURL(url) ? url : nil
                let dk = DraftKey(sid: sid, round: w.round, key: w.key ?? "")
                if drafts[dk] != nil { drafts[dk]!.reason = nil }
            } else { rp.error = failure }
            replied[fk] = rp
            cards[sid] = card
        case .delete:
            if let r = answer {
                let o = Findings.deleteOutcome(r)
                card.info = o.text; card.infoDanger = o.danger
            } else { card.error = "Not deleted: \(failure ?? "")" }
            cards[sid] = card
            cycleNow()
        }
    }

    private func verdicts(_ sid: String, _ held: JSON, completing: Bool) -> JSON {
        let round = Self.roundNumber(held)
        return Findings.verdicts(held["findings"], decision: { self.decision(sid, round, $0) }, reason: { self.reason(sid, round, $0) },
                                 completing: completing)
    }

    // MARK: Actions

    func complete(_ sid: String, _ round: Int) {
        guard let r = findRound(sid, round) else { return }
        let held = rounds[r].held
        let pr = heldRoundPRNumber(held) ?? 0, mine = heldRoundIsMine(held)
        var args: JSON = [:]
        var fixes = 0
        if mine {
            fixes = held["findings"].items.filter { decision(sid, round, $0["key"].string) == "fix" }.count
            args["verdicts"] = verdicts(sid, held, completing: true)
            let n = note(sid, round)
            if !n.isEmpty { args["note"] = .string(n) }
        }
        let prompt = Findings.completePrompt(mine: mine, fixes: fixes, pr: pr)
        guard Dialogs.confirm(prompt.title, prompt.message, continueLabel: "Complete"), let again = findRound(sid, round) else { return }
        start(.complete, "complete_findings", session(again), round: round, key: nil, args: args)
    }
    func save(_ sid: String, _ round: Int) {
        guard let r = findRound(sid, round) else { return }
        let held = rounds[r].held
        let args: JSON = ["verdicts": verdicts(sid, held, completing: false), "note": .string(note(sid, round))]
        forgetSaved(sid)
        start(.save, "save_findings", session(r), round: round, key: nil, args: args)
    }
    func reply(_ sid: String, _ round: Int, key: String, title: String?) {
        guard let typed = Dialogs.text("Reply on this finding\u{2019}s thread", label: title ?? "Reply", okLabel: "Reply", current: reason(sid, round, key)),
              let again = findRound(sid, round) else { return }
        let text = typed.cTrimmed
        let dk = DraftKey(sid: sid, round: round, key: key)
        var d = drafts[dk] ?? Draft()
        d.reason = text
        drafts[dk] = d
        guard !text.isEmpty else { return }
        replied[FindingKey(sid: sid, key: key)] = nil
        start(.reply, "reply_finding", session(again), round: round, key: key, args: ["key": .string(key), "text": .string(text)])
    }
    func delete(_ sid: String, _ round: Int, key: String, title: String?, pr: Int) {
        guard Dialogs.confirm("Delete this finding from the review?", Findings.deleteMessage(title: title, pr: pr),
                              continueLabel: "Delete from the review", destructive: true),
              let again = findRound(sid, round) else { return }
        start(.delete, "delete_finding", session(again), round: round, key: key, args: ["key": .string(key)])
    }
    /// The same pick twice clears it.
    func setVerdict(_ sid: String, _ round: Int, key: String, segment: Int) {
        guard findRound(sid, round) != nil, findingDecisionIds.indices.contains(segment) else { return }
        let dk = DraftKey(sid: sid, round: round, key: key)
        var d = drafts[dk] ?? Draft()
        let id = findingDecisionIds[segment]
        d.decision = d.decision == id ? nil : id
        drafts[dk] = d
        forgetSaved(sid)
    }
    func comment(_ sid: String, _ round: Int, key: String, title: String?) {
        guard let typed = Dialogs.text("Comment on this finding", label: title ?? "Comment", okLabel: "Save", current: reason(sid, round, key)),
              findRound(sid, round) != nil else { return }
        let dk = DraftKey(sid: sid, round: round, key: key)
        var d = drafts[dk] ?? Draft()
        d.reason = typed
        drafts[dk] = d
        forgetSaved(sid)
    }
    func editNote(_ sid: String, _ round: Int) {
        guard let typed = Dialogs.text("Note for the fix session", label: "A note for the pull request and the fix session", okLabel: "Save",
                                       current: note(sid, round)),
              findRound(sid, round) != nil else { return }
        notes[RoundKey(sid: sid, round: round)] = typed
        forgetSaved(sid)
    }
    func setAll(_ sid: String, _ round: Int, _ decision: String?) {
        guard let r = findRound(sid, round) else { return }
        for f in rounds[r].held["findings"].items {
            guard let key = f["key"].string else { continue }
            let dk = DraftKey(sid: sid, round: round, key: key)
            var d = drafts[dk] ?? Draft()
            d.decision = decision
            drafts[dk] = d
        }
        forgetSaved(sid)
    }
    func dismissOutcome(_ id: UUID) { outcomes.removeAll { $0.id == id } }
    func openOutcome(_ id: UUID) {
        guard let o = outcomes.first(where: { $0.id == id }) else { return }
        dismissOutcome(id)
        if let s = all.first(where: { $0.id == o.sid }) { Navigator.shared.push(.conversation(id: s.id, session: s.raw)) }
    }
}

// MARK: - Screen

struct FindingsScreen: View {
    @StateObject private var model = FindingsModel()
    @ObservedObject private var store = Store.shared

    var body: some View {
        let groups = model.groups
        VStack(spacing: 0) {
            PaneHeader(title: "\u{2691} Findings", subtitle: findingsSubtitle(rounds: model.rounds.count, pullRequests: groups.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 14)
                    if let error = model.error { Notice(message: error); Color.clear.frame(height: 10) }
                    ForEach(model.outcomes) { OutcomeBox(model: model, outcome: $0) }
                    if !model.rounds.isEmpty {
                        ForEach(groups, id: \.rounds) { g in GroupView(model: model, group: g) }
                    } else if model.loaded {
                        Text("No review is waiting. Findings arrive here from \u{2315} Code review and from every review-loop round.")
                            .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.loaded { LoadingNote(text: "Loading findings\u{2026}") }
                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, Theme.paneMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await poll(every: 7) { await model.tick() } }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.cycleNow() }
    }
}

@MainActor private func openConversation(_ s: Session) { Navigator.shared.push(.conversation(id: s.id, session: s.raw)) }

/// A line left by a send once its card is gone: the conversation's title (which opens it), what happened, and ✕.
private struct OutcomeBox: View {
    @ObservedObject var model: FindingsModel
    var outcome: FindingsModel.Outcome
    @State private var width: CGFloat = 0
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.openOutcome(outcome.id) } label: {
                Text(outcome.title).font(Theme.captionSemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(FDKit.LinkStyle())
            .frame(maxWidth: width > 0 ? width / 2 : nil, alignment: .leading)
            .fixedSize(horizontal: width <= 0, vertical: false)
            Text(outcome.text).font(Theme.caption).foregroundStyle(outcome.danger ? Theme.danger : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissOutcome(outcome.id) } label: {
                Image(systemName: Glyph.symbol(0xE711)).font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 18, height: 16)
            }
            .buttonStyle(FDKit.LinkStyle())
        }
        .fdReadWidth($width)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.bottom, 8)
    }
}

/// One pull request's heading (which opens it) and how many findings wait on it, then each round's card.
private struct GroupView: View {
    @ObservedObject var model: FindingsModel
    var group: FindingsGroup
    var body: some View {
        if group.rounds.allSatisfy({ $0 < model.rounds.count }) { content }
    }
    @ViewBuilder private var content: some View {
        let findings = group.rounds.reduce(0) { $0 + model.rounds[$1].held["findings"].count }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    let r = group.rounds[0]
                    openWebURL(model.session(r).heldRoundPRURL(model.rounds[r].held))
                } label: {
                    Text("\(group.repo) \u{00B7} PR #\(group.pr) \u{2197}").font(Theme.bodySemibold).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(FDKit.LinkStyle())
                .layoutPriority(1)
                Text(Findings.groupCount(findings: findings, reviews: group.rounds.count)).font(Theme.caption).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.tail).frame(minWidth: 72, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .padding(.bottom, 6)
            ForEach(group.rounds, id: \.self) { r in
                RoundCard(model: model, r: r)
            }
            Color.clear.frame(height: 6)
        }
    }
}

/// One held round: the conversation's title, what round it is and since when, how the card is worked, each finding, and
/// the note, Save comments and Complete.
private struct RoundCard: View {
    @ObservedObject var model: FindingsModel
    var r: Int
    @ObservedObject private var store = Store.shared

    var body: some View {
        if r < model.rounds.count { content }
    }
    @ViewBuilder private var content: some View {
        let ses = model.session(r), held = model.rounds[r].held
        let sid = ses.id, round = FindingsModel.roundNumber(held)
        let mine = heldRoundIsMine(held), manage = store.canManage, busy = model.busy
        let findings = held["findings"].items
        let canComplete = manage && store.supports("complete_findings")
        let card = model.card(sid)
        VStack(alignment: .leading, spacing: 0) {
            title(ses, held)
            if held["stale"].isSet {
                Text("The branch moved after this round was reviewed: some of these may already be fixed. Sending with nothing to fix reviews the new commits instead of closing the loop.")
                    .font(Theme.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            Text(Findings.howText(mine: mine, manage: manage, count: findings.count))
                .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            if mine && canComplete && !findings.isEmpty {
                HStack(spacing: 6) {
                    Button("Fix all") { model.setAll(sid, round, "fix") }.dashButton(.plain)
                    Button("Clear") { model.setAll(sid, round, nil) }.dashButton(.plain)
                }
                .disabled(busy)
                .padding(.top, 4)
            }
            Color.clear.frame(height: 8)
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                FindingView(model: model, session: ses, held: held, finding: f, mine: mine)
                Color.clear.frame(height: 8)
            }
            if canComplete {
                Rectangle().fill(Theme.line).frame(height: 1)
                Color.clear.frame(height: 8)
                if mine { footer(sid, round, held, findings, card) }
                else {
                    Button(model.writing(.complete, sid) ? "Completing\u{2026}" : "Complete") { model.complete(sid, round) }
                        .dashButton(.prominent).disabled(busy)
                }
            }
            if let info = card?.info {
                Text(info).font(Theme.caption).foregroundStyle(card?.infoDanger == true ? Theme.danger : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            if let error = card?.error { Notice(message: error).padding(.top, 6) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.bottom, 12)
    }

    /// The title and the meta on one 22px line when both fit, else the title wrapped and the meta under it.
    private func title(_ ses: Session, _ held: JSON) -> some View {
        let meta = Findings.roundMeta(held)
        let open = { openConversation(ses) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button(action: open) { Text(ses.displayTitle).font(Theme.bodySemibold).foregroundStyle(Theme.ink).fixedSize() }
                    .buttonStyle(FDKit.LinkStyle())
                Text(meta).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize()
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Button(action: open) {
                    Text(ses.displayTitle).font(Theme.bodySemibold).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(FDKit.LinkStyle())
                Text(meta).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func footer(_ sid: String, _ round: Int, _ held: JSON, _ findings: [JSON], _ card: FindingsModel.Card?) -> some View {
        let busy = model.busy
        let note = model.note(sid, round)
        let decisions = findings.map { model.decision(sid, round, $0["key"].string) }
        let fixes = decisions.filter { $0 == "fix" }.count, unruled = decisions.filter(\.isEmpty).count
        Button { model.editNote(sid, round) } label: {
            Text(note.isEmpty ? "A note for the pull request and the fix session (optional)" : note)
                .font(Theme.caption2).foregroundStyle(note.isEmpty ? Theme.muted : Theme.ink)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(FDKit.LinkStyle())
        .disabled(busy)
        Color.clear.frame(height: 8)
        let save = store.supports("save_findings")
        if save || unruled == 0 {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if save {
                    Button(model.writing(.save, sid) ? "Saving\u{2026}" : "Save comments") { model.save(sid, round) }.dashButton(.bordered)
                }
                if unruled == 0 {
                    Button(Findings.completeLabel(fixes: fixes, sending: model.writing(.complete, sid))) { model.complete(sid, round) }
                        .dashButton(.prominent)
                }
            }
            .disabled(busy)
        }
        if unruled > 0 {
            Text(Findings.unmarkedText(unruled)).font(Theme.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
        if let saved = card?.saved {
            Group {
                if let url = card?.savedURL {
                    Button { openWebURL(url) } label: {
                        Text("Saved \u{00B7} comment on the pull request \u{2197}").font(Theme.caption).foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(FDKit.LinkStyle())
                } else {
                    Text(saved).font(Theme.caption).foregroundStyle(card?.savedFailed == true ? Theme.danger : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } else if let at = boardDateParse(held["drafts"]["savedAt"].nonEmpty) {
            Text("Comments saved \(formatEventTime(at))").font(Theme.caption).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.tail).padding(.top, 6)
        }
    }
}

/// One finding: its severity, its title and place (which open it on the pull request), the loop's advice, and the verdict
/// and comment on the user's own pull request, or Reply and Delete on somebody else's.
private struct FindingView: View {
    @ObservedObject var model: FindingsModel
    var session: Session
    var held: JSON
    var finding: JSON
    var mine: Bool
    @ObservedObject private var store = Store.shared

    private func open() {
        let url = finding["url"].string
        if safeWebURL(url) { openWebURL(url) }
        else if let pr = session.heldRoundPRURL(held) { openWebURL("\(pr)/files") }
    }

    var body: some View {
        let sid = session.id, round = FindingsModel.roundNumber(held)
        let key = finding["key"].string, title = finding["title"].string
        let busy = model.busy
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Color.clear.frame(height: 8)
            HStack(alignment: .top, spacing: 6) {
                let sev = finding["severity"].string
                Badge(text: findingSeverityLabel(sev), color: severityColor(sev), background: Theme.raise)
                Button(action: open) {
                    Text(title ?? "Finding").font(Theme.footnote).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(FDKit.LinkStyle())
                Spacer(minLength: 0)
            }
            if let loc = Findings.location(finding) {
                Button(action: open) {
                    Text(loc).font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(FDKit.LinkStyle())
                .padding(.top, 4)
            }
            if let advice = Findings.parkedAdvice(finding) {
                Text(advice).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            }
            if store.canManage, let key {
                if mine {
                    if store.supports("complete_findings") {
                        Segments(titles: findingDecisionTitles, selected: findingDecisionIndex(model.decision(sid, round, key))) {
                            model.setVerdict(sid, round, key: key, segment: $0)
                        }
                        .disabled(busy)
                        .padding(.top, 4)
                        let reason = model.reason(sid, round, key)
                        Button { model.comment(sid, round, key: key, title: title) } label: {
                            Text(reason.isEmpty ? "Comment (saved to the pull request)" : reason)
                                .font(Theme.caption2).foregroundStyle(reason.isEmpty ? Theme.muted : Theme.ink)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(FDKit.LinkStyle())
                        .disabled(busy)
                        .padding(.top, 4)
                    }
                } else {
                    othersControls(sid, round, key, title)
                }
            }
        }
    }

    @ViewBuilder
    private func othersControls(_ sid: String, _ round: Int, _ key: String, _ title: String?) -> some View {
        let reply = store.supports("reply_finding"), delete = store.supports("delete_finding")
        if reply || delete {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if reply {
                    GlyphButton(glyph: "arrowshape.turn.up.left", title: model.writing(.reply, sid, key) ? "Replying\u{2026}" : "Reply") {
                        model.reply(sid, round, key: key, title: title)
                    }
                }
                if delete {
                    GlyphButton(glyph: Glyph.symbol(0xE74D), title: model.writing(.delete, sid, key) ? "Deleting\u{2026}" : "Delete from the review",
                                kind: .destructive) {
                        model.delete(sid, round, key: key, title: title, pr: heldRoundPRNumber(held) ?? 0)
                    }
                }
            }
            .disabled(model.busy)
            .padding(.top, 6)
        }
        if let rp = model.repliedOn(sid, key) {
            Group {
                if let e = rp.error {
                    Text("Not replied: \(e)").font(Theme.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                } else if let url = rp.url {
                    Button { openWebURL(url) } label: {
                        Text("Replied \u{00B7} on the pull request \u{2197}").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .buttonStyle(FDKit.LinkStyle())
                } else {
                    Text("Replied").font(Theme.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 4)
        }
    }
}
