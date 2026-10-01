// One line of a unified diff patch, numbered from its hunk header.
import Foundation

enum DiffKind: Equatable, Sendable { case hunk, added, removed, context, note }

struct DiffLine: Equatable, Sendable {
    var id: Int
    var kind: DiffKind
    var text: String
    /// 0 when the side has no number (a hunk header, a note, or the other side of an added or removed line).
    var oldLine: Int
    var newLine: Int
}

/// Parses a patch into lines; none for nil. Lines split on LF, CR LF or a lone CR; a trailing empty line is the patch's
/// final newline, not content.
func diffParse(_ patch: String?) -> [DiffLine] {
    guard let patch else { return [] }
    var raw: [String] = []
    var current = String.UnicodeScalarView()
    var previousCR = false
    for u in patch.unicodeScalars {
        if u == "\n" && previousCR { previousCR = false; continue }   // the LF of a CR LF
        previousCR = false
        if u == "\n" || u == "\r" {
            raw.append(String(current)); current = String.UnicodeScalarView()
            previousCR = u == "\r"
        } else {
            current.append(u)
        }
    }
    raw.append(String(current))
    if let last = raw.last, last.isEmpty { raw.removeLast() }

    var lines: [DiffLine] = []
    var oldLine = 0, newLine = 0
    for (i, line) in raw.enumerated() {
        let first = line.unicodeScalars.first
        let rest = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst()))
        if line.utf8.starts(with: "@@".utf8) {
            if let (o, w) = hunkStart(line) { oldLine = o; newLine = w }
            lines.append(DiffLine(id: i, kind: .hunk, text: line, oldLine: 0, newLine: 0))
        } else if first == "\\" {
            let text = String(String.UnicodeScalarView(rest.unicodeScalars.drop { $0 == " " }))
            lines.append(DiffLine(id: i, kind: .note, text: text, oldLine: 0, newLine: 0))
        } else if first == "+" {
            lines.append(DiffLine(id: i, kind: .added, text: rest, oldLine: 0, newLine: newLine)); newLine += 1
        } else if first == "-" {
            lines.append(DiffLine(id: i, kind: .removed, text: rest, oldLine: oldLine, newLine: 0)); oldLine += 1
        } else {
            lines.append(DiffLine(id: i, kind: .context, text: rest, oldLine: oldLine, newLine: newLine)); oldLine += 1; newLine += 1
        }
    }
    return lines
}

/// "@@ -10,3 +10,4 @@ context": the first line of each side, or nil for a header that does not read.
private func hunkStart(_ header: String) -> (Int, Int)? {
    let parts = header.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts[1].first == "-", parts[2].first == "+",
          let o = leadingNumber(parts[1].dropFirst()), let w = leadingNumber(parts[2].dropFirst()) else { return nil }
    return (o, w)
}
/// As C's `strtol`: optional leading white space and sign, then digits, which must end the text or come before a comma.
private func leadingNumber(_ s: Substring) -> Int? {
    var scalars = s.unicodeScalars[...]
    while let f = scalars.first, [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"].contains(f) { scalars = scalars.dropFirst() }
    var sign = 1
    if let f = scalars.first, f == "+" || f == "-" { sign = f == "-" ? -1 : 1; scalars = scalars.dropFirst() }
    var value = 0, digits = 0
    while let f = scalars.first, ("0"..."9").contains(f) {
        value = min(value * 10 + Int(f.value - 48), Int(Int32.max)); digits += 1; scalars = scalars.dropFirst()
    }
    guard digits > 0, scalars.isEmpty || scalars.first == "," else { return nil }
    return sign * value
}
