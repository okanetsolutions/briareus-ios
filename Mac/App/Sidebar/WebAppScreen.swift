// WhatsApp Web and Slack in the detail pane, from the sidebar strip's buttons. One browser per app serves every visit:
// leaving the screen keeps it instead of closing it, so the chats stay loaded and coming back is instant. Its profile is
// kept on disk, so the QR code is scanned, or the workspace signed in to, once.
import SwiftUI

extension WebApp {
    var name: String { self == .whatsapp ? "WhatsApp" : "Slack" }
    var host: String { self == .whatsapp ? "web.whatsapp.com" : "app.slack.com" }
    var url: String { self == .whatsapp ? "https://web.whatsapp.com/" : "https://app.slack.com/client" }
    var reloadTip: String { "Reload \(name)" }
}

@MainActor
private enum WebApps {
    static var browsers: [WebApp: Browser] = [:]
    static func browser(_ app: WebApp) -> Browser {
        // A browser that failed to start is tried again on the next visit.
        if let b = browsers[app], b.error == nil { return b }
        let b = Browser(profile: app.rawValue)
        b.load(app.url)
        browsers[app] = b
        return b
    }
}

struct WebAppScreen: View {
    var app: WebApp
    @StateObject private var holder = Holder()
    @MainActor final class Holder: ObservableObject { var browser: Browser? }

    var body: some View {
        let browser = holder.browser ?? WebApps.browser(app)
        VStack(spacing: 0) {
            PaneHeader(title: app.name, subtitle: app.host, buttons: [
                HeaderButton(glyph: Glyph.symbol(0xE72C), tip: app.reloadTip, enabled: browser.ready) { browser.reload() },
                HeaderButton(glyph: Glyph.symbol(0xE8A7), tip: "Open in your browser") { openWebURL(app.url) },
            ])
            Content(app: app, browser: browser)
        }
        .onAppear { holder.browser = browser }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in browser.reload() }
    }

    private struct Content: View {
        var app: WebApp
        @ObservedObject var browser: Browser
        var body: some View {
            ZStack(alignment: .topLeading) {
                BrowserView(browser: browser).opacity(browser.ready ? 1 : 0)
                if !browser.ready {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(browser.error ?? "Opening \(app.name)…").font(Theme.body).foregroundStyle(browser.error != nil ? Theme.danger : Theme.muted)
                        if browser.error != nil {
                            Button("Open in your browser instead ↗") { openWebURL(app.url) }.buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
