import AppKit
import SwiftUI
import WebKit

struct SafeEmailWebView: NSViewRepresentable {
    let html: String
    let allowsRemoteImages: Bool
    let linkActivated: (String) -> Void

    func makeCoordinator() -> Coordinator {
        #if DEBUG
        print("[JunkMailCleaner][Inspector][WebView] SafeEmailWebView created")
        #endif
        return Coordinator(
            allowsRemoteImages: allowsRemoteImages,
            linkActivated: linkActivated
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
#if DEBUG
        if ProcessInfo.processInfo.environment["JMC_WEBVIEW_DIAGNOSTIC"] != nil {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
#endif
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = SafeEmailWKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        print(
            "[JunkMailCleaner][Inspector][WebView] makeNSView; "
                + "view.window before attachment=\(String(describing: webView.window))"
        )
        #endif
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
        webView.didAttachToWindow = { [weak coordinator = context.coordinator] in
            // Let SwiftUI finish the attachment/layout pass before asking
            // WebKit to create its first document process.
            DispatchQueue.main.async {
                coordinator?.loadPendingIfNeeded()
            }
        }
        context.coordinator.load(html)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        #if DEBUG
        print(
            "[JunkMailCleaner][Inspector][WebView] updateNSView; "
                + "frame=\(webView.frame) attached=\(webView.window != nil)"
        )
        #endif
        context.coordinator.linkActivated = linkActivated
        context.coordinator.load(html)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // Keep one web view alive for the lifetime of this representable.  A
        // weak reference here allowed the first load to race SwiftUI's view
        // attachment and left an otherwise valid, but empty, WebView behind.
        var webView: WKWebView?
        private var loadedHTML: String?
        private var inFlightHTML: String?
        private var pendingHTML: String?
        private var loadAttemptCount = 0
        private var contentRulesReady = false
        private var isPreparingRules = false
        private let allowsRemoteImages: Bool
        var linkActivated: (String) -> Void

        init(allowsRemoteImages: Bool, linkActivated: @escaping (String) -> Void) {
            self.allowsRemoteImages = allowsRemoteImages
            self.linkActivated = linkActivated
        }

        func load(_ html: String) {
            let documentHTML = diagnosticHTML(for: html)
            if pendingHTML != documentHTML {
                loadAttemptCount = 0
            }
            pendingHTML = documentHTML
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] HTML queued; "
                    + "chars=\(documentHTML.count) attached=\(webView?.window != nil) "
                    + "rulesReady=\(contentRulesReady)"
            )
            #endif
            guard loadedHTML != documentHTML,
                  inFlightHTML != documentHTML else { return }
            guard contentRulesReady else {
                prepareContentRules()
                return
            }
            guard let webView else { return }
            guard webView.window != nil else {
                return
            }
            inFlightHTML = documentHTML
            loadAttemptCount += 1
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] HTML load started; "
                    + "attempt=\(loadAttemptCount) chars=\(documentHTML.count) frame=\(webView.frame)"
            )
            #endif
            #if DEBUG
            let htmlPrefix = String(documentHTML.prefix(200))
                .replacingOccurrences(
                    of: #"[\r\n\t]+"#,
                    with: " ",
                    options: .regularExpression
                )
            let visibleText = documentHTML
                .replacingOccurrences(of: #"(?is)<style\b.*?</style\s*>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"(?is)<script\b.*?</script\s*>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print(
                "[JunkMailCleaner][Inspector][WebView] WEBVIEW HTML LENGTH = \(documentHTML.count); "
                    + "WEBVIEW HTML PREFIX = \(htmlPrefix); "
                    + "baseURL=about:blank; REMOTE CONTENT ALLOWED = \(allowsRemoteImages); "
                    + "sanitizedVisibleTextChars=\(visibleText.count)"
            )
            #endif
            webView.loadHTMLString(documentHTML, baseURL: URL(string: "about:blank"))
            scheduleLoadWatchdog(for: documentHTML)
            #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let webView = self?.webView else { return }
                print(
                    "[JunkMailCleaner][Inspector][WebView] state after 1s "
                        + "isLoading=\(webView.isLoading) url=\(webView.url?.absoluteString ?? "nil") "
                        + "title=\(webView.title ?? "nil") frame=\(webView.frame) "
                        + "attached=\(webView.window != nil)"
                )
                let script = """
                document.readyState + "|" +
                (document.documentElement ? document.documentElement.outerHTML.length : 0) + "|" +
                (document.body !== null) + "|" +
                (document.body ? document.body.innerHTML.length : 0) + "|" +
                (document.body ? document.body.innerText.length : 0) + "|" +
                (document.body ? document.body.scrollHeight : 0) + "|" +
                (document.body ? document.body.scrollWidth : 0) + "|" +
                (document.body ? getComputedStyle(document.body).display : "none") + "|" +
                (document.body ? getComputedStyle(document.body).visibility : "hidden") + "|" +
                (document.body ? getComputedStyle(document.body).opacity : "0") + "|" +
                (document.body ? getComputedStyle(document.body).color : "") + "|" +
                (document.body ? getComputedStyle(document.body).backgroundColor : "") + "|" +
                (document.body ? getComputedStyle(document.body).fontSize : "")
                """
                webView.evaluateJavaScript(script) { result, error in
                    if let error {
                        print("[JunkMailCleaner][Inspector][WebView] DOM evaluation failed: \(error.localizedDescription)")
                    } else {
                        print("[JunkMailCleaner][Inspector][WebView] DOM DIAGNOSTICS = \(String(describing: result))")
                    }
                }
            }
            #endif
        }

        func loadPendingIfNeeded() {
            guard let pendingHTML else { return }
            load(pendingHTML)
        }

        private func scheduleLoadWatchdog(for html: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self,
                      self.loadedHTML != html,
                      self.inFlightHTML == html,
                      self.loadAttemptCount < 3 else {
                    return
                }
                #if DEBUG
                print(
                    "[JunkMailCleaner][Inspector][WebView] load did not finish; "
                        + "retrying attempt \(self.loadAttemptCount + 1)"
                )
                #endif
                self.inFlightHTML = nil
                self.load(html)
            }
        }

        private func diagnosticHTML(for html: String) -> String {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["JMC_WEBVIEW_DIAGNOSTIC"]?.uppercased() {
            case "TEST":
                return "<html><body style=\"background:white;color:black;font-size:30px\">TEST MESSAGE RENDERING</body></html>"
            case "PLAIN":
                return "<html><body><pre>DECODED PLAIN TEXT HERE</pre></body></html>"
            default:
                return html
            }
            #else
            return html
            #endif
        }

        private func prepareContentRules() {
            guard !isPreparingRules else { return }
#if DEBUG
            if ProcessInfo.processInfo.environment["JMC_WEBVIEW_DIAGNOSTIC"] != nil {
                contentRulesReady = true
                if let pendingHTML {
                    load(pendingHTML)
                }
                return
            }
#endif
            isPreparingRules = true
            let identifier = allowsRemoteImages
                ? "JunkMailCleaner.AllowRemoteImagesOnly.v2"
                : "JunkMailCleaner.BlockAllExternalResources.v2"
            let rules = SafeEmailNetworkPolicy.contentRuleJSON(
                allowsRemoteImages: allowsRemoteImages
            )
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: rules
            ) { [weak self] ruleList, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    #if DEBUG
                    if let error {
                        print(
                            "[JunkMailCleaner][Inspector][WebView] content-rule compilation failed: "
                                + error.localizedDescription
                        )
                    } else {
                        print(
                            "[JunkMailCleaner][Inspector][WebView] content rules ready; "
                                + "remoteContentAllowed=\(self.allowsRemoteImages)"
                        )
                    }
                    #endif
                    if let ruleList {
                        self.webView?.configuration.userContentController
                            .add(ruleList)
                    }
                    self.contentRulesReady = true
                    self.isPreparingRules = false
                    if let pendingHTML = self.pendingHTML {
                        self.load(pendingHTML)
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            let isLocalScheme = scheme == nil || scheme == "about" || scheme == "data"
            let currentScheme = webView.url?.scheme?.lowercased()
            let isInitialLocalLoad = isLocalScheme
                && (webView.url == nil || currentScheme == "about")
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] navigation type="
                    + "\(navigationAction.navigationType.rawValue) "
                    + "url=\(navigationAction.request.url?.absoluteString ?? "nil") "
                    + "decision=\(isInitialLocalLoad ? "allow-local" : "cancel")"
            )
            #endif
            if isInitialLocalLoad {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let destination = navigationAction.request.url?.absoluteString {
                linkActivated(destination)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadedHTML = inFlightHTML ?? pendingHTML
            inFlightHTML = nil
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] didFinish url="
                    + "\(webView.url?.absoluteString ?? "nil")"
            )
            webView.evaluateJavaScript(
                "String(document.body ? document.body.innerText.length : -1)"
            ) { result, error in
                let length = result as? String ?? "unavailable"
                let errorText = error.map { "; error=\($0.localizedDescription)" } ?? ""
                print(
                    "[JunkMailCleaner][Inspector][WebView] DOM text length="
                        + length + errorText
                )
            }
            evaluateDOM(webView, label: "didFinish")
            #endif
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] didCommit; "
                    + "url=\(webView.url?.absoluteString ?? "nil") frame=\(webView.frame)"
            )
            #endif
        }

        #if DEBUG
        private func evaluateDOM(_ webView: WKWebView, label: String) {
            let script = """
            [document.readyState, document.documentElement ? document.documentElement.outerHTML.length : 0,
             document.body !== null, document.body ? document.body.innerHTML.length : 0,
             document.body ? document.body.innerText.length : 0, document.body ? document.body.scrollHeight : 0,
             document.body ? document.body.scrollWidth : 0,
             document.body ? getComputedStyle(document.body).display : "none",
             document.body ? getComputedStyle(document.body).visibility : "hidden",
             document.body ? getComputedStyle(document.body).opacity : "0",
             document.body ? getComputedStyle(document.body).color : "",
             document.body ? getComputedStyle(document.body).backgroundColor : "",
             document.body ? getComputedStyle(document.body).fontSize : ""].join("|")
            """
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    print("[JunkMailCleaner][Inspector][WebView] DOM evaluation failed (\(label)): \(error.localizedDescription)")
                } else {
                    print("[JunkMailCleaner][Inspector][WebView] DOM DIAGNOSTICS (\(label)) = \(String(describing: result))")
                }
            }
        }
        #endif

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            inFlightHTML = nil
            #if DEBUG
            print("[JunkMailCleaner][Inspector][WebView] didFail: \(error.localizedDescription)")
            #endif
            retryPendingAfterFailure()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            inFlightHTML = nil
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] didFailProvisionalNavigation: "
                    + error.localizedDescription
            )
            #endif
            retryPendingAfterFailure()
        }

        private func retryPendingAfterFailure() {
            guard loadAttemptCount < 3 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.loadPendingIfNeeded()
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            #if DEBUG
            print("[JunkMailCleaner][Inspector][WebView] web content process terminated; reloading")
            #endif
            loadedHTML = nil
            inFlightHTML = nil
            loadAttemptCount = 0
            loadPendingIfNeeded()
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] didStartProvisionalNavigation url="
                    + "\(webView.url?.absoluteString ?? "nil")"
            )
            #endif
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            #if DEBUG
            print(
                "[JunkMailCleaner][Inspector][WebView] navigationResponse url="
                    + "\(navigationResponse.response.url?.absoluteString ?? "nil") decision=allow"
            )
            #endif
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}

private final class SafeEmailWKWebView: WKWebView {
    var didAttachToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if DEBUG
        print(
            "[JunkMailCleaner][Inspector][WebView] viewDidMoveToWindow; "
                + "attached=\(window != nil) frame=\(frame)"
        )
        #endif
        if window != nil {
            didAttachToWindow?()
        }
    }
}

struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    var monospaced = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = monospaced
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        textView.string = text
        if monospaced {
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else {
            return
        }
        textView.string = text
    }
}
