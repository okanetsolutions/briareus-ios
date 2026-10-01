// One conversation (screen_conversation.c): its transcript, read a little at a time after the saved part; the composer;
// and the actions on the session. The column beside it is the session's panel.
import AppKit
import SwiftUI

// MARK: - The composer's own state

/// What is typed, kept apart from the conversation so a keystroke does not lay the transcript out again.
@MainActor
final class ComposerState: ObservableObject {
    @Published var text = ""
    @Published var lines = 1
    @Published var focused = false
    @Published var focus = FocusRequest()
    var trimmedEmpty: Bool { text.cTrimmed.isEmpty }
    func focusNow() { focus.tick += 1 }
}

/// Text typed into a conversation that was left for a screen pushed over it, until it comes back.
@MainActor
enum ConversationDrafts { static var text: [String: String] = [:] }

// MARK: - The model

@MainActor
final class ConversationModel: ObservableObject {
    let id: String
    let initial: Session
    @Published private(set) var snapshot: Session?
    var session: Session { snapshot ?? initial }

    @Published private(set) var transcript = Transcript()
    @Published private(set) var blocks: [TranscriptBlock] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?
    @Published private(set) var writeError: String?
    /// Tool and preparation blocks opened, by their first event's sequence.
    @Published var expanded: Set<Int> = []
    /// Verdicts picked here for the held round, by finding key.
    @Published var decisions: [String: String] = [:]
    @Published var triageNote = ""
    /// Bumped to scroll the transcript to its end and keep it there.
    @Published private(set) var scrollToEnd = 0

    private var restored = false, unsaved = false, retimed = false, pendingFull = false
    var dialogOpen = false

    let composer = ComposerState()
    let files = Attachments(call: "message")
    let voice = VoiceNote()

    init(id: String, initial: JSON?) {
        self.id = id
        self.initial = initial.flatMap(Session.init) ?? Session(raw: ["id": .string(id), "status": ""])
        composer.text = ConversationDrafts.text[id] ?? ""
        voice.onText = { [weak self] text in
            guard let self else { return }
            self.composer.text = appendDictation(self.composer.text, text)
        }
    }

    private var cacheKey: String { "transcript:\(id)" }
    var screenID: String { "conversation:\(id)" }
    var canMessage: Bool { Store.shared.supports("message") && session.status != "closed" }
    /// Nothing is in flight and no earlier write left its outcome unknown.
    var can: Bool { !busy && !uncertain }

    // MARK: Reading

    /// Reads what happened since the cursor, or the whole transcript; a read already under way keeps a full one for after.
    @discardableResult
    func refresh(full requested: Bool) async -> APIError? {
        if loading { if requested { pendingFull = true }; return nil }
        loading = true
        var full = requested
        if !restored {
            // Saved events show at once and move the cursor, so only what happened since is downloaded.
            restored = true
            let saved = Store.shared.cache.lines(cacheKey)
            if !saved.isEmpty { transcript.append(.array(saved)); rebuild() }
        }
        // A transcript saved before messages showed their time has none; it is read again once to get them.
        if !retimed && transcriptNeedsRetime(transcript.events) { full = true }
        retimed = true
        var failure: APIError?
        do {
            let answer = try await Store.shared.call("session", ["sessionId": .string(id), "since": JSON(full ? 0 : transcript.cursor)])
            loading = false
            if let next = Session(answer["session"]) { snapshot = next }
            let events = answer["events"]
            if full { transcript = Transcript() }
            transcript.append(events)
            error = nil; loaded = true
            let cache = Store.shared.cache
            if full || unsaved { unsaved = !cache.replace(transcript.json.items, cacheKey) }
            else if events.count > 0 { unsaved = !cache.append(events.items, cacheKey) }
            rebuild()
            showPanel()
        } catch {
            loading = false
            if error.isCancellation { return APIError(.cancelled) }
            self.error = errorText(error); loaded = true
            failure = error as? APIError ?? APIError(.network, message: errorText(error))
        }
        if pendingFull { pendingFull = false; Task { await self.refresh(full: true) } }
        return failure
    }
    private func rebuild() {
        let next = transcriptBlocks(transcript.events)
        if next != blocks { blocks = next }
    }

    /// Polls while the screen is up: every 2 seconds while the agent works, every 7 otherwise, with the dashboard's backoff.
    func run() async {
        var failures = 0
        while !Task.isCancelled {
            while !Store.shared.active && !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            if Task.isCancelled { return }
            var failure: APIError?
            if !busy && !dialogOpen && !loading { failure = await refresh(full: false) }
            if Task.isCancelled { return }
            if let failure, failure.kind != .cancelled { failures += 1 } else { failures = 0 }
            let delay = pollDelay(base: session.isActive ? 2 : 7, failures: failures, retryAfter: failure?.retryAfter)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// The column at the right: the session's pull request and context usage, while this conversation is the page itself
    /// (not one pushed over a pull request) and the session has any of them. An open panel takes the latest record.
    func showPanel() {
        let nav = Navigator.shared
        guard nav.top.id == screenID else { return }
        if nav.stack.count == 1 && SessionPanel.wanted(session) {
            if nav.panelSession != session.raw { nav.panelSession = session.raw }
        } else if nav.panelSession != nil {
            nav.panelSession = nil
        }
    }
    /// The screen went away: a pull request pushed over the conversation fills the window, and the column returns with it.
    func hidden() {
        voice.drop()
        let draft = composer.text
        ConversationDrafts.text[id] = draft.isEmpty ? nil : draft
        files.clear()
        let nav = Navigator.shared
        if nav.panelSession?["id"].string == id { nav.panelSession = nil }
    }

    // MARK: Writing

    func mutate(_ name: String, _ extra: JSON = [:]) {
        if busy || uncertain { return }
        busy = true; writeError = nil
        var args: JSON = ["sessionId": .string(id)]
        args.merge(extra)
        Task {
            do { _ = try await Store.shared.call(name, args) } catch {
                busy = false
                writeError = errorText(error)
                uncertain = true
                return
            }
            busy = false
            let repo = session.repo ?? initial.repo
            switch name {
            case "message":
                if composer.text == args["text"].string {
                    composer.text = ""
                    ConversationDrafts.text[id] = nil
                    scrollToEnd += 1
                }
                // The files that went with it; one attached since stays for the next message.
                files.sent(args["attachments"].isNull ? nil : args["attachments"])
            case "delete":
                // The sidebar drops the row now instead of at its next poll; the transcript goes with it.
                Store.shared.cache.remove(cacheKey)
                ConversationDrafts.text[id] = nil
                var info: [String: Any] = ["id": id]
                if let repo { info["repo"] = repo }
                post(.sessionForgotten, info)
                // Beside the list there is nothing to go back to: the right-hand side empties instead.
                let nav = Navigator.shared
                if nav.top.id == screenID { if nav.stack.count > 1 { nav.pop() } else { nav.clear() } }
                return
            case "complete_findings":
                decisions = [:]; triageNote = ""
            default: break
            }
            post(.sessionsChanged, repo.map { ["repo": $0] } ?? [:])
            // A Clear or a compaction hides lines already on screen, so the transcript is read again whole.
            await refresh(full: name == "clear" || name == "compact")
        }
    }

    func confirmAndMutate(_ action: String) {
        let title: String
        switch action {
        case "delete": title = "Permanently delete this conversation and its transcript?"
        case "cancel": title = "Stop the running agent?"
        case "close": title = "Close this conversation?"
        case "review_loop": title = "Turn on the review loop? Each push gets a paid review round, and may start one now."
        default: title = "Reopen this conversation?"
        }
        dialogOpen = true
        let ok = Dialogs.confirm(title, nil, continueLabel: "Confirm", destructive: action == "delete" || action == "cancel")
        dialogOpen = false
        guard ok else { return }
        mutate(action, action == "review_loop" ? ["on": true] : [:])
    }

    func send() {
        guard !busy, !uncertain, !composer.trimmedEmpty, canMessage, !files.uploading else { return }
        var extra: JSON = ["text": .string(composer.text)]
        if let ids = files.ids { extra["attachments"] = ids }
        mutate("message", extra)
    }

    func rename() {
        dialogOpen = true
        let title = Dialogs.text("Rename conversation", label: "Title", okLabel: "Save", current: session.displayTitle)
        dialogOpen = false
        if let title, !title.cTrimmed.isEmpty { mutate("rename", ["title": .string(title)]) }
    }

    func toggleLoop() {
        if session.reviewLoopOn { mutate("review_loop", ["on": false]) } else { confirmAndMutate("review_loop") }
    }

    func answer(_ label: String) {
        composer.text = label
        composer.focusNow()
    }

    func refreshOutcome() {
        uncertain = false; writeError = nil
        Task { await refresh(full: false) }
    }

    // MARK: Held findings

    func pick(_ finding: JSON, decision index: Int) {
        guard let key = finding["key"].string, index >= 0, index < findingDecisionIds.count else { return }
        decisions[key] = findingDecisionIds[index]
    }
    func editNote() {
        dialogOpen = true
        let note = Dialogs.text("Note", label: "A note for the pull request and the fix session (optional)", okLabel: "Save", current: triageNote)
        dialogOpen = false
        if let note { triageNote = note }
    }
    func completeTriage(fixes: Int) {
        guard let triage = session.heldTriage else { return }
        let takes = triageTakesVerdicts(triage)
        dialogOpen = true
        let ok = Dialogs.confirm(triageConfirmTitle(takesVerdicts: takes, fixes: fixes), nil, continueLabel: "Complete")
        dialogOpen = false
        guard ok else { return }
        mutate("complete_findings", triageCompletion(triage, picked: decisions, note: triageNote))
    }
}

// MARK: - The screen

struct ConversationScreen: View {
    var sessionID: String
    var initial: JSON?
    @StateObject private var model: ConversationModel
    @ObservedObject private var store = Store.shared
    @State private var atBottom = true
    @State private var stick = true
    @State private var autoScrolling = false

    init(sessionID: String, initial: JSON?) {
        self.sessionID = sessionID
        self.initial = initial
        _model = StateObject(wrappedValue: ConversationModel(id: sessionID, initial: initial))
    }

    private var headerButtons: [HeaderButton] {
        let s = model.session
        let can = model.can
        let closed = s.status == "closed"
        var out: [HeaderButton] = []
        if store.supports("cancel") && s.isActive {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE71A), label: "\u{23F9} Stop", tip: "Stop", enabled: can) { model.confirmAndMutate("cancel") })
        }
        if store.supports("reopen") && closed {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE7A7), label: "\u{27F3} Reopen", tip: "Reopen", enabled: can) { model.confirmAndMutate("reopen") })
        }
        if store.supports("close") && !closed {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE8BB), label: "Close", tip: "Close", enabled: can) { model.confirmAndMutate("close") })
        }
        if store.supports("delete") {
            out.append(HeaderButton(glyph: Glyph.symbol(0xE74D), label: "\u{1F5D1} Delete", tip: "Delete", enabled: can, destructive: true) { model.confirmAndMutate("delete") })
        }
        return out
    }

    /// What changes the transcript's height at its end: new events, the queue, the held round, the working line, errors.
    private var contentMark: [Int] {
        let s = model.session
        return [model.transcript.events.count, model.transcript.cursor, s.queued.count, s.isActive ? 1 : 0,
                s.heldTriage?["findings"].count ?? -1, model.error == nil ? 0 : 1, model.writeError == nil ? 0 : 1,
                s.raw["error"].nonEmpty == nil ? 0 : 1, model.loaded ? 1 : 0]
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: model.session.displayTitle, subtitle: conversationStatusLine(model.session), buttons: headerButtons,
                       titleAction: store.supports("rename") ? { model.rename() } : nil)
            transcript
            ConversationFooter(model: model, composer: model.composer, files: model.files, voice: model.voice)
        }
        .task(id: store.active) { await model.run() }
        .onAppear {
            model.showPanel()
            stick = true
        }
        .onDisappear { model.hidden() }
        .onChange(of: store.active) { _, active in
            // Recording cannot go on in the background: what was said until then is transcribed, as if stopped.
            if !active && model.voice.state == .recording { model.voice.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in
            Task { await model.refresh(full: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationSessionOperation)) { note in
            guard let info = note.userInfo, info["id"] as? String == sessionID, let operation = info["operation"] as? String else { return }
            model.mutate(operation, (info["extra"] as? JSON) ?? [:])
        }
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TranscriptColumn(model: model, blocks: model.blocks, session: model.session, expanded: model.expanded,
                                         decisions: model.decisions, triageNote: model.triageNote, loaded: model.loaded,
                                         error: model.error, writeError: model.writeError, busy: model.busy, loading: model.loading,
                                         uncertain: model.uncertain, canMessage: model.canMessage)
                            .equatable()
                        Color.clear.frame(height: 1).id("end")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TranscriptEndKey.self, value: g.frame(in: .named("transcript")).maxY)
                            })
                    }
                    .padding(.top, 18).padding(.bottom, 30)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "transcript")
                .onPreferenceChange(TranscriptEndKey.self) { maxY in
                    let bottom = maxY <= outer.size.height + 4
                    if atBottom != bottom { atBottom = bottom }
                    if !autoScrolling && stick != bottom { stick = bottom }
                }
                .overlay(alignment: .bottom) {
                    // The "latest" button: back to the end, which the transcript then keeps to.
                    if !atBottom && !model.blocks.isEmpty {
                        Button {
                            stick = true
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                        } label: { Image(systemName: Glyph.symbol(0xE74B)) }
                            .buttonStyle(IconButtonStyle())
                            .help("Latest")
                            .padding(.bottom, 10)
                    }
                }
                .onChange(of: contentMark) { _, _ in if stick { scrollToEnd(proxy) } }
                .onChange(of: model.scrollToEnd) { _, _ in stick = true; scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        autoScrolling = true
        DispatchQueue.main.async {
            proxy.scrollTo("end", anchor: .bottom)
            DispatchQueue.main.async { autoScrolling = false }
        }
    }
}

private struct TranscriptEndKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Footer

/// `#composer-wrap`: the chips, the box with the files, the text and the buttons, and the note under it; or, on a closed
/// or read-only conversation, a box that says so with ⟳ Reopen.
private struct ConversationFooter: View {
    @ObservedObject var model: ConversationModel
    @ObservedObject var composer: ComposerState
    @ObservedObject var files: Attachments
    @ObservedObject var voice: VoiceNote
    @ObservedObject private var store = Store.shared

    private func chipShown(_ chip: ComposerChip) -> Bool {
        if chip == .loop { return store.supports("review_loop") && model.session.canReviewLoop }
        return !conversationChipText(model.session, chip).isEmpty
    }

    var body: some View {
        let s = model.session
        let can = model.can
        FooterColumn {
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(ComposerChip.allCases.filter(chipShown), id: \.self) { chip in
                        let live = chip == .loop
                        ComposerChipView(label: conversationChipText(s, chip), on: live && s.reviewLoopOn, live: live && can,
                                         action: live && can ? { model.toggleLoop() } : nil)
                    }
                }
                .padding(.top, 8).padding(.bottom, 8)
                if model.canMessage { box } else { closedBox }
            }
        }
        .background(Theme.canvas)
    }

    private var box: some View {
        let s = model.session
        let can = model.can
        let empty = composer.trimmedEmpty
        let uploading = files.uploading
        let active = s.isActive
        let stop = active && store.supports("cancel") && empty
        return VStack(spacing: 0) {
            ComposerBox(files: files, text: $composer.text, lines: $composer.lines, focused: $composer.focused, placeholder: "Reply\u{2026}",
                        focus: composer.focus,
                        onSubmit: { model.send() },
                        onPaste: { files.paste($0) },
                        onDrop: { files.drop($0) },
                        onTap: { composer.focusNow() }) {
                if files.supported {
                    AttachButton(enabled: files.count < attachmentsMax) { files.pick() }
                }
                if store.canTranscribe {
                    MicButton(voice: voice)
                    if voice.state == .recording || voice.state == .transcribing {
                        ComposerSquareButton(glyph: "\u{2715}", tip: "Discard the voice note") { voice.drop() }
                        VoiceClock(voice: voice)
                    }
                }
            } trailing: {
                if stop {
                    ComposerSquareButton(glyph: "\u{25A0}", color: Theme.ink, tip: "Stop") { if can { model.confirmAndMutate("cancel") } }
                } else {
                    SendButton(filled: (can && !empty && !uploading) || model.busy) { model.send() }
                }
            }
            Text(conversationComposerNote(active: active, liveInput: s.liveInput, uploading: uploading, files: files.count, empty: empty))
                .font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity).frame(height: 16)
                .padding(.top, 6).padding(.bottom, 14)
        }
    }

    private var closedBox: some View {
        let reopen = store.supports("reopen") && model.session.status == "closed"
        let can = model.can
        return HStack(spacing: 12) {
            Text(store.canManage ? "This session is closed." : "Read-only access")
                .font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if reopen {
                Button { if can { model.confirmAndMutate("reopen") } } label: { Text("\u{27F3} Reopen") }
                    .dashButton(.bordered)
                    .disabled(!can)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.bottom, 36)
    }
}
