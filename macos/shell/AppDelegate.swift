import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let browser = Browser()
    lazy var host = Host(ready: { [unowned self] in self.web.load(URLRequest(url: $0)) }, fail: { [unowned self] in self.fail($0) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Sapiens4", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sapiens4", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu!.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let view = NSMenuItem(); menu.addItem(view); view.submenu = NSMenu(title: "View")
        view.submenu!.addItem(withTitle: "Reload Tab", action: #selector(Browser.reloadTab), keyEquivalent: "r").target = browser
        view.submenu!.addItem(withTitle: "Reload App", action: #selector(reload), keyEquivalent: "").target = self
        for (title, action, key) in [("Zoom In", #selector(Browser.zoomIn), "="), ("Zoom Out", #selector(Browser.zoomOut), "-"), ("Actual Size", #selector(Browser.resetZoom), "0")] {
            view.submenu!.addItem(withTitle: title, action: action, keyEquivalent: key).target = browser
        }
        NSApp.mainMenu = menu
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(browser, name: "browser")
        web = WKWebView(frame: .zero, configuration: configuration)
        browser.shell = web
        web.navigationDelegate = self; web.uiDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Sapiens4"; window.minSize = NSSize(width: 720, height: 540)
        let content = NSView()
        content.addSubview(web); web.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor), web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor), web.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        window.contentView = content; window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Sapiens4Workspace"); window.center()
        showWindow()
        web.loadHTMLString("<body style='background:#191919;color:#eee;font:20px system-ui;padding:48px'>Starting Sapiens4…</body>", baseURL: nil)
        host.checkServer()
    }
    func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func reload() { host.attempts = 0; host.checkServer() }
    func fail(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Sapiens4 could not open"; alert.informativeText = message; alert.runModal()
    }
    func isLocal(_ url: URL) -> Bool { url.scheme == "http" && url.host == "127.0.0.1" && url.port == 4174 }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        switch navigationDecision(url: url, isMainFrame: action.targetFrame?.isMainFrame) {
        case .allow: decisionHandler(.allow)
        case .external:
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        case .cancel: decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, isLocal(url) { webView.load(action.request) }
        return nil
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }
}
