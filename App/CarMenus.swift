// The car needs the iOS 26.4 SDK, which came with the Swift 6.3 compiler.
#if os(iOS) && compiler(>=6.3)
import CarPlay

// The lists beside the voice screen. Browse chooses what is in hand and Actions says what to do with it; each is
// one screen away from the voice screen and opens at most one more, which is as deep as CarPlay lets the app go.
@available(iOS 26.4, *)
extension CarAssistant {
    // MARK: Building blocks

    private func item(_ text: String, _ detail: String? = nil, symbol: String? = nil, more: Bool = false, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: symbol.map { Self.symbol($0, size: 22) },
                              accessoryImage: nil, accessoryType: more ? .disclosureIndicator : .none)
        item.handler = { _, done in action(); done() }
        return item
    }
    private func section(_ header: String? = nil, _ items: [CPListItem]) -> CPListSection? {
        items.isEmpty ? nil : CPListSection(items: items, header: header, sectionIndexTitle: nil)
    }
    /// No more rows and sections than the car shows, which is fewer while it moves.
    private static func fit(_ sections: [CPListSection?]) -> [CPListSection] {
        var left = CPListTemplate.maximumItemCount
        return sections.compactMap { $0 }.prefix(CPListTemplate.maximumSectionCount).compactMap { section in
            let items = Array(section.items.prefix(left))
            left -= items.count
            return items.isEmpty ? nil : CPListSection(items: items, header: section.header, sectionIndexTitle: nil)
        }
    }
    /// A list that fills as its rows are read: from what the phone saved first, from the server after.
    private func list(_ title: String, empty: String, fill: @escaping (_ show: @escaping ([CPListSection?]) -> Void) async throws -> Void) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        Task {
            do {
                try await fill { sections in
                    template.emptyViewTitleVariants = [empty]
                    template.updateSections(Self.fit(sections))
                }
            } catch {
                guard template.sections.isEmpty else { return }
                template.emptyViewTitleVariants = ["Could not load"]
                template.emptyViewSubtitleVariants = [error.localizedDescription]
            }
        }
        return template
    }
    /// One screen away from the voice screen, whatever was showing.
    private func second(_ template: CPTemplate) {
        Task {
            await home()
            controller.pushTemplate(template, animated: true) { _, _ in }
        }
    }
    /// One screen further, from a list that is itself one away.
    private func third(_ template: CPTemplate) {
        guard controller.templates.count == 2 else { return }
        controller.pushTemplate(template, animated: true) { _, _ in }
    }
    private func choose(_ title: String, _ message: String? = nil, _ options: [(title: String, destructive: Bool, then: () -> Void)]) {
        let actions = options.map { option in
            CPAlertAction(title: option.title, style: option.destructive ? .destructive : .default) { [weak self] _ in
                self?.controller.dismissTemplate(animated: true) { _, _ in option.then() }
            }
        } + [CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.controller.dismissTemplate(animated: true) { _, _ in } }]
        controller.presentTemplate(CPActionSheetTemplate(title: title, message: message, actions: actions), animated: true) { _, _ in }
    }
    /// A row that says something and does nothing.
    private func fact(_ text: String, _ detail: String?, symbol: String) -> CPListItem { item(text, detail, symbol: symbol) {} }
    private func line(_ session: Session) -> String {
        [session.status.capitalized, session.model].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " · ")
    }

    // MARK: Browse

    func browse() {
        guard let project else { second(projects()); return }
        var rows: [CPListItem] = []
        if store.supports("start_session") { rows.append(item("New conversation", symbol: "square.and.pencil", more: true) { [weak self] in self?.newConversation() }) }
        rows.append(item("Conversations", symbol: "bubble.left.and.bubble.right", more: true) { [weak self] in self.map { $0.third($0.conversations()) } })
        if store.supports("complete_findings") { rows.append(item("Findings", "Review rounds waiting for a decision", symbol: "flag", more: true) { [weak self] in self.map { $0.third($0.conversations(holding: true)) } }) }
        if store.supports("pulls") {
            rows.append(item("Pull requests", symbol: "arrow.triangle.pull", more: true) { [weak self] in self.map { $0.third($0.pulls()) } })
            rows.append(item("Issues", symbol: "smallcircle.filled.circle", more: true) { [weak self] in self.map { $0.third($0.issues()) } })
        }
        let app = [
            item("Switch project", symbol: "folder", more: true) { [weak self] in self.map { $0.third($0.projects()) } },
            item("Connection", store.canManage ? nil : "Read-only access", symbol: "network", more: true) { [weak self] in self.map { $0.third($0.connection()) } },
        ]
        second(CPListTemplate(title: "Browse", sections: Self.fit([section(project.title, rows), section("Briareus", app)])))
    }
    private func projects() -> CPListTemplate {
        list("Projects", empty: "No projects") { [weak self] show in
            guard let self else { return }
            let rows = { (projects: [Project]) in
                show([self.section(nil, projects.map { project in
                    self.item(project.title, project.title != project.repo ? project.repo : nil, symbol: "folder") { [weak self] in
                        guard let self else { return }
                        self.project = project; self.plan = Plan()
                        self.close()
                    }
                })])
            }
            if let saved: [Project] = await self.store.cache.value("projects") { rows(saved) }
            let result: ProjectList = try await self.store.call("projects")
            rows(result.projects)
            await self.store.cache.store(result.projects, for: "projects")
        }
    }
    /// A project's conversations, or only those holding findings for a decision.
    private func conversations(holding: Bool = false) -> CPListTemplate {
        list(holding ? "Findings" : "Conversations", empty: holding ? "No findings waiting" : "No conversations") { [weak self] show in
            guard let self, let project = self.project else { return }
            let rows = { (sessions: [Session]) in
                let row = { (session: Session) in
                    self.item(session.displayTitle, holding ? CarText.count(session.heldTriage?["findings"].array.count ?? 0, "finding") : self.line(session),
                              symbol: holding ? "flag.fill" : session.isActive ? "circle.fill" : "circle") { [weak self] in self?.open(session) }
                }
                if holding { show([self.section(nil, Session.holdingFindings(sessions).map(row))]); return }
                let open = sessions.filter { $0.status != "closed" }
                show([self.section("Active", open.filter(\.isActive).map(row)), self.section("Recent", open.filter { !$0.isActive }.map(row)),
                      self.section("Closed", sessions.filter { $0.status == "closed" }.map(row))])
            }
            let key = "sessions:\(project.repo)"
            if let saved: [Session] = await self.store.cache.value(key) { rows(saved) }
            let result: SessionList = try await self.store.call("sessions", ["repo": .string(project.repo)])
            rows(result.sessions)
            await self.store.cache.store(result.sessions, for: key)
        }
    }
    private func pulls() -> CPListTemplate {
        list("Pull requests", empty: "No open pull requests") { [weak self] show in
            guard let self, let project = self.project else { return }
            let rows = { (board: JSONValue) in
                show([self.section(nil, board["pulls"].array.compactMap(PullSummary.init).map { pr in
                    var said = ["#\(pr.number)"]
                    if pr.draft { said.append("Draft") }
                    if pr.hasConflicts { said.append("Conflicts") }
                    if let checks = pr.checks { said.append(checks == "success" ? "Checks passed" : pr.checksFailed ? "Checks failed" : "Checks running") }
                    if let author = pr.author { said.append("@\(author)") }
                    return self.item(pr.title, said.joined(separator: " · "), symbol: pr.hasConflicts || pr.checksFailed ? "exclamationmark.triangle" : "arrow.triangle.pull") { [weak self] in
                        self?.open(pull: pr.number, row: pr)
                    }
                })])
            }
            let key = "pulls:\(project.repo)"
            if let saved: JSONValue = await self.store.cache.value(key) { rows(saved) }
            let result: JSONValue = try await self.store.call("pulls", ["repo": .string(project.repo)])
            rows(result)
            await self.store.cache.store(result, for: key)
        }
    }
    private func issues() -> CPListTemplate {
        list("Issues", empty: "No open issues") { [weak self] show in
            guard let self, let project = self.project else { return }
            let rows = { (board: JSONValue) in
                let nested = IssueSummary.nested(board["issues"].array.compactMap(IssueSummary.init), repo: project.repo)
                show([self.section(nil, nested.map { row in
                    var said = ["#\(row.issue.number)"]
                    if row.issue.isEpic { said.append("Epic \(row.issue.subIssuesDone)/\(row.issue.subIssues)") }
                    if let parent = row.issue.parent, row.depth > 0 { said.append("In #\(parent.number)") }
                    said += row.issue.labels.prefix(2).map(\.name)
                    return self.item(row.issue.title, said.joined(separator: " · "), symbol: row.issue.isEpic ? "square.stack.3d.up" : "smallcircle.filled.circle") { [weak self] in
                        self?.open(issue: row.issue)
                    }
                })])
            }
            let key = "pulls:\(project.repo)"
            if let saved: JSONValue = await self.store.cache.value(key) { rows(saved) }
            let result: JSONValue = try await self.store.call("pulls", ["repo": .string(project.repo)])
            if let refused = result["issuesError"].string, result["issues"].array.isEmpty { throw APIError.http(502, refused, retryAfter: nil) }
            rows(result)
            await self.store.cache.store(result, for: key)
        }
    }
    private func connection() -> CPListTemplate {
        var about = [item(store.server, "Connected dashboard", symbol: "checkmark.seal") {}]
        if let device = store.device {
            about.append(item(device.label, "\(device.canManage ? "Manage" : "Read only") · expires \(device.expiry.formatted(date: .abbreviated, time: .omitted))", symbol: "iphone.gen3") {})
        }
        let leave = [
            item("Revoke token and disconnect", "Disables this token on the server", symbol: "xmark.shield") { [weak self] in
                self?.ask(["Revoke this device token? Pairing again takes the phone.", "Revoke this token?"], yes: "Revoke", destructive: true) {
                    self?.perform(nil) { try await self?.store.revoke() }
                }
            },
            item("Forget this connection", "Removes it from this iPhone only", symbol: "trash") { [weak self] in
                self?.ask(["Forget this connection? Pairing again takes the phone.", "Forget this connection?"], yes: "Forget", destructive: true) {
                    self?.perform(nil) { try await self?.store.forget() }
                }
            },
        ]
        return CPListTemplate(title: "Connection", sections: Self.fit([section(nil, about), section("Neither stops running agents", leave)]))
    }

    // MARK: A new conversation

    private func newConversation() {
        guard let project else { return }
        let template = CPListTemplate(title: "New conversation", sections: planRows())
        second(template)
        guard store.supports("runtimes") else { return }
        Task {
            // Without the catalog the server still starts on the project's configured runtime.
            let key = "runtimes:\(project.repo)"
            let show = { [weak self] (catalog: RuntimeCatalog) in
                guard let self, self.project?.repo == project.repo else { return }
                self.plan.catalog = catalog
                if catalog.default == nil && self.plan.runtime == nil { self.plan.runtime = catalog.firstAvailable }
                template.updateSections(self.planRows())
            }
            if let saved: RuntimeCatalog = await store.cache.value(key), plan.catalog == nil { show(saved) }
            guard let result: RuntimeCatalog = try? await store.call("runtimes", ["repo": .string(project.repo)]) else { return }
            show(result)
            await store.cache.store(result, for: key)
        }
    }
    private func planRows() -> [CPListSection] {
        let chosen = plan.runtime ?? plan.catalog?.default
        var options = [item("Branch", plan.branch.isEmpty ? "Default branch" : plan.branch, symbol: "arrow.triangle.branch", more: true) { [weak self] in self.map { $0.third($0.branches()) } }]
        if let catalog = plan.catalog, !catalog.providers.isEmpty {
            let named = chosen.map { catalog.label(for: $0) + (plan.runtime == nil ? " · project default" : "") } ?? "Choose a model"
            options.append(item("Model", named, symbol: "cpu", more: true) { [weak self] in self.map { $0.third($0.models(catalog)) } })
            if let chosen, !catalog.efforts(for: chosen).isEmpty {
                options.append(item("Effort", (chosen.effort ?? "default").capitalized, symbol: "gauge.with.dots.needle.50percent") { [weak self] in
                    self?.choose("Effort", nil, catalog.efforts(for: chosen).map { effort in
                        (effort.capitalized, false, { self?.replan { $0.runtime = RuntimeChoice(providerId: chosen.providerId, model: chosen.model, effort: effort) } })
                    })
                })
            }
        }
        let ready = plan.catalog == nil || chosen != nil
        let start = item("Dictate the task", ready ? "Starts a paid agent once you said yes" : "Choose a model first", symbol: "mic.fill") { [weak self] in
            if ready { self?.dictate(.prompt) }
        }
        start.isEnabled = ready
        return Self.fit([section(project?.title, [start]), section("Runs on", options)])
    }
    /// Changes what the conversation starts on and shows it on the list the choice was opened from.
    private func replan(_ change: (inout Plan) -> Void) {
        change(&plan)
        let update = { [weak self] in
            guard let self, let template = self.controller.templates.last as? CPListTemplate, self.controller.templates.count == 2 else { return }
            template.updateSections(self.planRows())
        }
        if controller.templates.count > 2 { controller.popTemplate(animated: true) { _, _ in update() } } else { update() }
    }
    private func branches() -> CPListTemplate {
        list("Branch", empty: "No branches") { [weak self] show in
            guard let self, let project = self.project else { return }
            let rows = { (result: JSONValue) in
                let standard = result["defaultBranch"].string
                let rest = result["branches"].array.compactMap(\.string).filter { $0 != standard }
                show([self.section(nil, [self.item(standard.map { "\($0) (default)" } ?? "Default branch", symbol: self.plan.branch.isEmpty ? "checkmark" : nil) { [weak self] in
                    self?.replan { $0.branch = "" }
                }]), self.section(nil, rest.map { branch in
                    self.item(branch, symbol: self.plan.branch == branch ? "checkmark" : nil) { [weak self] in self?.replan { $0.branch = branch } }
                })])
            }
            guard self.store.supports("branches") else { rows(.null); return }
            let key = "branches:\(project.repo)"
            if let saved: JSONValue = await self.store.cache.value(key) { rows(saved) }
            let result: JSONValue = try await self.store.call("branches", ["repo": .string(project.repo)])
            rows(result)
            await self.store.cache.store(result, for: key)
        }
    }
    private func models(_ catalog: RuntimeCatalog) -> CPListTemplate {
        let chosen = plan.runtime ?? catalog.default
        var sections: [CPListSection?] = []
        if let standard = catalog.default {
            sections.append(section(nil, [item("Project default", catalog.label(for: standard), symbol: plan.runtime == nil ? "checkmark" : "gearshape") { [weak self] in
                self?.replan { $0.runtime = nil }
            }]))
        }
        for provider in catalog.providers {
            guard provider.isAvailable else {
                let row = item(provider.label, "Unavailable") {}
                row.isEnabled = false
                sections.append(section(nil, [row])); continue
            }
            let rows = provider.models.isEmpty
                ? [item(provider.label, symbol: chosen?.providerId == provider.id ? "checkmark" : nil) { [weak self] in self?.replan { $0.runtime = catalog.choice(provider: provider.id) } }]
                : provider.models.map { model in
                    item(model.title, symbol: plan.runtime != nil && chosen?.providerId == provider.id && chosen?.model == model.id ? "checkmark" : nil) { [weak self] in
                        self?.replan { $0.runtime = catalog.choice(provider: provider.id, model: model.id) }
                    }
                }
            sections.append(section(provider.label, rows))
        }
        return CPListTemplate(title: "Model", sections: Self.fit(sections))
    }

    // MARK: Actions

    func actions() {
        switch focus {
        case .conversation: if let session { second(CPListTemplate(title: "Actions", sections: actions(on: session))) }
        case .pull(let number): second(CPListTemplate(title: "Pull request #\(number)", sections: actions(onPull: number)))
        case .issue(let issue): second(CPListTemplate(title: "Issue #\(issue.number)", sections: actions(on: issue)))
        case .nothing: break
        }
    }
    private func putDown(_ what: String) -> CPListItem {
        item("Put down this \(what)", "Back to \(project?.title ?? "the project")", symbol: "arrow.uturn.backward") { [weak self] in self?.close() }
    }

    private func actions(on session: Session) -> [CPListSection] {
        var talk: [CPListItem] = []
        let question = CarText.openQuestion(transcript.events)
        if let question { talk.append(fact(CarText.question(question), "The agent asks", symbol: "questionmark.bubble")) }
        if canMessage {
            talk.append(item(session.isActive ? "Dictate a follow-up" : "Dictate a reply", session.isActive ? (session.liveInput == true ? "Sent into the running turn" : "Queued for the next turn") : nil,
                             symbol: "mic") { [weak self] in self?.dictate(.message) })
            if let question {
                talk += CarText.options(question).map { answer in item("Answer: \(answer)", symbol: "arrow.turn.down.left") { [weak self] in self?.send(answer) } }
            }
        }

        var agent: [CPListItem] = []
        if store.supports("cancel") && session.isActive {
            agent.append(item("Stop the agent", symbol: "stop.circle") { [weak self] in
                self?.ask(["Stop the running agent?", "Stop the agent?"], yes: "Stop", destructive: true) { self?.change("cancel", done: "The agent is stopped.") }
            })
        }
        if store.supports("drop_message") {
            agent += (session.queued ?? []).enumerated().map { index, queued in
                item("Remove a queued message", queued["text"].string, symbol: "clock.badge.xmark") { [weak self] in
                    self?.change("drop_message", ["index": .number(Double(index))], done: "The queued message is removed.")
                }
            }
        }
        if store.supports("review_loop") && session.canReviewLoop {
            agent.append(item("Review loop", session.reviewLoopOn ? "On" : "Off", symbol: "repeat") { [weak self] in
                if session.reviewLoopOn { self?.change("review_loop", ["on": .bool(false)], done: "The review loop is off."); return }
                self?.ask(["Turn on the review loop? Each push gets a paid review round, and may start one now.", "Turn on the review loop?"], yes: "Turn on") {
                    self?.change("review_loop", ["on": .bool(true)], done: "The review loop is on.")
                }
            })
        }
        if let held = session.heldTriage, store.supports("complete_findings") {
            agent.append(item("Findings", "\(CarText.count(held["findings"].array.count, "finding")) waiting for a decision", symbol: "flag.fill", more: true) { [weak self] in
                self.map { $0.third($0.triageList(held)) }
            })
        }

        var more: [CPListItem] = []
        if let number = session.pullNumber, store.supports("pull") {
            more.append(item("Pull request #\(number)", symbol: "arrow.triangle.pull") { [weak self] in self?.open(pull: number) })
        }
        if store.supports("rename") { more.append(item("Rename", "Dictated", symbol: "pencil") { [weak self] in self?.dictate(.rename) }) }
        if store.supports("close") && session.status != "closed" {
            more.append(item("Close the conversation", symbol: "archivebox") { [weak self] in
                self?.ask(["Close this conversation?", "Close it?"], yes: "Close") { self?.change("close", done: "The conversation is closed.") }
            })
        }
        if store.supports("reopen") && session.status == "closed" {
            more.append(item("Reopen", symbol: "arrow.uturn.backward") { [weak self] in
                self?.ask(["Reopen this conversation?", "Reopen it?"], yes: "Reopen") { self?.change("reopen", done: "The conversation is open again.") }
            })
        }
        if store.supports("delete") {
            more.append(item("Delete the conversation", symbol: "trash") { [weak self] in
                self?.ask(["Permanently delete this conversation and its transcript?", "Delete it for good?"], yes: "Delete", destructive: true) { self?.delete() }
            })
        }
        more.append(putDown("conversation"))
        return Self.fit([section(CarText.status(session, asking: question != nil), talk), section("Agent", agent), section("More", more)])
    }

    /// The round held for verdicts. An unmarked finding goes as optional, as on the dashboard and on the phone.
    private func triageList(_ triage: JSONValue) -> CPListTemplate {
        let template = CPListTemplate(title: "Findings", sections: [])
        let mine = triage["mine"].bool ?? true
        let titles = Dictionary(uniqueKeysWithValues: FindingsTriageCard.options.map { ($0.id, $0.title) })
        func decision(_ finding: JSONValue) -> String {
            guard let key = finding["key"].string else { return "" }
            return verdicts[key] ?? triage["drafts"]["verdicts"][key]["decision"].string ?? ""
        }
        func rows() -> [CPListSection] {
            let findings = triage["findings"].array
            let fixes = findings.filter { decision($0) == "fix" }.count
            var complete = [item(mine ? "Complete the triage" : "Clear the findings",
                                 !mine ? "Its author fixes them" : fixes == 0 ? "Without fixes" : "Starts a paid fix session for \(CarText.count(fixes, "finding"))",
                                 symbol: "checkmark.circle") { [weak self] in
                let question = !mine ? "Clear these findings?" : fixes == 0 ? "Complete the triage without fixes?" : "Start a paid fix session for \(CarText.count(fixes, "finding"))?"
                self?.ask([question, mine ? "Complete the triage?" : "Clear them?"], yes: mine ? "Complete" : "Clear") { self?.triage() }
            }]
            if mine {
                complete.append(item("Dictate a note for the fix session", note.isEmpty ? nil : note, symbol: "mic") { [weak self] in self?.dictate(.note) })
            }
            let list = findings.map { finding -> CPListItem in
                item(finding["title"].string ?? "Finding", CarText.finding(finding, verdict: titles[decision(finding)]),
                     symbol: decision(finding) == "fix" ? "wrench.and.screwdriver" : "flag") { [weak self] in
                    guard mine, let key = finding["key"].string else { return }
                    self?.choose(finding["title"].string ?? "Finding", finding["parkedWhy"].string, FindingsTriageCard.options.map { option in
                        (option.title, false, { self?.verdicts[key] = option.id; template.updateSections(rows()) })
                    })
                }
            }
            return Self.fit([section(nil, complete), section(mine ? "Verdicts go on the pull request" : nil, list)])
        }
        template.updateSections(rows())
        return template
    }

    private func actions(onPull number: Int) -> [CPListSection] {
        var about: [CPListItem] = []
        if pull != .null {
            about.append(fact("Checks", CarText.checks(pull["checks"]), symbol: (pull["checks"]["failed"].double ?? 0) > 0 ? "xmark.circle" : "checkmark.circle"))
            let said = CarText.reviews(pull).map { "\($0.user): \($0.state)" }
            about.append(item("Review", review ?? "No reviews yet", symbol: "person.2") { [weak self] in
                if !said.isEmpty { self?.warn(said.prefix(6).joined(separator: ", ")) }
            })
        }
        if store.supports("findings") && !findings.isEmpty {
            about.append(item("Findings", CarText.count(findings.count, "finding"), symbol: "flag", more: true) { [weak self] in self.map { $0.third($0.findingsList()) } })
        }
        if !runs.isEmpty {
            about.append(item("Conversations on it", CarText.count(runs.count, "conversation"), symbol: "bubble.left.and.bubble.right", more: true) { [weak self] in
                guard let self else { return }
                self.third(CPListTemplate(title: "Conversations", sections: Self.fit([self.section(nil, self.runs.map { session in
                    self.item(session.displayTitle, self.line(session), symbol: session.isActive ? "circle.fill" : "circle") { [weak self] in self?.open(session) }
                })])))
            })
        }
        let canMerge = store.supports("merge_pull") && pull["state"].string == "open" && pull["draft"].bool != true
            && pull["headSha"].string != nil && pull["baseRef"].string != nil
        if canMerge {
            about.append(item("Merge", "Into \(pull["baseRef"].string ?? "its base") · cannot be undone from here", symbol: "arrow.triangle.merge") { [weak self] in self?.prepareMerge(number) })
        }
        let errands = offered.map { action in
            item(action.label, row?.recommended == action.id ? "Suggested" : action.input != nil ? "Dictated" : nil, symbol: row?.recommended == action.id ? "sparkle" : "bolt") { [weak self] in
                if action.input != nil { self?.dictate(.feedback(action)); return }
                self?.ask(["Start a paid \(action.label) session on #\(number)? \(action.hint).", "Start \(action.label)?"], yes: "Start",
                          destructive: action.id == "delete-self-comments") { self?.run(action) }
            }
        }
        return Self.fit([section(row?.title ?? pull["title"].string, about), section("Paid agents, may write to GitHub", errands), section(nil, [putDown("pull request")])])
    }
    private func findingsList() -> CPListTemplate {
        let titles = Dictionary(uniqueKeysWithValues: FindingsTriageCard.options.map { ($0.id, $0.title) })
        let decides = store.supports("finding_decision")
        return CPListTemplate(title: "Findings", sections: Self.fit([section(nil, findings.map { finding in
            let fixed = finding["fixed"].bool == true
            let verdict = finding["decision"].string.map { titles[$0] ?? $0.capitalized } ?? "Undecided"
            return item(finding["title"].string ?? "Finding", CarText.finding(finding, verdict: verdict), symbol: fixed ? "checkmark.circle" : "flag") { [weak self] in
                guard decides, !fixed, let key = finding["key"].string else { return }
                var options: [(String, Bool, () -> Void)] = FindingsTriageCard.options.map { option in (option.title, false, { self?.decide(key, option.id) }) }
                if finding["decision"].string != nil { options.append(("Clear the decision", false, { self?.decide(key, nil) })) }
                self?.choose(finding["title"].string ?? "Finding", nil, options)
            }
        })]))
    }
    /// Reads what GitHub allows before asking, so that only methods the repository accepts are offered.
    private func prepareMerge(_ number: Int) {
        guard let project else { return }
        Task {
            var methods = ["squash", "merge", "rebase"]
            var notes: [String] = []
            if store.supports("pull_files"),
               let page: PullFilesPage = try? await store.call("pull_files", ["repo": .string(project.repo), "pr": .number(Double(number))]) {
                let allowed = page.pr["mergeMethods"].array.compactMap(\.string)
                if !allowed.isEmpty { methods = methods.filter(allowed.contains) }
                notes += MergeState.warnings(mergeable: page.pr["mergeable"], state: page.pr["mergeableState"].string)
                if let head = page.pr["headSha"].string, head != pull["headSha"].string {
                    guard (try? await load(pull: number)) != nil else { warn("The pull request changed and could not be read again."); return }
                    notes.append("New commits were pushed.")
                }
            }
            let failed = Int(pull["checks"]["failed"].double ?? 0), pending = Int(pull["checks"]["pending"].double ?? 0)
            if failed > 0 { notes.append("\(failed) check\(failed == 1 ? " is" : "s are") failing.") }
            if pending > 0 { notes.append("\(pending) check\(pending == 1 ? " is" : "s are") still running.") }
            let titles = ["squash": "Squash and merge", "merge": "Create a merge commit", "rebase": "Rebase and merge"]
            guard case .pull(number) = focus else { return }
            choose("Merge #\(number) into \(pull["baseRef"].string ?? "its base")?", notes.isEmpty ? nil : notes.joined(separator: " "),
                   methods.map { method in (titles[method] ?? method.capitalized, false, { [weak self] in self?.merge(method) }) })
        }
    }

    private func actions(on issue: IssueSummary) -> [CPListSection] {
        let said = ["#\(issue.number)"] + (issue.isEpic ? ["Epic \(issue.subIssuesDone)/\(issue.subIssues)"] : []) + issue.labels.prefix(3).map(\.name)
            + (issue.comments > 0 ? [CarText.count(issue.comments, "comment")] : [])
        var rows = [fact(issue.author.map { "By @\($0)" } ?? "Issue", said.joined(separator: " · "), symbol: "smallcircle.filled.circle")]
        if store.supports("start_session") {
            rows.append(item("Start a session on it", "Starts a paid agent", symbol: "play") { [weak self] in
                self?.ask(["Start a paid session on issue #\(issue.number)?", "Start a session?"], yes: "Start") { self?.begin(on: issue) }
            })
        }
        let answers = !store.supports("pull") ? [] : issue.pulls.filter { !$0.isForeign(to: project?.repo ?? "") }.map { link in
            item(link.title, "#\(link.number)\(link.draft ? " · Draft" : "")", symbol: "arrow.triangle.pull") { [weak self] in self?.open(pull: link.number) }
        }
        return Self.fit([section(issue.title, rows), section("Answered by", answers), section(nil, [putDown("issue")])])
    }
}
#endif
