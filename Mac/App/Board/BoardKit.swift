// What the board's screens share: their models kept while the screen is in the detail pane's stack, the request helper,
// the errands a row offers, the popup menus (TrackPopupMenu), the errand input dialog (dialog_action_input) and a few
// drawn pieces (pills, branch chips, word-wrapped runs, boxes and rules).
import AVFoundation
import AppKit
import SwiftUI

// MARK: - Models

/// The screens' models outlive their views: the detail pane draws only its top screen, and a screen further down the stack
/// keeps its state for when it is back on top, as the Windows client's screens stay alive in the pane's stack.
@MainActor
enum BoardModels {
    private static var models: [String: AnyObject] = [:]

    static func model<T: AnyObject>(_ id: String, make: () -> T) -> T {
        // Screens the stack no longer holds (replaced while further down it) go now.
        let live = Set(Navigator.shared.stack.map(\.id))
        models = models.filter { $0.key == id || live.contains($0.key) }
        if let m = models[id] as? T { return m }
        let m = make()
        models[id] = m
        return m
    }
    /// A screen that left the stack takes its model with it.
    static func release(_ id: String) {
        if !Navigator.shared.stack.contains(where: { $0.id == id }) { models[id] = nil }
    }
    /// Keeps a model made ahead of its screen (▶ Run from the board opens the pull request on its Run tab).
    static func adopt(_ id: String, _ model: AnyObject) { models[id] = model }
}

// MARK: - Requests

/// One call: its answer, or why it failed (`.cancelled` when the screen went away meanwhile).
@MainActor
func boardCall(_ operation: String, _ arguments: JSON = [:], timeout: TimeInterval? = nil) async -> Result<JSON, APIError> {
    do { return .success(try await Store.shared.call(operation, arguments, timeout: timeout)) }
    catch let e as APIError { return .failure(e) }
    catch { return .failure(APIError(.cancelled)) }
}
extension Result where Failure == APIError {
    var value: Success? { if case .success(let v) = self { return v }; return nil }
    var error: APIError? { if case .failure(let e) = self { return e }; return nil }
}

// MARK: - Errands

/// The glyph before an errand's label.
func actionIcon(_ id: String) -> String {
    switch id {
    case "run": return "▶"
    case "review": return "⌕"
    case "solve-conflicts": return "🔀"
    case "fix-checks": return "🧪"
    case "implement-feedback": return "💬"
    case "custom-feedback": return "✍"
    case "pr-body-summary": return "✎"
    case "delete-self-comments": return "🧹"
    default: return ""
    }
}
/// The errands this app can start on a row: what the server offers for it, less what the token or server lacks.
@MainActor
func rowActions(catalog: JSON, pull: PullSummary?, failedChecks: Int) -> [BoardAction] {
    guard Store.shared.canManage else { return [] }
    return BoardAction.offered(catalog: catalog, pull: pull, failedChecks: failedChecks).filter { Store.shared.supports($0.operation) }
}
/// Asks for an errand's input when it takes one; the others start straight away. Nil when cancelled.
@MainActor
func actionPrompt(_ action: BoardAction, number: Int) -> String?? {
    guard action.input != nil else { return .some(nil) }
    guard let text = ActionInputDialog.run(action: action, number: number) else { return nil }
    return .some(text)
}

// MARK: - Popup menus

/// A menu at the pointer that answers which item was chosen, as TrackPopupMenu with TPM_RETURNCMD.
@MainActor
enum PopupMenu {
    struct Item {
        var title: String
        var checked = false
        var separator = false
        static let divider = Item(title: "", separator: true)
    }
    private final class Catcher: NSObject {
        var chosen: Int?
        @objc func pick(_ sender: NSMenuItem) { chosen = sender.tag }
    }
    /// The index of the item chosen, or nil. `rightAligned` puts the menu's right edge at the pointer.
    static func show(_ items: [Item], rightAligned: Bool = false) -> Int? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return nil }
        let catcher = Catcher()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, item) in items.enumerated() {
            if item.separator { menu.addItem(.separator()); continue }
            let m = NSMenuItem(title: item.title, action: #selector(Catcher.pick(_:)), keyEquivalent: "")
            m.target = catcher; m.tag = i; m.state = item.checked ? .on : .off
            menu.addItem(m)
        }
        var at = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if rightAligned { at.x -= menu.size.width }
        menu.popUp(positioning: nil, at: at, in: view)
        return catcher.chosen
    }
}

// MARK: - Errand input

/// The errand's question (dialog_action_input): its label as the title, the question, a box for the answer with a voice
/// note button, and what it costs; Start stays off while a required answer is empty. Returns the answer trimmed.
@MainActor
enum ActionInputDialog {
    static func run(action: BoardAction, number: Int) -> String? {
        let state = InputState()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = action.label
        let finish: (Bool) -> Void = { ok in
            state.confirmed = ok
            state.voice.discard()
            NSApp.stopModal()
            panel.orderOut(nil)
        }
        panel.contentViewController = NSHostingController(rootView: ActionInputView(action: action, number: number, state: state, finish: finish))
        panel.center()
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in if NSApp.modalWindow === panel { NSApp.stopModal() } }
        }
        NSApp.runModal(for: panel)
        NotificationCenter.default.removeObserver(closeObserver)
        state.voice.discard()
        return state.confirmed ? state.text.cTrimmed : nil
    }
}

@MainActor
private final class InputState: ObservableObject {
    @Published var text = ""
    var confirmed = false
    let voice = VoiceNote()
}

private struct ActionInputView: View {
    var action: BoardAction
    var number: Int
    @ObservedObject var state: InputState
    var finish: (Bool) -> Void
    @ObservedObject private var voice: VoiceNote

    init(action: BoardAction, number: Int, state: InputState, finish: @escaping (Bool) -> Void) {
        self.action = action; self.number = number; self.state = state; self.finish = finish
        voice = state.voice
    }

    private var canStart: Bool { !(state.text.cTrimmed.isEmpty && (action.input?.required ?? false)) }

    var body: some View {
        let hint = (action.input?.placeholder).flatMap { $0.isEmpty ? nil : $0 } ?? action.input?.label ?? ""
        VStack(alignment: .leading, spacing: 10) {
            Text(hint).font(Theme.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $state.text)
                .font(Theme.callout).scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
                .frame(minHeight: 110)
            Text("\(action.hint). This runs a paid agent on pull request #\(number) and may write to GitHub.")
                .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if Store.shared.canTranscribe {
                    Button(voice.buttonLabel) { voice.toggle { state.text += ($0.isEmpty || state.text.isEmpty ? "" : " ") + $0 } }
                        .dashButton(.bordered).disabled(!(voice.state == .idle || voice.state == .recording))
                    if voice.state == .recording {
                        Text("Recording \(formatClock(voice.elapsed)) · Esc discards").font(Theme.caption).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 8)
                Button("Cancel") { if voice.state == .recording { voice.discard() } else { finish(false) } }
                    .dashButton(.bordered).keyboardShortcut(.cancelAction)
                Button("Start") { finish(true) }.dashButton(.prominent).disabled(!canStart)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(Theme.canvas)
    }
}

/// A voice note for a dialog's box (voice.c): recorded to a file, sent to the server to be written out, its text added.
@MainActor
final class VoiceNote: NSObject, ObservableObject {
    enum State { case idle, starting, recording, transcribing }
    @Published private(set) var state = State.idle
    @Published private(set) var elapsed = 0
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var ticker: Timer?
    private var started = Date()

    var buttonLabel: String {
        switch state {
        case .recording: return "Stop and transcribe"
        case .transcribing: return "Transcribing…"
        case .starting: return "Starting…"
        case .idle: return "Record a voice note"
        }
    }

    func toggle(_ took: @escaping (String) -> Void) {
        if state == .recording { stop(took) } else if state == .idle { record() }
    }

    private func record() {
        state = .starting
        Task {
            if let off = await Store.shared.voiceNotesOff() { state = .idle; Dialogs.alert("Voice note", off); return }
            let allowed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
            }
            guard allowed else {
                state = .idle
                Dialogs.alert("Voice note", "Briareus may not use the microphone. Allow it in System Settings → Privacy & Security → Microphone.")
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("briareus-voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                           AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            do {
                let r = try AVAudioRecorder(url: url, settings: settings)
                guard r.record() else { throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone did not start."]) }
                recorder = r; file = url; started = Date(); elapsed = 0; state = .recording
                startTicker()
            } catch {
                state = .idle
                Dialogs.alert("Voice note", error.localizedDescription)
            }
        }
    }

    private func startTicker() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.elapsed = Int(Date().timeIntervalSince(self.started)) }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stop(_ took: @escaping (String) -> Void) {
        guard let recorder, let file else { return }
        recorder.stop(); self.recorder = nil; ticker?.invalidate(); ticker = nil
        state = .transcribing
        Task {
            defer { try? FileManager.default.removeItem(at: file); self.file = nil }
            do {
                let data = try Data(contentsOf: file)
                let text = try await Store.shared.transcribe(data, contentType: "audio/mp4")
                state = .idle
                took(text.cTrimmed)
            } catch {
                state = .idle
                if !error.isCancellation { Dialogs.alert("Voice note", errorText(error)) }
            }
        }
    }

    /// Drops a recording under way without sending it.
    func discard() {
        guard state == .recording || state == .starting else { return }
        recorder?.stop(); recorder?.deleteRecording(); recorder = nil
        ticker?.invalidate(); ticker = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        state = .idle
    }
}

// MARK: - Drawn pieces

/// A 1px rule in the line colour.
struct Rule: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

/// A box: `fill` with a 1px border, its contents padded.
struct BoardBox<Content: View>: View {
    var padding: CGFloat = 12
    var fill: Color = Theme.raise
    var border: Color = Theme.line
    var radius: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
    }
}

/// `.prv-state`: a filled pill, capitalised.
struct StatePill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text.asciiCapitalized).font(Theme.footnoteSemibold).foregroundStyle(Theme.canvas).lineLimit(1)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(color))
    }
}

/// `.commit-ref`: a branch in small mono type on a tint of the accent.
struct BranchChip: View {
    var text: String
    var body: some View {
        Text(text).font(Theme.monoCaption2).foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).frame(height: 19)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.16)))
    }
}

/// Text that wraps a word at a time and mixes fonts, colours and branch chips (doc_flow).
struct FlowRun {
    var text: String
    var font: Font
    var color: Color
    var chip = false
}
struct WordFlow: View {
    var runs: [FlowRun]
    var lineHeight: CGFloat
    private var words: [FlowRun] {
        var out: [FlowRun] = []
        for r in runs {
            if r.chip { out.append(r); continue }
            // Each word keeps its trailing spaces, as C splits it.
            var word = ""
            var inSpaces = false
            for ch in r.text {
                if ch == " " { inSpaces = true; word.append(ch); continue }
                if inSpaces { out.append(FlowRun(text: word, font: r.font, color: r.color)); word = ""; inSpaces = false }
                word.append(ch)
            }
            if !word.isEmpty { out.append(FlowRun(text: word, font: r.font, color: r.color)) }
        }
        return out
    }
    var body: some View {
        FlowLayout(spacing: 0, lineSpacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                Group {
                    if w.chip { BranchChip(text: w.text).padding(.trailing, 5) }
                    else { Text(w.text).font(w.font).foregroundStyle(w.color).lineLimit(1) }
                }
                .frame(height: lineHeight)
            }
        }
    }
}

/// `.timeline-comment-header`: a tinted strip with `author did · when`, a review's verdict glyph first.
struct CommentHead: View {
    var author: String?
    var when: String
    var glyph: String? = nil
    var glyphColor: Color = Theme.muted
    var body: some View {
        HStack(spacing: 0) {
            if let glyph { Image(systemName: glyph).font(.system(size: 12)).foregroundStyle(glyphColor).frame(width: 18).padding(.trailing, 6) }
            if let author { Text(author).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1).padding(.trailing, 5) }
            Text(when).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(height: 38)
        .background(UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7).fill(Theme.accent.opacity(0.10)))
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// The checks as counts: passed, pending and failed, each with its glyph.
struct CheckCounts: View {
    var passed: Int
    var pending: Int
    var failed: Int
    var body: some View {
        HStack(spacing: 14) {
            part(0xE930, passed, Theme.ok)
            part(0xE823, pending, Theme.warn)
            part(0xEA39, failed, Theme.danger)
        }
        .frame(height: 22)
    }
    private func part(_ glyph: UInt32, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: Glyph.symbol(glyph)).font(.system(size: 12)).foregroundStyle(color).frame(width: 18)
            Text("\(n)").font(Theme.subheadlineSemibold).foregroundStyle(color)
        }
    }
}

/// A glyph and a line of text after it (doc_label).
struct GlyphLabel: View {
    var glyph: UInt32
    var text: String
    var font: Font = Theme.callout
    var color: Color = Theme.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: Glyph.symbol(glyph)).font(.system(size: 11)).foregroundStyle(color).frame(width: 18)
            Text(text).font(font).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A hand cursor over something clickable that is not a button.
extension View {
    func handCursor(_ on: Bool = true) -> some View {
        onHover { inside in if on { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
    }
}
