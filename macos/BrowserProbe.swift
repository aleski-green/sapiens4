import Cocoa
import WebKit

@main
struct BrowserProbe {
    static var observations: [String: Any] = [:]
    static var settled: [Bool] = []
    static func observe(_ name: String, _ value: Any?) { observations[name] = value ?? NSNull() }
    static func wait(_ condition: () -> Bool, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        let ready = condition(); settled.append(ready)
        if !ready {
            observations["settled"] = settled
            print(String(data: try! JSONSerialization.data(withJSONObject: observations), encoding: .utf8)!)
            fputs("WebKit operation timed out at line \(line)\n", stderr); exit(1)
        }
    }
    static func js(_ view: WKWebView, _ source: String) -> Any? {
        var done = false; var result: Any?
        view.evaluateJavaScript(source) { value, error in
            if let error { fputs("JavaScript: \(error)\n", stderr) }
            result = value; done = true
        }
        wait { done }; return result
    }
    // Interactive native fixture for RSpec's external Blindly4 contract. It loads the
    // real workspace UI against an isolated host; stdin controls only window geometry.
    static func accessibilityApp(_ origin: URL) {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let browser = Browser(origin: origin)
        let config = WKWebViewConfiguration()
        config.userContentController.add(browser, name: "browser")
        let shell = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 820), configuration: config)
        browser.shell = shell
        let container = NSView(frame: shell.frame)
        container.addSubview(shell)
        let window = NSWindow(contentRect: shell.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sapiens4 accessibility fixture"; window.contentView = container
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        shell.load(URLRequest(url: origin.appendingPathComponent("workspace/")))
        DispatchQueue.global().async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let size = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                      let width = size["width"], let height = size["height"] else { continue }
                DispatchQueue.main.async {
                    window.setContentSize(NSSize(width: width, height: height))
                    // A top inset simulates the desktop update banner above the shell.
                    shell.frame = NSRect(x: 0, y: 0, width: width, height: height - (size["top"] ?? 0))
                }
            }
            DispatchQueue.main.async { app.terminate(nil) }
        }
        DispatchQueue.main.async { print("READY"); fflush(stdout) }
        withExtendedLifetime(browser) { app.run() }
    }
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--accessibility" {
            accessibilityApp(URL(string: CommandLine.arguments[2])!); return
        }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let shell = WKWebView(frame: NSRect(x:0,y:0,width:1000,height:800))
        let window = NSWindow(contentRect:shell.frame,styleMask:[.titled],backing:.buffered,defer:false)
        let container = NSView(frame: shell.frame)
        container.addSubview(shell)
        window.contentView = container
        shell.loadHTMLString("<script>window.events=[];window.sapiensBrowserEvent=e=>events.push(e)</script>",baseURL:nil)
        wait { !shell.isLoading && shell.url != nil }
        let browser = Browser(); browser.shell = shell
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let note = folder.appendingPathComponent("My notes.md")
        try "# Hello\n<script>window.bad=true</script>".write(to:note,atomically:true,encoding:.utf8)
        var tab: [String:Any] = ["id":"notes","url":note.absoluteString,"zoom":1.5,"command":["seq":"one","action":"navigate"]]
        func sync(dark: Bool = true, visible: Bool = true, rows: [[String:Any]]? = nil) {
            browser.sync(["owner":"sapi","active":"notes","dark":dark,"visible":visible,
                          "workspaces":["sapi":["tabs":rows ?? [tab]]],
                          "rect":["x":400.0,"y":150.0,"width":600.0,"height":600.0]])
        }
        sync(); let native = browser.active!
        wait { !native.view.isLoading && !native.awaitingCommit }
        observe("separateView", native.view !== shell)
        observe("zoom", native.view.pageZoom)
        observe("textURL", TextFiles.fileURL(native.view.url)?.absoluteString); observe("noteURL", note.absoluteString)
        observe("text", js(native.view,"document.body.innerText"))
        observe("textScript", js(native.view,"typeof window.bad"))
        observe("guestBridge", js(native.view,"!!window.webkit?.messageHandlers?.browser"))
        observe("darkBackground", js(native.view,"getComputedStyle(document.documentElement).backgroundColor"))
        sync(dark:false)
        wait { js(native.view,"matchMedia('(prefers-color-scheme:dark)').matches") as? Bool == false }
        observe("lightBackground", js(native.view,"getComputedStyle(document.documentElement).backgroundColor"))
        try "Updated on disk".write(to:note,atomically:true,encoding:.utf8)
        tab["command"] = ["seq":"two","action":"reload"]
        sync(); wait { !native.view.isLoading && !native.awaitingCommit }
        observe("reloadedText", js(native.view,"document.body.innerText"))
        sync(visible:false); observe("hidden", native.view.isHidden)
        let html = folder.appendingPathComponent("page.html")
        try "<title>Live title</title><script>document.title='Changed title'</script><h1>Web page</h1>".write(to:html,atomically:true,encoding:.utf8)
        tab["url"] = html.absoluteString; tab["command"] = ["seq":"three","action":"navigate"]
        sync(); wait { !native.view.isLoading && !native.awaitingCommit && native.view.title == "Changed title" }
        observe("scriptTitle", native.view.title)
        wait { (js(shell,"events.some(e=>e.title==='Changed title' && e.url.endsWith('/page.html'))") as? Bool) == true }
        let pdf = folder.appendingPathComponent("report.pdf")
        let textView = NSTextView(frame:NSRect(x:0,y:0,width:300,height:200)); textView.string = "PDF document"
        try textView.dataWithPDF(inside:textView.bounds).write(to:pdf)
        tab["url"] = pdf.absoluteString; tab["command"] = ["seq":"pdf","action":"navigate"]
        sync(); wait { !native.view.isLoading && !native.awaitingCommit }
        observe("pdfURL", native.view.url?.absoluteString); observe("documentURL", pdf.absoluteString); observe("pdfError", native.error)
        sync(rows:[]); observe("closedTabs", browser.tabs.count)
        if CommandLine.arguments.count == 3 {
            let origin = URL(string: CommandLine.arguments[1])!
            let website = CommandLine.arguments[2]
            let integrated = Browser(origin: origin); integrated.shell = shell
            shell.configuration.userContentController.add(integrated, name: "browser")
            shell.load(URLRequest(url: origin.appendingPathComponent("workspace/")))
            wait { integrated.active != nil && integrated.active?.view.isLoading == false }
            let page = integrated.active!
            observe("openedFile", page.document?.lastPathComponent)
            _ = js(shell, "document.querySelector('#workspace-menu').click();document.querySelector('#open-file').click()")
            wait { window.attachedSheet is NSOpenPanel }
            let picker = window.attachedSheet as! NSOpenPanel
            observe("pickerDirectory", picker.directoryURL?.standardizedFileURL.absoluteString); observe("workspaceDirectory", page.document?.deletingLastPathComponent().standardizedFileURL.absoluteString)
            observe("hiddenFiles", picker.showsHiddenFiles)
            picker.cancel(nil); wait { window.attachedSheet == nil }
            _ = js(shell, "document.querySelector('#add-tab').click()")
            wait { integrated.active !== page && integrated.active?.view.url?.absoluteString == "about:blank" }
            observe("plus", js(shell, "({modal:document.querySelector('#modal').open,focused:document.activeElement.id,value:document.activeElement.value,tabs:document.querySelectorAll('#browser-tabs [data-tab]').length})"))
            _ = js(shell, "document.querySelector('.workspace-tab.active [data-close-tab]').click()")
            wait { integrated.active === page && integrated.tabs.count == 1 }
            _ = js(shell, "document.querySelector('[data-zoom=\"0.1\"]').click()")
            wait { page.view.pageZoom > 1 }
            _ = js(shell, "document.querySelector('#browser-tabs [data-star-tab]').click()")
            wait { js(shell, "document.querySelector('#browser-tabs [data-star-tab]').getAttribute('aria-pressed')==='true'") as? Bool == true }
            _ = js(shell, "document.querySelector('#workspace-menu').click()")
            wait { page.view.isHidden }
            _ = js(shell, "document.querySelector('#workspace-menu').click()")
            wait { !page.view.isHidden }
            func navigate(_ address: String) {
                let encoded = String(data: try! JSONSerialization.data(withJSONObject: [address]), encoding: .utf8)!
                _ = js(shell, "document.querySelector('#browser-address').value=\(encoded)[0];document.querySelector('#browser-address-form').requestSubmit()")
            }
            navigate(website + "/redirect")
            wait { page.view.title == "First page" && !page.view.isLoading }
            wait { js(shell, "document.querySelector('#browser-address').value.endsWith('/one')") as? Bool == true }
            observe("frameDenyingContent", js(page.view,"document.querySelector('h1').textContent"))
            _ = js(page.view, "location.href='/two'")
            wait { page.view.title == "Second page" && !page.view.isLoading }
            wait { js(shell, "document.querySelector('[data-browser-action=back]').disabled") as? Bool == false }
            _ = js(shell, "document.querySelector('[data-browser-action=back]').click()")
            wait { page.view.title == "First page" && !page.view.isLoading }
            wait { js(shell, "document.querySelector('[data-browser-action=forward]').disabled") as? Bool == false }
            _ = js(shell, "document.querySelector('[data-browser-action=forward]').click()")
            wait { page.view.title == "Second page" && !page.view.isLoading }
            wait { js(shell, "document.querySelector('[data-browser-action=back]').disabled") as? Bool == false }
            _ = js(shell, "document.querySelector('[data-browser-action=back]').click()")
            wait { page.view.title == "First page" && !page.view.isLoading }
            wait { js(shell, "document.querySelector('[data-browser-action=back]').disabled") as? Bool == false }
            _ = js(shell, "document.querySelector('[data-browser-action=back]').click()")
            wait { page.view.url?.lastPathComponent == "integration.md" && !page.view.isLoading }
            wait { js(shell, "document.querySelector('#browser-address').value.endsWith('/integration.md')") as? Bool == true }
            _ = js(shell, "document.querySelector('[data-browser-action=reload]').click()")
            wait { page.document?.lastPathComponent == "integration.md" && !page.view.isLoading }
            _ = js(shell, "document.documentElement.dataset.theme='dark'")
            navigate(website + "/text")
            wait { page.view.url?.path == "/text" && !page.view.isLoading }
            observe("webTextBackground", js(page.view,"getComputedStyle(document.body).backgroundColor"))
            _ = js(shell,"document.querySelector('[data-close-tab]').click()")
            wait { integrated.tabs.isEmpty }
            observe("emptyWorkspace", js(shell, "document.querySelector('[data-action=\"new-tab\"]').textContent"))
            shell.configuration.userContentController.removeScriptMessageHandler(forName:"browser")
        }
        observations["settled"] = settled
        print(String(data: try JSONSerialization.data(withJSONObject: observations), encoding: .utf8)!)
    }
}
