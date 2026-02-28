import SwiftUI
import WebKit

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
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        
        // Observe loading progress
        context.coordinator.webView = webView
        context.coordinator.setupObservers()
        
        webView.load(URLRequest(url: url))
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
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
