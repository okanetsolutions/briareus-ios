import SwiftUI

struct PullsView: View {
    let project: Project
    @EnvironmentObject private var store: AppStore
    @State private var pulls: [JSONValue] = []
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        List {
            if let error { ErrorNotice(message: error) }
            ForEach(Array(pulls.enumerated()), id: \.offset) { _, pr in
                if let number = pr["number"].double {
                    NavigationLink { PullDetailView(project: project, number: Int(number)) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "arrow.triangle.pull").font(.subheadline).foregroundStyle(Theme.success)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pr["title"].string ?? "Pull request").font(.body.weight(.medium)).lineLimit(2)
                                Text("#\(Int(number)) · \(pr["branch"].string ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }.listRowBackground(Theme.elevated)
            if !loaded { ProgressView("Loading pull requests…") }
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
        pulls = result["pulls"].array; loaded = true; error = nil
    }
}

struct PullDetailView: View {
    let project: Project
    let number: Int
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
                LabeledContent("Branch", value: pr["headRef"].string ?? "—")
                LabeledContent("Target", value: pr["baseRef"].string ?? "—")
                if let additions = pr["additions"].double, let deletions = pr["deletions"].double {
                    HStack { Text("+\(Int(additions))").foregroundStyle(Theme.success); Text("−\(Int(deletions))").foregroundStyle(Theme.danger) }.font(.callout.monospaced())
                }
                if let url = safeWebURL(pr["url"].string) { Link("Open on GitHub", destination: url) }
            }.listRowBackground(Theme.elevated)
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
                    LabeledContent(review["user"].string ?? "Reviewer", value: review["state"].string ?? "")
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
        .foregroundPoll(every: 30, enabled: !busy && pendingAction == nil, action: load) { error = $0.localizedDescription }
        .confirmationDialog("Start a paid \(pendingAction == "qa" ? "QA" : "code review") session?",
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button("Start session") { if let action = pendingAction { Task { await start(action) } } }
        }
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

func safeWebURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil else { return nil }
    return url
}

struct UsageView: View {
    let project: Project
    @EnvironmentObject private var store: AppStore
    @State private var usage: JSONValue = .null
    @State private var error: String?
    var body: some View {
        List {
            if let error { ErrorNotice(message: error) }
            Section("This month") {
                if let cost = usage["costUsd"].double {
                    Text(cost, format: .currency(code: "USD")).font(.system(.largeTitle, design: .serif).weight(.semibold))
                } else { Text("Usage reported by your dashboard").foregroundStyle(.secondary) }
            }.listRowBackground(Theme.elevated)
            Section("Activity") {
                LabeledContent("Conversations", value: count("sessions"))
                LabeledContent("Turns", value: count("turns"))
                LabeledContent("Tokens", value: count("totalTokens"))
                LabeledContent("Unpriced turns", value: count("unpricedTurns"))
            }.listRowBackground(Theme.elevated)
            Section("Models") {
                ForEach(Array(usage["models"].array.enumerated()), id: \.offset) { _, model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model["model"].string ?? "Unknown model").font(.headline)
                        Text(model["provider"].string ?? "").font(.caption).foregroundStyle(.secondary)
                        if let cost = model["costUsd"].double {
                            Text(cost, format: .currency(code: "USD"))
                        } else { Text("Cost unavailable").foregroundStyle(.secondary) }
                    }
                }
            }.listRowBackground(Theme.elevated)
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Usage").navigationBarTitleDisplayMode(.inline)
            .refreshable { do { try await load() } catch { self.error = error.localizedDescription } }
            .foregroundPoll(every: 60, action: load) { error = $0.localizedDescription }
    }
    private func count(_ key: String) -> String { usage[key].double.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—" }
    private func load() async throws {
        let result: JSONValue = try await store.call("usage", ["repo": .string(project.repo)])
        try Task.checkCancellation()
        usage = result; error = nil
    }
}
