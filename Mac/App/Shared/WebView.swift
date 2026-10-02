// An embedded browser: WebKit's WKWebView, in a profile of its own that is kept on disk, with an optional Cloudflare Access
// service token sent only to preview hosts.
import SwiftUI
import WebKit

/// The Cloudflare Access service token (`GET /preview/access`): sent as CF-Access-Client-Id and CF-Access-Client-Secret
/// with every navigation to a host ending in `.` + `hostSuffix`, and to no other.
struct WebAccess: Equatable {
    var clientID: String, clientSecret: String, hostSuffix: String
}

/// One browser and what it reports: its title, address, whether it is loading and why it failed.
@MainActor
final class Browser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published private(set) var title: String?
    @Published private(set) var url: String?
    @Published private(set) var loading = false
    @Published private(set) var ready = false
    @Published private(set) var error: String?
    var access: WebAccess?
    private var observations: [NSKeyValueObservation] = []
    /// The address last asked for, which a reload opens again when nothing has loaded yet.
    private var requested: String?

    /// `profile` names the data store, so a sign-in lasts between runs and between launches.
    init(profile: String, access: WebAccess? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Browser.identifier(profile))
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        // Web apps such as WhatsApp Web only serve browsers they know; this is Safari's own.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        self.access = access
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in Task { @MainActor in self?.title = wv.title } },
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

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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

    /// A link that opens a new window opens in the default browser instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url, u.scheme == "https" || u.scheme == "http" { NSWorkspace.shared.open(u) }
        return nil
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.prompt) }
}

/// The browser's view, edge to edge.
struct BrowserView: NSViewRepresentable {
    @ObservedObject var browser: Browser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
