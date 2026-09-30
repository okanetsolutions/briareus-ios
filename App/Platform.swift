import SwiftUI

// What differs between the iPhone and iPad app and the Mac one, kept here so the screens read the same on both.

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

#if os(macOS)
// A Mac has no navigation bar, software keyboard or grouped lists; these stand in so a screen needs no branch of its own.
enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}
enum UIKeyboardType { case `default`, URL, emailAddress, numberPad, decimalPad }
struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization(), words = never, sentences = never, characters = never
}
extension View {
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { self }
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }
}
extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var topBarLeading: ToolbarItemPlacement { .navigation }
}
extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}
extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}
#endif

extension SearchFieldPlacement {
    /// A search field that stays in view rather than hiding until the list is pulled down.
    static var pinned: SearchFieldPlacement {
        #if os(macOS)
        .automatic
        #else
        .navigationBarDrawer(displayMode: .always)
        #endif
    }
}

extension ScenePhase {
    /// Whether the app is in front of its user. A Mac window stays in view, and goes on
    /// updating, while another app has the keyboard; an iPhone screen does not.
    var isInUse: Bool {
        #if os(macOS)
        self != .background
        #else
        self == .active
        #endif
    }
}

extension View {
    /// Says whether another app is in front of this one, when the screen appears and whenever that changes.
    /// Only a Mac has a window that stays in view behind another app's.
    func onBehindOtherApps(_ change: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        onAppear { change(!NSApplication.shared.isActive) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in change(true) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in change(false) }
        #else
        self
        #endif
    }
}

enum Platform {
    static var name: String {
        #if os(macOS)
        "Mac"
        #else
        "iOS"
        #endif
    }
}

extension View {
    /// A menu drawn by its own label. A Mac would otherwise wrap it in a button with an indicator.
    func plainMenu() -> some View {
        #if os(macOS)
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #else
        self
        #endif
    }
}
