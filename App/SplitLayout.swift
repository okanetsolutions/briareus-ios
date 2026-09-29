import SwiftUI

/// What the right-hand side shows where there is room for two columns.
enum Pane: Hashable {
    case conversation(Session), pulls(Project)
    /// A conversation keeps its identity while polling changes what is known about it.
    var id: String {
        switch self {
        case .conversation(let session): return "conversation:\(session.id)"
        case .pulls(let project): return "pulls:\(project.repo)"
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

/// Projects and their conversations on the left, the chosen one on the right, as the dashboard lays them out.
struct SplitLayout: View {
    @State private var pane: Pane?
    @State private var columns = NavigationSplitViewVisibility.all
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            NavigationStack { ProjectsList() }
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            NavigationStack {
                switch pane {
                case .conversation(let session): ConversationView(initial: session)
                case .pulls(let project): PullsView(project: project)
                case nil:
                    ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("Choose a conversation from the list to read it here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                }
            }
            // Another choice starts from its own first screen rather than under what was pushed on the last.
            .id(pane?.id)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.splitPane, $pane)
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
            .listRowBackground(selected ? Theme.accent.opacity(0.16) : Theme.elevated)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(destination: destination, label: label)
        }
    }
}

extension View {
    /// Keeps a transcript at a readable measure in a wide window.
    func readableWidth() -> some View {
        frame(maxWidth: 860).frame(maxWidth: .infinity)
    }
}
