// A project's voice conversation, opened from its screen: GPT-Realtime about that project's agents, pull requests and
// findings, and nothing else. What both sides said scrolls as captions; the actions it ran on the server are listed
// under them.
import SwiftUI

struct VoiceScreen: View {
    let repo: String
    @ObservedObject private var voice = VoiceSession.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @ObservedObject private var settings = VoiceSettings.shared
    @Environment(\.navigate) private var navigate

    private var project: Project { projects.projects.first { $0.repo == repo } ?? Project(repo: repo, label: nil) }
    /// A conversation is going on about another project; this screen can only end it.
    private var elsewhere: Bool { voice.isOn && voice.repo != repo }
    /// What this screen shows: its project's conversation, the last one included, and nothing of another's.
    private var mine: Bool { voice.repo == repo }

    var body: some View {
        VStack(spacing: 0) {
            captions
            if mine && !voice.steps.isEmpty { steps }
            controls
        }
        .background(Theme.background)
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { navigate(.voiceSettings) } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Voice settings")
            }
        }
    }

    // MARK: Captions

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !mine || voice.lines.isEmpty { intro }
                    ForEach(mine ? voice.lines : []) { line in
                        Text(line.text)
                            .font(.body)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(line.user ? Theme.accent.opacity(0.14) : Theme.bubble,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: line.user ? .trailing : .leading)
                            .id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: voice.lines.last?.text) {
                if let id = voice.lines.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Talk to \(project.title)'s agents").font(.system(.title2, design: .serif).weight(.semibold))
            Text("Ask what a conversation is doing, answer an agent's question, start one, or stop one. Everything stays on this project. Changes are read back and wait for your yes.")
                .foregroundStyle(.secondary)
            if elsewhere, let other = voice.repo {
                Text("A voice conversation is going on about \(other). End it to talk about this project.")
                    .foregroundStyle(Theme.warning)
            }
            if !settings.hasKey {
                Button("Add your OpenAI API key") { navigate(.voiceSettings) }.padding(.top, 4)
            }
        }
        .padding(.top, 24)
    }

    // MARK: Actions

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(voice.steps.suffix(3)) { step in
                HStack(spacing: 8) {
                    icon(step.state)
                    Text(step.title).font(.footnote).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
    }

    @ViewBuilder private func icon(_ state: VoiceSession.Step.State) -> some View {
        switch state {
        case .running: ProgressView().controlSize(.mini).frame(width: 16)
        case .waiting: Image(systemName: "questionmark.bubble").foregroundStyle(Theme.warning).frame(width: 16)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).frame(width: 16)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger).frame(width: 16)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if mine, let notice = voice.notice { ErrorNotice(message: notice).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: 28) {
                Button { voice.toggleMute() } label: {
                    Image(systemName: voice.muted ? "mic.slash.fill" : "mic.fill").font(.title2)
                        .frame(width: 56, height: 56).background(Theme.surface, in: Circle())
                        .foregroundStyle(voice.muted ? Theme.danger : .primary)
                }
                .buttonStyle(.plain).disabled(voice.phase != .live || elsewhere)
                .accessibilityLabel(voice.muted ? "Unmute" : "Mute")

                Button { voice.isOn ? voice.stop() : voice.start(project) } label: {
                    ZStack {
                        Circle().fill(voice.isOn ? Theme.danger : Theme.accent)
                        if voice.phase == .connecting || voice.phase == .closing { ProgressView().tint(.white) }
                        else { Image(systemName: voice.isOn ? "phone.down.fill" : "waveform").font(.system(size: 30, weight: .semibold)) }
                    }
                    .foregroundStyle(.white).frame(width: 84, height: 84)
                    .scaleEffect(voice.speaking ? 1.06 : 1).animation(.easeInOut(duration: 0.35), value: voice.speaking)
                }
                .buttonStyle(.plain).disabled(voice.phase == .closing || (!voice.isOn && !settings.hasKey))
                .accessibilityLabel(voice.isOn ? "End conversation" : "Start conversation")
                .accessibilityIdentifier("voiceButton")

                // Keeps the big button centred.
                Color.clear.frame(width: 56, height: 56)
            }
            status.font(.footnote).foregroundStyle(.secondary)
            if mine && (voice.isOn || voice.cost.dollars > 0) {
                Text("Cost so far: \(voice.cost.text)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("voiceCost")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 18)
    }

    @ViewBuilder private var status: some View {
        switch voice.phase {
        case _ where elsewhere: Text("Tap to end the conversation about \(voice.repo ?? "another project")")
        case .off: Text(settings.hasKey ? "Tap to talk about \(project.title)" : "Add an OpenAI API key in Voice settings")
        case .connecting: Text("Connecting…")
        case .closing: Text("Ending…")
        case .live:
            if let started = voice.started {
                HStack(spacing: 4) {
                    Text(voice.muted ? "Muted" : voice.speaking ? "Speaking" : "Listening")
                    Text("·")
                    Text(started, style: .timer).monospacedDigit()
                }
            }
        }
    }
}

extension VoiceSession.Step {
    /// What the step does, in a few words.
    var title: String {
        let session = args["session_id"].string.map { _ in "a conversation" }
        switch tool {
        case .listConversations: return "Read the conversations"
        case .readConversation: return "Read \(session ?? "a conversation")"
        case .listPullRequests: return "Read the pull requests"
        case .waitingFindings: return "Read the findings waiting"
        case .listIssues: return "Read the issues"
        case .readIssue: return "Read issue #" + (args["issue"].int.map(String.init) ?? "")
        case .readPullRequest: return "Read the changes of #" + (args["number"].int.map(String.init) ?? "")
        case .workOnIssue: return (state == .waiting ? "Asked to work on issue #" : "Work on issue #") + (args["issue"].int.map(String.init) ?? "")
        case .startConversation: return (state == .waiting ? "Asked to start an agent: " : "Start an agent: ") + (args["prompt"].string ?? "")
        case .sendMessage: return (state == .waiting ? "Asked to send: " : "Send: ") + (args["text"].string ?? "")
        case .stopConversation: return state == .waiting ? "Asked to stop an agent" : "Stop an agent"
        case nil: return name
        }
    }
}
