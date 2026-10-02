// Agent replies are Markdown. Blocks are split out here; the app lays their inline spans out itself.
// A port of the Windows client's core/markdown.c, byte for byte: the parser works on the UTF-8 bytes, so every edge case
// (where a marker counts, what stays literal) matches the C one.
import Foundation

enum MdBlockKind: Equatable, Sendable { case paragraph, heading, bullet, quote, code, rule, table }

/// A table column's alignment, from its delimiter cell: `:--` left, `:-:` centre, `--:` right.
enum MdAlignment: Character, Equatable, Sendable { case left = "l", center = "c", right = "r" }

/// A list item's task box.
enum MdTask: Int, Equatable, Sendable { case none = 0, unchecked = 1, checked = 2 }

struct MdBlock: Equatable, Sendable {
    var kind: MdBlockKind
    /// heading 1...6
    var level = 0
    /// bullet nesting
    var indent = 0
    /// bullet: "•" or "2."
    var marker: String?
    /// paragraph, heading, bullet, quote and code text; empty for rules and tables
    var text = ""
    /// code fence info string, or nil
    var language: String?
    /// table: the rows of cell texts, header row first, each `cols` long
    var cells: [[String]] = []
    /// table: one per column
    var aligns: [MdAlignment] = []
    /// bullet: plain, unchecked task or checked task
    var task: MdTask = .none

    var rows: Int { cells.count }
    var cols: Int { aligns.count }

    init(kind: MdBlockKind) { self.kind = kind }
}

struct MdSpanStyle: OptionSet, Hashable, Sendable {
    let rawValue: UInt
    static let bold = MdSpanStyle(rawValue: 1)
    static let italic = MdSpanStyle(rawValue: 2)
    static let code = MdSpanStyle(rawValue: 4)
    static let link = MdSpanStyle(rawValue: 8)
    static let strike = MdSpanStyle(rawValue: 16)
}

struct MdSpan: Equatable, Sendable {
    var flags: MdSpanStyle
    var text: String
    var url: String?
}

enum Markdown {
    /// The blocks of a reply.
    static func parse(_ source: String?) -> [MdBlock] { MdParser.parse(Array((source ?? "").utf8)) }

    /// Inline syntax: `code`, **bold**, *italic*, ~~strike~~, [text](url), ![alt](url), <url>, bare URLs and HTML entities. Newlines stay in the text.
    static func inline(_ text: String?) -> [MdSpan] {
        let bytes = Array((text ?? "").utf8)
        var out: [RawSpan] = []
        MdInline(t: bytes).parse(&out, bytes.startIndex, bytes.endIndex, [])
        return out.map { MdSpan(flags: $0.flags, text: utf8($0.text), url: $0.url.map(utf8)) }
    }

    /// The text with inline markers removed.
    static func plain(_ text: String?) -> String { inline(text).map(\.text).joined() }
}

// MARK: - Bytes

private typealias Bytes = [UInt8]

private func utf8(_ b: Bytes) -> String { String(decoding: b, as: UTF8.self) }

private extension Array where Element == UInt8 {
    /// The byte at `i`, or 0 past the end, as reading a C string would.
    func at(_ i: Int) -> UInt8 { i >= 0 && i < count ? self[i] : 0 }
    func hasPrefixBytes(_ p: String) -> Bool { let u = Array(p.utf8); return count >= u.count && Array(self[0..<u.count]) == u }
}

private let SP: UInt8 = 0x20, TAB: UInt8 = 0x09, NL: UInt8 = 0x0A, CR: UInt8 = 0x0D, BSL: UInt8 = 0x5C, PIPE: UInt8 = 0x7C

private func ch(_ s: Unicode.Scalar) -> UInt8 { UInt8(s.value) }
/// C's isspace in the C locale.
private func isSpace(_ c: UInt8) -> Bool { c == SP || c == TAB || c == NL || c == CR || c == 0x0C || c == 0x0B }
private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
private func isAlnum(_ c: UInt8) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

private func trim<C: Collection>(_ z: C) -> Bytes where C.Element == UInt8 {
    var a = Array(z)
    while let l = a.last, isSpace(l) { a.removeLast() }
    if let i = a.firstIndex(where: { !isSpace($0) }) { return Array(a[i...]) }
    return []
}
private func replace(_ z: Bytes, _ from: String, _ to: String) -> Bytes {
    let f = Array(from.utf8), t = Array(to.utf8)
    var out = Bytes(); out.reserveCapacity(z.count)
    var i = 0
    while i < z.count {
        if i + f.count <= z.count && Array(z[i..<(i + f.count)]) == f { out += t; i += f.count } else { out.append(z[i]); i += 1 }
    }
    return out
}
private func split(_ z: Bytes, _ sep: UInt8) -> [Bytes] { z.split(separator: sep, omittingEmptySubsequences: false).map(Array.init) }
private func joinLines(_ lines: [Bytes]) -> String { utf8(Array(lines.joined(separator: [NL]))) }

// MARK: - Blocks

private enum MdParser {
    static func heading(_ trimmed: Bytes) -> (Int, Bytes)? {
        var hashes = 0
        while trimmed.at(hashes) == ch("#") { hashes += 1 }
        if hashes < 1 || hashes > 6 || trimmed.at(hashes) != SP { return nil }
        var t = hashes + 1
        while trimmed.at(t) == SP { t += 1 }
        return (hashes, Array(trimmed[min(t, trimmed.count)...]))
    }

    static func bullet(_ line: Bytes) -> (indent: Int, marker: String, text: Bytes)? {
        var spaces = 0
        while line.at(spaces) == SP || line.at(spaces) == TAB { spaces += 1 }
        let rest = Array(line[spaces...])
        if (rest.at(0) == ch("-") || rest.at(0) == ch("*") || rest.at(0) == ch("+")) && rest.at(1) == SP {
            return (spaces / 2, "\u{2022}", Array(rest[2...]))
        }
        var digits = 0
        while isDigit(rest.at(digits)) { digits += 1 }
        if digits >= 1 && digits <= 3 && (rest.at(digits) == ch(".") || rest.at(digits) == ch(")")) && rest.at(digits + 1) == SP {
            return (spaces / 2, utf8(Array(rest[0..<digits])) + ".", Array(rest[(digits + 2)...]))
        }
        return nil
    }

    /// A pipe-delimited row split into trimmed cells; outer pipes are optional.
    static func tableCells(_ line: Bytes) -> [String] {
        var p = 0
        while line.at(p) == SP || line.at(p) == TAB { p += 1 }
        if line.at(p) == PIPE { p += 1 }
        var copy = Array(line[min(p, line.count)...])
        while let l = copy.last, l == SP || l == TAB { copy.removeLast() }
        let n = copy.count
        if n > 0 && copy[n - 1] == PIPE && (n < 2 || copy[n - 2] != BSL) { copy.removeLast() }
        var cells: [String] = []
        var start = 0, q = 0
        while true {
            if copy.at(q) == BSL && copy.at(q + 1) == PIPE { q += 2; continue }
            if q >= copy.count || copy[q] == PIPE {
                let raw = Array(copy[start..<min(q, copy.count)])
                cells.append(utf8(trim(replace(raw, "\\|", "|"))))
                if q >= copy.count { break }
                start = q + 1
            }
            q += 1
        }
        return cells
    }

    /// "|---|:--:|--:|" says a table starts; the alignment of each column.
    static func tableDelimiter(_ line: Bytes) -> [MdAlignment]? {
        let cells = tableCells(line)
        var ok = !cells.isEmpty
        var al: [MdAlignment] = []
        for c in cells where ok {
            let b = Array(c.utf8)
            let left = !b.isEmpty && b[0] == ch(":"), right = !b.isEmpty && b[b.count - 1] == ch(":")
            var dashes = 0
            for k in b { if k == ch("-") { dashes += 1 } else if k != ch(":") && k != SP { ok = false } }
            if dashes < 1 { ok = false }
            al.append(left && right ? .center : right ? .right : .left)
        }
        return ok ? al : nil
    }
    static func isTableRow(_ trimmed: Bytes) -> Bool { trimmed.contains(PIPE) }

    static func isRule(_ trimmed: Bytes) -> Bool {
        if trimmed.count < 3 { return false }
        let first = trimmed[0]
        if first != ch("-") && first != ch("*") && first != ch("_") { return false }
        var marks = 0
        for c in trimmed {
            if c == first { marks += 1 } else if c != SP { return false }
        }
        return marks >= 3
    }

    static func parse(_ source: Bytes) -> [MdBlock] {
        var b: [MdBlock] = []
        var paragraph: [Bytes] = [], quote: [Bytes] = [], fenceLines: [Bytes] = []
        var inFence = false, fenceChar: UInt8 = 0, fenceLen = 0
        var fenceLanguage: String?
        let lines = split(replace(source, "\r\n", "\n"), NL)

        func flush() {
            if !paragraph.isEmpty { var k = MdBlock(kind: .paragraph); k.text = joinLines(paragraph); b.append(k); paragraph = [] }
            if !quote.isEmpty { var k = MdBlock(kind: .quote); k.text = joinLines(quote); b.append(k); quote = [] }
        }
        func closeFence() {
            var code = MdBlock(kind: .code); code.language = fenceLanguage; fenceLanguage = nil
            code.text = joinLines(fenceLines); fenceLines = []
            b.append(code)
        }

        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let line = lines[i]
            let trimmed = trim(line)
            if inFence {
                var k = 0
                while trimmed.at(k) == fenceChar { k += 1 }
                if k >= fenceLen && k == trimmed.count { closeFence(); inFence = false } else { fenceLines.append(line) }
                continue
            }
            if trimmed.hasPrefixBytes("```") || trimmed.hasPrefixBytes("~~~") {
                flush()
                fenceChar = trimmed[0]; fenceLen = 0
                while trimmed.at(fenceLen) == fenceChar { fenceLen += 1 }
                let language = trim(trimmed[fenceLen...])
                fenceLanguage = language.isEmpty ? nil : utf8(language)
                inFence = true
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if trimmed[0] == ch(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(trim(trimmed[1...]))
                continue
            }
            if !quote.isEmpty { flush() }
            // A table: a header row, a delimiter row, then rows until a blank line.
            if isTableRow(trimmed) && i + 1 < lines.count, let aligns = tableDelimiter(trim(lines[i + 1])) {
                let header = tableCells(line)
                if header.count == aligns.count {
                    flush()
                    var t = MdBlock(kind: .table)
                    t.aligns = aligns
                    t.cells = [header]
                    var k = i + 2
                    while k < lines.count {
                        let rt = trim(lines[k])
                        if rt.isEmpty || !isTableRow(rt) { break }
                        let cells = tableCells(lines[k])
                        t.cells.append((0..<aligns.count).map { $0 < cells.count ? cells[$0] : "" })
                        k += 1
                    }
                    b.append(t)
                    i = k - 1
                    continue
                }
            }
            if let (level, text) = heading(trimmed) {
                flush()
                var k = MdBlock(kind: .heading); k.level = level; k.text = utf8(trim(text))
                b.append(k)
                continue
            }
            if isRule(trimmed) { flush(); b.append(MdBlock(kind: .rule)); continue }
            if let item = bullet(line) {
                flush()
                var k = MdBlock(kind: .bullet); k.indent = item.indent; k.marker = item.marker
                var text = item.text
                // A task list item carries its box instead of a bullet.
                let drop = text.count > 3 ? 4 : 3
                if text.hasPrefixBytes("[ ] ") || text == Array("[ ]".utf8) {
                    k.task = .unchecked; text.removeFirst(drop)
                } else if text.hasPrefixBytes("[x] ") || text.hasPrefixBytes("[X] ") || text == Array("[x]".utf8) || text == Array("[X]".utf8) {
                    k.task = .checked; text.removeFirst(drop)
                }
                k.text = utf8(text)
                b.append(k)
                continue
            }
            if paragraph.isEmpty, let last = b.last, last.kind == .bullet, line.at(0) == SP {
                // Lazy continuation of the previous list item.
                b[b.count - 1].text = last.text + "\n" + utf8(trimmed)
                continue
            }
            paragraph.append(line)
        }
        if inFence { closeFence() }
        flush()
        return b
    }
}

// MARK: - Inline

private struct RawSpan { var flags: MdSpanStyle; var text: Bytes; var url: Bytes? }

private let ENTITIES: [(Bytes, Bytes)] = [
    ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", "\u{00A0}"),
].map { (Array($0.0.utf8), Array($0.1.utf8)) }
private let ESCAPABLE = Set("\\`*_[]()<>#~!|".utf8)

private struct MdInline {
    let t: Bytes

    func at(_ i: Int) -> UInt8 { t.at(i) }

    func emit(_ s: inout [RawSpan], _ flags: MdSpanStyle, _ text: ArraySlice<UInt8>, _ url: Bytes?) {
        if text.isEmpty && url == nil { return }
        if let last = s.last, last.flags == flags, url == nil, last.url == nil {
            s[s.count - 1].text += text
            return
        }
        s.append(RawSpan(flags: flags, text: Array(text), url: url))
    }

    func isURLStart(_ p: Int, _ end: Int) -> Bool {
        func has(_ prefix: String) -> Bool { let u = Array(prefix.utf8); return p + u.count <= end && Array(t[p..<(p + u.count)]) == u }
        return has("https://") || has("http://")
    }

    func matches(_ q: Int, _ marker: Bytes) -> Bool { q + marker.count <= t.count && Array(t[q..<(q + marker.count)]) == marker }

    /// Finds the closing `marker` after `p` on the same span; nil without one. A single marker steps over a doubled span inside it.
    func findClose(_ p: Int, _ end: Int, _ marker: Bytes) -> Int? {
        let m = marker.count
        var q = p
        while q + m <= end {
            defer { q += 1 }
            if t[q] == BSL { q += 1; continue }
            if m == 1 && q + 2 < end && t[q + 1] == marker[0] && t[q + 2] != marker[0] && !isSpace(t[q + 2]) {
                if let inner = findClose(q + 2, end, [marker[0], marker[0]]) { q = inner + 1; continue }
            }
            if matches(q, marker) && q > p && !isSpace(t[q - 1]) { return q }
        }
        return nil
    }

    func parse(_ out: inout [RawSpan], _ text: Int, _ end: Int, _ flags: MdSpanStyle) {
        var p = text
        var plain = Bytes()
        func flushPlain(_ out: inout [RawSpan]) { if !plain.isEmpty { emit(&out, flags, plain[...], nil); plain = [] } }
        func wordBefore(_ p: Int) -> Bool { p > text && (isAlnum(t[p - 1]) || t[p - 1] == ch("_")) }

        scan: while p < end {
            var c = t[p]
            if c == BSL && p + 1 < end && ESCAPABLE.contains(t[p + 1]) { plain.append(t[p + 1]); p += 2; continue }
            if c == ch("&") {
                // The entities GitHub's renderer leaves in agent replies.
                for (name, value) in ENTITIES where end - p >= name.count && Array(t[p..<(p + name.count)]) == name {
                    plain += value; p += name.count
                    continue scan
                }
            }
            if c == ch("~") && p + 2 < end && t[p + 1] == ch("~") && !isSpace(t[p + 2]) {
                if let close = findClose(p + 2, end, Array("~~".utf8)), close > p + 2 {
                    flushPlain(&out)
                    parse(&out, p + 2, close, flags.union(.strike))
                    p = close + 2; continue
                }
            }
            if c == ch("!") && p + 1 < end && t[p + 1] == ch("[") { p += 1; c = ch("[") }
            if c == ch("`") {
                var ticks = 0
                while p + ticks < end && t[p + ticks] == ch("`") { ticks += 1 }
                var q = p + ticks
                var close: Int?
                while q + ticks <= end {
                    var k = 0
                    while k < ticks && t[q + k] == ch("`") { k += 1 }
                    if k == ticks && (q + ticks == end || t[q + ticks] != ch("`")) { close = q; break }
                    q += 1
                }
                if let close {
                    flushPlain(&out)
                    var inner = p + ticks, innerEnd = close
                    if innerEnd - inner >= 2 && t[inner] == SP && t[innerEnd - 1] == SP { inner += 1; innerEnd -= 1 }
                    emit(&out, flags.union(.code), t[inner..<innerEnd], nil)
                    p = close + ticks; continue
                }
                plain += t[p..<(p + ticks)]; p += ticks; continue
            }
            if (c == ch("*") || (c == ch("_") && !wordBefore(p))) && p + 3 < end && t[p + 1] == c && t[p + 2] == c && !isSpace(t[p + 3]) {
                if let close = findClose(p + 3, end, [c, c, c]), close > p + 3 {
                    flushPlain(&out)
                    parse(&out, p + 3, close, flags.union([.bold, .italic]))
                    p = close + 3; continue
                }
            }
            if (c == ch("*") || c == ch("_")) && p + 1 < end {
                let doubled = t[p + 1] == c
                let marker: Bytes = doubled ? [c, c] : [c]
                let content = p + marker.count
                // Intraword underscores are literal, as in snake_case names.
                if content < end && !isSpace(t[content]) && !(c == ch("_") && wordBefore(p)) {
                    if let close = findClose(content, end, marker), close > content {
                        flushPlain(&out)
                        parse(&out, content, close, flags.union(doubled ? .bold : .italic))
                        p = close + marker.count; continue
                    }
                }
                plain.append(c); p += 1; continue
            }
            if c == ch("[") {
                var close: Int?
                var depth = 0
                for q in p..<end {
                    if t[q] == ch("[") { depth += 1 } else if t[q] == ch("]") { depth -= 1; if depth == 0 { close = q; break } }
                }
                if let close, close + 1 < end && t[close + 1] == ch("(") {
                    // Parentheses inside the URL come in pairs, as in Wikipedia's links.
                    var paren: Int?
                    var parens = 0
                    var q = close + 2
                    while q < end && paren == nil {
                        if t[q] == ch("(") { parens += 1 } else if t[q] == ch(")") { if parens == 0 { paren = q }; parens -= 1 }
                        q += 1
                    }
                    if let paren {
                        var url = Array(t[(close + 2)..<paren])
                        if let space = url.firstIndex(of: SP) { url = Array(url[..<space]) }
                        flushPlain(&out)
                        var label: [RawSpan] = []
                        parse(&label, p + 1, close, flags.union(.link))
                        for var span in label { span.url = url; out.append(span) }
                        // An empty label shows the link itself.
                        if label.isEmpty && !url.isEmpty { emit(&out, flags.union(.link), url[...], url) }
                        p = paren + 1; continue
                    }
                }
                plain.append(c); p += 1; continue
            }
            if c == ch("<") && isURLStart(p + 1, end) {
                if let close = t[p..<end].firstIndex(of: ch(">")) {
                    flushPlain(&out)
                    let url = Array(t[(p + 1)..<close])
                    emit(&out, flags.union(.link), url[...], url)
                    p = close + 1; continue
                }
            }
            if isURLStart(p, end) && (p == text || !isAlnum(t[p - 1])) {
                var q = p
                while q < end && !isSpace(t[q]) && t[q] != ch("<") && t[q] != ch(">") && t[q] != ch("\"") && t[q] != ch(")") { q += 1 }
                while q > p && Array(".,;:!?".utf8).contains(t[q - 1]) { q -= 1 }
                flushPlain(&out)
                let url = Array(t[p..<q])
                emit(&out, flags.union(.link), url[...], url)
                p = q; continue
            }
            plain.append(c); p += 1
        }
        flushPlain(&out)
    }
}
