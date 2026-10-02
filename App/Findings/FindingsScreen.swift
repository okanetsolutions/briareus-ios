// The review rounds waiting for a decision, across every project (the Findings tab) or one project's, as the Mac's
// Findings screen queues them: oldest held first, grouped by the pull request they were left on. A round opens its
// triage card in a sheet; its conversation and its pull request open on the tab's stack.
import Combine
import SwiftUI

/// The queue, read off the projects' conversation feeds, so a round completed anywhere leaves it at once.
@MainActor
final class FindingsQueueModel: ObservableObject {
    let repo: String?
    @Published private(set) var queue: [Session] = []
    @Published private(set) var loaded = false
    @Published var error: String?
    private var feeds: [ProjectFeed] = []
    private var watch: AnyCancellable?
    private var projectsWatch: AnyCancellable?

    init(repo: String?) {
        self.repo = repo
        if repo == nil {
            projectsWatch = ProjectsModel.shared.$projects.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        follow()
    }

    /// Watches the feeds of the projects shown: one, or every project the device may read.
    private func follow() {
        let repos = repo.map { [$0] } ?? ProjectsModel.shared.projects.map(\.repo)
        feeds = repos.map { Store.shared.feed($0) }
        // `$sessions` fires before the value changes; the queue is rebuilt once it has.
        watch = Publishers.MergeMany(feeds.map { $0.$sessions.map { _ in () } }).receive(on: DispatchQueue.main).sink { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
    }
    private func rebuild() {
        let next = PhoneFindings.queue(feeds.flatMap(\.sessions), repo: repo)
        if next != queue { queue = next }
        if !loaded { loaded = repo == nil ? ProjectsModel.shared.loaded && feeds.allSatisfy(\.sessionsLoaded) : feeds.first?.sessionsLoaded == true }
    }
    func session(_ id: String) -> Session? { queue.first { $0.id == id } }

    func load(fresh: Bool = false) async throws {
        do {
            if let repo { try await Store.shared.feed(repo).loadSessions(fresh: fresh) }
            else { try await ProjectsModel.shared.load() }
            error = nil
        } catch {
            if let said = failure(error) { self.error = said }
            throw error
        }
        loaded = true
        rebuild()
    }
}

struct FindingsScreen: View {
    let repo: String?
    @StateObject private var model: FindingsQueueModel
    @ObservedObject private var drafts = TriageDrafts.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @Environment(\.navigate) private var navigate
    @State private var opened: String?

    init(repo: String?) {
        self.repo = repo
        _model = StateObject(wrappedValue: FindingsQueueModel(repo: repo))
    }

    /// The queue cut where the pull request changes, as the Mac's groups.
    private var groups: [(repo: String, pr: Int, rounds: [Session])] {
        var out: [(repo: String, pr: Int, rounds: [Session])] = []
        for s in model.queue {
            let r = s.repo ?? "", pr = heldRoundPRNumber(s.heldRound ?? .null) ?? 0
            if let last = out.last, last.pr == pr, foldEqual(last.repo, r) { out[out.count - 1].rounds.append(s) }
            else { out.append((r, pr, [s])) }
        }
        return out
    }

    var body: some View {
        let groups = self.groups
        List {
            if !drafts.outcomes.isEmpty {
                Section { ForEach(drafts.outcomes) { outcomeRow($0) } }
            }
            if let error = model.error { ErrorNotice(message: error).listRowBackground(Theme.row) }
            if !model.queue.isEmpty {
                Section {} footer: { Text(findingsSubtitle(rounds: model.queue.count, pullRequests: groups.count).asciiCapitalized) }
            }
            ForEach(groups, id: \.rounds.first!.id) { g in
                Section {
                    ForEach(g.rounds, id: \.id) { roundRow($0) }
                } header: {
                    groupHeader(g)
                }
            }
            if model.loaded && model.queue.isEmpty {
                ContentUnavailableView("Nothing waiting", systemImage: "flag",
                                       description: Text("Findings arrive here from Code review and from every review-loop round."))
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if !model.loaded && model.queue.isEmpty {
                ProgressView("Loading findings…").frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(repo.flatMap { projects.project($0)?.title }.map { "Findings · \($0)" } ?? "Findings")
        .navigationBarTitleDisplayMode(repo == nil ? .large : .inline)
        .refreshable { try? await model.load(fresh: true) }
        .task { await poll(every: ProjectFeed.sessionsEvery) { await reading { try await model.load() } } }
        .sheet(item: Binding(get: { opened.map(OpenedRound.init) }, set: { opened = $0?.id })) { o in
            TriageSheet(model: model, sessionID: o.id) { s in
                opened = nil
                navigate(.conversation(id: s.id, session: s.raw))
            }
        }
    }

    private struct OpenedRound: Identifiable { var id: String }

    private func groupHeader(_ g: (repo: String, pr: Int, rounds: [Session])) -> some View {
        let findings = g.rounds.reduce(0) { $0 + ($1.heldRound?["findings"].count ?? 0) }
        return VStack(alignment: .leading, spacing: 2) {
            if g.pr > 0, !g.repo.isEmpty {
                Button { navigate(.pull(repo: g.repo, number: g.pr, stack: nil, summary: nil)) } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: "\(repo == nil ? "\(projects.project(g.repo)?.title ?? g.repo) · " : "")PR #\(g.pr)")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the pull request")
            } else {
                Text(repo == nil ? (projects.project(g.repo)?.title ?? g.repo) : "No pull request").font(.subheadline.weight(.semibold))
            }
            Text(Findings.groupCount(findings: findings, reviews: g.rounds.count)).font(.caption)
        }
        .textCase(nil)
    }

    private func roundRow(_ s: Session) -> some View {
        let held = s.heldRound ?? .null
        let takes = triageTakesVerdicts(held)
        return Button { opened = s.id } label: {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: s.status).padding(.top, 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.displayTitle).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                    Text(Findings.roundMeta(held)).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(PhoneFindings.countLine(held)).font(.caption.weight(.medium)).foregroundStyle(Theme.warning)
                        if !takes { Text("· somebody else’s").font(.caption).foregroundStyle(.secondary) }
                        if held["stale"].isSet { Text("· branch moved").font(.caption).foregroundStyle(Theme.danger) }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 6)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.row)
        .accessibilityHint(takes ? "Opens the findings to give each a verdict" : "Opens the findings")
        .swipeActions(edge: .trailing) {
            Button { navigate(.conversation(id: s.id, session: s.raw)) } label: { Label("Conversation", systemImage: "bubble.left") }
                .tint(Theme.accent)
        }
        .contextMenu {
            Button { opened = s.id } label: { Label("Findings", systemImage: "flag") }
            Button { navigate(.conversation(id: s.id, session: s.raw)) } label: { Label("Open conversation", systemImage: "bubble.left") }
            if let repo = s.repo, let pr = heldRoundPRNumber(held) {
                Button { navigate(.pull(repo: repo, number: pr, stack: nil, summary: nil)) } label: {
                    Label("Open pull request", systemImage: "arrow.triangle.pull")
                }
            }
            if let url = s.heldRoundPRURL(held), safeWebURL(url) {
                Button { openTriageLink(url) } label: { Label("Open on GitHub", systemImage: "safari") }
            }
        }
    }

    /// A line left by a completion once its card is gone: the conversation (which opens it), what happened, and dismiss.
    private func outcomeRow(_ o: TriageDrafts.Outcome) -> some View {
        Button {
            drafts.outcomes.removeAll { $0.id == o.id }
            navigate(.conversation(id: o.sessionID, session: nil))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(o.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(o.text).font(.caption).foregroundStyle(o.danger ? Theme.danger : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.row)
        .swipeActions { Button("Dismiss") { drafts.outcomes.removeAll { $0.id == o.id } }.tint(.gray) }
        .accessibilityHint("Opens the conversation; swipe to dismiss")
    }
}

/// One round's triage card in a sheet, following the queue: once the round is no longer held, the sheet closes.
private struct TriageSheet: View {
    @ObservedObject var model: FindingsQueueModel
    let sessionID: String
    let openConversation: (Session) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var last: Session?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let s = model.session(sessionID) ?? last {
                        Button { openConversation(s) } label: {
                            HStack(spacing: 8) {
                                StatusDot(status: s.status)
                                Text(s.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the conversation")
                        TriageCard(session: s) { dismiss() }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("Findings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { last = model.session(sessionID) }
        .onChange(of: model.queue) { _, _ in
            if let s = model.session(sessionID) { last = s } else if last != nil { dismiss() }
        }
    }
}
