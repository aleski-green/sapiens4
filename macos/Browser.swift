import Cocoa
import WebKit

// A normal navigable resource keeps text files in WebKit's back/forward history.
// Each tab grants access only to files explicitly opened through the host.
final class TextFiles: NSObject, WKURLSchemeHandler {
    var allowed = Set<String>()
    static func fileURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return url.scheme == "sapiens-file" ? URL(fileURLWithPath: url.path) : url
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, allowed.contains(url.path) else {
            task.didFailWithError(NSError(domain:NSURLErrorDomain,code:NSURLErrorNoPermissionsToReadFile)); return
        }
        do {
            let text = try String(contentsOfFile:url.path,encoding:.utf8)
            let data = Browser.textDocument(text,title:url.lastPathComponent).data(using:.utf8)!
            task.didReceive(URLResponse(url:url,mimeType:"text/html",expectedContentLength:data.count,textEncodingName:"utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// Guest views have no script-message handlers and never share the app's origin.
final class BrowserTab {
    let owner: String
    let id: String
    let files = TextFiles()
    let view: WKWebView
    var sequence = ""
    var document: URL?
    var requested: URL?
    var error = ""
    var awaitingCommit = false
    var observations: [NSKeyValueObservation] = []
    init(owner: String, id: String) {
        self.owner = owner; self.id = id
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(files, forURLScheme:"sapiens-file")
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(WKUserScript(source: """
            if (location.href === 'about:blank' || ['text/plain','application/json','application/xml','text/xml'].includes(document.contentType)) {
                const style = document.createElement('style');
                style.textContent = 'html,body{background:#fff;color:#171717;color-scheme:light dark}pre{white-space:pre-wrap;overflow-wrap:anywhere}@media(prefers-color-scheme:dark){html,body{background:#000;color:#eee}}';
                document.documentElement.append(style);
            }
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
    }
}

final class Browser: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var shell: WKWebView?
    let origin: URL
    init(origin: URL = URL(string: "http://127.0.0.1:4174")!) { self.origin = origin; super.init() }
    var tabs: [String: BrowserTab] = [:]
    var active: BrowserTab?
    var dark = false
    var owner = ""

    func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return }
        shell?.evaluateJavaScript("window.sapiensBrowserEvent?.(\(json))", completionHandler: nil)
    }
    func tab(for view: WKWebView) -> BrowserTab? { tabs.values.first { $0.view === view } }
    func report(_ tab: BrowserTab) {
        guard !tab.awaitingCommit else { return }
        let url = TextFiles.fileURL(tab.error.isEmpty ? tab.view.url : tab.requested) ?? tab.requested
        guard let url else { return }
        emit(["owner": tab.owner, "id": tab.id, "seq": tab.sequence, "url": url.absoluteString,
              "title": tab.document?.lastPathComponent ?? tab.view.title ?? url.lastPathComponent,
              "can_back": tab.view.canGoBack, "can_forward": tab.view.canGoForward,
              "loading": tab.view.isLoading, "error": tab.error])
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === shell, message.frameInfo.isMainFrame,
              let source = message.frameInfo.request.url,
              source.scheme == origin.scheme, source.host == origin.host, source.port == origin.port,
              ["/workspace", "/workspace/", "/workspace/index.html"].contains(source.path),
              let data = message.body as? [String: Any] else { return }
        if data["pickFile"] as? Bool == true, let owner = data["owner"] as? String, let window = shell?.window {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            panel.beginSheetModal(for: window) { result in
                if result == .OK { for url in panel.urls { self.emit(["owner": owner, "file": url.path]) } }
            }
            return
        }
        sync(data)
    }
    func sync(_ data: [String: Any]) {
        guard let shell, let workspaces = data["workspaces"] as? [String: [String: Any]] else { return }
        dark = data["dark"] as? Bool == true
        owner = data["owner"] as? String ?? ""
        let activeKey = owner + ":" + (data["active"] as? String ?? "")
        let visible = data["visible"] as? Bool == true
        var alive = Set<String>()
        for (owner, workspace) in workspaces {
            for item in workspace["tabs"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String, let address = item["url"] as? String,
                      let url = URL(string: address), let command = item["command"] as? [String: String],
                      let sequence = command["seq"] else { continue }
                let key = owner + ":" + id
                alive.insert(key)
                let fresh = tabs[key] == nil
                let tab = tabs[key] ?? BrowserTab(owner: owner, id: id)
                if fresh {
                    tabs[key] = tab
                    tab.view.navigationDelegate = self; tab.view.uiDelegate = self
                    tab.view.isHidden = true; shell.addSubview(tab.view)
                    tab.observations = [
                        tab.view.observe(\.title, options: [.new]) { [weak self, weak tab] _, _ in if let tab { self?.report(tab) } },
                        tab.view.observe(\.url, options: [.new]) { [weak self, weak tab] _, _ in if let tab { self?.report(tab) } }
                    ]
                }
                tab.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                tab.view.underPageBackgroundColor = dark ? .black : .white
                tab.view.pageZoom = item["zoom"] as? Double ?? 1
                if tab.sequence != sequence {
                    tab.sequence = sequence; tab.error = ""; tab.awaitingCommit = true
                    if fresh || command["action"] == "navigate" { load(url, in: tab) }
                    else {
                        switch command["action"] {
                        case "reload":
                            if let document = TextFiles.fileURL(tab.view.url).flatMap({ $0.isFileURL ? $0 : nil }) { load(document, in: tab) } else { tab.view.reload() }
                        case "back":
                            tab.document = nil
                            if tab.view.canGoBack { tab.view.goBack() } else { tab.awaitingCommit = false; report(tab) }
                        case "forward":
                            tab.document = nil
                            if tab.view.canGoForward { tab.view.goForward() } else { tab.awaitingCommit = false; report(tab) }
                        default: break
                        }
                    }
                }
                tab.view.isHidden = key != activeKey || !visible
            }
        }
        for key in Array(tabs.keys) where !alive.contains(key) {
            tabs[key]?.view.stopLoading(); tabs[key]?.view.removeFromSuperview(); tabs.removeValue(forKey: key)
        }
        active = tabs[activeKey]
        if let rect = data["rect"] as? [String: Double], data["visible"] as? Bool == true,
           let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
           width > 0, height > 0 {
            active?.view.frame = NSRect(x: x, y: shell.isFlipped ? y : shell.bounds.height - y - height, width: width, height: height)
            active?.view.isHidden = false
        }
    }
    func load(_ url: URL, in tab: BrowserTab) {
        tab.document = nil; tab.requested = url; tab.awaitingCommit = true
        if url.isFileURL {
            let native = ["html", "htm", "pdf", "svg", "png", "jpg", "jpeg", "gif", "webp", "heic", "mp4", "mov", "mp3", "wav"]
            if !native.contains(url.pathExtension.lowercased()) {
                tab.document = url; tab.files.allowed.insert(url.path)
                var address = URLComponents(); address.scheme = "sapiens-file"; address.host = "local"; address.path = url.path
                tab.view.load(URLRequest(url:address.url!))
            } else {
                tab.view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        } else if ["http", "https"].contains(url.scheme ?? "") || url.absoluteString == "about:blank" {
            tab.view.load(URLRequest(url: url))
        }
    }
    static func textDocument(_ text: String, title: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escape(title))</title><style>
        html{color-scheme:light dark;background:#fff;color:#171717}
        body{margin:24px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:15px/1.6 ui-monospace,monospace}
        @media(prefers-color-scheme:dark){html{background:#000;color:#eee}}
        </style><pre>\(escape(text))</pre>
        """
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let tab = tab(for: webView), let url = action.request.url else { decisionHandler(.cancel); return }
        // The app control server must never become a guest page, including in frames.
        let host = url.host ?? ""
        if url.port == origin.port && ["127.0.0.1", "localhost", "::1"].contains(host) {
            tab.error = "The Sapiens control server cannot open in a browser tab."
            tab.awaitingCommit = false; report(tab); decisionHandler(.cancel); return
        }
        let allowed = ["http", "https", "about", "blob", "data"].contains(url.scheme ?? "") ||
            (url.isFileURL && (tab.requested?.isFileURL == true || action.navigationType == .backForward)) ||
            (url.scheme == "sapiens-file" && tab.files.allowed.contains(url.path))
        guard allowed else { decisionHandler(.cancel); return }
        if action.targetFrame == nil {
            if ["http", "https"].contains(url.scheme ?? "") { emit(["owner":tab.owner,"open":url.absoluteString]) }
            decisionHandler(.cancel); return
        }
        if action.targetFrame?.isMainFrame == true && !["about", "blob", "data"].contains(url.scheme ?? "") {
            tab.requested = TextFiles.fileURL(url)
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let tab = tab(for: webView) { tab.awaitingCommit = false; report(tab) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tab(for: webView) { tab.awaitingCommit = false; report(tab) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func failed(_ view: WKWebView, _ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled, let tab = tab(for: view) else { return }
        tab.awaitingCommit = false; tab.error = error.localizedDescription; report(tab)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let tab = tab(for: webView) { tab.error = "Page process stopped. Reload to continue."; report(tab) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = shell?.window else { completionHandler(nil); return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
    @objc func reloadTab() { if let tab = active { emit(["owner":tab.owner,"action":"reload","fields":["id":tab.id]]) } }
    @objc func zoomIn() { zoom(0.1) }
    @objc func zoomOut() { zoom(-0.1) }
    @objc func resetZoom() { zoom(0) }
    func zoom(_ delta: Double) {
        if let tab = active { emit(["owner":tab.owner,"action":"zoom","fields":["id":tab.id,"factor":delta == 0 ? 1 : min(5,max(0.25,tab.view.pageZoom+delta))]]) }
    }
}
