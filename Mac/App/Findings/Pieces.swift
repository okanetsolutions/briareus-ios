// What the Findings and Usage screens share: the width a pane's content is laid out at, text that works as a link
// (the hand cursor of a clickable doc item), a popup menu at the pointer (TrackPopupMenu) and measured text widths.
import AppKit
import Combine
import SwiftUI

/// The pieces live under one name, so they cannot meet another area's own.
enum FDKit {}

extension FDKit {
/// The width a view was given, for layouts that switch on it as the Windows client's doc layouts do.
struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
}

extension View {
    func fdReadWidth(_ width: Binding<CGFloat>) -> some View {
        background(GeometryReader { Color.clear.preference(key: FDKit.WidthKey.self, value: $0.size.width) })
            .onPreferenceChange(FDKit.WidthKey.self) { if abs($0 - width.wrappedValue) > 0.5 { width.wrappedValue = $0 } }
    }
    /// The hand cursor over something clickable.
    func fdHand(_ on: Bool = true) -> some View {
        onHover { inside in
            guard on else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

extension FDKit {
/// A screen's model, kept while its screen is on the navigator's stack: the Windows client keeps a screen alive under the
/// one pushed over it (a conversation opened from it), so what was typed or picked there is still there on the way back.
/// The SwiftUI view is rebuilt on the way back; its model is not. Released (and `release` called) once the screen leaves the
/// stack.
@MainActor
final class Keeper<Model: AnyObject> {
    private let screen: Screen
    private var model: Model?
    private var watch: AnyCancellable?
    init(_ screen: Screen) { self.screen = screen }

    func obtain(_ make: () -> Model, release: @escaping @MainActor (Model) -> Void) -> Model {
        if let model { return model }
        let made = make()
        model = made
        watch = Navigator.shared.$stack.sink { [weak self] stack in
            MainActor.assumeIsolated {
                guard let self, !stack.contains(self.screen), let kept = self.model else { return }
                self.model = nil
                self.watch = nil
                release(kept)
            }
        }
        return made
    }
}

/// Text that is clicked as a link: drawn as given, with the hand cursor.
struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.7 : 1).fdHand()
    }
}

/// A menu at the pointer, as TrackPopupMenu with TPM_RETURNCMD: the index of the item chosen, or nil.
@MainActor
enum Menu {
    struct Item {
        var title: String
        var checked = false
        var enabled = true
        var separator = false
        static let separatorItem = Item(title: "", separator: true)
    }
    private final class Target: NSObject {
        var chosen: Int?
        @objc func pick(_ sender: NSMenuItem) { chosen = sender.tag }
    }
    /// `rightAligned` puts the menu's right edge at the pointer (TPM_RIGHTALIGN), as a header button's menu opens.
    static func show(_ items: [Item], rightAligned: Bool = false) -> Int? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = Target()
        for (i, it) in items.enumerated() {
            if it.separator { menu.addItem(.separator()); continue }
            let m = NSMenuItem(title: it.title, action: it.enabled ? #selector(Target.pick(_:)) : nil, keyEquivalent: "")
            m.target = target
            m.tag = i
            m.state = it.checked ? .on : .off
            m.isEnabled = it.enabled
            menu.addItem(m)
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return nil }
        var point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if rightAligned { point.x = max(point.x - menu.size.width, 0) }
        menu.popUp(positioning: nil, at: point, in: view)
        return target.chosen
    }
}

/// The fonts a measured layout uses, as SwiftUI fonts and as the AppKit fonts they are measured with.
enum MeasuredFont {
    case footnote, footnoteSemibold, caption, caption2, monoSmall, subheadline

    var font: Font {
        switch self {
        case .footnote: return Theme.footnote
        case .footnoteSemibold: return Theme.footnoteSemibold
        case .caption: return Theme.caption
        case .caption2: return Theme.caption2
        case .monoSmall: return Theme.monoSmall
        case .subheadline: return Theme.subheadline
        }
    }
    var ns: NSFont {
        switch self {
        case .footnote: return .systemFont(ofSize: 13)
        case .footnoteSemibold: return .systemFont(ofSize: 13, weight: .semibold)
        case .caption: return .systemFont(ofSize: 12)
        case .caption2: return .systemFont(ofSize: 11)
        case .monoSmall: return .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .subheadline: return .systemFont(ofSize: 14)
        }
    }
    func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: ns]).width) }
    var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: ns)) }
}
}
