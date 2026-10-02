// The conversation's composer, as the Mac's ConversationFooter (`#composer-wrap`): the files, the text, 📎, the
// microphone and send, or ■ to stop the agent while nothing is typed; under it what a message sent now does. A closed or
// read-only conversation shows a box that says so, with Reopen.
import SwiftUI

struct ConversationComposer: View {
    @ObservedObject var model: ConversationScreenModel
    @ObservedObject var draft: ComposerDraft
    @ObservedObject var files: ComposerFiles
    var focused: FocusState<Bool>.Binding
    let stop: () -> Void
    let reopen: () -> Void
    @EnvironmentObject private var store: Store

    var body: some View {
        Group {
            if model.canMessage { box } else { closedBox }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .background(Theme.background)
    }

    private var box: some View {
        let s = model.session
        let empty = draft.trimmedEmpty
        let blocked = !model.can
        let note = conversationComposerNote(active: s.isActive, liveInput: s.liveInput, uploading: files.uploading, files: files.count, empty: empty)
        return VStack(alignment: .leading, spacing: 10) {
            AttachmentChipRow(files: files, enabled: !model.busy)
            TextField(s.isActive ? "Send a follow-up\u{2026}" : "Reply to your agent\u{2026}", text: $draft.text, axis: .vertical)
                .lineLimit(1...8).focused(focused).accessibilityIdentifier("messageInput")
            HStack(spacing: 8) {
                if files.supported { AttachMenu(files: files, enabled: !model.busy) }
                if store.canTranscribe { VoiceNoteControls(voice: model.voice) }
                if !note.isEmpty {
                    Label(note, systemImage: s.isActive ? (s.liveInput ? "bolt.fill" : "clock") : files.uploading ? "arrow.up.circle" : "text.cursor")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if s.isActive && store.supports("cancel") && empty && files.count == 0 {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.footnote).foregroundStyle(.primary)
                            .frame(width: 32, height: 32).background(Theme.bubble, in: Circle())
                    }
                    .buttonStyle(.plain).disabled(blocked).accessibilityLabel("Stop agent")
                } else {
                    let enabled = !blocked && !empty && !files.uploading
                    Button { model.send() } label: {
                        Group {
                            if model.busy { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.subheadline.weight(.bold)) }
                        }
                        .foregroundStyle(.white).frame(width: 32, height: 32)
                        .background(enabled || model.busy ? Theme.accent : Color.secondary.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain).disabled(!enabled).accessibilityLabel("Send message")
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 2)
        .onTapGesture { focused.wrappedValue = true }
    }

    private var closedBox: some View {
        HStack(spacing: 10) {
            Image(systemName: store.canManage ? "archivebox" : "eye").foregroundStyle(.secondary)
            Text(store.canManage ? (model.session.status == "closed" ? "This conversation is closed" : "Messages cannot be sent here")
                                 : "Read-only access")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if store.supports("reopen") && model.session.status == "closed" {
                Button("Reopen", action: reopen).buttonStyle(.borderedProminent).controlSize(.small).disabled(!model.can)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
