// The conversation's `#messages` (screen_conversation.c conversation_layout): the errors, the transcript with workspace
// preparation and tool calls folded into blocks, why the session failed, the queued messages, the held review round and
// the working line.
import AppKit
import SwiftUI

/// Whether a link is one the app opens: https with a host and no credentials.
func isSafeWebURL(_ url: String?) -> Bool {
    guard let url, let u = URL(string: url), u.scheme?.lowercased() == "https", u.host != nil, u.user == nil, u.password == nil else { return false }
    return true
}

/// The transcript's column. Its inputs are compared, so typing in the composer or a poll that changed nothing does not
/// lay it out again.
struct TranscriptColumn: View, Equatable {
    unowned let model: ConversationModel
    var blocks: [TranscriptBlock]
    var session: Session
    var expanded: Set<Int>
    var decisions: [String: String]
    var triageNote: String
    var loaded: Bool
    var error: String?
    var writeError: String?
    var busy: Bool
    var loading: Bool
    var uncertain: Bool
    var canMessage: Bool

    static func == (a: TranscriptColumn, b: TranscriptColumn) -> Bool {
        a.blocks == b.blocks && a.session == b.session && a.expanded == b.expanded && a.decisions == b.decisions
            && a.triageNote == b.triageNote && a.loaded == b.loaded && a.error == b.error && a.writeError == b.writeError
            && a.busy == b.busy && a.loading == b.loading && a.uncertain == b.uncertain && a.canMessage == b.canMessage
    }

    private var can: Bool { !busy && !uncertain }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error { DangerBox { DangerText(error) }.padding(.bottom, 12) }
            if let writeError {
                DangerBox(bottom: 10) {
                    DangerText(writeError)
                    SelectableText("The action may have completed. Check the latest conversation before trying again.",
                                   font: SelectableFont.system(12), color: Theme.muted)
                        .padding(.top, 4)
                    Button("Refresh and check outcome") { model.refreshOutcome() }
                        .dashButton(.bordered).disabled(loading || busy).padding(.top, 8)
                }
                .padding(.bottom, 12)
            }
            if blocks.isEmpty && error == nil {
                SelectableText(loaded ? "No messages yet." : "Waiting for the conversation\u{2026}", font: SelectableFont.system(13), color: Theme.muted)
            }
            ForEach(blocks, id: \.seq) { block in blockView(block) }
            // Why the session failed: the Windows client's `⚠ error` in the head, said where the transcript stops.
            if let failure = session.raw["error"].nonEmpty {
                DangerBox { DangerText("\u{26A0} \(failure)") }.padding(.top, 10)
            }
            queued
            if let triage = session.heldTriage, Store.shared.supports("complete_findings") {
                TriageBox(model: model, triage: triage, decisions: decisions, note: triageNote, enabled: can).padding(.top, 14)
            }
            if session.isActive { WorkingLine(status: session.status).padding(.top, 12) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: TranscriptBlock) -> some View {
        switch block {
        case .preparation(let events):
            Folded(summary: block.summary ?? "", open: expanded.contains(block.seq), toggle: { toggle(block.seq) }) {
                ForEach(events, id: \.seq) { e in LogLine(text: logLineText(e), color: Theme.muted) }
            }
        case .tools(let events):
            Folded(summary: block.summary ?? "", open: expanded.contains(block.seq), toggle: { toggle(block.seq) }) {
                ForEach(events, id: \.seq) { e in ToolStep(event: e) }
            }
        case .event(let e):
            EventView(event: e, canMessage: canMessage, answer: { model.answer($0) })
        }
    }
    private func toggle(_ seq: Int) {
        if model.expanded.contains(seq) { model.expanded.remove(seq) } else { model.expanded.insert(seq) }
    }

    @ViewBuilder private var queued: some View {
        let items = session.queued.items
        let removable = Store.shared.supports("drop_message") && can
        ForEach(Array(items.enumerated()), id: \.offset) { q, item in
            let text = item["text"].string ?? "Message"
            VStack(alignment: .leading, spacing: 0) {
                SelectableText(text, font: SelectableFont.system(15), color: Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [1, 2])))
                HStack(spacing: 0) {
                    SelectableText("Queued for the next turn", font: SelectableFont.system(11), color: Theme.muted)
                    Spacer(minLength: 0)
                    if removable {
                        Button { model.mutate("drop_message", ["index": JSON(q)]) } label: {
                            Text("Remove").font(Theme.caption2).foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.plain)
                        .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
                        .fixedSize()
                    }
                }
                .frame(height: 18)
                .padding(.top, 4)
            }
            .padding(.top, 10)
        }
    }
}

// MARK: - Pieces

/// `doc_notice_box`: danger text on a danger tint with a danger border, 8px corners.
private struct DangerBox<Content: View>: View {
    var bottom: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.danger, lineWidth: 1))
    }
}
private struct DangerText: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        SelectableText(text, font: SelectableFont.system(13), color: Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.ev-log`: a 12px mono line.
private struct LogLine: View {
    var text: String
    var color: Color
    var body: some View {
        SelectableText(text, font: SelectableFont.mono(12), color: color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
    }
}

/// A `<details>`: its 13px muted summary with ▸/▾ (ink on hover); open, its lines indented 12px beside a 2px rule.
private struct Folded<Content: View>: View {
    var summary: String
    var open: Bool
    var toggle: () -> Void
    @ViewBuilder var content: Content
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                Text(verbatim: "\(open ? "\u{25BE}" : "\u{25B8}") \(summary)").font(Theme.footnote).foregroundStyle(hovered ? Theme.ink : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            if open { content }
        }
        .padding(.leading, open ? 12 : 0)
        .overlay(alignment: .leading) { if open { Rectangle().fill(Theme.line).frame(width: 2) } }
        .padding(.vertical, 8)
    }
}

/// One step of a tool block: the tool's name in a chip, then what it did, in mono, on one line.
private struct ToolStep: View {
    var event: Event
    var body: some View {
        let error = event.kind == "tool_error"
        let summary = firstLine(event.detail)
        HStack(spacing: 8) {
            Text(toolTitle(event)).font(Theme.caption).foregroundStyle(error ? Theme.danger : Theme.ink).lineLimit(1)
                .padding(.horizontal, 6).frame(height: 19)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(error ? Theme.danger : Theme.line, lineWidth: 1))
                .fixedSize()
            Text(summary).font(Theme.monoSmall).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: 19)
        .padding(.vertical, 3)
    }
}

/// A message's time: the clock today, else the day and the clock.
private struct EventTime: View {
    var event: Event
    var trailing = false
    var body: some View {
        if let when = event.time {
            SelectableText(formatEventTime(when), font: SelectableFont.system(11), color: Theme.muted, align: trailing ? .right : .left)
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                .padding(.top, 6)
        }
    }
}

/// One visible event: the user's message, the agent's reply in Markdown, a question with its options, a turn's footer,
/// or a log line.
private struct EventView: View, Equatable {
    var event: Event
    var canMessage: Bool
    var answer: (String) -> Void
    static func == (a: EventView, b: EventView) -> Bool { a.event == b.event && a.canMessage == b.canMessage }

    var body: some View {
        switch event.kind {
        case "user":
            // `rounded-xl border border-line bg-raise px-3.5 py-2.5`, the time right-aligned under the text.
            VStack(alignment: .leading, spacing: 0) {
                SelectableText(event.text ?? "", font: SelectableFont.system(15), color: Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array((event.attachments?.items ?? []).enumerated()), id: \.offset) { _, a in
                    Text(verbatim: "\u{1F4CE} \(a["name"].string ?? "Attachment")").font(Theme.caption).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail).padding(.top, 6)
                }
                EventTime(event: event, trailing: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 18).padding(.bottom, 14)
        case "text":
            VStack(alignment: .leading, spacing: 0) {
                MarkdownView(source: event.text ?? "")
                EventTime(event: event)
            }
            .padding(.vertical, 10)
        case "ask":
            VStack(alignment: .leading, spacing: 0) {
                SelectableText("Your input is needed", font: SelectableFont.system(12), color: Theme.accent)
                MarkdownView(source: event.question ?? event.text ?? "").padding(.top, 8)
                if canMessage {
                    let labels = (event.options?.items ?? []).compactMap { $0["label"].string }
                    if !labels.isEmpty {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                                Button(label) { answer(label) }.dashButton(.bordered)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: 1))
            .padding(.vertical, 10)
        case "result":
            // "— $2.9565 · 455s · 57 turns · …", under a dashed rule.
            let text = turnFooterText(event)
            VStack(alignment: .leading, spacing: 0) {
                Line().stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
                Text(text).font(Theme.caption).foregroundStyle(event.isError == true ? Theme.danger : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(height: 20).padding(.top, 8)
            }
            .padding(.top, 10).padding(.bottom, 4)
        default:
            if event.text != nil {
                LogLine(text: logLineText(event), color: event.kind == "stderr" ? Theme.danger : Theme.muted)
            }
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); return p }
}

/// The agent at work: the spinner's glyph in the accent and "Thinking…", "Queued…" or "Starting up…".
private struct WorkingLine: View {
    var status: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            let verb = status == "queued" ? "Queued" : (status == "preparing" || status == "starting") ? "Starting up" : workingVerb(tick)
            HStack(spacing: 8) {
                Text(workingGlyph(tick)).font(Theme.bodySemibold).foregroundStyle(Theme.accent).frame(width: 16)
                Text(verbatim: "\(verb)\u{2026}").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
            .frame(height: 24)
        }
    }
}

// MARK: - The held review round

/// A review round waiting for verdicts, completed from inside the conversation: each finding with Fix / Optional /
/// Dismiss, a note, and Complete.
private struct TriageBox: View {
    unowned let model: ConversationModel
    var triage: JSON
    var decisions: [String: String]
    var note: String
    var enabled: Bool

    var body: some View {
        let takes = triageTakesVerdicts(triage)
        let findings = triage["findings"].items
        var fixes = 0
        for f in findings where takes && f["key"].string != nil && findingDecisionIndex(triageDecision(triage, f, picked: decisions)) == 0 { fixes += 1 }
        return VStack(alignment: .leading, spacing: 0) {
            Text(triageTitle(triage)).font(Theme.bodySemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                Rule().padding(.vertical, 8)
                finding(f, takes: takes)
            }
            Rule().padding(.vertical, 8)
            if takes {
                Button { model.editNote() } label: {
                    Text(note.isEmpty ? "A note for the pull request and the fix session (optional)" : note)
                        .font(Theme.caption2).foregroundStyle(note.isEmpty ? Theme.muted : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
            Button(triageCompleteTitle(takesVerdicts: takes, fixes: fixes)) { model.completeTriage(fixes: fixes) }
                .dashButton(.prominent).disabled(!enabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private func finding(_ f: JSON, takes: Bool) -> some View {
        let title = f["title"].string ?? "Finding"
        let url = f["url"].string
        if isSafeWebURL(url) {
            Button { openWebURL(url) } label: {
                Text(title).font(Theme.footnote).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
        } else {
            SelectableText(title, font: SelectableFont.system(13), color: Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let location = findingLocation(f) {
            Text(location).font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).padding(.top, 3)
        }
        if let why = f["parkedWhy"].string {
            SelectableText(why, font: SelectableFont.system(12), color: Theme.muted).padding(.top, 3)
        }
        if takes && f["key"].string != nil {
            Segments(titles: findingDecisionTitles, selected: findingDecisionIndex(triageDecision(triage, f, picked: decisions))) { i in
                model.pick(f, decision: i)
            }
            .disabled(!enabled)
            .padding(.top, 6)
        }
    }
}

/// A 1px rule in the line colour.
struct Rule: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}
