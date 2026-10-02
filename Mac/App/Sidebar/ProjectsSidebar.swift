// The sidebar, as the Windows client draws it (screen_projects.c): the ＋ New session strip with WhatsApp and Slack, the 📊 and ⚑
// switches, the projects with their session counts, and inside a project its conversations; what Spotify plays, and
// ⚙ Settings, ☑ Select and ⎋ along the foot. The project's conversations are pushed inside the sidebar, as on Windows, with
// `‹ All projects` to come back.
import AppKit
import SwiftUI

struct ProjectsSidebar: View {
    @ObservedObject private var model = ProjectsModel.shared

    var body: some View {
        Group {
            if let open = model.openProject {
                SidebarSessionsScreen(model: open).id(open.project.repo)
            } else {
                SidebarProjectsScreen()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .onAppear { Media.shared.start() }
    }
}

// MARK: - What both sidebar screens draw

@MainActor
enum SidebarCommon {
    /// sidebar_common_action: the strip's own actions, the same on both screens; ＋ New session opens on `repo`.
    static func perform(_ action: StripAction, newSessionRepo: String?) {
        let nav = Navigator.shared
        switch action {
        case .newSession: nav.show(.newSession(repo: newSessionRepo))
        case .usage: nav.show(.usage)
        case .whatsapp: nav.show(.webApp(.whatsapp))
        case .slack: nav.show(.webApp(.slack))
        case .findings: nav.show(.findings)
        }
    }

    /// The foot's ⚙: Settings take the sidebar's place, as the Windows client's settings page has a sidebar of its own.
    static func openSettings() { Navigator.shared.sidebarMode = .settings }

    static func signOut() {
        guard Dialogs.confirm("Sign out of this server?",
                              "The device token and the saved conversations are removed from this computer. Revoke the token itself in web Settings.",
                              continueLabel: "Sign out", destructive: true) else { return }
        Store.shared.forget()
    }
}

/// A sidebar screen: the strip and the rows scrolling between the sidebar's 10px margins, over the foot.
private struct SidebarScreenFrame<Content: View>: View {
    var sessions: SidebarSessions?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SidebarScroll { content() }
            SidebarFooter(sessions: sessions, settings: SidebarCommon.openSettings, signOut: SidebarCommon.signOut)
        }
    }
}

/// The sidebar pane's scrolling (pane.c): the rows between 10px margins, 12px more to scroll past the end, and the
/// the Windows client's own 10px scrollbar (`::-webkit-scrollbar`, the palette's thumb, no track) in place of the system's. Once the
/// rows overflow, the bar takes its own 10px of width instead of covering the ⚑ badge and the rows' edges.
struct SidebarScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0
    @State private var offset: CGFloat = 0
    private let space = "sidebarScroll"

    var body: some View {
        GeometryReader { outer in
            let visible = outer.size.height
            let overflows = contentHeight > visible + 0.5
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                    Color.clear.frame(height: 12)
                }
                .padding(.leading, Theme.sidebarMargin)
                .padding(.trailing, Theme.sidebarMargin + (overflows ? 10 : 0))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: SidebarScrollMetrics.self, value: g.frame(in: .named(space)))
                })
            }
            .coordinateSpace(name: space)
            .scrollIndicators(.never)
            .onPreferenceChange(SidebarScrollMetrics.self) { r in
                if abs(r.height - contentHeight) > 0.5 { contentHeight = r.height }
                if abs(-r.minY - offset) > 0.5 { offset = -r.minY }
            }
            .overlay(alignment: .topTrailing) {
                if overflows {
                    let total = contentHeight, maxScroll = max(total - visible, 1)
                    let thumb = max(28, visible * visible / max(total, 1))
                    let y = (visible - thumb) * min(max(offset, 0), maxScroll) / maxScroll
                    RoundedRectangle(cornerRadius: 6).fill(Theme.thumb)
                        .frame(width: 10, height: thumb)
                        .offset(y: y)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct SidebarScrollMetrics: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// A line of text in the sidebar (doc_text), 8px in, with the copy menu a right click on text has.
private struct SidebarNote: View {
    var text: String
    var font: Font = Theme.footnote
    var color: Color = Theme.muted
    var wraps = true
    var body: some View {
        Text(text).font(font).foregroundStyle(color)
            .lineLimit(wraps ? nil : 1).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: wraps)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu { Button("Copy text") { Clipboard.copy(text) } }
    }
}

// MARK: - Projects

private struct SidebarProjectsScreen: View {
    @ObservedObject private var model = ProjectsModel.shared
    @ObservedObject private var navigator = Navigator.shared
    @ObservedObject private var store = Store.shared

    var body: some View {
        SidebarScreenFrame(sessions: nil) {
            Color.clear.frame(height: 10)
            SidebarStrip(selected: navigator.selectedID, waiting: model.findingsWaiting) {
                SidebarCommon.perform($0, newSessionRepo: model.projects.first?.repo)
            }
            Color.clear.frame(height: 14)
            if !store.canManage {
                SidebarNote(text: "🔒 Read-only access", font: Theme.caption, wraps: false)
                Color.clear.frame(height: 8)
            }
            if let error = model.error {
                Notice(message: error).padding(.horizontal, 8)
                Color.clear.frame(height: 8)
            }
            ForEach(model.projects, id: \.repo) { p in
                ProjectRow(name: p.title, count: model.counts[p.repo] ?? 0, busy: model.busy[p.repo] ?? false, height: 39) {
                    model.openProject = SidebarSessions(project: p)
                }
            }
            if model.loaded && model.projects.isEmpty && model.error == nil {
                SidebarNote(text: "No projects yet. Add one in ⚙ Settings → Projects.")
            }
            if !model.loaded { LoadingNote(text: "Loading projects…") }
            Color.clear.frame(height: 8)
        }
        // Shown: the counts from the saved lists, then every 30 seconds the server's.
        .onAppear { model.recount() }
        .task { await poll(every: 30) { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
    }
}

// MARK: - Sessions

private struct SidebarSessionsScreen: View {
    @ObservedObject var model: SidebarSessions
    @ObservedObject private var projects = ProjectsModel.shared
    @ObservedObject private var navigator = Navigator.shared
    @State private var keyMonitor: Any?

    var body: some View {
        let selected = navigator.selectedID
        SidebarScreenFrame(sessions: model) {
            Color.clear.frame(height: 10)
            SidebarStrip(selected: selected, waiting: projects.findingsWaiting) {
                SidebarCommon.perform($0, newSessionRepo: model.project.repo)
            }
            Color.clear.frame(height: 14)
            // `‹ All projects`, the project itself (its pull requests), then its conversations.
            BackRow { projects.openProject = nil }
            Color.clear.frame(height: 2)
            ProjectRow(name: model.project.title, count: model.sessions.count, selected: selected == "pulls:\(model.project.repo)",
                       chevron: false, height: 35) {
                navigator.show(.board(repo: model.project.repo))
            }
            Color.clear.frame(height: 4)
            if let error = model.error {
                Notice(message: error).padding(.horizontal, 8)
                Color.clear.frame(height: 8)
            }
            ForEach(model.sessions, id: \.id) { s in
                SidebarSessionRow(session: s,
                                    lit: model.selectMode ? model.isPicked(s.id) : selected == "conversation:\(s.id)",
                                    selectMode: model.selectMode, picked: model.isPicked(s.id)) { open(s) }
            }
            if model.loaded && model.sessions.isEmpty { SidebarNote(text: "No conversations here yet.") }
            if !model.loaded { LoadingNote() }
            Color.clear.frame(height: 8)
        }
        .task { await poll(every: 7) { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await model.load() } }
        .onAppear {
            // Esc leaves ☑ Select.
            let model = model
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, NSApp.modalWindow == nil else { return event }
                let consumed: Bool = MainActor.assumeIsolated {
                    guard model.selectMode else { return false }
                    model.leaveSelectMode()
                    return true
                }
                return consumed ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private func open(_ s: Session) {
        if model.selectMode { model.togglePick(s.id); return }
        // Ctrl- or ⌘-clicking a row turns ☑ Select on with that row ticked, as the Windows client does.
        let flags = NSEvent.modifierFlags
        if flags.contains(.control) || flags.contains(.command) {
            model.selectMode = true
            model.togglePick(s.id)
            return
        }
        navigator.show(.conversation(id: s.id, session: s.raw))
    }
}
