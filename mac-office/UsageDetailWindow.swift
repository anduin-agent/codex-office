import AppKit
import WebKit

@MainActor
final class UsageDetailWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let window: NSWindow
    let webView: WKWebView
    private let sceneURL: URL
    private let collector: OfficeUsageCollector
    private let openChat: (String, NSWindow) -> Void
    private var language: OfficeLanguage
    private var queryTask: Task<Void, Never>?
    private var loaded = false

    init(sceneURL: URL, collector: OfficeUsageCollector, language: OfficeLanguage,
         openChat: @escaping (String, NSWindow) -> Void) {
        self.sceneURL = sceneURL
        self.collector = collector
        self.language = language
        self.openChat = openChat
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 340)
        window.contentView = webView
        window.delegate = self
        window.title = title
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        configuration.userContentController.add(self, name: "officeDetail")
    }

    private var title: String { language.text("详细用量", "Usage details") }

    func show(on screen: NSScreen?) {
        #if !OFFICE_UI_TEST
        if !window.isVisible, let screen {
            let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let width = min(window.frame.width, bounds.width)
            let height = min(window.frame.height, bounds.height)
            window.setFrame(NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                   width: width, height: height), display: false)
        }
        window.deminiaturize(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        #endif
        if loaded {
            setVisible(true)
            webView.evaluateJavaScript("window.officeDetailRefresh?.()")
        } else if !webView.isLoading {
            load()
        }
    }

    func setLanguage(_ language: OfficeLanguage) {
        guard self.language != language else { return }
        self.language = language
        window.title = title
        if loaded { pushLanguage() }
    }

    func stop() {
        queryTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "officeDetail")
    }

    private func load() {
        loaded = false
        queryTask?.cancel()
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: "window.officeInitialLanguage = '\(language.rawValue)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        webView.loadFileURL(sceneURL, allowingReadAccessTo: sceneURL.deletingLastPathComponent())
    }

    private func pushLanguage() {
        webView.callAsyncJavaScript("window.officeDetailSetLanguage?.(language);",
            arguments: ["language": language.rawValue], in: nil, in: .page, completionHandler: nil)
    }

    private func setVisible(_ visible: Bool) {
        webView.callAsyncJavaScript("window.officeDetailSetVisible?.(visible);",
            arguments: ["visible": visible], in: nil, in: .page, completionHandler: nil)
    }

    func windowWillClose(_ notification: Notification) {
        queryTask?.cancel()
        if loaded { setVisible(false) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.targetFrame?.isMainFrame == true &&
            navigationAction.request.url?.standardizedFileURL == sceneURL
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        pushLanguage()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        if window.isVisible { load() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "officeDetail", message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == sceneURL,
              let body = message.body as? OfficeJSON, let action = body["action"] as? String else { return }
        #if !OFFICE_UI_TEST
        guard window.isVisible else { return }
        #endif
        if action == "openChat", let id = body["id"] as? String {
            openChat(id, window)
        } else if action == "query", let request = body["request"] as? Int, request > 0,
                  let data = try? JSONSerialization.data(withJSONObject: body) {
            queryTask?.cancel()
            let language = self.language
            queryTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let reply = try? await self.collector.detailedUsage(data, language: language)
                guard !Task.isCancelled else { return }
                let result = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? OfficeJSON
                    ?? ["status": "unavailable"]
                self.webView.callAsyncJavaScript("window.officeDetailReceiveUsage(result, request);",
                    arguments: ["result": result, "request": request], in: nil, in: .page, completionHandler: nil)
            }
        }
    }
}
