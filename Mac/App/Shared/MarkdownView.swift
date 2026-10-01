// Markdown as doc.c lays it out: paragraphs, headings, bullets and task lists, quotes, code with a copy button, tables and
// rules, with bold, italic, strikethrough, inline code and links inline. Text is selectable.
import SwiftUI

enum MarkdownSize {
    case body, callout, footnote, caption
    var size: CGFloat { switch self { case .body: return 15; case .callout: return 14; case .footnote: return 13; case .caption: return 12 } }
    var mono: CGFloat { self == .body || self == .callout ? 13 : 12 }
}

/// Inline Markdown as one attributed string: links in the accent, strikethrough muted, code in the mono font on the sunken colour.
func richText(_ source: String, size: MarkdownSize = .body, color: Color = Theme.ink, bold: Bool = false) -> AttributedString {
    var out = AttributedString()
    for span in Markdown.inline(source) {
        var a = AttributedString(span.text)
        var font: Font
        if span.flags.contains(.code) {
            font = .system(size: size.mono, design: .monospaced)
            a.backgroundColor = Theme.sunken
        } else {
            font = .system(size: size.size, weight: span.flags.contains(.bold) || bold ? .semibold : .regular)
            if span.flags.contains(.italic) { font = font.italic() }
        }
        a.font = font
        a.foregroundColor = span.flags.contains(.link) && span.url != nil ? Theme.accent : span.flags.contains(.strike) ? Theme.muted : color
        if span.flags.contains(.strike) { a.strikethroughStyle = .single }
        if span.flags.contains(.link), let url = span.url, let u = URL(string: url) { a.link = u }
        out += a
    }
    return out
}

/// Inline Markdown, wrapped.
struct RichText: View {
    var source: String
    var size: MarkdownSize = .body
    var color: Color = Theme.ink
    var bold = false
    var body: some View {
        Text(richText(source, size: size, color: color, bold: bold))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .tint(Theme.accent)
            .environment(\.openURL, OpenURLAction { url in openWebURL(url.absoluteString); return .handled })
    }
}

/// Block Markdown; blocks 6px apart.
struct MarkdownView: View {
    var source: String
    var size: MarkdownSize = .body

    var body: some View {
        let blocks = Markdown.parse(source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: MdBlock) -> some View {
        switch b.kind {
        case .paragraph:
            RichText(source: b.text, size: size)
        case .heading:
            HeadingText(text: b.text)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if b.task != .none {
                    TaskBox(checked: b.task == .checked).frame(width: 22, alignment: .leading)
                } else {
                    Text(b.marker ?? "•").font(.system(size: size.size)).foregroundStyle(Theme.muted)
                        .frame(minWidth: 18, alignment: .leading).padding(.trailing, 8)
                }
                RichText(source: b.text, size: size, color: b.task == .checked ? Theme.muted : Theme.ink)
            }
            .padding(.leading, CGFloat(b.indent) * 16)
        case .quote:
            RichText(source: b.text, size: size, color: Theme.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
        case .code:
            CodeBlock(language: b.language, code: b.text)
        case .rule:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
        case .table:
            MarkdownTable(block: b, size: size)
        }
    }
}

/// A heading is the title3 size, semibold, whatever the base size, 6px further from what is above it.
private struct HeadingText: View {
    var text: String
    var body: some View {
        Text(richTextHeading(text)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
    private func richTextHeading(_ s: String) -> AttributedString {
        var a = richText(s, size: .body, bold: true)
        for run in a.runs where a[run.range].backgroundColor == nil { a[run.range].font = Theme.title3 }
        return a
    }
}

private struct TaskBox: View {
    var checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(checked ? Theme.accent : Theme.raise)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(checked ? Theme.accent : Theme.ink.opacity(0.35), lineWidth: 1))
            .overlay { if checked { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
            .frame(width: 14, height: 14)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
    }
}

/// A code block: its language over a line with a copy button, then the code, on the sunken colour.
struct CodeBlock: View {
    var language: String?
    var code: String
    @State private var copied = false
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code").font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? Glyph.symbol(0xE73E) : Glyph.symbol(0xE8C8)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.ink.opacity(0.06) : .clear))
                }
                .buttonStyle(.plain).onHover { hovered = $0 }.help("Copy")
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 25)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            Text(code).font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A table sized to its content: a header tint, a grid, and each column's alignment.
private struct MarkdownTable: View {
    var block: MdBlock
    var size: MarkdownSize
    var body: some View {
        let cellSize: MarkdownSize = size == .body ? .callout : size
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(block.cells.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            let align = c < block.aligns.count ? block.aligns[c] : .left
                            Text(richText(cell, size: cellSize, bold: r == 0))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 32, maxWidth: 420, alignment: align == .right ? .trailing : align == .center ? .center : .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(r == 0 ? Theme.raise : .clear)
                                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 0.5))
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
        }
    }
}
