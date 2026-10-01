// Briareus for Mac: the main window, its columns, and the navigation between them, laid out as the Windows client is.
import AppKit
import SwiftUI

@main
struct BriareusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared
    @StateObject private var navigator = Navigator.shared

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
            if event.keyCode == 96 /* F5 */ {
                NotificationCenter.default.post(name: .refreshScreen, object: nil)
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "s" {
                NotificationCenter.default.post(name: .saveScreen, object: nil)
                return nil
            }
            return event
        }
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
                    if geo.size.width < Theme.narrowWidth { narrow } else { wide }
                }
            } else {
                PairingScreen()
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
        .onChange(of: store.connected) { _, connected in if !connected { navigator.reset() } }
    }

    private var wide: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: Theme.sidebarWidth)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.line).frame(width: 1)
            DetailPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let session = navigator.panelSession {
                Rectangle().fill(Theme.line).frame(width: 1)
                SessionPanel(session: session)
                    .id(session["id"].string ?? "")
                    .frame(width: Theme.panelWidth)
                    .background(Theme.sidebar)
            }
        }
    }

    /// Below the dashboard's `lg` breakpoint, one column at a time, with a back button on the detail's root.
    private var narrow: some View {
        Group {
            if navigator.narrowShowsDetail && navigator.root != .placeholder {
                DetailPane(rootBack: { navigator.narrowShowsDetail = false })
            } else {
                SidebarView().background(Theme.sidebar)
            }
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
        case .dashboard: DashboardScreen()
        case .webApp(let app): WebAppScreen(app: app)
        case .projectSettings(let row, let defaults): ProjectSettingsScreen(row: row, defaults: defaults)
        case .providerSettings(let row, let defaults): ProviderSettingsScreen(row: row, defaults: defaults)
        case .dbServerSettings(let row, let defaults): DBServerSettingsScreen(row: row, defaults: defaults)
        case .sshServerSettings(let row, let defaults): SSHServerSettingsScreen(row: row, defaults: defaults)
        case .devices: DevicesScreen()
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
