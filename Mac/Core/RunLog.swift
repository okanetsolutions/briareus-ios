// The Run tab's log: the log lines of a session's transcript.
import Foundation

/// One entry per line of text, the latest `RunLog.cap`.
struct RunLog: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var text: String
        var isError: Bool
    }
    static let cap = 400

    private(set) var lines: [Line] = []
    /// The last transcript sequence read.
    private(set) var cursor: Double = 0

    init() {}

    /// Adds `text`, one entry per line (LF or CR LF; empty lines are skipped); how many lines it added.
    @discardableResult
    mutating func add(_ text: String?, error: Bool) -> Int {
        guard let text else { return 0 }
        var added = 0
        for piece in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var scalars = piece[...]
            if scalars.last == "\r" { scalars = scalars.dropLast() }
            if scalars.isEmpty { continue }
            if lines.count == RunLog.cap { lines.removeFirst() }
            lines.append(Line(text: String(String.UnicodeScalarView(scalars)), isError: error))
            added += 1
        }
        return added
    }
    /// Adds the log lines among transcript events past the cursor (`info`, `cmd` as `$ …`, `git`, `setup`, `claude`,
    /// `stderr` as errors, `status` as `• …`; the conversation's own kinds are skipped) and moves the cursor on. True
    /// when a line was added.
    @discardableResult
    mutating func addEvents(_ events: JSON) -> Bool {
        var added = 0
        for e in events.items {
            if let seq = e["seq"].number {
                if seq <= cursor { continue }
                cursor = seq
            }
            let kind = e["kind"].string, text = e["text"].string
            if kind == "status" {
                if let status = e["status"].string { added += add("\u{2022} \(status)", error: false) }
            } else if kind == "cmd", let text {
                added += add("$ \(text)", error: false)
            } else if let text, let kind, ["info", "git", "setup", "claude", "stderr"].contains(kind) {
                added += add(text, error: kind == "stderr")
            }
        }
        return added > 0
    }
    /// Empties the log and rewinds its cursor.
    mutating func clear() { lines = []; cursor = 0 }
}
