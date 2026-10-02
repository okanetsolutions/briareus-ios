import SwiftUI

// Warm neutrals and a clay accent, in the spirit of the Claude apps.
enum Theme {
    static let accent = Color(light: 0xC96442, dark: 0xD97757)
    static let background = Color(light: 0xFAF9F5, dark: 0x1F1E1D)
    static let surface = Color(light: 0xF0EEE6, dark: 0x2A2927)
    static let elevated = Color(light: 0xFFFFFF, dark: 0x302F2C)
    static let bubble = Color(light: 0xEAE7DD, dark: 0x3A3936)
    static let border = Color(light: 0xDEDBD0, dark: 0x3E3D39)
    static let code = Color(light: 0xF3F1EA, dark: 0x262523)
    static let success = Color(light: 0x3D8C5A, dark: 0x6FBF8B)
    static let danger = Color(light: 0xC0392B, dark: 0xE5776A)
    static let warning = Color(light: 0xB7791F, dark: 0xE3B25C)

    /// Behind a list row: a card, tinted while an iPad's right-hand side shows it.
    static var row: Color { row(selected: false) }
    static func row(selected: Bool) -> Color { selected ? accent.opacity(0.16) : elevated }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return success
        case "queued", "preparing", "starting": return warning
        case "failed", "error", "cancelled": return danger
        case "closed": return .secondary.opacity(0.6)
        default: return .secondary
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func rgb(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }
}

struct StatusDot: View {
    let status: String
    @State private var pulse = false
    var body: some View {
        Circle().fill(Theme.statusColor(status)).frame(width: 7, height: 7)
            .overlay {
                if status == "running" {
                    Circle().stroke(Theme.statusColor(status), lineWidth: 1.5).scaleEffect(pulse ? 2.4 : 1).opacity(pulse ? 0 : 0.8)
                        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
                }
            }
            .accessibilityHidden(true)
    }
}

struct StatusLabel: View {
    let status: String
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(status.capitalized).font(.caption.weight(.medium)).foregroundStyle(status == "running" ? Theme.statusColor(status) : .secondary)
        }
        .accessibilityElement(children: .combine).accessibilityLabel("Status: \(status)")
    }
}

struct ErrorNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(Theme.danger).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("errorNotice")
    }
}

/// Square monogram used for projects so the list scans quickly.
struct Monogram: View {
    let text: String
    var size: CGFloat = 34
    var body: some View {
        let letter = text.split(separator: "/").last?.first.map { String($0).uppercased() } ?? "?"
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.accent.opacity(0.14))
            .frame(width: size, height: size)
            .overlay { Text(letter).font(.system(size: size * 0.46, weight: .semibold, design: .serif)).foregroundStyle(Theme.accent) }
            .accessibilityHidden(true)
    }
}

// MARK: - Markdown

/// A reply's Markdown, on the core's parser (Mac/Core/Markdown.swift, the Windows client's): headings, lists and task
/// boxes, quotes, code, rules and tables. Equal sources draw the same, so a screen redrawn around a reply leaves it be.
struct MarkdownText: View, Equatable {
    let source: String
    init(_ source: String) { self.source = source }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.parse(source).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .paragraph:
                    Text(inlineMarkdown(block.text))
                case .heading:
                    Text(inlineMarkdown(block.text)).font(block.level == 1 ? .title3.bold() : block.level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, 4)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        switch block.task {
                        case .none: Text(block.marker ?? "•").foregroundStyle(.secondary).monospacedDigit()
                        case .unchecked: Image(systemName: "square").foregroundStyle(.secondary).accessibilityLabel("Not done")
                        case .checked: Image(systemName: "checkmark.square.fill").foregroundStyle(Theme.accent).accessibilityLabel("Done")
                        }
                        Text(inlineMarkdown(block.text))
                    }.padding(.leading, CGFloat(block.indent) * 16)
                case .quote:
                    Text(inlineMarkdown(block.text)).foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Capsule().fill(Theme.border).frame(width: 3) }
                case .code:
                    CodeBlock(language: block.language, text: block.text)
                case .rule:
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
                case .table:
                    MarkdownTable(block: block)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline Markdown as styled text: code in the accent on a tint, bold, italic, struck through, and links that open.
func inlineMarkdown(_ text: String) -> AttributedString {
    var out = AttributedString()
    for span in Markdown.inline(text) {
        var run = AttributedString(span.text)
        if span.flags.contains(.code) {
            run.font = .system(.callout, design: .monospaced)
            run.backgroundColor = Theme.code
            run.foregroundColor = Theme.accent
        } else {
            var intent: InlinePresentationIntent = []
            if span.flags.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if span.flags.contains(.italic) { intent.insert(.emphasized) }
            if span.flags.contains(.strike) { intent.insert(.strikethrough) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
        }
        if span.flags.contains(.link), let url = span.url.flatMap(URL.init(string:)), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            run.link = url
        }
        out += run
    }
    return out
}

/// A table that scrolls sideways when wider than the screen, its header row tinted.
private struct MarkdownTable: View {
    let block: MdBlock
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(block.cells.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            let align = c < block.aligns.count ? block.aligns[c] : .left
                            Text(inlineMarkdown(cell)).font(.callout.weight(r == 0 ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 32, maxWidth: 280, alignment: align == .right ? .trailing : align == .center ? .center : .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(r == 0 ? Theme.surface : .clear)
                                .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 0.5))
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}

struct CodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(text); copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption).labelStyle(.iconOnly).frame(width: 28, height: 22)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider().overlay(Theme.border)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.footnote, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled).padding(12)
            }
        }
        .background(Theme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }
}
