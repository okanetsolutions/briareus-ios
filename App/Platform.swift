import SwiftUI
import UIKit

enum Pasteboard {
    static func copy(_ text: String) { UIPasteboard.general.string = text }
}

/// Whether the car's screen is showing the app, which keeps polling going while the phone is locked in a pocket.
@MainActor
enum CarScreen {
    static var connected = false {
        didSet { Store.shared.active = connected || UIApplication.shared.applicationState == .active }
    }
}

extension SearchFieldPlacement {
    /// A search field that stays in view rather than hiding until the list is pulled down.
    static var pinned: SearchFieldPlacement { .navigationBarDrawer(displayMode: .always) }
}

enum Platform {
    static var name: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
}
