// The Windows client's opening view (screen_new_session.c): "Welcome back", and the composer that starts a session, with its
// row of chips for the project, branch, provider, model, effort and the review loop.
import AppKit
import SwiftUI

@MainActor
final class NewSessionModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var chosen = 0
    @Published private(set) var catalog: RuntimeCatalog?
    /// The pick; none starts on the project default.
    @Published private(set) var runtime: RuntimeChoice?
    @Published private(set) var branches: [String] = []
    @Published private(set) var defaultBranch: String?
    /// Nil: a new branch off the default.
    @Published private(set) var branch: String?
    @Published var reviewLoop = true
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?

    let composer = ComposerState()
    let files = Attachments(call: "start_session")
    let voice = VoiceNote()
    private var choicesTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var projectsAsked = false

    init(repo: String?) {
        var list = ProjectsModel.shared.projects
        if list.isEmpty, let repo { list = [Project(repo: repo)] }
        // Opened before the sidebar has its list: what was saved serves until the server answers.
        if list.isEmpty, let saved = Store.shared.cache.value("projects").flatMap(Project.parseList) { list = saved }
        projects = list
        chosen = list.firstIndex { $0.repo == repo } ?? 0
        voice.onText = { [weak self] text in
            guard let self else { return }
            self.composer.text = appendDictation(self.composer.text, text)
        }
    }

    var project: Project? { projects.isEmpty ? nil : projects[min(chosen, projects.count - 1)] }
    /// What the session would start on: the pick, else the project's default.
    var effective: RuntimeChoice? { runtime ?? catalog?.defaultChoice }
    /// A session starts on a prompt, on files, or on both; never while a file is still uploading.
    var canStart: Bool {
        !busy && !uncertain && project != nil && (!composer.trimmedEmpty || files.count > 0) && !files.uploading
    }

    func appeared() {
        if projects.isEmpty && !projectsAsked {
            projectsAsked = true
            Task {
                guard await ProjectsModel.shared.load() == nil else { return }
                projects = ProjectsModel.shared.projects
                chosen = 0
                loadChoices()
            }
        }
        if !projects.isEmpty && catalog == nil && choicesTask == nil { loadChoices() }
    }
    func disappeared() {
        voice.drop()
        choicesTask?.cancel(); choicesTask = nil
        // Gone from the screen: a start still under way does not pull the window back to its conversation.
        startTask?.cancel(); startTask = nil
    }

    // MARK: What the chips offer

    /// Reads what the picked project offers: its runtimes and branches, the saved answer first.
    func loadChoices() {
        choicesTask?.cancel()
        catalog = nil; runtime = nil; branches = []; defaultBranch = nil; branch = nil
        guard let p = project else { return }
        let store = Store.shared
        if store.supports("runtimes"), let saved = store.cache.value("runtimes:\(p.repo)") { catalog = RuntimeCatalog(saved) }
        if store.supports("branches"), let saved = store.cache.value("branches:\(p.repo)") { adoptBranches(saved) }
        choicesTask = Task {
            await withTaskGroup(of: Void.self) { group in
                if store.supports("runtimes") {
                    group.addTask { @MainActor in
                        guard let answer = try? await store.call("runtimes", ["repo": .string(p.repo)]), !Task.isCancelled,
                              self.project?.repo == p.repo, let c = RuntimeCatalog(answer) else { return }
                        self.catalog = c
                        if c.defaultChoice == nil && self.runtime == nil { self.runtime = c.firstAvailable() }
                        store.cache.store(answer, "runtimes:\(p.repo)")
                    }
                }
                if store.supports("branches") {
                    group.addTask { @MainActor in
                        guard let answer = try? await store.call("branches", ["repo": .string(p.repo)]), !Task.isCancelled,
                              self.project?.repo == p.repo else { return }
                        self.adoptBranches(answer)
                        store.cache.store(answer, "branches:\(p.repo)")
                    }
                }
            }
        }
    }
    private func adoptBranches(_ value: JSON) {
        branches = value["branches"].items.compactMap(\.string)
        defaultBranch = value["defaultBranch"].string
    }

    func chipLabel(_ chip: ComposerChip) -> String {
        let eff = effective
        switch chip {
        case .workspace: return "\u{2317} Worktree"
        case .project: return project?.title ?? "Project"
        case .branch: return branch ?? "New branch off \(defaultBranch ?? "main")"
        case .provider: return eff.flatMap { catalog?.provider($0.providerId)?.label } ?? "Provider"
        case .model:
            if let eff, let m = catalog?.model(for: eff) { return m.title }
            return eff?.model ?? "Model"
        case .effort: return eff?.effort ?? "effort"
        case .loop: return reviewLoopChipText(reviewLoop)
        }
    }
    func chipShown(_ chip: ComposerChip) -> Bool {
        switch chip {
        case .provider, .model: return !(catalog?.providers.isEmpty ?? true)
        case .effort: return effective.map { !(catalog?.efforts(for: $0).isEmpty ?? true) } ?? false
        case .branch: return Store.shared.supports("branches")
        case .loop: return Store.shared.supports("review_loop")
        default: return true
        }
    }
    static func isPicker(_ chip: ComposerChip) -> Bool { chip != .loop && chip != .workspace }

    func pick(_ chip: ComposerChip) {
        if busy { return }
        let eff = effective
        switch chip {
        case .project:
            let rows = projects.enumerated().map { MenuRow(title: $0.element.title, checked: $0.offset == chosen) }
            if let i = popUpMenu(rows), i != chosen { chosen = i; loadChoices() }
        case .branch:
            var rows = [MenuRow(title: "New branch off \(defaultBranch ?? "main")", checked: branch == nil)]
            let shown = Array(branches.prefix(60))
            if !shown.isEmpty { rows.append(.divider) }
            rows += shown.map { MenuRow(title: $0, checked: branch == $0) }
            guard let i = popUpMenu(rows) else { return }
            branch = i == 0 ? nil : shown[i - 2]
        case .provider:
            guard let catalog else { return }
            let rows = catalog.providers.map { p in
                MenuRow(title: p.isAvailable ? p.label : "\(p.label) (unavailable)", checked: eff?.providerId == p.id, enabled: p.isAvailable)
            }
            guard let i = popUpMenu(rows) else { return }
            let p = catalog.providers[i]
            if let c = catalog.choice(provider: p.id, model: p.defaultModel ?? p.models.first?.id) { runtime = c }
        case .model:
            guard let catalog, let eff, let p = catalog.provider(eff.providerId) else { return }
            let rows = p.models.map { MenuRow(title: $0.title, checked: eff.model == $0.id) }
            guard let i = popUpMenu(rows) else { return }
            if let c = catalog.choice(provider: p.id, model: p.models[i].id) { runtime = c }
        case .effort:
            guard let catalog, let eff else { return }
            let efforts = catalog.efforts(for: eff)
            let rows = efforts.map { MenuRow(title: $0, checked: eff.effort == $0) }
            guard let i = popUpMenu(rows) else { return }
            runtime = RuntimeChoice(providerId: eff.providerId, model: eff.model, effort: efforts[i])
        case .loop: reviewLoop.toggle()
        case .workspace: break
        }
    }

    // MARK: Starting

    func start() {
        guard canStart, let p = project, Store.shared.supports("start_session") else { return }
        var args: JSON = ["repo": .string(p.repo)]
        if !composer.trimmedEmpty { args["prompt"] = .string(composer.text) }
        if let ids = files.ids { args["attachments"] = ids }
        if let branch { args["branch"] = .string(branch) }
        if let runtime { args.merge(runtime.arguments) }
        busy = true; error = nil
        let loop = reviewLoop
        startTask = Task {
            do {
                let answer = try await Store.shared.call("start_session", args)
                busy = false
                if Task.isCancelled { return }
                guard let started = Session(answer["session"]) else { error = "The server returned an unexpected response."; return }
                composer.text = ""
                files.sent(args["attachments"].isNull ? nil : args["attachments"])
                // The loop the chip asked for that the server does not arm by default.
                if !loop && Store.shared.supports("review_loop") && started.canReviewLoop {
                    Task { _ = try? await Store.shared.call("review_loop", ["sessionId": .string(started.id), "on": false]) }
                }
                post(.sessionsChanged, ["repo": p.repo])
                Navigator.shared.show(.conversation(id: started.id, session: started.raw))
            } catch {
                busy = false
                if error.isCancellation { return }
                self.error = errorText(error)
                if !((error as? APIError)?.isRefusal ?? false) { uncertain = true }
            }
        }
    }
}

struct NewSessionScreen: View {
    var repo: String?
    @StateObject private var model: NewSessionModel
    @ObservedObject private var store = Store.shared
    @Environment(\.paneBack) private var back

    init(repo: String?) {
        self.repo = repo
        _model = StateObject(wrappedValue: NewSessionModel(repo: repo))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The screen has no header of its own; one column away from the sidebar, the back button still shows.
            if back != nil { PaneHeader(title: "") }
            GeometryReader { g in
                ScrollView {
                    welcome
                        .padding(.top, g.size.height * 14 / 100)
                        .padding(.horizontal, Theme.paneMargin)
                        .frame(maxWidth: .infinity)
                }
            }
            NewSessionFooter(model: model, composer: model.composer, files: model.files, voice: model.voice)
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .onChange(of: store.active) { _, active in
            if !active && model.voice.state == .recording { model.voice.stop() }
        }
    }

    /// `#welcome`: `mx-auto mt-[14vh] max-w-[640px] text-center`.
    private var welcome: some View {
        VStack(spacing: 0) {
            Text("Welcome back").font(Theme.largeTitle).foregroundStyle(Theme.ink).lineLimit(1)
            (Text("Start a session in a fresh ").foregroundColor(Theme.muted)
             + Text(model.project?.title ?? "project").foregroundColor(Theme.accent)
             + Text(" checkout with its own database.").foregroundColor(Theme.muted))
                .font(Theme.body).multilineTextAlignment(.center).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text("Pick a provider and model below, then describe what to build.")
                .font(Theme.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.projects.isEmpty {
                Text("No projects yet, so there is nothing to build. Add one in \u{2699} Settings \u{2192} Projects.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: 640)
    }
}

/// The chips and the composer, 8px above, the box, and the note under it.
private struct NewSessionFooter: View {
    @ObservedObject var model: NewSessionModel
    @ObservedObject var composer: ComposerState
    @ObservedObject var files: Attachments
    @ObservedObject var voice: VoiceNote
    @ObservedObject private var store = Store.shared

    var body: some View {
        FooterColumn {
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(ComposerChip.allCases.filter(model.chipShown), id: \.self) { chip in
                        ComposerChipView(label: model.chipLabel(chip), on: chip == .loop && model.reviewLoop,
                                         live: !(chip == .workspace || model.busy), picker: NewSessionModel.isPicker(chip),
                                         action: { model.pick(chip) })
                    }
                }
                .padding(.top, 8).padding(.bottom, 8)
                ComposerBox(files: files, text: $composer.text, lines: $composer.lines, focused: $composer.focused,
                            placeholder: "Describe what to build\u{2026}", focus: composer.focus, filesEnabled: !model.busy,
                            onSubmit: { model.start() },
                            onPaste: { files.paste($0) },
                            onDrop: { files.drop($0) },
                            onTap: { composer.focusNow() }) {
                    if files.supported {
                        AttachButton(enabled: !model.busy && files.count < attachmentsMax) { if !model.busy { files.pick() } }
                    }
                    if store.canTranscribe {
                        MicButton(voice: voice, showsWait: false)
                        VoiceClock(voice: voice).padding(.leading, 2)
                    }
                } trailing: {
                    SendButton(filled: model.canStart) { model.start() }
                }
                let note = model.busy ? "Starting the session\u{2026}" : model.error ?? (files.uploading ? "Uploading\u{2026}" : "")
                Text(note).font(Theme.footnote).foregroundStyle(model.error != nil && !model.busy ? Theme.danger : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity).frame(height: 16)
                    .padding(.top, 6).padding(.bottom, 14)
            }
        }
        .background(Theme.canvas)
    }
}
