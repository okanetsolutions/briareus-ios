// The programs the SSH and SFTP sessions tabs run: OpenSSH's ssh in a pseudo-terminal, its sftp on pipes. Each starts as
// the leader of a session of its own (so ssh gets the terminal as its controlling one, and everything it starts can be
// ended together), in the home folder, where ~/.ssh is. What it prints is read on a queue of its own and handed to the
// main thread; its end is reported once everything it printed has been.
import Darwin
import Foundation

final class ChildProcess {
    struct Failure: Error { let message: String }

    let pid: pid_t
    /// The pseudo-terminal's master, or the read end of the output pipe.
    private let readFD: Int32
    /// The master again, or the write end of the input pipe.
    private let writeFD: Int32
    let isPTY: Bool
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    // Touched only on `queue`.
    private var status: Int32?
    private var eof = false
    private var done = false
    private var broken = false
    private var fdsClosed = false
    private var writeClosed = false
    /// The process keeps itself until its program has ended and been reaped, even once its session has let it go.
    private var keepAlive: ChildProcess?
    /// Whether writes can no longer reach the program, as the main thread reads it.
    private let deadLock = NSLock()
    private var deadFlag = false
    private var dead: Bool {
        get { deadLock.lock(); defer { deadLock.unlock() }; return deadFlag }
        set { deadLock.lock(); deadFlag = newValue; deadLock.unlock() }
    }

    /// What the program printed, on the main thread.
    var onData: ((Data) -> Void)?
    /// The program ended (its exit code, or 128 + the signal that ended it), on the main thread, after its last output.
    var onExit: ((Int32) -> Void)?

    private init(pid: pid_t, readFD: Int32, writeFD: Int32, pty: Bool) {
        self.pid = pid; self.readFD = readFD; self.writeFD = writeFD; isPTY = pty
        queue = DispatchQueue(label: "briareus.child.\(pid)")
    }

    /// Starts `path` with `arguments` (after the program's own name). With `pty` it runs in a new pseudo-terminal of that
    /// size; otherwise its standard input is a pipe and its standard output and error share another.
    static func spawn(_ path: String, _ arguments: [String], environment: [String: String], directory: String?,
                      pty: (cols: Int, rows: Int)?) throws -> ChildProcess {
        guard access(path, X_OK) == 0 else { throw Failure(message: "\(path) was not found.") }
        var childIn: Int32 = -1, childOut: Int32 = -1, parentRead: Int32 = -1, parentWrite: Int32 = -1
        var slaveName: String?
        var closeAfter: [Int32] = []
        if let pty {
            var master: Int32 = -1, slave: Int32 = -1
            var size = winsize(ws_row: UInt16(clamping: pty.rows), ws_col: UInt16(clamping: pty.cols), ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Failure(message: "Could not create a pseudo-terminal for the session.") }
            slaveName = String(cString: ptsname(master))
            // The slave stays open here until the program has opened its own, so the terminal keeps its size.
            closeAfter = [slave]
            parentRead = master; parentWrite = master
        } else {
            var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
            guard pipe(&input) == 0 else { throw Failure(message: "Could not create the pipes for sftp.") }
            guard pipe(&output) == 0 else { close(input[0]); close(input[1]); throw Failure(message: "Could not create the pipes for sftp.") }
            childIn = input[0]; parentWrite = input[1]; parentRead = output[0]; childOut = output[1]
            closeAfter = [childIn, childOut]
        }
        func cleanup() {
            closeAfter.forEach { close($0) }
            close(parentRead)
            if parentWrite != parentRead { close(parentWrite) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let slaveName {
            // Opened after setsid, the terminal becomes the program's controlling one.
            posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
            posix_spawn_file_actions_adddup2(&actions, 0, 1)
            posix_spawn_file_actions_adddup2(&actions, 0, 2)
        } else {
            posix_spawn_file_actions_adddup2(&actions, childIn, 0)
            posix_spawn_file_actions_adddup2(&actions, childOut, 1)
            posix_spawn_file_actions_adddup2(&actions, childOut, 2)
        }
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three standard descriptors go to the program, whatever else the app holds open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                posix_spawn(&pid, path, &actions, &attributes, a.baseAddress, e.baseAddress)
            }
        }
        closeAfter.forEach { close($0) }
        closeAfter = []
        if result != 0 {
            cleanup()
            throw Failure(message: "Could not start \((path as NSString).lastPathComponent) (\(String(cString: strerror(result))).")
        }
        // The app's own descriptors stay out of later programs, and a write to an ended program fails instead of killing the app.
        for fd in Set([parentRead, parentWrite]) {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
        return ChildProcess(pid: pid, readFD: parentRead, writeFD: parentWrite, pty: pty != nil)
    }

    /// Starts reading, once `onData` and `onExit` are set.
    func start() {
        keepAlive = self
        let rs = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
        rs.setEventHandler { [weak self] in self?.drain() }
        readSource = rs
        rs.resume()
        let es = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        es.setEventHandler { [weak self] in self?.reap() }
        exitSource = es
        es.resume()
        // It may have ended before the source was watching.
        queue.async { [weak self] in self?.reap(blocking: false) }
    }

    // MARK: - On the queue

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var got = Data()
        while true {
            let n = read(readFD, &buffer, buffer.count)
            if n > 0 { got.append(contentsOf: buffer[0..<n]); if got.count >= 1 << 20 { break }; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
            // End of file, or EIO once the terminal has no program left on it.
            eof = true
            break
        }
        if !got.isEmpty { DispatchQueue.main.async { [weak self] in self?.onData?(got) } }
        if eof {
            readSource?.cancel(); readSource = nil
            if status != nil { finish() }
            else {
                // Its output closed: it is ending; one that does not is made to.
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.status == nil else { return }
                    Darwin.kill(-self.pid, SIGKILL)
                }
            }
        }
    }

    private func reap(blocking: Bool = true) {
        if status != nil { return }
        var st: Int32 = 0
        let r = waitpid(pid, &st, blocking ? 0 : WNOHANG)
        guard r == pid else { if r < 0 && errno == ECHILD { status = 1; afterExit() }; return }
        let sig = st & 0x7F
        status = sig == 0 ? (st >> 8) & 0xFF : 128 + sig
        afterExit()
    }

    private func afterExit() {
        exitSource?.cancel(); exitSource = nil
        if done { keepAlive = nil; return }
        if eof { finish(); return }
        // What it printed last is read; a program it left running on the terminal does not keep the session open.
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.done else { return }
            self.drain()
            self.eof = true
            self.finish()
        }
    }

    private func finish() {
        if done { return }
        done = true
        readSource?.cancel(); readSource = nil
        closeFDs()
        let code = status ?? 1
        DispatchQueue.main.async { [self] in self.onExit?(code) }
        // Let go once the program has been reaped (it may still be running when its output ended).
        if status != nil { keepAlive = nil }
    }

    private func closeFDs() {
        if fdsClosed { return }
        fdsClosed = true
        close(readFD)
        if writeFD != readFD && !writeClosed { close(writeFD) }
        writeClosed = true
        dead = true
    }

    // MARK: - From the main thread

    /// Writes to the program's input (the terminal, or sftp's standard input); false once it can no longer be written.
    @discardableResult func write(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        queue.async { [weak self] in
            guard let self, !self.writeClosed, !self.broken else { return }
            let bytes = [UInt8](data)
            var at = 0
            while at < bytes.count {
                let n = bytes[at...].withUnsafeBytes { Darwin.write(self.writeFD, $0.baseAddress, $0.count) }
                if n > 0 { at += n; continue }
                if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    var p = pollfd(fd: self.writeFD, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, 1000) < 0 && errno != EINTR { self.broken = true; self.dead = true; return }
                    continue
                }
                self.broken = true
                self.dead = true
                return
            }
        }
        return !dead
    }
    func write(_ text: String) -> Bool { write(Data(text.utf8)) }
    func write(_ bytes: [UInt8]) { write(Data(bytes)) }

    /// Tells the terminal its new size; the program on it hears SIGWINCH.
    func resize(cols: Int, rows: Int) {
        guard isPTY else { return }
        queue.async { [weak self] in
            guard let self, !self.fdsClosed else { return }
            var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = withUnsafeMutablePointer(to: &size) { ioctl(self.readFD, TIOCSWINSZ, $0) }
        }
    }

    /// Ends the program and everything it started (its process group): hang-up and terminate, then kill what is left.
    func terminate() {
        let pid = self.pid
        queue.async { [weak self] in
            guard let self, self.status == nil else { return }
            Darwin.kill(-pid, SIGHUP); Darwin.kill(-pid, SIGTERM)
            if !self.isPTY && !self.writeClosed { close(self.writeFD); self.writeClosed = true; self.dead = true }
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.status == nil else { return }
                Darwin.kill(-pid, SIGKILL)
            }
        }
    }

    /// Ends it at once, as the app quits.
    func killNow() {
        if queue.sync(execute: { status }) == nil { Darwin.kill(-pid, SIGHUP); Darwin.kill(-pid, SIGKILL) }
    }

    deinit {
        readSource?.cancel(); exitSource?.cancel()
        if !fdsClosed { close(readFD); if writeFD != readFD && !writeClosed { close(writeFD) } }
    }
}
