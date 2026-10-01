// The main window's columns and the navigation between them: the sidebar, the detail pane's stack of screens, and the
// column beside a conversation (the dashboard's pull request panel).
import SwiftUI

/// The web apps the sidebar strip opens in the detail pane.
enum WebApp: String, Hashable, CaseIterable { case whatsapp, slack }

/// What the detail pane shows. Each case's `id` names what it shows, so a repeated choice is not reopened.
enum Screen: Hashable, Identifiable {
    case placeholder
    /// The dashboard's opening view: Welcome back, and the composer that starts a session on a project.
    case newSession(repo: String?)
    /// A conversation; `session` is the record the sidebar had, shown until the server answers.
    case conversation(id: String, session: JSON?)
    /// A project's board: pull requests, issues, SSH sessions and SFTP sessions as tabs.
    case board(repo: String)
    /// A pull request; `stack` is its StackPosition JSON and `summary` its board row, either nil when unknown.
    case pull(repo: String, number: Int, stack: JSON?, summary: JSON?)
    /// The changed files on their own, for the conversation's menu.
    case pullFiles(repo: String, number: Int)
    /// An issue, with its board row.
    case issue(repo: String, issue: JSON)
    /// The review rounds waiting for a decision across every project.
    case findings
    /// What every project spent over a window.
    case dashboard
    case webApp(WebApp)
    /// The settings page's forms: `row` is the server's record (nil with `defaults` for a new one).
    case projectSettings(row: JSON?, defaults: JSON?)
    case providerSettings(row: JSON?, defaults: JSON?)
    case dbServerSettings(row: JSON?, defaults: JSON?)
    case sshServerSettings(row: JSON?, defaults: JSON?)
    /// Settings → Devices and clients.
    case devices

    var id: String {
        switch self {
        case .placeholder: return "placeholder"
        case .newSession(let repo): return "new:\(repo ?? "")"
        case .conversation(let id, _): return "conversation:\(id)"
        case .board(let repo): return "pulls:\(repo)"
        case .pull(let repo, let n, _, _): return "pull:\(repo)#\(n)"
        case .pullFiles(let repo, let n): return "files:\(repo)#\(n)"
        case .issue(let repo, let issue): return "issue:\(repo)#\(issue["number"].int ?? 0)"
        case .findings: return "findings"
        case .dashboard: return "dashboard"
        case .webApp(let app): return app.rawValue
        case .projectSettings(let row, _): return "project-settings:\(row?["id"].int.map(String.init) ?? "new")"
        case .providerSettings(let row, _): return "provider-settings:\(row?["id"].int.map(String.init) ?? "new")"
        case .dbServerSettings(let row, _): return "db-server:\(row?["id"].int.map(String.init) ?? "new")"
        case .sshServerSettings(let row, _): return "ssh-server:\(row?["id"].int.map(String.init) ?? "new")"
        case .devices: return "devices"
        }
    }
    static func == (a: Screen, b: Screen) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class Navigator: ObservableObject {
    static let shared = Navigator()

    enum SidebarMode { case projects, settings }

    /// The detail pane's stack: its root first.
    @Published private(set) var stack: [Screen] = [.placeholder]
    @Published var sidebarMode: SidebarMode = .projects
    /// The session whose column shows beside its conversation; nil takes the column away.
    @Published var panelSession: JSON?
    /// In one column, whether the detail is the visible pane.
    @Published var narrowShowsDetail = false

    /// A form with unsaved changes registers here; it answers whether another screen may replace it (asking first).
    var leaveGuard: (() -> Bool)?

    var root: Screen { stack.first ?? .placeholder }
    var top: Screen { stack.last ?? .placeholder }
    /// The row the sidebar highlights: the detail pane's root screen id.
    var selectedID: String? { root == .placeholder ? nil : root.id }

    private func mayLeave() -> Bool {
        guard let leaveGuard else { return true }
        if leaveGuard() { self.leaveGuard = nil; return true }
        return false
    }

    /// Shows a screen as the detail pane's root, unless one with the same id already is.
    func show(_ screen: Screen) {
        if stack.count == 1 && root == screen { narrowShowsDetail = true; return }
        guard mayLeave() else { return }
        panelSession = nil
        stack = [screen]
        narrowShowsDetail = true
    }
    func push(_ screen: Screen) {
        if top == screen { return }
        stack.append(screen)
        narrowShowsDetail = true
    }
    func pop() {
        if stack.count > 1 {
            if top.id.hasPrefix("conversation:") { panelSession = nil }
            stack.removeLast()
        } else { narrowShowsDetail = false }
    }
    /// Empties the detail pane after its conversation was deleted, unless a form there keeps its unsaved changes.
    func clear() {
        guard mayLeave() else { return }
        panelSession = nil
        stack = [.placeholder]
        narrowShowsDetail = false
    }
    /// Signing out or a revoked token: everything goes.
    func reset() {
        leaveGuard = nil
        panelSession = nil
        stack = [.placeholder]
        sidebarMode = .projects
        narrowShowsDetail = false
    }
}

// MARK: - Header

/// A header button: a glyph alone, or a labelled pill when `label` is set and the header has room for the labels.
/// `prominent` fills it with the accent, as the dashboard's `.btn-primary` (Save).
struct HeaderButton: Identifiable {
    var id: String { label ?? glyph }
    var glyph: String           // an SF Symbol
    var label: String? = nil
    var tip: String? = nil
    var enabled = true
    var destructive = false
    var prominent = false
    var action: () -> Void
}

/// The pane's header: `px-[18px] py-2.5` around a 15px title and a 13px subtitle (with a status dot before it), the back
/// button when the pane can go back, a ✎ after the title when it can be renamed, and the `.btn` pills on the right.
struct PaneHeader: View {
    var title: String
    var subtitle: String? = nil
    var status: String? = nil
    var buttons: [HeaderButton] = []
    var titleAction: (() -> Void)? = nil
    var sidebar = false
    @Environment(\.paneBack) private var back

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(minHeight: subtitle != nil ? 61 : 53)
        .background(sidebar ? Theme.sidebar : Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func row(labels: Bool) -> some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) { Text("‹").font(Theme.body) }.buttonStyle(IconButtonStyle())
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(title).font(Theme.headline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    if let titleAction {
                        Button(action: titleAction) { Text("✎").font(Theme.footnote) }.buttonStyle(HoverInkStyle()).help("Rename")
                    }
                }
                .frame(minHeight: 22)
                if let subtitle {
                    HStack(spacing: 6) {
                        if let status { StatusDot(status: status) }
                        Text(subtitle).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(minHeight: 18)
                }
            }
            .frame(minWidth: labels ? 120 : 0, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            ForEach(buttons) { b in
                Group {
                    if let label = b.label, labels {
                        Button(action: b.action) { Text(label) }.dashButton(b.prominent ? .prominent : b.destructive ? .destructive : .bordered)
                    } else {
                        Button(action: b.action) { Image(systemName: b.glyph) }
                            .buttonStyle(IconButtonStyle(destructive: b.destructive, prominent: b.prominent))
                    }
                }
                .disabled(!b.enabled)
                .help(b.tip ?? b.label ?? "")
            }
        }
    }
}

/// Muted text that turns to ink on hover, as the ✎ after a title.
struct HoverInkStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hovered ? Theme.ink : Theme.muted).onHover { hovered = $0 }
    }
}

private struct PaneBackKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    /// The back button's action when the pane can go back: a pushed screen, or the root in one column.
    var paneBack: (() -> Void)? {
        get { self[PaneBackKey.self] }
        set { self[PaneBackKey.self] = newValue }
    }
}
