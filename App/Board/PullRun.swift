// The Run tab on a phone (the Mac's RunArea and WebView): the pull request served by ▶ Run in an embedded browser, with
// the setup's log while the workspace is prepared. The Cloudflare Access service token goes only to preview hosts.
import SwiftUI
import WebKit

/// The Cloudflare Access service token (`GET /preview/access`): sent as CF-Access-Client-Id and CF-Access-Client-Secret
/// with every navigation to a host ending in `.` + `hostSuffix`, and to no other.
struct RunWebAccess: Equatable {
    var clientID: String, clientSecret: String, hostSuffix: String
}

/// One browser and what it reports: its address, whether it is loading, whether a page is up, and why it failed.
@MainActor
final class RunBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published private(set) var url: String?
    @Published private(set) var loading = false
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    private let access: RunWebAccess?
    private var observations: [NSKeyValueObservation] = []
    /// The address last asked for, which a reload opens again when nothing has loaded yet.
    private var requested: String?

    /// `profile` names the data store, so a sign-in lasts between runs and between launches.
    init(profile: String, access: RunWebAccess?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: RunBrowser.identifier(profile))
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        self.access = access
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url) { [weak self] wv, _ in Task { @MainActor in self?.url = wv.url?.absoluteString } },
            webView.observe(\.isLoading) { [weak self] wv, _ in Task { @MainActor in self?.loading = wv.isLoading } },
        ]
    }

    /// A stable UUID for a profile name.
    private static func identifier(_ profile: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in ("briareus.web." + profile).utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        bytes[6] = (bytes[6] & 0x0F) | 0x40; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func load(_ address: String) {
        guard let u = URL(string: address) else { error = "The address could not be opened."; return }
        requested = address
        error = nil
        webView.load(request(for: URLRequest(url: u)))
    }
    func reload() {
        if webView.url == nil, let address = url ?? requested { load(address) } else { webView.reload() }
    }

    private func request(for r: URLRequest) -> URLRequest {
        guard let access, let u = r.url?.absoluteString, previewAccessApplies(url: u, hostSuffix: access.hostSuffix) else { return r }
        var r = r
        r.setValue(access.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
        r.setValue(access.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        return r
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A navigation to a preview host without the service token is sent again with it. Only a GET is: a form's POST
        // would lose its body, and the Access cookie the first one earned already lets it through.
        if let access, let u = action.request.url?.absoluteString, action.targetFrame?.isMainFrame != false,
           (action.request.httpMethod ?? "GET").uppercased() == "GET",
           previewAccessApplies(url: u, hostSuffix: access.hostSuffix),
           action.request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil {
            decisionHandler(.cancel)
            webView.load(request(for: action.request))
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; error = nil }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { ready = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ e: Error) {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // frame load interrupted by a policy change
        error = e.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    // MARK: WKUIDelegate

    /// A link that opens a new window opens in Safari instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url, u.scheme == "https" || u.scheme == "http" { UIApplication.shared.open(u) }
        return nil
    }
}

/// The browser's view, edge to edge.
private struct RunBrowserView: UIViewRepresentable {
    @ObservedObject var browser: RunBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// The Run tab's area: the page once it is up, and until then what is happening, with the setup's log as it runs.
struct PullRunArea: View {
    @ObservedObject var model: PullScreenModel

    var body: some View {
        let browser = model.browser
        let page = model.runURL != nil && !model.runBusy && browser != nil && browser?.error == nil
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.runError { ErrorNotice(message: e).padding(.horizontal, 16).padding(.bottom, 8) }
            if page, let e = model.serveError {
                Text(e).font(.footnote).foregroundStyle(Theme.danger).lineLimit(2).padding(.horizontal, 16).padding(.bottom, 8)
            }
            ZStack(alignment: .topLeading) {
                if let browser, page { RunBrowserView(browser: browser).opacity(browser.ready ? 1 : 0) }
                if !(page && browser?.ready == true) { status }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: "\(model.runURL ?? "")|\(model.runBusy)|\(browser == nil)|\(model.section == .run)") { model.ensureBrowser() }
    }

    private func statusText(_ error: String?) -> String? {
        if let error { return error }
        if model.runBusy && model.runURL != nil { return model.runAsked.map { "Restarting with profile \($0)…" } ?? "Serving it again…" }
        if model.runURL != nil { return "Starting the browser…" }
        if model.runBusy && model.runSession != nil { return "Serving it…" }
        if model.log.lines.isEmpty {
            return "Preparing a workspace for this pull request and serving it with the project’s run commands. This can take a few minutes…"
        }
        return nil
    }

    @ViewBuilder private var status: some View {
        let browser = model.browser
        let error: String? = model.runBusy ? nil : model.runURL == nil ? model.serveError : browser?.error
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.runBusy || (model.runURL != nil && error == nil) { ProgressView() }
                if let text = statusText(error) {
                    Text(text).font(.callout).foregroundStyle(error != nil ? Theme.danger : .secondary)
                }
            }
            if model.runURL == nil && model.serveError != nil && !model.runBusy {
                Button { model.runStart() } label: { Label("Try again", systemImage: "play.fill") }.buttonStyle(.bordered)
            } else if error != nil && model.runURL != nil {
                Button { boardOpenWeb(model.pageURL) } label: { Label("Open in Safari instead", systemImage: "safari") }
            }
            // The setup as it happens, its latest lines at the bottom, as a terminal shows them.
            if !model.log.lines.isEmpty && (model.runBusy || model.runURL == nil) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.log.lines.enumerated()), id: \.offset) { _, l in
                            Text(l.text).font(.caption2.monospaced()).foregroundStyle(l.isError ? Theme.danger : .secondary)
                                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
