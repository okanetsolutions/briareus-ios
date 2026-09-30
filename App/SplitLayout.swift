import SwiftUI

/// What the right-hand side shows where there is room for two columns.
enum Pane: Hashable {
    case conversation(Session), pulls(Project), findings(Project)
    /// A conversation keeps its identity while polling changes what is known about it.
    var id: String {
        switch self {
        case .conversation(let session): return "conversation:\(session.id)"
        case .pulls(let project): return "pulls:\(project.repo)"
        case .findings(let project): return "findings:\(project.repo)"
        }
    }
    @ViewBuilder var screen: some View {
        switch self {
        case .conversation(let session): ConversationView(initial: session)
        case .pulls(let project): PullsView(project: project)
        case .findings(let project): FindingsView(project: project)
        }
    }
}

private struct SplitPaneKey: EnvironmentKey {
    static let defaultValue: Binding<Pane?>? = nil
}
extension EnvironmentValues {
    /// Set only in the two-column layout; nil on a phone, where a row pushes its screen instead.
    var splitPane: Binding<Pane?>? {
        get { self[SplitPaneKey.self] }
        set { self[SplitPaneKey.self] = newValue }
    }
}

private struct SplitProjectKey: EnvironmentKey {
    static let defaultValue: Binding<Project?>? = nil
}
extension EnvironmentValues {
    /// Set only on a Mac, where the projects keep a column of their own and a row chooses rather than pushes.
    var splitProject: Binding<Project?>? {
        get { self[SplitProjectKey.self] }
        set { self[SplitProjectKey.self] = newValue }
    }
}

/// Projects and their conversations on the left, the chosen one on the right, as the dashboard lays them out.
struct SplitLayout: View {
    @State private var pane: Pane?
    @State private var project: Project?
    @State private var columns = NavigationSplitViewVisibility.all
    var body: some View {
        Group {
            #if os(macOS)
            // A Mac window is wide enough for the projects, a project's conversations and the chosen one side by side.
            NavigationSplitView(columnVisibility: $columns) {
                ProjectsList().ownControls().navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } content: {
                Group {
                    if let project { ProjectView(project: project).id(project.repo) }
                    else {
                        ContentUnavailableView("No project selected", systemImage: "folder",
                                               description: Text("Choose a project to see its conversations."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                    }
                }
                .ownControls()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
            } detail: { detail.ownControls() }
            .environment(\.splitProject, $project)
            #else
            NavigationSplitView(columnVisibility: $columns) {
                NavigationStack { ProjectsList() }
                    .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
                    // The two sides share a background, so a rule marks where the list ends.
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 0.5).ignoresSafeArea() }
            } detail: { detail }
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.splitPane, $pane)
    }
    private var detail: some View {
        NavigationStack {
            if let pane { pane.screen } else {
                ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Choose a conversation from the list to read it here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            }
        }
        // Another choice starts from its own first screen rather than under what was pushed on the last.
        .id(pane?.id)
    }
}

/// A list row that fills the right-hand side in two columns and pushes its screen on a phone.
struct PaneLink<Destination: View, Label: View>: View {
    let pane: Pane
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @Environment(\.splitPane) private var selection
    var body: some View {
        if let selection {
            let selected = selection.wrappedValue?.id == pane.id
            Button { selection.wrappedValue = pane } label: {
                label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.row(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(destination: destination, label: label)
        }
    }
}

extension View {
    /// A sheet on a Mac takes the size of what it holds, which for a form is next to nothing.
    func sheetSize(width: CGFloat = 520, height: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height).ownControls()
        #else
        self
        #endif
    }
}

extension View {
    /// A Mac draws a bezel around every button unless told otherwise; the screens draw their own.
    /// It goes on a column's content, not the window, so the toolbar keeps the system's buttons.
    func ownControls() -> some View {
        #if os(macOS)
        buttonStyle(.borderless)
        #else
        self
        #endif
    }
}
