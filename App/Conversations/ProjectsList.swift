// The Projects tab, as the Mac sidebar's first screen (screen_projects.c): every project this device reads, each with how
// many conversations it holds and whether one is at work, and a new session on any of them.
import SwiftUI

struct ProjectsList: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var model = ProjectsModel.shared
    @Environment(\.navigate) private var navigate
    @State private var composing = false

    var body: some View {
        List {
            if !store.canManage {
                Section {
                    Label("Read-only access", systemImage: "lock").font(.subheadline).foregroundStyle(.secondary)
                } footer: { Text("This device can read conversations but not start or change them.") }
                .listRowBackground(Theme.row)
            }
            if let error = model.error {
                Section { ErrorNotice(message: error) }.listRowBackground(Theme.row)
            }
            Section {
                ForEach(model.projects, id: \.repo) { project in
                    DestinationLink(destination: .project(repo: project.repo)) {
                        ProjectRowLabel(project: project, feed: store.feed(project.repo))
                    }
                }
            }
            if model.loaded && model.projects.isEmpty && model.error == nil {
                ContentUnavailableView("No projects", systemImage: "folder",
                                       description: Text("Issue this device a token that includes a project, or add one in Settings \u{2192} Projects."))
                    .listRowBackground(Color.clear)
            }
            if !model.loaded {
                ProgressView("Loading projects\u{2026}").frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Projects")
        .toolbar {
            if store.supports("start_session") && !model.projects.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New session")
                }
            }
        }
        .sheet(isPresented: $composing) {
            NewConversationSheet(repo: nil) { started in navigate(.conversation(id: started.id, session: started.raw)) }
        }
        .refreshable { _ = await reading { try await model.load() } }
        // Shown: the counts from the saved lists, then every 30 seconds the server's.
        .onAppear { model.recount() }
        .task { await poll(every: 30) { await reading { try await model.load() } } }
    }
}

/// A project: its monogram, its name and repository, how many conversations it holds, and how many are at work.
private struct ProjectRowLabel: View {
    let project: Project
    @ObservedObject var feed: ProjectFeed

    var body: some View {
        let working = feed.sessions.filter(\.isActive).count
        let count = feed.sessions.count
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).font(.body.weight(.medium)).lineLimit(1)
                if project.title != project.repo {
                    Text(project.repo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if working > 0 {
                HStack(spacing: 5) {
                    StatusDot(status: "running")
                    Text("\(working)").font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(Theme.success)
                }
            }
            if feed.sessionsLoaded {
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(feed.sessionsLoaded ? "\(count) conversation\(count == 1 ? "" : "s")\(working > 0 ? ", \(working) working" : "")" : "")
    }
}
