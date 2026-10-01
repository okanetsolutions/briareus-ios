// The SSH sessions tab's sessions (the Windows client's terminal.c): this Mac's OpenSSH client, /usr/bin/ssh, run in a
// pseudo-terminal and drawn by a terminal view of the app's own. Sessions outlive the screens that show them, as
// SecureCRT's tabs do, until they are closed or the app quits.
import AppKit
import Foundation

@MainActor
final class TerminalSession: Identifiable {
    static let scrollback = 5000
    static let client = "/usr/bin/ssh"

    let id: Int
    let target: TermTarget
    let vt: VTerminal
    /// The view's scroll position and selection.
    var view = TerminalView()
    /// The program runs, or its last output is still being read.
    private(set) var running = false
    private var process: ChildProcess?
    /// The view that draws it; kept with the session so its state survives the screens that show it.
    private(set) lazy var canvas = TerminalCanvas(session: self)

    var key: String { target.key }
    var group: String { target.group }
    var label: String { target.tabLabel }
    /// user@host:port
    var display: String { target.display }
    /// The title the remote shell set, or nil.
    var title: String? { TerminalInput.displayTitle(vt.title, clientSuffix: Self.client) }

    fileprivate init(id: Int, target: TermTarget) {
        self.id = id
        self.target = target
        vt = VTerminal(cols: 80, rows: 24, scrollback: Self.scrollback)
    }

    /// The environment ssh runs in: the app's, with the terminal named so the remote shell knows what it understands.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "BRIAREUS_ASKPASS"] { env[k] = nil }
        env["TERM"] = "xterm-256color"
        // An app started from the Finder has no locale; the terminal speaks UTF-8.
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// Starts ssh; the error text when it could not start.
    fileprivate func spawn() -> String? {
        if let problem = target.problem { return problem }
        do {
            let p = try ChildProcess.spawn(Self.client, target.sshArguments, environment: Self.environment(),
                                           directory: NSHomeDirectory(), pty: (vt.cols, vt.rows))
            p.onData = { [weak self] data in self?.feed(data) }
            p.onExit = { [weak self, weak p] code in
                guard let self, let p, self.process === p else { return }
                self.ended(code)
            }
            process = p
            running = true
            p.start()
            return nil
        } catch let f as ChildProcess.Failure {
            return f.message
        } catch {
            return error.localizedDescription
        }
    }

    private func ended(_ code: Int32) {
        process = nil
        running = false
        feed(Data(TerminalInput.sessionClosedNote(exitCode: code).utf8))
        SSHSessions.shared.changed()
    }

    /// Starts ssh again in the same terminal, after it ended; the error text when it could not.
    func reconnect() -> String? {
        if running { return nil }
        if let error = spawn() { return error }
        feed(Data(TerminalInput.connectingNote(target: target).utf8))
        SSHSessions.shared.changed()
        return nil
    }

    fileprivate func stop() {
        process?.onData = nil
        process?.onExit = nil
        process?.terminate()
        process = nil
        running = false
    }
    fileprivate func killNow() { process?.killNow(); process = nil; running = false }

    // MARK: - Output and input

    func feed(_ data: Data) {
        let before = vt.linesPushed
        let focusEvents = vt.focusEvents
        vt.feed(data)
        if !focusEvents && vt.focusEvents { reportFocus() }
        if let reply = vt.takeResponse() { write(reply) }
        // A view scrolled back stays on the text it shows while new lines arrive below.
        view.follow(vt: vt, pushedBefore: before)
        if vt.takeTitleChanged() { SSHSessions.shared.changed() }
        _ = vt.takeBell()
        canvas.contentChanged()
    }

    func write(_ data: Data) { if running { process?.write(data) } }
    func write(_ bytes: [UInt8]) { write(Data(bytes)) }

    /// Keys typed: the view goes back to the bottom and the selection goes.
    func send(_ bytes: [UInt8]) {
        guard running, !bytes.isEmpty else { return }
        view.offset = 0
        view.clearSelection()
        canvas.contentChanged()
        write(bytes)
    }

    /// Focus in or out, for a program that asked to be told (mode 1004).
    func reportFocus() {
        if running && vt.focusEvents { write(TerminalInput.focusReport(focused: canvas.isFocused)) }
    }

    func resize(cols: Int, rows: Int) {
        if cols == vt.cols && rows == vt.rows { return }
        vt.resize(cols: cols, rows: rows)
        if running { process?.resize(cols: cols, rows: rows) }
        view.clamp(vt: vt)
    }
}

/// Every open SSH session, whichever project's tab shows it.
@MainActor
final class SSHSessions: ObservableObject {
    static let shared = SSHSessions()

    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var active: TerminalSession?
    private var nextID = 1

    private init() {
        // Quitting asks first while a session runs, and ends them all.
        LiveSessions.sshCount = { MainActor.assumeIsolated { SSHSessions.shared.sessions.filter(\.running).count } }
        LiveSessions.shutdown.append { MainActor.assumeIsolated { SSHSessions.shared.shutdown() } }
    }

    /// A session's state changed (it ended, reconnected, its title changed).
    func changed() { objectWillChange.send() }

    /// Starts a session and makes it the active one; the error text when the client could not start.
    func open(_ target: TermTarget) -> String? {
        if let problem = target.problem { return problem }
        let s = TerminalSession(id: nextID, target: target)
        nextID += 1
        if let error = s.spawn() { return error }
        sessions.append(s)
        active = s
        return nil
    }

    /// Ends the session's program and drops it.
    func close(_ s: TerminalSession) {
        guard let i = sessions.firstIndex(where: { $0 === s }) else { return }
        sessions.remove(at: i)
        if active === s { active = sessions.isEmpty ? nil : sessions[i < sessions.count ? i : sessions.count - 1] }
        s.stop()
        s.canvas.removeFromSuperview()
    }

    func setActive(_ s: TerminalSession?) {
        guard let s, s !== active else { return }
        active = s
    }

    /// The first session open to a server.
    func find(_ key: String) -> TerminalSession? { sessions.first { $0.key == key } }
    func count(for key: String) -> Int { sessions.filter { $0.key == key }.count }
    func count(group: String) -> Int { sessions.filter { $0.group == group }.count }
    func live(_ key: String) -> Bool { sessions.contains { $0.key == key && $0.running } }

    /// The project's session on show: the active one when it is the project's, else its first.
    func shown(group: String) -> TerminalSession? {
        if let a = active, a.group == group { return a }
        return sessions.first { $0.group == group }
    }

    /// Ctrl+Tab: the next (or previous) session of the same project.
    func step(from s: TerminalSession, backward: Bool) {
        guard let i = sessions.firstIndex(where: { $0 === s }) else { return }
        let n = sessions.count
        for step in 1..<max(n, 1) {
            let next = sessions[(i + (backward ? n - step : step)) % n]
            if next.group == s.group { setActive(next); return }
        }
    }

    /// Ends every session, as the app quits.
    func shutdown() {
        for s in sessions { s.killNow() }
        sessions = []
        active = nil
    }
}
