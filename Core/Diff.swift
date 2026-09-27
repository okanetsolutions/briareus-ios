import Foundation

/// One line of a unified diff patch, numbered from its hunk header.
public struct DiffLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case hunk, added, removed, context, note }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let old: Int?
    public let new: Int?

    public static func parse(_ patch: String) -> [DiffLine] {
        var raw = patch.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if raw.last == "" { raw.removeLast() }
        var lines: [DiffLine] = []
        var old = 0, new = 0
        for (index, line) in raw.enumerated() {
            if line.hasPrefix("@@") {
                if let start = hunkStart(line) { (old, new) = start }
                lines.append(DiffLine(id: index, kind: .hunk, text: line, old: nil, new: nil))
            } else if line.hasPrefix("\\") {
                lines.append(DiffLine(id: index, kind: .note, text: String(line.dropFirst().drop { $0 == " " }), old: nil, new: nil))
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(id: index, kind: .added, text: String(line.dropFirst()), old: nil, new: new)); new += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(id: index, kind: .removed, text: String(line.dropFirst()), old: old, new: nil)); old += 1
            } else {
                lines.append(DiffLine(id: index, kind: .context, text: String(line.dropFirst()), old: old, new: new)); old += 1; new += 1
            }
        }
        return lines
    }
    private static func hunkStart(_ header: String) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else { return nil }
        return (old, new)
    }
}
