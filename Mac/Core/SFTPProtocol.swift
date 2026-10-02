// The SFTP sessions tab's platform-independent part, ported from the Windows client's app/sftp_session.c: OpenSSH's sftp
// client fed one command at a time through its standard input, its answers read back into a tree of the server's
// folders. After each command the session writes `version`, whose echo and answer mark where the command's own output
// ended: sftp echoes every command it reads from a pipe as "sftp> <command>", and its errors arrive on the same pipe (its
// standard error joined to its standard output), in order. Starting sftp, reading its output and noticing it end belong
// to the app, which hands the bytes to `receive` and calls `ended` at end of file.
import Foundation

/// A file or folder on the server. Folders hold their entries once listed, folders first, then by name.
final class SFTPNode {
    let name: String
    let path: String
    var dir: Bool
    var link = false
    var size: Int64 = 0
    var when: String?
    var expanded = false, loaded = false, loading = false
    /// why listing it failed
    var error: String?
    var kids: [SFTPNode] = []

    init(name: String, path: String, dir: Bool) { self.name = name; self.path = path; self.dir = dir }

    func find(_ path: String) -> SFTPNode? {
        if self.path == path { return self }
        if !SFTP.pathWithin(path, self.path) { return nil }
        for k in kids { if let f = k.find(path) { return f } }
        return nil
    }

    /// Folders (and links, which may be folders) first, then by name, case aside, then by name exactly.
    static func ordered(_ x: SFTPNode, _ y: SFTPNode) -> Bool {
        let fx = x.dir || x.link, fy = y.dir || y.link
        if fx != fy { return fx }
        let lx = x.name.utf8.map(asciiLower), ly = y.name.utf8.map(asciiLower)
        if lx != ly { return lx.lexicographicallyPrecedes(ly) }
        return Array(x.name.utf8).lexicographicallyPrecedes(Array(y.name.utf8))
    }
    private static func asciiLower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c + 0x20 : c }
}

enum SFTPState: Equatable, Sendable { case connecting, ready, closed }

/// One SFTP session's protocol state: its command queue, the tree and what the header says.
final class SFTPSessionCore {
    enum CommandKind: Equatable, Sendable { case pwd, list, get, put, mkdir, rename, rm, rmdir }
    struct Command: Equatable, Sendable {
        var kind: CommandKind
        /// what is written to sftp, without the newline
        var line: String
        /// the remote path it is about (and a rename's new one, an upload's folder)
        var path: String?
        var path2: String?
        /// a transfer's local path
        var local: String?
        /// what the header says while it runs, for transfers and changes
        var what: String?
    }

    static let logLines = 12

    /// Writes text to sftp's standard input; false when the pipe is gone (later writes are then skipped).
    private let write: (String) -> Bool
    private var canWrite = true
    /// Called whenever the session connects, finishes a command or its tree or header changes.
    var onChange: (() -> Void)?

    private(set) var state = SFTPState.closed
    private var partial: [UInt8] = []
    private var log: [String] = []
    private(set) var current: Command?
    private(set) var queue: [Command] = []
    /// 0: its echo is awaited, 1: its output, 2: the marker's answer
    private var phase = 0
    private var out: [String] = []
    /// The folder the server started in, once connected.
    private(set) var home: String?
    var selected: String?
    private var reveal: String?
    /// "/" and everything listed under it; nil until connected.
    private(set) var root: SFTPNode?
    /// The last transfer's or change's outcome; nil when there is none.
    private(set) var status: String?
    private(set) var statusFailed = false
    /// The local path of the last finished download, for "Show in Finder"; nil when there is none.
    private(set) var lastDownload: String?

    init(write: @escaping (String) -> Bool) { self.write = write }

    private func notify() { onChange?() }

    // MARK: - Starting and ending

    /// sftp has just started: the first command (`pwd`) waits in the pipe until the connection is up; its echo says it is.
    func start() {
        state = .connecting
        canWrite = true
        log = []
        partial = []
        enqueue(Command(kind: .pwd, line: "pwd"))
    }

    /// Before starting sftp again for a closed session: its tree is read afresh.
    func prepareReconnect() {
        root = nil
        status = nil; statusFailed = false
    }

    /// The program ended: what it was doing is dropped, the tree stays to look at until a reconnect.
    func ended() {
        guard state != .closed else { return }
        if !partial.isEmpty { let rest = String(decoding: partial, as: UTF8.self); partial = []; onLine(rest) }
        let wasReady = state == .ready
        state = .closed
        canWrite = false
        if let what = current?.what { setStatus("\(what) stopped: the connection closed.", true) }
        else if wasReady { setStatus("The connection closed.", true) }
        current = nil
        queue = []
        // Folders waiting for a listing stop spinning.
        var stack = root.map { [$0] } ?? []
        while let n = stack.popLast() { n.loading = false; stack += n.kids }
        notify()
    }

    /// What the client printed while connecting, when it closed before it was ready (the reason it failed).
    var connectLog: String? {
        if state != .closed || root != nil || log.isEmpty { return nil }
        return log.joined(separator: "\n")
    }

    // MARK: - Commands

    private func writeLine(_ line: String) {
        guard canWrite else { return }
        if !write("\(line)\nversion\n") { canWrite = false }
    }
    /// Starts the next command when none runs.
    private func pump() {
        if current != nil || queue.isEmpty || state == .closed { return }
        current = queue.removeFirst()
        phase = 0
        out = []
        writeLine(current!.line)
    }
    @discardableResult private func enqueue(_ c: Command?) -> Bool {
        guard let c else { return false }
        queue.append(c)
        pump()
        return true
    }
    /// `<verb> <quoted> [<quoted>]`, or nil when a path cannot be written on sftp's command line.
    private func command(_ verb: String, _ a: String, _ b: String? = nil) -> String? {
        guard let qa = SFTP.quote(a) else { return nil }
        guard let b else { return "\(verb) \(qa)" }
        guard let qb = SFTP.quote(b) else { return nil }
        return "\(verb) \(qa) \(qb)"
    }

    func node(_ path: String?) -> SFTPNode? { path.flatMap { root?.find($0) } }

    private func relist(_ path: String?) {
        if let n = node(path), n.loaded || n.expanded, !n.loading { list(n.path) }
    }

    /// What runs now (an upload, a download, a change), or nil, and how many wait behind it.
    var busy: (what: String?, queued: Int) {
        let n = queue.filter { $0.what != nil }.count
        if let w = current?.what { return (w, n) }
        if let w = queue.first(where: { $0.what != nil })?.what { return (w, n - 1) }
        return (nil, n)
    }

    /// Lists a folder again.
    func list(_ path: String) {
        guard let n = node(path), !n.loading, state != .closed else { return }
        // The trailing slash lists a link's target folder, and fails for a link to a file.
        guard let line = command("ls -la", path == "/" ? "/" : path + "/") else {
            n.error = "This name cannot be given to sftp."; n.loaded = true
            return
        }
        n.loading = true
        enqueue(Command(kind: .list, line: line, path: path))
    }
    /// Opens a folder (listing it the first time) or closes it.
    func toggle(_ path: String) {
        guard let n = node(path), n.dir || n.link else { return }
        n.expanded.toggle()
        if n.expanded && !n.loaded { list(path) }
        notify()
    }
    func select(_ path: String?) { selected = path; notify() }

    /// The entry of `n` on the way down to `path`. When the listing does not show it (a folder that can be entered but not
    /// listed, as Linux's /home can be, or a mount point) it is added, so the tree still reaches it.
    private func stepToward(_ n: SFTPNode, _ path: String) -> SFTPNode? {
        if let k = n.kids.first(where: { SFTP.pathWithin(path, $0.path) }) { return k }
        var rest = Substring(path.dropFirst(n.path.count))
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        if rest.isEmpty { return nil }
        let name = String(rest.prefix(while: { $0 != "/" }))
        let k = SFTPNode(name: name, path: SFTP.join(n.path, name), dir: true)
        n.kids.append(k)
        n.kids.sort(by: SFTPNode.ordered)
        return k
    }
    /// Opens the folders down to `reveal` as far as they are listed, listing the next one; done once it is reached.
    private func revealMore() {
        var n = root
        while let cur = n, let target = reveal {
            cur.expanded = true
            if !cur.loaded { list(cur.path); return }
            if cur.path == target { reveal = nil; return }
            n = stepToward(cur, target)
        }
    }
    /// Opens every folder from "/" down to `path` and selects it.
    func revealPath(_ path: String?) {
        guard let path else { return }
        selected = path
        reveal = path
        revealMore()
        notify()
    }

    private func refuse() { setStatus("That name cannot be given to sftp.", true) }

    /// Queues a download of a file or a folder (recursively) to a local path.
    func download(_ remote: String, to local: String, folder: Bool) {
        let line = command(folder ? "get -r" : "get", remote, local)
        if !enqueue(line.map { Command(kind: .get, line: $0, path: remote, local: local, what: "Downloading \(SFTP.basename(remote))\u{2026}") }) { refuse() }
        notify()
    }
    /// Queues an upload of a local file or folder (recursively) into a remote folder, under its own name.
    func upload(_ local: String, into remoteDir: String, folder: Bool) {
        let base = local.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? local
        let target = SFTP.join(remoteDir, base)
        let line = command(folder ? "put -r" : "put", local, target)
        if !enqueue(line.map { Command(kind: .put, line: $0, path: target, path2: remoteDir, local: local, what: "Uploading \(base)\u{2026}") }) { refuse() }
        notify()
    }
    func mkdir(_ path: String) {
        enqueue(command("mkdir", path).map { Command(kind: .mkdir, line: $0, path: path, what: "Creating \(SFTP.basename(path))\u{2026}") })
        notify()
    }
    func rename(_ from: String, to: String) {
        enqueue(command("rename", from, to).map { Command(kind: .rename, line: $0, path: from, path2: to, what: "Renaming \(SFTP.basename(from))\u{2026}") })
        notify()
    }
    /// Deletes a file, or an empty folder.
    func remove(_ path: String, folder: Bool) {
        enqueue(command(folder ? "rmdir" : "rm", path).map { Command(kind: folder ? .rmdir : .rm, line: $0, path: path, what: "Deleting \(SFTP.basename(path))\u{2026}") })
        notify()
    }

    // MARK: - Answers

    /// The lines sftp prints about a transfer or a change going well; anything else it printed is a complaint.
    static func isChatter(_ line: String) -> Bool {
        if line.isEmpty { return true }
        return ["Fetching ", "Retrieving ", "Uploading ", "Entering ", "Removing ", "Renaming "].contains { line.hasPrefix($0) }
    }
    /// The complaints in a command's output, one per line; nil when there were none.
    static func complaints(_ out: String) -> String? {
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !isChatter($0) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    private func setStatus(_ text: String?, _ failed: Bool) { status = text; statusFailed = failed }

    private func listDone(_ c: Command, _ out: String) {
        guard let n = node(c.path) else { return }
        n.loading = false; n.loaded = true
        var old: [SFTPNode?] = n.kids
        var kids: [SFTPNode] = []
        var errors: [String] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let e = SFTP.parseEntry(line) {
                // A folder listed again keeps what was open under it.
                var k: SFTPNode?
                if let j = old.firstIndex(where: { $0 != nil && $0!.name == e.name && $0!.dir == e.dir }) { k = old[j]; old[j] = nil }
                let node = k ?? SFTPNode(name: e.name, path: SFTP.join(n.path, e.name), dir: e.dir)
                node.link = e.link; node.size = e.size; node.when = e.when
                kids.append(node)
            } else if !line.isEmpty && !line.hasPrefix("total ") {
                errors.append(line)
            }
        }
        // An entry the listing does not show but the way home passes (see stepToward) stays.
        for case let k? in old where home.map({ SFTP.pathWithin($0, k.path) }) ?? false { kids.append(k) }
        kids.sort(by: SFTPNode.ordered)
        n.kids = kids
        if kids.isEmpty && !errors.isEmpty && n.link {
            // A link to a file: it has nothing to open.
            n.expanded = false
            n.error = nil
        } else {
            n.error = kids.isEmpty && !errors.isEmpty ? errors.joined(separator: "\n") : nil
        }
        // Opening the way down to a folder asked for.
        if let r = reveal, SFTP.pathWithin(r, n.path) { revealMore() }
    }

    private func finish() {
        guard let c = current else { return }
        current = nil
        let out = self.out.joined(separator: "\n")
        self.out = []
        switch c.kind {
        case .pwd:
            var home: String?
            if let r = out.range(of: "Remote working directory: ") {
                home = String(out[r.upperBound...].prefix(while: { $0 != "\n" }))
            }
            if home == nil || !home!.hasPrefix("/") { home = "/" }
            self.home = home
            root = SFTPNode(name: "/", path: "/", dir: true)
            revealPath(home)
        case .list:
            listDone(c, out)
        case .get:
            let name = SFTP.basename(c.path)
            if let why = Self.complaints(out) { setStatus("Could not download \(name): \(why)", true) }
            else { setStatus("Downloaded \(name) to \(c.local ?? "")", false); lastDownload = c.local }
        case .put:
            if let why = Self.complaints(out) { setStatus("Could not upload \(SFTP.basename(c.path)): \(why)", true) }
            else { setStatus("Uploaded \(SFTP.basename(c.path)) to \(c.path2 ?? "")", false) }
            relist(c.path2)
        case .mkdir, .rename, .rm, .rmdir:
            let why = Self.complaints(out)
            let verb = c.kind == .mkdir ? "create" : c.kind == .rename ? "rename" : "delete"
            let done = c.kind == .mkdir ? "Created" : c.kind == .rename ? "Renamed" : "Deleted"
            if let why { setStatus("Could not \(verb) \(SFTP.basename(c.path)): \(why)", true) }
            else if c.kind == .rename { setStatus("Renamed \(SFTP.basename(c.path)) to \(SFTP.basename(c.path2))", false) }
            else { setStatus("\(done) \(c.path ?? "")", false) }
            if why == nil && (c.kind == .rm || c.kind == .rmdir || c.kind == .rename), let sel = selected, SFTP.pathWithin(sel, c.path) {
                selected = c.kind == .rename ? c.path2 : SFTP.parent(c.path)
            }
            let parent = SFTP.parent(c.path)
            relist(parent)
            if c.kind == .rename { let to = SFTP.parent(c.path2); if to != parent { relist(to) } }
        }
        pump()
        notify()
    }

    private func logLine(_ line: String) {
        if line.isEmpty { return }
        if log.count == Self.logLines { log.removeFirst() }
        log.append(line)
    }
    private func onLine(_ line: String) {
        if line.hasPrefix("sftp> ") {
            if current != nil && phase == 0 {
                phase = 1
                if state == .connecting { state = .ready; notify() }
                return
            }
            if current != nil && phase == 1 && line.dropFirst(6) == "version" { phase = 2; return }
        }
        if current != nil && phase == 2 && line.hasPrefix("SFTP protocol version") { finish(); return }
        if current != nil && phase == 1 { out.append(line); return }
        logLine(line)
    }

    /// What sftp printed (its standard output and error together), in pieces as they arrive.
    func receive<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes {
            if b == 0x0A {
                var line = partial
                partial = []
                if line.last == 0x0D { line.removeLast() }
                onLine(String(decoding: line, as: UTF8.self))
            } else {
                partial.append(b)
            }
        }
    }
}

// MARK: - ssh's prompts

/// How the app answers ssh's prompts when it is ssh's SSH_ASKPASS: ssh runs the askpass program with the prompt as its
/// one argument, and SSH_ASKPASS_PROMPT says what kind of answer it wants.
enum SSHAskpass {
    enum Prompt: Equatable, Sendable {
        /// A notice, such as "touch your security key": shown, nothing read back.
        case notice
        /// A host key never seen before: ssh wants "yes" (or "no") printed.
        case hostKey
        /// A key that asks to be confirmed: the exit code says yes or no, nothing printed.
        case confirm
        /// A password or passphrase, printed with a newline.
        case secret
    }

    /// The prompt's kind, from SSH_ASKPASS_PROMPT ("none", "confirm" or unset) and its text (trimmed).
    static func classify(prompt: String, kind: String?) -> Prompt {
        let k = (kind ?? "").lowercased()
        if k == "none" { return .notice }
        if prompt.contains("(yes/no") { return .hostKey }
        if k == "confirm" { return .confirm }
        return .secret
    }

    /// What the askpass program prints and exits with. `answer` is the user's: true/false for a host key or a
    /// confirmation, the secret for a password (nil when cancelled), ignored for a notice.
    static func reply(_ prompt: Prompt, accepted: Bool = false, secret: String? = nil) -> (output: String, exitCode: Int32) {
        switch prompt {
        case .notice: return ("", 0)
        case .hostKey: return (accepted ? "yes\n" : "no\n", 0)
        case .confirm: return ("", accepted ? 0 : 1)
        case .secret: return secret.map { ("\($0)\n", 0) } ?? ("", 1)
        }
    }

    /// The window title the Windows client puts on the question.
    static func title(_ prompt: Prompt) -> String { prompt == .hostKey ? "Trust this server?" : "SSH" }

    /// sftp's environment: this process's, with ssh pointed at `askpass` for its prompts (even with a terminal),
    /// BRIAREUS_ASKPASS=1 so the app knows to answer one, and the output in UTF-8.
    static func environment(base: [String: String], askpass: String) -> [String: String] {
        var env = base
        for k in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "BRIAREUS_ASKPASS", "LC_ALL"] { env[k] = nil }
        env["SSH_ASKPASS"] = askpass
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["BRIAREUS_ASKPASS"] = "1"
        env["LC_ALL"] = "C.UTF-8"
        return env
    }
}
