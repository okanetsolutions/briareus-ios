import SwiftUI

struct PullsView: View {
    let project: Project
    @EnvironmentObject private var store: AppStore
    @State private var pulls: [JSONValue] = []
    @State private var stacks: JSONValue = .null
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        List {
            if let error { ErrorNotice(message: error) }
            ForEach(Array(pulls.enumerated()), id: \.offset) { _, pr in
                if let number = pr["number"].double {
                    let stack = StackPosition(pr["stack"], chain: stacks)
                    let review = ReviewStatus(decision: pr["reviewDecision"].string, reviews: pr["reviewers"].array)
                    NavigationLink { PullDetailView(project: project, number: Int(number), stack: stack) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "arrow.triangle.pull").font(.subheadline).foregroundStyle(Theme.success)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pr["title"].string ?? "Pull request").font(.body.weight(.medium)).lineLimit(2)
                                Text("#\(Int(number)) · \(pr["branch"].string ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                if review != nil || stack != nil || pr["draft"].bool == true {
                                    HStack(spacing: 6) {
                                        if let stack { StackBadge(stack: stack) }
                                        if let review { ReviewBadge(status: review) }
                                        if pr["draft"].bool == true { Badge(text: "Draft", systemImage: "pencil", color: .secondary) }
                                    }
                                }
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }.listRowBackground(Theme.elevated)
            if !loaded { ProgressView("Loading pull requests…").frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear) }
            if loaded && pulls.isEmpty && error == nil {
                ContentUnavailableView("No open pull requests", systemImage: "arrow.triangle.pull")
            }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Pull requests").navigationBarTitleDisplayMode(.inline)
            .refreshable { do { try await load() } catch { self.error = error.localizedDescription } }
            .foregroundPoll(every: 45, action: load) { error = $0.localizedDescription; loaded = true }
    }
    private func load() async throws {
        let result: JSONValue = try await store.call("pulls", ["repo": .string(project.repo)])
        try Task.checkCancellation()
        pulls = result["pulls"].array; stacks = result["stacks"]; loaded = true; error = nil
    }
}

struct PullDetailView: View {
    let project: Project
    let number: Int
    var stack: StackPosition? = nil
    @EnvironmentObject private var store: AppStore
    @State private var pr: JSONValue = .null
    @State private var findings: [JSONValue] = []
    @State private var error: String?
    @State private var findingsError: String?
    @State private var pendingAction: String?
    @State private var busy = false
    @State private var uncertain = false
    @State private var writeError: String?
    @State private var started: Session?
    @State private var mergeMethods: [String]?
    @State private var mergeNote: String?
    @State private var mergeError: String?
    @State private var merging = false
    private var canMerge: Bool {
        store.supports("merge_pull") && pr["state"].string == "open" && pr["draft"].bool != true
            && pr["headSha"].string != nil && pr["baseRef"].string != nil
    }
    var body: some View {
        List {
            if let error { ErrorNotice(message: error).listRowBackground(Theme.elevated) }
            if let writeError {
                ErrorNotice(message: writeError)
                Text("The request may have completed. Check the project’s conversations before starting another agent.").font(.caption)
            }
            Section {
                Text(pr["title"].string ?? "Pull request #\(number)").font(.title3.bold())
                LabeledContent("State", value: pr["state"].string ?? "Loading…")
                if pr != .null {
                    LabeledContent("Review") {
                        if let review = ReviewStatus(decision: nil, reviews: pr["reviews"].array) { ReviewBadge(status: review) }
                        else { Text("No reviews yet") }
                    }
                }
                LabeledContent("Branch", value: pr["headRef"].string ?? "—")
                LabeledContent("Target", value: pr["baseRef"].string ?? "—")
                if let additions = pr["additions"].double, let deletions = pr["deletions"].double {
                    HStack { Text("+\(Int(additions))").foregroundStyle(Theme.success); Text("−\(Int(deletions))").foregroundStyle(Theme.danger) }.font(.callout.monospaced())
                }
                let filesLabel = Label(pr["changedFiles"].double.map { "\(Int($0)) files changed" } ?? "Files changed", systemImage: "doc.on.doc")
                if store.supports("pull_files") {
                    NavigationLink { PullFilesView(project: project, number: number) } label: {
                        Label("Description and changes", systemImage: "doc.text.magnifyingglass")
                        if let count = pr["changedFiles"].double {
                            Spacer()
                            Text("\(Int(count)) files").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if let url = safeWebURL(pr["url"].string) {
                    if !store.supports("pull_files") {
                        Link(destination: url.appendingPathComponent("files")) {
                            HStack {
                                filesLabel
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Link("Open on GitHub", destination: url)
                }
            }.listRowBackground(Theme.elevated)
            if let stack {
                Section {
                    ForEach(stack.chain, id: \.number) { item in
                        let row = HStack(spacing: 8) {
                            Text("\(item.depth)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(2).fontWeight(item.number == number ? .semibold : .regular)
                                Text("#\(item.number)\(item.draft ? " · draft" : "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if item.number == number { Spacer(); Text("This PR").font(.caption).foregroundStyle(Theme.accent) }
                        }.padding(.leading, CGFloat(max(0, item.depth - 1)) * 10)
                        if item.number == number { row }
                        else { NavigationLink { PullDetailView(project: project, number: item.number, stack: stack) } label: { row } }
                    }
                } header: {
                    Text("Stack · \(stack.label)")
                } footer: {
                    Text(stack.partial ? "Bottom first. Only part of this stack is visible; it may be longer." : "Bottom first. Merge from the bottom up.")
                }.listRowBackground(Theme.elevated)
            }
            Section("Checks") {
                HStack(spacing: 14) {
                    Label("\(Int(pr["checks"]["passed"].double ?? 0))", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    Label("\(Int(pr["checks"]["failed"].double ?? 0))", systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger)
                    Label("\(Int(pr["checks"]["pending"].double ?? 0))", systemImage: "clock.fill").foregroundStyle(Theme.warning)
                }
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Int(pr["checks"]["passed"].double ?? 0)) passed, \(Int(pr["checks"]["failed"].double ?? 0)) failed, \(Int(pr["checks"]["pending"].double ?? 0)) pending")
                ForEach(Array(pr["checks"]["runs"].array.enumerated()), id: \.offset) { _, check in
                    let result = check["conclusion"].string ?? check["status"].string ?? "Pending"
                    LabeledContent {
                        Text(result.capitalized)
                    } label: {
                        Label { Text(check["name"].string ?? "Check") } icon: { checkIcon(result) }
                    }
                }
            }.listRowBackground(Theme.elevated)
            Section("Reviews") {
                ForEach(Array(pr["reviews"].array.enumerated()), id: \.offset) { _, review in
                    LabeledContent(review["user"].string ?? "Reviewer") {
                        if let status = ReviewStatus(decision: nil, reviews: [review]) { ReviewBadge(status: status) }
                        else { Text(review["state"].string ?? "") }
                    }
                }
                if pr["reviews"].array.isEmpty {
                    Text("No reviews reported").foregroundStyle(.secondary)
                }
            }.listRowBackground(Theme.elevated)
            if store.supports("findings") {
                Section("Findings") {
                    if let findingsError { ErrorNotice(message: findingsError) }
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                        DisclosureGroup {
                            Text(.init(finding["body"].string ?? finding["title"].string ?? "")).textSelection(.enabled)
                            if let file = finding["file"].string { Text(file).font(.caption.monospaced()) }
                            if let url = safeWebURL(finding["url"].string) { Link("Open finding on GitHub", destination: url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(finding["title"].string ?? "Finding")
                                Text([finding["severity"].string, finding["fixed"].bool == true ? "Fixed" : finding["decision"].string].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if findings.isEmpty && findingsError == nil { Text("No findings reported").foregroundStyle(.secondary) }
                }.listRowBackground(Theme.elevated)
            }
            if canMerge || mergeError != nil {
                Section {
                    if let mergeError { ErrorNotice(message: mergeError) }
                    if canMerge {
                        Button { Task { await prepareMerge() } } label: {
                            HStack {
                                Label("Merge pull request", systemImage: "arrow.triangle.merge").fontWeight(.semibold)
                                if merging { Spacer(); ProgressView() }
                            }
                        }.disabled(merging || busy)
                    }
                } footer: {
                    if canMerge { Text("Merges \(pr["headRef"].string ?? "this branch") into \(pr["baseRef"].string ?? "its base") on GitHub. This cannot be undone from the app.") }
                }.listRowBackground(Theme.elevated)
            }
            if store.canManage && pr["headRef"].string != nil {
                Section {
                    if store.supports("review") { Button("Start code review") { pendingAction = "review" } }
                    if store.supports("qa") { Button("Start QA") { pendingAction = "qa" } }
                } footer: { Text("Uses the provider and model configured for this project. These actions run paid agents and may write to GitHub.") }
                    .disabled(busy || uncertain).listRowBackground(Theme.elevated)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("#\(number)").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $started) { ConversationView(initial: $0) }
        .refreshable { do { try await load() } catch { self.error = error.localizedDescription } }
        .foregroundPoll(every: 30, enabled: !busy && !merging && pendingAction == nil && mergeMethods == nil, action: load) { error = $0.localizedDescription }
        .confirmationDialog("Start a paid \(pendingAction == "qa" ? "QA" : "code review") session?",
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button("Start session") { if let action = pendingAction { Task { await start(action) } } }
        }
        .confirmationDialog("Merge #\(number) into \(pr["baseRef"].string ?? "its base")?",
                            isPresented: Binding(get: { mergeMethods != nil }, set: { if !$0 { mergeMethods = nil } }), titleVisibility: .visible) {
            ForEach(mergeMethods ?? [], id: \.self) { method in
                Button(Self.mergeTitles[method] ?? method.capitalized) { Task { await merge(method) } }
            }
        } message: { if let mergeNote { Text(mergeNote) } }
    }
    private static let mergeTitles = ["squash": "Squash and merge", "merge": "Create a merge commit", "rebase": "Rebase and merge"]
    /// Reads what GitHub allows before asking, so the dialog offers only methods the repository accepts.
    private func prepareMerge() async {
        guard !merging else { return }
        merging = true; mergeError = nil; defer { merging = false }
        var methods = ["squash", "merge", "rebase"]
        var notes: [String] = []
        if store.supports("pull_files"),
           let page: PullFilesPage = try? await store.call("pull_files", ["repo": .string(project.repo), "pr": .number(Double(number))]) {
            let allowed = page.pr["mergeMethods"].array.compactMap(\.string)
            if !allowed.isEmpty { methods = methods.filter(allowed.contains) }
            if page.pr["mergeable"].bool == false { notes.append("GitHub reports conflicts with the base branch.") }
            if let head = page.pr["headSha"].string, head != pr["headSha"].string {
                do { try await load() } catch { mergeError = error.localizedDescription; return }
                notes.append("New commits were pushed; the checks below were refreshed.")
            }
        }
        let failed = Int(pr["checks"]["failed"].double ?? 0), pending = Int(pr["checks"]["pending"].double ?? 0)
        if failed > 0 { notes.append("\(failed) check\(failed == 1 ? " is" : "s are") failing.") }
        if pending > 0 { notes.append("\(pending) check\(pending == 1 ? " is" : "s are") still running.") }
        mergeNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        mergeMethods = methods
    }
    private func merge(_ method: String) async {
        guard !merging, let head = pr["headSha"].string, let base = pr["baseRef"].string else { return }
        merging = true; mergeError = nil; defer { merging = false }
        do {
            let _: JSONValue = try await store.call("merge_pull", ["repo": .string(project.repo), "pr": .number(Double(number)),
                                                                     "headSha": .string(head), "baseRef": .string(base), "method": .string(method)])
        } catch {
            // A 4xx is a definite refusal; anything else may have merged, which the reload below shows.
            if case .http(400..<500, _, _)? = error as? APIError { mergeError = error.localizedDescription }
            else { mergeError = "\(error.localizedDescription) The merge may still have completed; check the state above before trying again." }
        }
        do { try await load() } catch { self.error = error.localizedDescription }
    }
    private func checkIcon(_ result: String) -> some View {
        switch result.lowercased() {
        case "success", "passed", "neutral", "skipped": return Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case "failure", "failed", "cancelled", "timed_out", "action_required", "error": return Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        default: return Image(systemName: "clock.fill").foregroundStyle(Theme.warning)
        }
    }
    private func load() async throws {
        let args: [String: JSONValue] = ["repo": .string(project.repo), "pr": .number(Double(number))]
        let result: JSONValue = try await store.call("pull", args)
        try Task.checkCancellation()
        pr = result["pr"]; error = nil
        if store.supports("findings") {
            do {
                let result: JSONValue = try await store.call("findings", args)
                try Task.checkCancellation()
                findings = result["findings"].array; findingsError = nil
            } catch {
                if Task.isCancelled { throw error }
                findingsError = error.localizedDescription
            }
        }
    }
    private func start(_ action: String) async {
        guard !busy, !uncertain, let branch = pr["headRef"].string else { return }
        busy = true; defer { busy = false }
        do {
            let result: SessionResult = try await store.call(action, ["repo": .string(project.repo), "prNumber": .number(Double(number)), "branch": .string(branch)])
            started = result.session
        } catch { writeError = error.localizedDescription; uncertain = true }
    }
}

/// The overall verdict a pull request carries, read from GitHub's review decision
/// and, since that is null on repos without required reviews, the reviewers themselves.
enum ReviewStatus: Equatable {
    case approved, changesRequested, feedback, requested
    init?(decision: String?, reviews: [JSONValue]) {
        let states = Set(reviews.compactMap { $0["state"].string?.lowercased() })
        switch decision?.lowercased() {
        case "approved": self = .approved
        case "changes_requested": self = .changesRequested
        default:
            if states.contains("changes_requested") { self = .changesRequested }
            else if states.contains("approved") { self = .approved }
            else if states.contains("commented") { self = .feedback }
            else if decision?.lowercased() == "review_required" || states.contains("requested") { self = .requested }
            else { return nil }
        }
    }
    var text: String {
        switch self {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .feedback: return "Feedback given"
        case .requested: return "Review requested"
        }
    }
    var systemImage: String {
        switch self {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "xmark.octagon.fill"
        case .feedback: return "text.bubble.fill"
        case .requested: return "clock"
        }
    }
    var color: Color {
        switch self {
        case .approved: return Theme.success
        case .changesRequested: return Theme.danger
        case .feedback: return Theme.warning
        case .requested: return .secondary
        }
    }
}

/// Where a pull request sits in a stack of branches built on each other, 1 being the bottom.
struct StackPosition: Hashable {
    struct Item: Hashable { let number: Int; let title: String; let depth: Int; let draft: Bool }
    let position: Int
    let total: Int
    let partial: Bool
    let chain: [Item]
    var label: String { "\(position)/\(total)\(partial ? "+" : "")" }
    init?(_ value: JSONValue, chain stacks: JSONValue) {
        guard let position = value["position"].double, let total = value["total"].double else { return nil }
        self.position = Int(position); self.total = Int(total); partial = value["partial"].bool == true
        let id = value["id"].double.map { String(Int($0)) } ?? value["id"].string ?? ""
        chain = stacks[id].array.compactMap { item in
            guard let number = item["number"].double else { return nil }
            return Item(number: Int(number), title: item["title"].string ?? "Pull request #\(Int(number))",
                        depth: Int(item["depth"].double ?? 1), draft: item["draft"].bool == true)
        }
    }
}

struct Badge: View {
    let text: String
    var systemImage: String? = nil
    let color: Color
    var body: some View {
        Group {
            if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
        }
            .font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct ReviewBadge: View {
    let status: ReviewStatus
    var body: some View { Badge(text: status.text, systemImage: status.systemImage, color: status.color) }
}

struct StackBadge: View {
    let stack: StackPosition
    var body: some View {
        Badge(text: "Stack \(stack.label)", color: Theme.accent)
            .accessibilityLabel("Stacked pull request \(stack.position) of \(stack.total)\(stack.partial ? " or more" : "")")
    }
}

func safeWebURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil else { return nil }
    return url
}
