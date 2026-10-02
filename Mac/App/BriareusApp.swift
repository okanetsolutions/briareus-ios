// Briareus for Mac: the main window, its columns, and the navigation between them, laid out as the Windows client is.
import AppKit
import SwiftUI
import WebKit

@main
struct BriareusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared
    @StateObject private var navigator = Navigator.shared

    init() {
        // Started by ssh as its SSH_ASKPASS: asks, answers and exits before the app proper starts.
        Askpass.runIfRequested(); RemoteBoardHooks.install()
    }

    var body: some Scene {
        WindowGroup("Briareus", id: "main") {
            MainWindow()
                .environmentObject(store)
                .environmentObject(navigator)
                .frame(minWidth: 420, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("View") {
                Button("Reload") { NotificationCenter.default.post(name: .refreshScreen, object: nil) }.keyboardShortcut("r")
            }
        }
    }
}

extension Notification.Name {
    /// F5 or ⌘R: the screen on show reads everything again.
    static let refreshScreen = Notification.Name("BriareusRefreshScreen")
    /// ⌘S: the settings form on show saves.
    static let saveScreen = Notification.Name("BriareusSaveScreen")
}

/// What is still running when the app is asked to quit: SSH and SFTP sessions end with it, so it asks first.
@MainActor
enum LiveSessions {
    static var sshCount: () -> Int = { 0 }
    static var sftpCount: () -> Int = { 0 }
    static var shutdown: [() -> Void] = []
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            Store.shared.restore()
            // The app always opens filling the screen.
            if let window = NSApp.windows.first, let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Store.shared.active = true }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Store.shared.active = false }
        }
        center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Store.shared.active = false }
        }
        center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Store.shared.active = NSApp.isActive }
        }
        // F5 reads the screen again, as on Windows.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A terminal keeps its own keys, F5 and ⌘S included.
            if event.window?.firstResponder is TerminalCanvas { return event }
            if event.keyCode == 96 /* F5 */ {
                NotificationCenter.default.post(name: .refreshScreen, object: nil)
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "s" {
                NotificationCenter.default.post(name: .saveScreen, object: nil)
                return nil
            }
            return MainActor.assumeIsolated { AppDelegate.paneBackKey(event) } ? nil : event
        }
    }

    /// pane.c: Backspace and Escape go back in the detail pane, and ⌥← too (the main loop's Alt+Left), unless a field, the
    /// terminal or a web page has the keys. Escape is ☑ Select's while it is on, and Settings' sidebar keeps both its own.
    @MainActor
    private static func paneBackKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let back = (event.keyCode == 51 || event.keyCode == 53) && flags.isEmpty || event.keyCode == 123 && flags == .option
        guard back, let window = event.window, window.isKeyWindow, !(window is NSPanel), window.attachedSheet == nil,
              NSApp.modalWindow == nil, Store.shared.connected, Navigator.shared.sidebarMode == .projects else { return false }
        if let responder = window.firstResponder as? NSView {
            var view: NSView? = responder
            while let v = view {
                if v is NSText || v is NSTextField || v is TerminalCanvas || v is WKWebView { return false }
                view = v.superview
            }
        }
        if event.keyCode == 53, ProjectsModel.shared.openProject?.selectMode == true { return false }
        return Navigator.shared.goBack()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let ssh = LiveSessions.sshCount(), sftp = LiveSessions.sftpCount(), live = ssh + sftp
        if live > 0 {
            let kind = sftp == 0 ? "SSH" : ssh == 0 ? "SFTP" : "SSH and SFTP"
            let message = "\(live) \(kind) session\(live == 1 ? " is" : "s are") still open; closing Briareus disconnects \(live == 1 ? "it" : "them")."
            if !Dialogs.confirm("Close Briareus?", message, continueLabel: "Close", destructive: true) { return .terminateCancel }
        }
        LiveSessions.shutdown.forEach { $0() }
        return .terminateNow
    }
}

struct MainWindow: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        Group {
            if store.connected {
                GeometryReader { geo in
                    let narrow = geo.size.width < Theme.narrowWidth
                    columns(narrow: narrow)
                        .clipped()
                        .onAppear { navigator.isNarrow = narrow }
                        .onChange(of: narrow) { _, now in navigator.isNarrow = now }
                }
            } else {
                PairingScreen()
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
        .onChange(of: store.connected) { _, connected in if !connected { navigator.reset() } }
    }

    /// main.c layout(): the 268px sidebar, the main column and, beside a conversation, the 272px panel, the dividers drawn
    /// on the sidebar's last pixel column and the panel's first. Below the Windows client's `lg` breakpoint, one column at a
    /// time, with a back button on the detail's root. The columns are the same views in both: one hidden in a narrow window
    /// keeps its screen, as a hidden Windows pane does, so crossing the breakpoint loses nothing.
    private func columns(narrow: Bool) -> some View {
        let showDetail = narrow && navigator.narrowShowsDetail && navigator.root != .placeholder
        let hideSidebar = narrow && showDetail, hideDetail = narrow && !showDetail
        let panelShown = navigator.panelSession != nil
        return ColumnsLayout(narrow: narrow, showDetail: showDetail, panel: panelShown) {
            SidebarView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) { if !narrow { Rectangle().fill(Theme.line).frame(width: 1) } }
                .columnHidden(hideSidebar)
            DetailPane(rootBack: narrow ? { navigator.narrowShowsDetail = false } : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .columnHidden(hideDetail)
            Group {
                if let session = navigator.panelSession {
                    SessionPanel(session: session)
                        .id(session["id"].string ?? "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.sidebar)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
                } else {
                    Color.clear
                }
            }
            .columnHidden(narrow || !panelShown)
        }
    }
}

private extension View {
    /// A column out of sight: still there, so its screen keeps its state, but not drawn, hit or read out.
    func columnHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).accessibilityHidden(hidden)
    }
}

/// Places the sidebar, the detail and the panel (in that order) as main.c layout() sets the panes' bounds. A hidden column
/// keeps the size it would have so its screen does not lay out at zero width.
private struct ColumnsLayout: Layout {
    var narrow: Bool
    var showDetail: Bool
    var panel: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let w = bounds.width, h = bounds.height
        func put(_ i: Int, x: CGFloat, width: CGFloat) {
            subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), proposal: ProposedViewSize(width: max(width, 0), height: h))
        }
        // A hidden column sits just past the window's right edge, where nothing of it, an embedded browser or terminal
        // included, can be seen or clicked.
        if narrow {
            put(0, x: showDetail ? w : 0, width: w)
            put(1, x: showDetail ? 0 : w, width: w)
            put(2, x: w, width: Theme.panelWidth)
        } else {
            let sw = Theme.sidebarWidth, pw = panel ? Theme.panelWidth : 0
            put(0, x: 0, width: sw)
            put(1, x: sw, width: w - sw - pw)
            put(2, x: panel ? w - pw : w, width: Theme.panelWidth)
        }
    }
}

/// The detail pane: the top of the navigator's stack, with a back button when it can go back.
struct DetailPane: View {
    var rootBack: (() -> Void)? = nil
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        let top = navigator.top
        ScreenView(screen: top)
            .id(top.id)
            .environment(\.paneBack, navigator.stack.count > 1 ? { navigator.pop() } : rootBack)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas)
    }
}

/// The view for each screen.
struct ScreenView: View {
    var screen: Screen
    var body: some View {
        switch screen {
        case .placeholder: PlaceholderScreen()
        case .newSession(let repo): NewSessionScreen(repo: repo)
        case .conversation(let id, let session): ConversationScreen(sessionID: id, initial: session)
        case .board(let repo): BoardScreen(repo: repo)
        case .pull(let repo, let number, let stack, let summary): PullScreen(repo: repo, number: number, stack: stack, summary: summary)
        case .pullFiles(let repo, let number): PullFilesScreen(repo: repo, number: number)
        case .issue(let repo, let issue): IssueScreen(repo: repo, issue: issue)
        case .findings: FindingsScreen()
        case .usage: UsageScreen()
        case .webApp(let app): WebAppScreen(app: app)
        case .projectSettings(let row, let defaults): ProjectSettingsScreen(row: row, defaults: defaults)
        case .providerSettings(let row, let defaults): ProviderSettingsScreen(row: row, defaults: defaults)
        case .dbServerSettings(let row, let defaults): DBServerSettingsScreen(row: row, defaults: defaults)
        case .sshServerSettings(let row, let defaults): SSHServerSettingsScreen(row: row, defaults: defaults)
        }
    }
}

/// The sidebar: the projects and their conversations, or the settings page's own list.
struct SidebarView: View {
    @EnvironmentObject private var navigator: Navigator
    var body: some View {
        switch navigator.sidebarMode {
        case .projects: ProjectsSidebar()
        case .settings: SettingsSidebar()
        }
    }
}
