// One conversation's state, as the Mac's ConversationModel (screen_conversation.c): the transcript read a little at a
// time after the saved part, the session's latest record, and the writes on it, one at a time, a write whose outcome is
// unknown blocking the next until the conversation is read again.
import Combine
import SwiftUI

/// What is typed, kept apart from the conversation so a keystroke does not lay the transcript out again.
@MainActor
final class ComposerDraft: ObservableObject {
    @Published var text = ""
    var trimmedEmpty: Bool { text.cTrimmed.isEmpty }
}

/// Text typed into a conversation that was left for a screen pushed over it, until it comes back.
@MainActor
enum ConversationDrafts { static var text: [String: String] = [:] }

@MainActor
final class ConversationScreenModel: ObservableObject {
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
    /// Set once the conversation was deleted from here: the screen goes back, or says so where there is nothing to go
    /// back to.
    @Published private(set) var deleted = false
    /// Tool and preparation blocks opened, by their first event's sequence.
    @Published var expanded: Set<Int> = []
    /// Bumped to scroll the transcript to its end.
    @Published private(set) var scrollToEnd = 0
    /// A dialog is up: polling waits, so the record does not change under it.
    var paused = false

    private var restored = false, unsaved = false, retimed = false, pendingFull = false

    let draft = ComposerDraft()
    let files = ComposerFiles(call: "message")
    let voice = PhoneVoiceNote()
    /// Whether a message can go depends on the files too.
    private var filesChanged: AnyCancellable?

    init(id: String, initial: JSON?) {
        self.id = id
        self.initial = initial.flatMap(Session.init) ?? Session(raw: ["id": .string(id), "status": ""])
        draft.text = ConversationDrafts.text[id] ?? ""
        voice.onText = { [weak self] text in
            guard let self else { return }
            draft.text = appendDictation(draft.text, text)
        }
        filesChanged = files.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private var cacheKey: String { "transcript:\(id)" }
    var repo: String? { session.repo ?? initial.repo }
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
        var failed: APIError?
        do {
            let answer = try await Store.shared.call("session", ["sessionId": .string(id), "since": JSON(full ? 0 : transcript.cursor)])
            loading = false
            if let next = Session(answer["session"]), next != snapshot { snapshot = next }
            let events = answer["events"]
            if full { transcript = Transcript() }
            transcript.append(events)
            error = nil; loaded = true
            let cache = Store.shared.cache
            if full || unsaved { unsaved = !cache.replace(transcript.json.items, cacheKey) }
            else if events.count > 0 { unsaved = !cache.append(events.items, cacheKey) }
            rebuild()
        } catch {
            loading = false
            if error.isCancellation { return APIError(.cancelled) }
            self.error = errorText(error); loaded = true
            failed = error as? APIError ?? APIError(.network, message: errorText(error))
        }
        if pendingFull { pendingFull = false; Task { await self.refresh(full: true) } }
        return failed
    }
    private func rebuild() {
        let next = transcriptBlocks(transcript.events)
        if next != blocks { blocks = next }
    }

    /// Polls while the screen is up: often while the agent works, less once it waits, rarely once closed, with the
    /// dashboard's backoff; never while a write or a dialog is under way.
    func run() async {
        var failures = 0
        while !Task.isCancelled {
            while !Store.shared.active && !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            if Task.isCancelled { return }
            var failed: APIError?
            if !busy && !paused && !loading && !deleted { failed = await refresh(full: false) }
            if Task.isCancelled || failed?.unauthorized == true { return }
            if let failed, failed.kind != .cancelled { failures += 1 } else { failures = 0 }
            let delay = pollDelay(base: conversationPollInterval(session), failures: failures, retryAfter: failed?.retryAfter)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// The screen went away, or a screen was pushed over it: the draft is kept for its return, a voice note is dropped.
    func hidden() {
        voice.drop()
        let text = draft.text
        ConversationDrafts.text[id] = text.isEmpty ? nil : text
    }

    // MARK: Writing

    func mutate(_ name: String, _ extra: JSON = [:]) {
        if busy || uncertain { return }
        busy = true; writeError = nil
        var args: JSON = ["sessionId": .string(id)]
        args.merge(extra)
        Task {
            do { try await Store.shared.call(name, args) } catch {
                busy = false
                if error.isCancellation { return }
                writeError = errorText(error)
                // A refusal changed nothing; anything else may have.
                if !((error as? APIError)?.isRefusal ?? false) { uncertain = true }
                return
            }
            busy = false
            let feed = repo.map { Store.shared.feed($0) }
            switch name {
            case "message":
                if draft.text == args["text"].string {
                    draft.text = ""
                    ConversationDrafts.text[id] = nil
                }
                scrollToEnd += 1
                // The files that went with it; one attached since stays for the next message.
                files.sent(args["attachments"].isNull ? nil : args["attachments"])
            case "delete":
                // The list drops the row now instead of at its next poll; the transcript goes with it.
                Store.shared.cache.remove(cacheKey)
                ConversationDrafts.text[id] = nil
                feed?.drop(id)
                deleted = true
                return
            default: break
            }
            if let feed { Task { try? await feed.loadSessions(fresh: true) } }
            // A Clear or a compaction hides lines already on screen, so the transcript is read again whole.
            await refresh(full: name == "clear" || name == "compact")
        }
    }

    func send() {
        guard can, !draft.trimmedEmpty, canMessage, !files.uploading else { return }
        var extra: JSON = ["text": .string(draft.text)]
        if let ids = files.ids { extra["attachments"] = ids }
        mutate("message", extra)
    }

    func refreshOutcome() {
        uncertain = false; writeError = nil
        Task { await refresh(full: false) }
    }

    /// A review round completed from its card: the record is read again, and the lists' ⚑ counts with it.
    func triageDone() {
        if let repo { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
        Task { await refresh(full: false) }
    }

    func toggle(_ seq: Int) {
        if expanded.contains(seq) { expanded.remove(seq) } else { expanded.insert(seq) }
    }
}
