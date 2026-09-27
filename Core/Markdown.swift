import Foundation

// Agent replies are Markdown; SwiftUI's Text only renders inline syntax, so block structure is split out here.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case rule

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var fence: (marker: String, language: String?, lines: [String])?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        for line in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
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
