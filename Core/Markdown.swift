import Foundation

// Agent replies are Markdown; SwiftUI's Text only renders inline syntax, so block structure is split out here.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], alignments: [ColumnAlignment], rows: [[String]])
    case rule

    public enum ColumnAlignment: Equatable, Sendable { case leading, center, trailing }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var fence: (marker: String, language: String?, lines: [String])?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var skipped = 0
        for (index, line) in lines.enumerated() {
            if skipped > 0 { skipped -= 1; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open.marker) && trimmed.allSatisfy({ $0 == open.marker.first }) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))); fence = nil
                } else { fence?.lines.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = String(trimmed.prefix { $0 == trimmed.first })
                let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if let (table, taken) = table(lines, at: index) { flush(); blocks.append(table); skipped = taken - 1; continue }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if !quote.isEmpty { flush() }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); continue }
            if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first),
               trimmed.allSatisfy({ $0 == first || $0 == " " }), trimmed.filter({ $0 == first }).count >= 3 {
                flush(); blocks.append(.rule); continue
            }
            if let item = bullet(line) { flush(); blocks.append(item); continue }
            if paragraph.isEmpty, case .bullet(let indent, let marker, let text)? = blocks.last, line.first == " " {
                // Lazy continuation of the previous list item.
                blocks[blocks.count - 1] = .bullet(indent: indent, marker: marker, text: text + "\n" + trimmed); continue
            }
            paragraph.append(line)
        }
        if let open = fence { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// A table is a row of cells, a row of dashes that gives each column its alignment, then the rows under them.
    private static func table(_ lines: [String], at start: Int) -> (MarkdownBlock, Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let header = cells(lines[start])
        let rule = cells(lines[start + 1])
        guard !header.isEmpty, rule.count == header.count,
              rule.allSatisfy({ cell in cell.contains("-") && cell.allSatisfy { "-: ".contains($0) } }) else { return nil }
        let alignments: [ColumnAlignment] = rule.map { cell in
            cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .trailing) : .leading
        }
        var rows: [[String]] = []
        var next = start + 2
        while next < lines.count, lines[next].contains("|"), !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            // A short row is padded and a long one cut, so every row has the header's columns.
            let row = cells(lines[next])
            rows.append((row + Array(repeating: "", count: max(0, header.count - row.count))).prefix(header.count).map { $0 })
            next += 1
        }
        return (.table(header: header, alignments: alignments, rows: rows), next - start)
    }
    /// The cells of a row, without the bars at its ends; a bar written as \| stays in its cell.
    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in text {
            if escaped { if character != "|" { cell.append("\\") }; cell.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(cell); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> MarkdownBlock? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(spaces)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .bullet(indent: spaces / 2, marker: "•", text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, let dot = rest.dropFirst(digits.count).first, dot == "." || dot == ")",
           rest.dropFirst(digits.count + 1).first == " " {
            return .bullet(indent: spaces / 2, marker: digits + ".", text: String(rest.dropFirst(digits.count + 2)))
        }
        return nil
    }
}
