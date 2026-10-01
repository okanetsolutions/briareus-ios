// The dashboard's own look, dark or light as macOS's appearance says: its palette (canvas, sidebar, raise, field, sunken,
// line, ink, muted, accent), its pixel sizes for the system font and the monospaced one, and the pieces the screens share.
import AppKit
import SwiftUI

enum Theme {
    // MARK: Palette

    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    static func nsDynamic(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    // The dashboard's `@theme` block, verbatim, dark; light is the same warm palette on paper, with the accents darkened.
    static let canvas = dynamic(0x262624, 0xFAF9F5)
    static let sidebar = dynamic(0x1F1E1D, 0xF0EEE6)
    static let raise = dynamic(0x30302E, 0xFFFFFF)
    static let field = dynamic(0x3D3D3A, 0xE9E6DC)
    static let sunken = dynamic(0x1C1C1A, 0xF3F1EA)
    static let line = dynamic(0x3E3E3A, 0xE0DDD3)
    static let lineStrong = dynamic(0x5A5850, 0xC4C0B4)
    static let ink = dynamic(0xE8E6E1, 0x1F1E1D)
    static let muted = dynamic(0xA29E93, 0x6B675E)
    static let accent = dynamic(0xD97757, 0xC96442)
    static let accentDim = dynamic(0xB35C3E, 0xE0A58E)
    static let ok = dynamic(0x7FBF7F, 0x3D8B4A)
    static let warn = dynamic(0xE0AF68, 0xA86E12)
    static let danger = dynamic(0xE06C75, 0xC2404B)
    static let onAccent = dynamic(0x1B1B19, 0xFFFFFF)
    static let dot = dynamic(0x6B6862, 0xA29E93)
    static let thumb = dynamic(0x3C3B38, 0xCFCBC0)
    /// `text-muted/70`.
    static let tertiary = muted.opacity(0.7)

    /// The `.dot` colours: running/queued in the accent, idle green, waiting amber, failed red, the rest grey.
    static func statusColor(_ status: String?) -> Color {
        switch status {
        case "running", "queued", "preparing", "starting": return accent
        case "idle": return ok
        case "waiting", "interrupted", "cancelled": return warn
        case "failed", "error": return danger
        default: return dot
        }
    }

    // MARK: Type

    // The dashboard's type at its own pixel sizes: body 15px (`text-sm`), the smallest chrome 13px (`text-xs`), the sidebar
    // rows 14px, metadata 12px and 11px. The Mac's system font stands in for Segoe UI and its monospaced one for Cascadia Code.
    static let body = Font.system(size: 15)
    static let bodyMedium = Font.system(size: 15, weight: .medium)
    static let bodySemibold = Font.system(size: 15, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let subheadline = Font.system(size: 14)
    static let subheadlineSemibold = Font.system(size: 14, weight: .semibold)
    static let title3 = Font.system(size: 17, weight: .semibold)
    static let largeTitle = Font.system(size: 26, weight: .semibold)
    static let callout = Font.system(size: 14)
    static let footnote = Font.system(size: 13)
    static let footnoteSemibold = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 12)
    static let captionMedium = Font.system(size: 12, weight: .medium)
    static let captionSemibold = Font.system(size: 12, weight: .semibold)
    static let caption2 = Font.system(size: 11)
    static let bodyItalic = Font.system(size: 15).italic()
    static let mono = Font.system(size: 13, design: .monospaced)
    static let monoSmall = Font.system(size: 12, design: .monospaced)
    static let monoCaption2 = Font.system(size: 11, design: .monospaced)
    static let tinySemibold = Font.system(size: 10, weight: .semibold)
    /// 23px semibold: a pull request's title.
    static let title = Font.system(size: 23, weight: .semibold)
    /// 22px semibold: dashboard tiles.
    static let stat = Font.system(size: 22, weight: .semibold)
    static let monogram = Font.system(size: 17, weight: .semibold, design: .serif)

    // MARK: Layout

    /// The dashboard's columns: a 268px sidebar, the main column, and a 272px pull request panel beside a conversation.
    static let sidebarWidth: CGFloat = 268
    static let panelWidth: CGFloat = 272
    /// Below the dashboard's `lg` breakpoint (64rem) the columns become one at a time.
    static let narrowWidth: CGFloat = 1024
    /// Pane margins: the sidebar's 10px, the others' 18px.
    static let sidebarMargin: CGFloat = 10
    static let paneMargin: CGFloat = 18

    // MARK: Working indicator

    static let workingGlyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    static let workingVerbs = ["Working", "Thinking", "Reasoning", "Tinkering", "Crafting", "Pondering"]
    static func workingGlyph(_ tick: Int) -> String { workingGlyphs[((tick % 10) + 10) % 10] }
    static func workingVerb(_ tick: Int) -> String { workingVerbs[((tick / 25) % 6 + 6) % 6] }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// A GitHub label's "rrggbb".
    init?(hexString: String?) {
        guard var s = hexString?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(nsColor: NSColor(hex: v))
    }
}

// MARK: - Icons

/// The Windows app draws Segoe Fluent Icons by code point; these are the SF Symbols that stand for each.
enum Glyph {
    static func symbol(_ codepoint: UInt32) -> String {
        switch codepoint {
        case 0xE710: return "plus"
        case 0xE711: return "xmark"
        case 0xE713: return "gearshape"
        case 0xE716: return "person.2"
        case 0xE717: return "phone"
        case 0xE71A: return "stop.fill"
        case 0xE71B: return "link"
        case 0xE72A: return "arrow.right"
        case 0xE72C: return "arrow.clockwise"
        case 0xE738: return "minus"
        case 0xE73E: return "checkmark"
        case 0xE74B: return "arrow.down"
        case 0xE74D: return "trash"
        case 0xE74E: return "square.and.arrow.down"
        case 0xE756: return "terminal"
        case 0xE768: return "play.fill"
        case 0xE769: return "pause.fill"
        case 0xE76C: return "chevron.right"
        case 0xE70D: return "chevron.down"
        case 0xE70F: return "pencil"
        case 0xE774: return "globe"
        case 0xE783: return "exclamationmark.circle"
        case 0xE787: return "calendar"
        case 0xE7A7: return "arrow.uturn.backward"
        case 0xE7BA: return "exclamationmark.triangle"
        case 0xE7C1: return "flag"
        case 0xE7C3: return "doc"
        case 0xE7F4: return "display"
        case 0xE80F: return "house"
        case 0xE81E: return "square.3.layers.3d"
        case 0xE823: return "clock"
        case 0xE838: return "folder"
        case 0xE892: return "backward.end.fill"
        case 0xE893: return "forward.end.fill"
        case 0xE895: return "arrow.triangle.2.circlepath"
        case 0xE896: return "arrow.down.to.line"
        case 0xE898: return "arrow.up.to.line"
        case 0xE8A5: return "doc.text"
        case 0xE8A7: return "arrow.up.right.square"
        case 0xE8AB: return "arrow.triangle.branch"
        case 0xE8B7: return "folder"
        case 0xE8BB: return "xmark"
        case 0xE8BD: return "text.bubble"
        case 0xE8C8: return "doc.on.doc"
        case 0xE8D6: return "music.note"
        case 0xE8D7: return "lock"
        case 0xE8E3: return "list.bullet"
        case 0xE8E4: return "text.alignleft"
        case 0xE8EE: return "repeat"
        case 0xE8F2: return "bubble.left.and.bubble.right"
        case 0xE8F4: return "folder.badge.plus"
        case 0xE8FD: return "list.bullet.rectangle"
        case 0xE90F: return "wrench.and.screwdriver"
        case 0xE930: return "checkmark.circle"
        case 0xE946: return "info.circle"
        case 0xE968: return "network"
        case 0xE97A: return "chevron.left.forwardslash.chevron.right"
        case 0xE9D5: return "checklist"
        case 0xE9D9: return "chart.bar"
        case 0xEA39: return "xmark.circle"
        case 0xE1D3: return "mic"
        case 0xE721: return "magnifyingglass"
        default: return "circle"
        }
    }
}
