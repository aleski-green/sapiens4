import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let browser = Browser()
    var attempts = 0
    var launched = false
    var child: Process?
    let base = URL(string: "http://127.0.0.1:4174")!
    var config: [String: String] = [:]

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
        if let url = Bundle.main.url(forResource: "Launcher", withExtension: "plist"), let data = try? Data(contentsOf: url), let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] { config = values }
        checkServer()
    }
    func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func reload() { attempts = 0; checkServer() }
    func retryServer() {
        attempts += 1
        if attempts >= 60 {
            fail("The server did not become ready. Choose View → Reload to try again.")
            launched = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkServer() }
    }
    func checkServer() {
        var request = URLRequest(url: base.appendingPathComponent("api/health")); request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    switch serverReadiness(statusCode: http.statusCode, server: http.value(forHTTPHeaderField: "Server"), data: data) {
                    case .ready:
                        self.attempts = 0
                        self.web.load(URLRequest(url: self.base.appendingPathComponent("workspace/")))
                    case .unavailable:
                        self.fail("Port 4174 is occupied by another service. Stop that service and choose View → Reload.")
                    }
                    return
                }
                if !self.launched {
                    do { try self.startServer(); self.launched = true } catch { self.fail(error.localizedDescription); return }
                }
                self.retryServer()
            }
        }.resume()
    }
    func startServer() throws {
        guard let root = config["Repository"], let python = config["Python"], FileManager.default.fileExists(atPath: root + "/sapiens/__main__.py"), FileManager.default.isExecutableFile(atPath: python) else {
            throw NSError(domain: "Sapiens4", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository or Python was moved. Rebuild the app with macos/build.sh."])
        }
        let logs = URL(fileURLWithPath: config["DataDirectory"] ?? root + "/.sapiens4")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let path = logs.appendingPathComponent("desktop-server.log").path
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); log.seekToEndOfFile()
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "sapiens", "--port", "4174", "--data-dir", logs.path]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = config["Path"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env; process.standardInput = FileHandle.nullDevice
        process.standardOutput = log; process.standardError = log
        try process.run(); child = process
    }
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
@main
struct DesktopApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
