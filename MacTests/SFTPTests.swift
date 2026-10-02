// Ported from the Windows client's tests/core_sftp_tests.c: the long listing, quoting paths for sftp's command line, and
// remote path arithmetic; then the session protocol of app/sftp_session.c driven by a scripted sftp.
import XCTest
@testable import BriareusMacCore

final class SFTPTests: XCTestCase {
    func testParsesALongListing() throws {
        var e = try XCTUnwrap(SFTP.parseEntry("drwxr-xr-x    2 root     root         4096 Jan  1 12:00 www"))
        XCTAssertEqual(e.name, "www"); XCTAssertTrue(e.dir); XCTAssertFalse(e.link); XCTAssertEqual(e.size, 4096)
        XCTAssertEqual(e.when, "Jan 1 12:00"); XCTAssertEqual(e.perms, "drwxr-xr-x")
        // Names keep their spaces; OpenSSH's own server writes "?" for the link count on Windows; a carriage return goes.
        e = try XCTUnwrap(SFTP.parseEntry("-rw-r--r--    ? nadin    197609          3 Oct  1 19:34 a  b.txt\r"))
        XCTAssertEqual(e.name, "a  b.txt"); XCTAssertFalse(e.dir); XCTAssertEqual(e.size, 3)
        e = try XCTUnwrap(SFTP.parseEntry("-rw-------    1 1000     1000     123456789012 Mar 14  2023 big.iso"))
        XCTAssertEqual(e.size, 123456789012); XCTAssertEqual(e.when, "Mar 14 2023")
    }

    func testReadsLinksAndSkipsTheDotEntries() throws {
        var e = try XCTUnwrap(SFTP.parseEntry("lrwxrwxrwx    1 root     root            7 Jan  1 12:00 bin -> usr/bin"))
        XCTAssertEqual(e.name, "bin"); XCTAssertTrue(e.link); XCTAssertFalse(e.dir)
        XCTAssertNil(SFTP.parseEntry("drwxr-xr-x    2 root     root         4096 Jan  1 12:00 ."))
        XCTAssertNil(SFTP.parseEntry("drwxr-xr-x    2 root     root         4096 Jan  1 12:00 .."))
        // `ls -la /dir/` prints the entries under their full paths.
        XCTAssertNil(SFTP.parseEntry("drwxr-xr-x    ? nadin    197609          0 Aug 23 14:27 /c/Users/."))
        e = try XCTUnwrap(SFTP.parseEntry("lrwxrwxrwx    ? nadin    197609         14 Apr  1  2024 /c/Users/All Users"))
        XCTAssertEqual(e.name, "All Users"); XCTAssertTrue(e.link)
        e = try XCTUnwrap(SFTP.parseEntry("-rw-r--r--    1 root     root            0 Jan  1 12:00 .bashrc"))
        XCTAssertEqual(e.name, ".bashrc")
    }

    func testRefusesLinesThatAreNotEntries() {
        XCTAssertNil(SFTP.parseEntry("Can't ls: \"/nope\" not found"))
        XCTAssertNil(SFTP.parseEntry("sftp> ls -la /"))
        XCTAssertNil(SFTP.parseEntry(""))
        XCTAssertNil(SFTP.parseEntry(nil))
        XCTAssertNil(SFTP.parseEntry("drwxr-xr-x    2 root     root         4096 Jan  1 12:00"))
        XCTAssertNil(SFTP.parseEntry("drwxr-xr-x    2 root     root         40x6 Jan  1 12:00 a"))
        XCTAssertNil(SFTP.parseEntry("Fetching /a to C:/b"))
    }

    func testQuotesPathsForTheCommandLine() {
        XCTAssertEqual(SFTP.quote("/home/me/file.txt"), "/home/me/file.txt")
        XCTAssertEqual(SFTP.quote("/srv/a b/up[1].txt"), "/srv/a\\ b/up\\[1\\].txt")
        XCTAssertEqual(SFTP.quote("q\"u'o*te?"), "q\\\"u\\'o\\*te\\?")
        XCTAssertEqual(SFTP.quote("C:/Users/me/x.zip"), "C:/Users/me/x.zip")
        XCTAssertEqual(SFTP.quote("~/#notes"), "\\~/\\#notes")
        XCTAssertEqual(SFTP.quote("back\\slash"), "back\\\\slash")
        XCTAssertEqual(SFTP.quote("-rf"), "./-rf")
        XCTAssertEqual(SFTP.quote("/café"), "/café")
        XCTAssertNil(SFTP.quote("two\nlines"))
        XCTAssertNil(SFTP.quote(""))
        XCTAssertNil(SFTP.quote(nil))
    }

    func testDoesPathArithmetic() {
        XCTAssertEqual(SFTP.join("/", "etc"), "/etc")
        XCTAssertEqual(SFTP.join("/home/me", "a b"), "/home/me/a b")
        XCTAssertEqual(SFTP.join("/home/me/", "x"), "/home/me/x")
        XCTAssertEqual(SFTP.parent("/home/me"), "/home")
        XCTAssertEqual(SFTP.parent("/home"), "/")
        XCTAssertEqual(SFTP.parent("/home/me/"), "/home")
        XCTAssertNil(SFTP.parent("/"))
        XCTAssertEqual(SFTP.basename("/home/me"), "me")
        XCTAssertEqual(SFTP.basename("/"), "/")
        XCTAssertTrue(SFTP.pathWithin("/home/me/x", "/home/me"))
        XCTAssertTrue(SFTP.pathWithin("/home/me", "/home/me"))
        XCTAssertFalse(SFTP.pathWithin("/home/meow", "/home/me"))
        XCTAssertTrue(SFTP.pathWithin("/etc", "/"))
    }

    func testFormatsSizes() {
        XCTAssertEqual(SFTP.formatSize(1), "1 byte")
        XCTAssertEqual(SFTP.formatSize(512), "512 bytes")
        XCTAssertEqual(SFTP.formatSize(1536), "1.5 KB")
        XCTAssertEqual(SFTP.formatSize(52428800), "50 MB")
    }

    // MARK: - The session protocol

    /// A session whose writes are recorded; `answer` feeds what sftp would print back.
    private final class Script {
        var written: [String] = []
        lazy var core = SFTPSessionCore(write: { [unowned self] in self.written.append($0); return true })
        /// sftp's echo of a command, its output, then the `version` marker's echo and answer.
        func answer(_ command: String, _ output: [String]) {
            let lines = ["sftp> \(command)"] + output + ["sftp> version", "SFTP protocol version 3"]
            core.receive(Array((lines.joined(separator: "\r\n") + "\r\n").utf8))
        }
    }

    func testASessionConnectsListsItsHomeAndRunsCommandsInTurn() throws {
        let s = Script()
        s.core.start()
        XCTAssertEqual(s.core.state, .connecting)
        XCTAssertEqual(s.written, ["pwd\nversion\n"])
        // ssh's chatter before the connection is up goes to the log.
        s.core.receive(Array("Warning: Permanently added 'h'\r\n".utf8))
        s.answer("pwd", ["Remote working directory: /home/me"])
        XCTAssertEqual(s.core.state, .ready)
        XCTAssertEqual(s.core.home, "/home/me")
        XCTAssertEqual(s.core.selected, "/home/me")
        // Revealing home lists "/" first.
        XCTAssertEqual(s.written.last, "ls -la /\nversion\n")
        s.answer("ls -la /", ["drwxr-xr-x    2 root root 4096 Jan  1 12:00 etc", "-rw-r--r--    1 root root 10 Jan  1 12:00 Zed",
                              "drwxr-xr-x    2 root root 4096 Jan  1 12:00 bin"])
        // /home is not in the listing, but the way home passes it.
        XCTAssertEqual(s.core.root?.kids.map(\.name), ["bin", "etc", "home", "Zed"])
        XCTAssertEqual(s.written.last, "ls -la /home/\nversion\n")
        s.answer("ls -la /home/", ["Can't ls: \"/home/\" permission denied"])
        XCTAssertEqual(s.core.node("/home")?.kids.map(\.name), ["me"])
        XCTAssertEqual(s.core.node("/home")?.error, "Can't ls: \"/home/\" permission denied")
        XCTAssertEqual(s.written.last, "ls -la /home/me/\nversion\n")
        s.answer("ls -la /home/me/", ["total 8", "-rw-r--r--    1 me me 3 Jan  1 12:00 a b.txt"])
        XCTAssertEqual(s.core.node("/home/me")?.kids.first?.path, "/home/me/a b.txt")
        XCTAssertTrue(s.core.node("/home/me")!.expanded)

        // Commands queue behind the one running.
        s.core.mkdir("/home/me/new")
        s.core.download("/home/me/a b.txt", to: "/Users/me/Downloads/a b.txt", folder: false)
        XCTAssertEqual(s.written.last, "mkdir /home/me/new\nversion\n")
        XCTAssertEqual(s.core.busy.what, "Creating new\u{2026}"); XCTAssertEqual(s.core.busy.queued, 1)
        s.answer("mkdir /home/me/new", [])
        XCTAssertEqual(s.core.status, "Created /home/me/new"); XCTAssertFalse(s.core.statusFailed)
        XCTAssertEqual(s.written.last, "get /home/me/a\\ b.txt /Users/me/Downloads/a\\ b.txt\nversion\n")
        s.answer("get /home/me/a\\ b.txt /Users/me/Downloads/a\\ b.txt", ["Fetching /home/me/a b.txt to /Users/me/Downloads/a b.txt"])
        XCTAssertEqual(s.core.status, "Downloaded a b.txt to /Users/me/Downloads/a b.txt")
        XCTAssertEqual(s.core.lastDownload, "/Users/me/Downloads/a b.txt")
        // The mkdir's relist of /home/me ran after the download.
        XCTAssertEqual(s.written.last, "ls -la /home/me/\nversion\n")
        s.answer("ls -la /home/me/", ["-rw-r--r--    1 me me 3 Jan  1 12:00 a b.txt", "drwxr-xr-x    2 me me 4096 Jan  1 12:00 new"])
        XCTAssertEqual(s.core.node("/home/me")?.kids.map(\.name), ["new", "a b.txt"])

        s.core.remove("/home/me/new", folder: true)
        s.answer("rmdir /home/me/new", ["Couldn't remove directory: Failure"])
        XCTAssertEqual(s.core.status, "Could not delete new: Couldn't remove directory: Failure"); XCTAssertTrue(s.core.statusFailed)
        XCTAssertEqual(s.written.last, "ls -la /home/me/\nversion\n")
        s.answer("ls -la /home/me/", ["-rw-r--r--    1 me me 3 Jan  1 12:00 a b.txt", "drwxr-xr-x    2 me me 4096 Jan  1 12:00 new"])

        // The connection closing drops what was queued.
        s.core.upload("/tmp/x.zip", into: "/home/me", folder: false)
        XCTAssertEqual(s.written.last, "put /tmp/x.zip /home/me/x.zip\nversion\n")
        s.core.ended()
        XCTAssertEqual(s.core.state, .closed)
        XCTAssertEqual(s.core.status, "Uploading x.zip\u{2026} stopped: the connection closed.")
        XCTAssertNil(s.core.busy.what)
        XCTAssertNil(s.core.connectLog)   // it had connected
    }

    func testAFailedConnectionKeepsWhatSSHSaid() {
        let s = Script()
        s.core.start()
        s.core.receive(Array("ssh: Could not resolve hostname nope\r\nConnection closed".utf8))
        s.core.ended()
        XCTAssertEqual(s.core.connectLog, "ssh: Could not resolve hostname nope\nConnection closed")
        XCTAssertNil(s.core.status)
    }

    func testAskpassAnswers() {
        XCTAssertEqual(SSHAskpass.classify(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])?", kind: nil), .hostKey)
        XCTAssertEqual(SSHAskpass.classify(prompt: "me@h's password:", kind: nil), .secret)
        XCTAssertEqual(SSHAskpass.classify(prompt: "Confirm user presence", kind: "confirm"), .confirm)
        XCTAssertEqual(SSHAskpass.classify(prompt: "Touch your key", kind: "none"), .notice)
        XCTAssertEqual(SSHAskpass.reply(.hostKey, accepted: false).output, "no\n")
        XCTAssertEqual(SSHAskpass.reply(.hostKey, accepted: false).exitCode, 0)
        XCTAssertEqual(SSHAskpass.reply(.secret, secret: "pw").output, "pw\n")
        XCTAssertEqual(SSHAskpass.reply(.secret).exitCode, 1)
        let env = SSHAskpass.environment(base: ["PATH": "/bin", "SSH_ASKPASS": "old"], askpass: "/A/Briareus")
        XCTAssertEqual(env["SSH_ASKPASS"], "/A/Briareus"); XCTAssertEqual(env["SSH_ASKPASS_REQUIRE"], "force"); XCTAssertEqual(env["PATH"], "/bin")
    }
}
