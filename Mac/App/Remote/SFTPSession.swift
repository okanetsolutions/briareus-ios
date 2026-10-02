// The SFTP sessions tab's sessions (the Windows client's sftp_session.c): this Mac's OpenSSH sftp client, /usr/bin/sftp,
// run without a terminal, fed one command at a time through a pipe (SFTPSessionCore), its answers read back into a tree
// of the server's folders. With no terminal, ssh asks for passwords and host keys through SSH_ASKPASS, which is this app
// (Askpass.swift). Each runs as a process group of its own, so closing it (or the app) ends sftp and the ssh it started.
import Foundation

@MainActor
final class SFTPSession: Identifiable {
    static let client = "/usr/bin/sftp"

    let id: Int
    let target: TermTarget
    private(set) var core: SFTPSessionCore!
    private var process: ChildProcess?

    var key: String { target.key }
    var group: String { target.group }
    var label: String { target.label.isEmpty ? (target.host.isEmpty ? "SFTP" : target.host) : target.label }
    /// user@host:port
    var display: String { target.display }
    var state: SFTPState { core.state }

    fileprivate init(id: Int, target: TermTarget) {
        self.id = id
        self.target = target
        core = SFTPSessionCore(write: { [weak self] text in
            MainActor.assumeIsolated { self?.process?.write(text) ?? false }
        })
        core.onChange = { MainActor.assumeIsolated { SFTPSessions.shared.changed() } }
    }

    /// Starts sftp; the error text when it could not start.
    fileprivate func spawn() -> String? {
        if let problem = target.problem { return problem }
        let askpass = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let env = SSHAskpass.environment(base: ProcessInfo.processInfo.environment, askpass: askpass)
        do {
            let p = try ChildProcess.spawn(Self.client, target.sftpArguments, environment: env, directory: NSHomeDirectory(), pty: nil)
            p.onData = { [weak self, weak p] data in
                guard let self, let p, self.process === p else { return }
                self.core.receive(data)
            }
            p.onExit = { [weak self, weak p] _ in
                guard let self, let p, self.process === p else { return }
                self.process = nil
                self.core.ended()
            }
            process = p
            // The first command waits in the pipe until the connection is up; its echo says it is.
            core.start()
            p.start()
            return nil
        } catch let f as ChildProcess.Failure {
            return f.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Connects a closed session again; its tree is read afresh. The error text when it could not.
    func reconnect() -> String? {
        if state != .closed { return nil }
        stop()
        core.prepareReconnect()
        if let error = spawn() { return error }
        SFTPSessions.shared.changed()
        return nil
    }

    fileprivate func stop() {
        process?.onData = nil
        process?.onExit = nil
        process?.terminate()
        process = nil
    }
    fileprivate func killNow() { process?.killNow(); process = nil }
}

/// Every open SFTP session, whichever project's tab shows it.
@MainActor
final class SFTPSessions: ObservableObject {
    static let shared = SFTPSessions()

    @Published private(set) var sessions: [SFTPSession] = []
    @Published private(set) var active: SFTPSession?
    private var nextID = 1

    private init() {
        LiveSessions.sftpCount = { MainActor.assumeIsolated { SFTPSessions.shared.liveCount } }
        LiveSessions.shutdown.append { MainActor.assumeIsolated { SFTPSessions.shared.shutdown() } }
    }

    /// A session connected, finished a command or its tree or header changed.
    func changed() { objectWillChange.send() }

    /// Starts a session and makes it the active one; the error text when sftp could not start.
    func open(_ target: TermTarget) -> String? {
        let s = SFTPSession(id: nextID, target: target)
        nextID += 1
        if let error = s.spawn() { return error }
        sessions.append(s)
        active = s
        return nil
    }

    /// Ends the session's program and drops it.
    func close(_ s: SFTPSession) {
        guard let at = sessions.firstIndex(where: { $0 === s }) else { return }
        sessions.remove(at: at)
        if active === s {
            // The next session of the same project, else the one before it.
            active = sessions[at...].first { $0.group == s.group } ?? sessions[..<at].last { $0.group == s.group }
        }
        s.stop()
    }

    func setActive(_ s: SFTPSession?) {
        guard let s, s !== active else { return }
        active = s
    }

    func find(_ key: String) -> SFTPSession? { sessions.first { $0.key == key } }
    func count(for key: String) -> Int { sessions.filter { $0.key == key }.count }
    func count(group: String) -> Int { sessions.filter { $0.group == group }.count }
    func live(_ key: String) -> Bool { sessions.contains { $0.key == key && $0.state != .closed } }
    /// Sessions connecting or connected, which quitting the app ends.
    var liveCount: Int { sessions.filter { $0.state != .closed }.count }

    /// The project's session on show: the active one when it is the project's, else its first.
    func shown(group: String) -> SFTPSession? {
        if let a = active, a.group == group { return a }
        return sessions.first { $0.group == group }
    }

    /// Ends every session, as the app quits.
    func shutdown() {
        for s in sessions { s.killNow() }
        sessions = []
        active = nil
    }
}
