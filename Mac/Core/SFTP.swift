// What the SFTP sessions tab says to OpenSSH's sftp client and reads back: paths written as sftp's command line wants
// them, the long listing `ls -la` prints, and remote path arithmetic. A port of the Windows client's core/sftp.c.
import Foundation

/// One row of `ls -la`: "drwxr-xr-x    2 root     root         4096 Jan  1 12:00 name".
struct SFTPEntry: Equatable, Sendable {
    var name: String
    var perms: String
    var dir: Bool
    var link: Bool
    var size: Int64
    /// "Jan 1 12:00" or "Jan 1 2024"
    var when: String
}

enum SFTP {
    private static func isBlank(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

    /// Reads one line of a long listing; nil for anything else (an error, a blank line) and for "." and "..".
    static func parseEntry(_ line: String?) -> SFTPEntry? {
        guard let line else { return nil }
        let b = Array(line.utf8)
        func at(_ i: Int) -> UInt8 { i < b.count ? b[i] : 0 }
        var p = 0
        var fields: [ArraySlice<UInt8>] = []
        /// The next whitespace-separated field; empty at the end of the line.
        for _ in 0..<8 {
            var s = p
            while at(s) != 0 && isBlank(at(s)) { s += 1 }
            var e = s
            while at(e) != 0 && !isBlank(at(e)) && at(e) != 0x0D && at(e) != 0x0A { e += 1 }
            p = e
            if e == s { return nil }
            fields.append(b[s..<e])
        }
        // The mode: ten characters, the first the type.
        let mode = Array(fields[0])
        if mode.count < 10 || !"-dlcbps".utf8.contains(mode[0]) { return nil }
        for i in 1..<10 where !"-rwxsStTl".utf8.contains(mode[i]) { return nil }
        if fields[4].contains(where: { $0 < 0x30 || $0 > 0x39 }) { return nil }
        // The name is the rest of the line after one run of spaces, kept as it is (names may hold spaces).
        if !isBlank(at(p)) { return nil }
        while isBlank(at(p)) { p += 1 }
        var nm = Array(b[p...])
        while let l = nm.last, l == 0x0D || l == 0x0A { nm.removeLast() }
        if nm.isEmpty { return nil }
        if mode[0] == UInt8(ascii: "l"), let arrow = find(nm, Array(" -> ".utf8)) { nm = Array(nm[..<arrow]) }
        // Listing a path given in full prints each entry under it in full: the entry is the last part.
        if let slash = nm.lastIndex(of: UInt8(ascii: "/")) { nm = Array(nm[(slash + 1)...]) }
        let name = String(decoding: nm, as: UTF8.self)
        if name.isEmpty || name == "." || name == ".." { return nil }
        func str(_ s: ArraySlice<UInt8>) -> String { String(decoding: s, as: UTF8.self) }
        // strtoll saturates rather than failing.
        let size = Int64(str(fields[4])) ?? Int64.max
        return SFTPEntry(name: name, perms: String(decoding: mode[0..<10], as: UTF8.self), dir: mode[0] == UInt8(ascii: "d"),
                         link: mode[0] == UInt8(ascii: "l"), size: size,
                         when: "\(str(fields[5])) \(str(fields[6])) \(str(fields[7]))")
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        if needle.count > hay.count { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    /// A path as one word of sftp's command line: every character outside letters, digits and `/._-+,=@%:` escaped with a
    /// backslash (which also keeps glob characters literal), and "./" before a leading '-'. nil when it holds a line break
    /// or another control character, which the command line cannot carry, and for an empty path.
    static func quote(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var out: [UInt8] = []
        if path.hasPrefix("-") { out += Array("./".utf8) }
        let safe = Set("/._-+,=@%:".utf8)
        for c in path.utf8 {
            if c < 0x20 || c == 0x7F { return nil }
            let plain = c >= 0x80 || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || safe.contains(c)
            if !plain { out.append(0x5C) }
            out.append(c)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `dir` + '/' + `name`, without doubling the slash.
    static func join(_ dir: String?, _ name: String?) -> String {
        guard let dir, !dir.isEmpty else { return name ?? "" }
        return dir + (dir.hasSuffix("/") ? "" : "/") + (name ?? "")
    }

    /// The folder holding `path`: "/" for "/x", nil for "/" itself, "." for a bare name.
    static func parent(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let b = Array(path.utf8)
        var n = b.count
        while n > 1 && b[n - 1] == 0x2F { n -= 1 }
        if n == 1 && b[0] == 0x2F { return nil }
        while n > 0 && b[n - 1] != 0x2F { n -= 1 }
        if n == 0 { return "." }
        while n > 1 && b[n - 1] == 0x2F { n -= 1 }
        return String(decoding: b[0..<n], as: UTF8.self)
    }

    /// The last component of `path` ("/" for "/"; the whole path when it ends in a slash).
    static func basename(_ path: String?) -> String {
        guard let path else { return "" }
        if path == "/" { return path }
        let b = Array(path.utf8)
        if let slash = b.lastIndex(of: 0x2F), slash + 1 < b.count { return String(decoding: b[(slash + 1)...], as: UTF8.self) }
        return path
    }

    /// Whether `path` is `folder` or inside it.
    static func pathWithin(_ path: String?, _ folder: String?) -> Bool {
        guard let path, let folder else { return false }
        if folder == "/" { return path.hasPrefix("/") }
        let p = Array(path.utf8), f = Array(folder.utf8)
        return p.count >= f.count && Array(p[0..<f.count]) == f && (p.count == f.count || p[f.count] == 0x2F)
    }

    /// A size as Explorer shows it: "512 bytes", "1.4 KB", "3.2 MB".
    static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) byte\(bytes == 1 ? "" : "s")" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(bytes)
        var u = -1
        repeat { v /= 1024; u += 1 } while v >= 1024 && u < 3
        return v < 10 ? String(format: "%.1f %@", v, units[u]) : String(format: "%.0f %@", v, units[u])
    }
}
