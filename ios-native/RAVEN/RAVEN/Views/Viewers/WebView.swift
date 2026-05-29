import SwiftUI
import WebKit

// MARK: - Allowed-host policy
//
// Round 14 (2026-05-16) — hacker-audit finding N10.
//
// Until today both `WebView` and `SimpleWebView` wrapped
// `WKWebView` with the default config, no navigation delegate
// (`SimpleWebView`), and JS enabled. Any code path that handed a
// server-controlled URL to either wrapper inherited the full
// browser surface: XSS, fingerprinting, credential phishing, and
// — because `URLSessionConfiguration.default`-derived process
// cookies are shared — auth-cookie exfiltration if anything ever
// sat behind the same cookie jar.
//
// Both wrappers now route every navigation through a single
// `decidePolicyFor` that enforces:
//   • HTTPS only (no http://, no file://, no data: URLs)
//   • Hostname must end with one of our known suffixes
// Anything else is cancelled with a debug log.
private enum WebViewPolicy {
    static let allowedHostSuffixes: Set<String> = [
        // Our own domains.
        "raven.app",
        "raven-messager.com",
        // Cloud Run hostnames.
        "run.app",
        // OAuth surfaces used by sign-in coordinators.
        "apple.com",
        "google.com",
        "googleusercontent.com",
        "accounts.google.com"
    ]

    static func allow(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        guard url.scheme?.lowercased() == "https" else { return false }
        return allowedHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }
}

// MARK: - WKWebView Wrapper
struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var progress: Double
    @Binding var currentURL: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Round 14 — N10: use a process pool dedicated to this
        // wrapper so it doesn't share its cookie jar with any other
        // WKWebView elsewhere in the app. Defense in depth.
        config.processPool = WKProcessPool()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator

        // Observe loading progress
        context.coordinator.webView = webView
        context.coordinator.setupObservers()

        if WebViewPolicy.allow(url) {
            webView.load(URLRequest(url: url))
        } else {
            #if DEBUG
            print("⚠️ [WebView] initial URL rejected by host allowlist: \(url.absoluteString.prefix(80))")
            #endif
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebView
        weak var webView: WKWebView?
        private var progressObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var backObserver: NSKeyValueObservation?
        private var forwardObserver: NSKeyValueObservation?

        init(_ parent: WebView) {
            self.parent = parent
        }

        func setupObservers() {
            progressObserver = webView?.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.progress = webView.estimatedProgress
                }
            }

            urlObserver = webView?.observe(\.url, options: .new) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.currentURL = webView.url
                }
            }

            backObserver = webView?.observe(\.canGoBack, options: .new) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.canGoBack = webView.canGoBack
                }
            }

            forwardObserver = webView?.observe(\.canGoForward, options: .new) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.canGoForward = webView.canGoForward
                }
            }
        }

        // Round 14 — N10: gate every navigation through the host
        // allowlist. Cancels redirects to off-list hosts (a common
        // phishing technique: legitimate domain redirects to attacker
        // domain that visually mimics a sign-in page).
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if WebViewPolicy.allow(navigationAction.request.url) {
                decisionHandler(.allow)
            } else {
                #if DEBUG
                print("⚠️ [WebView] navigation rejected by host allowlist: \(navigationAction.request.url?.absoluteString.prefix(80) ?? "<nil>")")
                #endif
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            parent.isLoading = false
        }
    }
}

// MARK: - Simple WebView (Minimal bindings)
struct SimpleWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Same isolation + policy as the full WebView.
        config.processPool = WKProcessPool()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator

        if WebViewPolicy.allow(url) {
            webView.load(URLRequest(url: url))
        } else {
            #if DEBUG
            print("⚠️ [SimpleWebView] initial URL rejected by host allowlist: \(url.absoluteString.prefix(80))")
            #endif
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if WebViewPolicy.allow(navigationAction.request.url) {
                decisionHandler(.allow)
            } else {
                #if DEBUG
                print("⚠️ [SimpleWebView] navigation rejected by host allowlist: \(navigationAction.request.url?.absoluteString.prefix(80) ?? "<nil>")")
                #endif
                decisionHandler(.cancel)
            }
        }
    }
}
