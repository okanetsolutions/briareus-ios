// The conversation's messages, as the Mac's TranscriptColumn lays them out (screen_conversation.c conversation_layout):
// errors first, then what was said, with each run of tool calls and the workspace preparation folded into one short row
// that opens on a tap, so a phone shows mostly the conversation; why the session failed, the queued messages and the
// working line at the end.
import SwiftUI

/// The transcript's column. Its inputs are compared, so typing in the composer or a poll that changed nothing does not
/// lay it out again.
struct ConversationTranscript: View, Equatable {
    var blocks: [TranscriptBlock]
    var session: Session
    var expanded: Set<Int>
    var loaded: Bool
    var error: String?
    var writeError: String?
    var uncertain: Bool
    var blocked: Bool
    var canMessage: Bool
    var answer: (String) -> Void
    var toggle: (Int) -> Void
    var dropQueued: (Int) -> Void
    var refreshOutcome: () -> Void

    static func == (a: ConversationTranscript, b: ConversationTranscript) -> Bool {
        a.blocks == b.blocks && a.session == b.session && a.expanded == b.expanded && a.loaded == b.loaded && a.error == b.error
            && a.writeError == b.writeError && a.uncertain == b.uncertain && a.blocked == b.blocked && a.canMessage == b.canMessage
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            if let error {
                ErrorNotice(message: error).padding(12).background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if let writeError { writeNotice(writeError) }
            if blocks.isEmpty && error == nil {
                VStack(spacing: 12) {
                    if loaded { Image(systemName: "text.bubble").font(.title).foregroundStyle(.tertiary) } else { ProgressView() }
                    Text(loaded ? "No messages yet" : "Waiting for the conversation\u{2026}").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            }
            ForEach(blocks, id: \.seq) { block in
                switch block {
                case .preparation(let events):
                    FoldedSteps(summary: block.summary ?? "", symbol: "shippingbox", open: expanded.contains(block.seq),
                                toggle: { toggle(block.seq) }) {
                        ForEach(events, id: \.seq) { e in LogLine(text: logLineText(e), danger: false) }
                    }
                case .tools(let events):
                    FoldedSteps(summary: block.summary ?? "", symbol: "wrench.and.screwdriver",
                                failed: events.contains { $0.kind == "tool_error" }, open: expanded.contains(block.seq),
                                toggle: { toggle(block.seq) }) {
                        ForEach(events, id: \.seq) { e in ToolStepRow(event: e) }
                    }
                case .event(let e):
                    TranscriptEventView(event: e, canAnswer: canMessage, answer: answer)
                }
            }
            // Why the session failed, said where the transcript stops.
            if let failure = session.raw["error"].nonEmpty {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            let removable = Store.shared.supports("drop_message") && !blocked
            ForEach(Array(session.queued.items.enumerated()), id: \.offset) { index, item in
                QueuedBubble(text: item["text"].string ?? "Message", removable: removable) { dropQueued(index) }
            }
            if session.isActive { WorkingIndicator(status: session.status) }
        }
    }

    private func writeNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ErrorNotice(message: message)
            if uncertain {
                Text("The action may have completed. Check the latest conversation before trying again.").font(.caption).foregroundStyle(.secondary)
                Button("Refresh and check outcome", action: refreshOutcome).buttonStyle(.bordered).controlSize(.small).disabled(blocked && !uncertain)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Folded steps

/// A run of tool calls or the workspace preparation as one row, "3 steps · Bash"; a tap opens its lines.
private struct FoldedSteps<Content: View>: View {
    let summary: String
    let symbol: String
    var failed = false
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.caption2).foregroundStyle(failed ? Theme.danger : .secondary).frame(width: 16)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityHint(open ? "Hides the steps" : "Shows the steps")
            if open {
                VStack(alignment: .leading, spacing: 4) { content }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
            }
        }
        .animation(.snappy(duration: 0.2), value: open)
    }
}

/// One tool step: the tool's name in a chip, then the first line of what it did.
private struct ToolStepRow: View {
    let event: Event
    var body: some View {
        let error = event.kind == "tool_error"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(toolTitle(event)).font(.caption2.weight(.medium)).foregroundStyle(error ? Theme.danger : .primary).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(error ? Theme.danger : Theme.border, lineWidth: 0.5))
                .fixedSize()
            Text(firstLine(event.detail)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct LogLine: View {
    let text: String
    let danger: Bool
    var body: some View {
        Text(text).font(.caption.monospaced()).foregroundStyle(danger ? Theme.danger : .secondary)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Events

/// One visible event: the user's message, the agent's reply in Markdown, a question with its options, a turn's footer,
/// or a log line.
private struct TranscriptEventView: View, Equatable {
    let event: Event
    let canAnswer: Bool
    let answer: (String) -> Void
    static func == (a: TranscriptEventView, b: TranscriptEventView) -> Bool { a.event == b.event && a.canAnswer == b.canAnswer }

    var body: some View {
        switch event.kind {
        case "user":
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(event.text ?? "").textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    ForEach(Array((event.attachments?.items ?? []).enumerated()), id: \.offset) { _, attachment in
                        Label(attachment["name"].string ?? "Attachment", systemImage: "paperclip")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surface, in: Capsule())
                    }
                    EventTimeText(event: event)
                }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("You: \(event.text ?? "")")
        case "text":
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(event.text ?? "").equatable()
                EventTimeText(event: event)
            }
        case "ask":
            AskCard(event: event, canAnswer: canAnswer, answer: answer)
        case "result":
            let failed = event.isError == true
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Theme.danger : Theme.success)
                Text(String(turnFooterText(event).dropFirst(2))).lineLimit(2)
            }
            .font(.caption).foregroundStyle(failed ? Theme.danger : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.border).frame(height: 0.5).offset(y: -8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(failed ? "Turn failed" : "Turn complete")
        default:
            if event.text != nil {
                if event.kind == "stderr" || event.kind == "claude" || event.kind == "stdout" {
                    LogLine(text: logLineText(event), danger: event.kind == "stderr")
                } else {
                    // Dashboard notices: review loops, interruptions, the worker starting.
                    Label { Text(inlineMarkdown(logLineText(event))).textSelection(.enabled) } icon: { Image(systemName: "info.circle") }
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A message's time: the clock today, else the day and the clock.
private struct EventTimeText: View {
    let event: Event
    var body: some View {
        if let when = event.time { Text(formatEventTime(when)).font(.caption2).foregroundStyle(.tertiary) }
    }
}

/// A question from the agent: its options put their label in the composer, to send as it is or after an edit.
private struct AskCard: View {
    let event: Event
    let canAnswer: Bool
    let answer: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your input is needed", systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            MarkdownText(event.question ?? event.text ?? "")
            if canAnswer {
                let options = (event.options?.items ?? []).compactMap { $0["label"].string }
                if !options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, label in
                            Button { answer(label) } label: {
                                HStack {
                                    Text(label).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.turn.down.left").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Choose an answer to put it in the composer, or write your own.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
    }
}

/// A message waiting for the next turn, with Remove while the server can drop it.
private struct QueuedBubble: View {
    let text: String
    let removable: Bool
    let remove: () -> Void
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                HStack(spacing: 8) {
                    Label("Queued for the next turn", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                    if removable {
                        Button("Remove", role: .destructive, action: remove).font(.caption2.weight(.semibold))
                    }
                }
            }
        }
    }
}

/// The agent at work: the spinner's glyph and "Thinking…", "Queued…" or "Starting up…".
private struct WorkingIndicator: View {
    let status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 3 : 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            let verb = status == "queued" ? "Queued" : (status == "preparing" || status == "starting") ? "Starting up" : workingVerb(tick)
            HStack(spacing: 8) {
                Text(reduceMotion ? "\u{273B}" : workingGlyph(tick)).font(.body.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 16)
                Text("\(verb)\u{2026}").font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement().accessibilityLabel(status == "running" ? "Agent is working" : "Agent is \(status)")
    }
}
