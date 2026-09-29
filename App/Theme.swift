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

    /// Behind a list row: a card on the phone, nothing on a Mac, whose lists are plain.
    static var row: some View { row(selected: false) }
    @ViewBuilder static func row(selected: Bool) -> some View {
        #if os(macOS)
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? accent.opacity(0.18) : .clear).padding(.horizontal, 6)
        #else
        selected ? accent.opacity(0.16) : elevated
        #endif
    }

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
        func rgb(_ hex: UInt32) -> PlatformColor {
            PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) })
        #else
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
        #endif
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

struct MarkdownText: View {
    let blocks: [MarkdownBlock]
    init(_ source: String) { blocks = MarkdownBlock.parse(source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(inline(text))
                case .heading(let level, let text):
                    Text(inline(text)).font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, 4)
                case .bullet(let indent, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(text))
                    }.padding(.leading, CGFloat(indent) * 16)
                case .quote(let text):
                    Text(inline(text)).foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Capsule().fill(Theme.border).frame(width: 3) }
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
                case .table(let header, let alignments, let rows):
                    table(header: header, alignments: alignments, rows: rows)
                case .rule:
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// A table scrolls sideways when it is wider than the screen rather than squeezing its columns.
    private func table(header: [String], alignments: [MarkdownBlock.ColumnAlignment], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                        cell(text, alignments[column]).fontWeight(.semibold)
                    }
                }
                .background(Theme.surface)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(Theme.border).frame(height: 0.5).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in cell(text, alignments[column]) }
                    }
                }
            }
            .font(.callout)
            .background(Theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
            .padding(.vertical, 1)
        }
    }
    private func cell(_ text: String, _ alignment: MarkdownBlock.ColumnAlignment) -> some View {
        let edge: Alignment = alignment == .trailing ? .trailing : alignment == .center ? .center : .leading
        return Text(inline(text))
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(maxWidth: 360, alignment: edge).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .gridColumnAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
    private func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.callout, design: .monospaced)
            result[run.range].backgroundColor = Theme.code
            result[run.range].foregroundColor = Theme.accent
        }
        return result
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
