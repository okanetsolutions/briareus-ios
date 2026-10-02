// The dashboard's pieces the screens share: buttons, dots, badges, chips, monograms, notices, sections, segmented pickers,
// the tabnav row and a wrapping layout. Sizes are the Windows client's (and so the dashboard's) pixel sizes.
import AppKit
import SwiftUI

// MARK: - Buttons

enum ButtonKind { case prominent, bordered, plain, destructive }

/// The dashboard's `.btn` (bordered), `.btn-primary` (prominent), its link-like plain button and the danger-on-hover one:
/// 13px text, 10px side padding, 7px corners, 30px tall.
struct DashButtonStyle: ButtonStyle {
    var kind: ButtonKind = .bordered
    var stretch = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let h = hovered && enabled
        var fill: Color = Theme.raise, border: Color = h ? Theme.accentDim : Theme.line, text: Color = Theme.ink
        switch kind {
        case .prominent:
            fill = h ? Theme.accentDim : Theme.accent; border = fill; text = Theme.onAccent
            if !enabled { fill = Theme.accent.opacity(0.5); border = fill }
        case .destructive:
            border = h ? Theme.danger : Theme.line; text = h ? Theme.danger : Theme.ink
        case .plain:
            fill = .clear; border = .clear; text = Theme.accent
        case .bordered: break
        }
        if !enabled && kind != .prominent { text = Theme.muted }
        return Group {
            if kind == .plain {
                configuration.label.font(Theme.caption).foregroundStyle(text).underline(h)
                    .padding(.vertical, 3)
            } else {
                configuration.label
                    .font(Theme.footnote).foregroundStyle(text).lineLimit(1)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .frame(maxWidth: stretch ? .infinity : nil)
                    .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? fill.opacity(0.85) : fill))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(border, lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// A `.btn-icon`: a 32px square with a border, as the dashboard's ☰ ＋ ⓘ and ⟳.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var destructive = false
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        let h = hovered && enabled
        let fill = prominent && enabled ? (h ? Theme.accentDim : Theme.accent) : Theme.raise
        let border = prominent && enabled ? fill : h ? (destructive ? Theme.danger : Theme.accentDim) : Theme.line
        let ink = !enabled ? Theme.muted : prominent ? Theme.onAccent : (h && destructive) ? Theme.danger : Theme.ink
        return configuration.label
            .font(.system(size: 12)).foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? fill.opacity(0.85) : fill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

extension View {
    func dashButton(_ kind: ButtonKind = .bordered, stretch: Bool = false) -> some View { buttonStyle(DashButtonStyle(kind: kind, stretch: stretch)) }
}

/// A small button with a glyph before its text, as the board's errand buttons.
struct GlyphButton: View {
    var glyph: String?          // an SF Symbol
    var title: String
    var kind: ButtonKind = .bordered
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph { Image(systemName: glyph).font(.system(size: 11)) }
                Text(title)
            }
        }
        .dashButton(kind)
    }
}

// MARK: - Dots, badges, chips

/// The dashboard's 7px `.dot`.
struct StatusDot: View {
    var status: String?
    var size: CGFloat = 7
    var body: some View { Circle().fill(Theme.statusColor(status)).frame(width: size, height: size) }
}

/// A small bordered tag (`rounded-[5px] border px-1.5 text-[11px] font-semibold`) in a colour.
struct Badge: View {
    var glyph: String? = nil    // an SF Symbol
    var text: String
    var color: Color
    var background: Color = Theme.raise
    var body: some View {
        HStack(spacing: 3) {
            if let glyph { Image(systemName: glyph).font(.system(size: 9, weight: .semibold)) }
            if !text.isEmpty { Text(text) }
        }
        .font(Theme.caption2.weight(.semibold)).foregroundStyle(color).lineLimit(1)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color == Theme.muted ? Theme.line : color, lineWidth: 1))
    }
}

/// A GitHub label as the board draws it: `rounded-full border px-1.5 text-[11px]` in the label's colour.
struct Chip: View {
    var name: String
    var color: Color
    var background: Color = Theme.raise
    var body: some View {
        Text(name).font(Theme.caption2).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(color, lineWidth: 1))
    }
}

/// The square monogram used for projects: the first letter of the repository name on an accent tint.
struct Monogram: View {
    var text: String
    var size: CGFloat = 28
    var body: some View {
        let name = text.split(separator: "/").last.map(String.init) ?? text
        let letter = name.first.map { String($0).uppercased() } ?? "?"
        Text(letter).font(Theme.monogram).foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Theme.accent.opacity(0.15)))
    }
}

// MARK: - Notices and sections

/// An error notice: warning glyph, danger colour, wrapped.
struct Notice: View {
    var message: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(Theme.footnote).foregroundStyle(Theme.danger)
    }
}
/// A boxed error notice on a tinted background.
struct NoticeBox: View {
    var message: String
    var body: some View {
        Notice(message: message).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.danger, lineWidth: 1))
    }
}
/// A progress note ("Loading…").
struct LoadingNote: View {
    var text = "Loading…"
    var body: some View { Text(text).font(Theme.footnote).foregroundStyle(Theme.muted).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
}
/// An empty-state note.
struct EmptyNote: View {
    var title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail) }
        }
        .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
/// A section header, 12px muted, 12px above and 4px below.
struct SectionTitle: View {
    var title: String
    var body: some View {
        Text(title).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
            .padding(.top, 12).padding(.bottom, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
}
/// A "Label: value" row with the value on the right.
struct LabeledRow: View {
    var label: String
    var value: String
    var valueColor: Color = Theme.ink
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(valueColor).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(Theme.callout)
    }
}

/// A rounded box: the dashboard's `.card` (`bg-raise border border-line rounded-xl`).
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var fill: Color = Theme.raise
    var border: Color = Theme.line
    var radius: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
    }
}

// MARK: - Pickers

/// A row of small toggle buttons; the first one selected is in danger red, the others in the accent, as the findings'
/// Fix / Optional / Dismiss.
struct Segments: View {
    var titles: [String]
    var selected: Int?
    var dangerFirst = true
    var onSelect: (Int) -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                let on = i == selected
                let c = on ? (i == 0 && dangerFirst ? Theme.danger : Theme.accent) : Theme.muted
                Button { onSelect(i) } label: {
                    Text(title).font(Theme.caption2).foregroundStyle(enabled ? c : c.opacity(0.5))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raise))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? c : Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One tab of GitHub's `tabnav` row: a glyph, a title and an optional count, the open one underlined in the accent.
struct TabNavItem: View {
    var glyph: String?   // an SF Symbol
    var title: String
    var count: String? = nil
    var active: Bool
    var dot = false      // a tab with unsaved changes
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let glyph { Image(systemName: glyph).font(.system(size: 12)).foregroundStyle(active ? Theme.ink : Theme.muted) }
                Text(title + (dot ? " •" : "")).font(active ? Theme.footnoteSemibold : Theme.footnote)
                    .foregroundStyle(active || hovered ? Theme.ink : Theme.muted)
                if let count {
                    Text(count).font(Theme.caption).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.line))
                }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered && !active ? Theme.raise : .clear).padding(.vertical, 5).padding(.horizontal, 2))
            .overlay(alignment: .bottom) {
                if active { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(height: 2).padding(.horizontal, 4) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(active)
        .onHover { hovered = $0 }
    }
}
/// A `tabnav` row: the tabs left to right, wrapping, over a 1px line.
struct TabNav<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: 0, lineSpacing: 0) { content }
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// MARK: - Text fields

/// The dashboard's inputs: `bg-field rounded-lg border-line`, 14px text.
struct FieldStyle: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(Theme.callout).foregroundStyle(Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accentDim : Theme.line, lineWidth: 1))
    }
}
extension View {
    func dashField(focused: Bool = false) -> some View { modifier(FieldStyle(focused: focused)) }
}

// MARK: - Layout

/// Lays its subviews out left to right, wrapping onto new lines, as CSS `flex-wrap`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, width)
            if x > 0 && x + w > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += w + spacing; lineHeight = max(lineHeight, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: subviews.isEmpty ? 0 : y + lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, bounds.width)
            if x > 0 && x + w > bounds.width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: w, height: s.height))
            x += w + spacing; lineHeight = max(lineHeight, s.height)
        }
    }
}

// MARK: - Clipboard and links

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Opens an https URL in the default browser; anything else is refused.
func openWebURL(_ url: String?) {
    guard let url, let u = URL(string: url), u.scheme?.lowercased() == "https", u.host != nil, u.user == nil, u.password == nil else { return }
    NSWorkspace.shared.open(u)
}
