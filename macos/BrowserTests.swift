import Cocoa
import WebKit

@main
struct BrowserTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func wait(_ condition: () -> Bool, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        check(condition(), "WebKit operation timed out at line \(line)")
    }
    static func js(_ view: WKWebView, _ source: String) -> Any? {
        var done = false; var result: Any?
        view.evaluateJavaScript(source) { value, error in
            if let error { fputs("JavaScript: \(error)\n", stderr) }
            result = value; done = true
        }
        wait { done }; return result
    }
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let shell = WKWebView(frame: NSRect(x:0,y:0,width:1000,height:800))
        let window = NSWindow(contentRect:shell.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = shell
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
        check(native.view !== shell, "Tab is a separate native view")
        check(native.view.pageZoom == 1.5, "Zoom applies")
        check(TextFiles.fileURL(native.view.url) == note, "Text views retain their real file URL")
        check(js(native.view,"document.body.innerText") as? String == "# Hello\n<script>window.bad=true</script>","Text is preserved")
        check(js(native.view,"typeof window.bad") as? String == "undefined","Text never executes")
        check(js(native.view,"!!window.webkit?.messageHandlers?.browser") as? Bool == false,"Guest has no host bridge")
        check(js(native.view,"getComputedStyle(document.documentElement).backgroundColor") as? String == "rgb(0, 0, 0)","Dark text background is black")
        sync(dark:false)
        wait { js(native.view,"matchMedia('(prefers-color-scheme:dark)').matches") as? Bool == false }
        check(js(native.view,"getComputedStyle(document.documentElement).backgroundColor") as? String == "rgb(255, 255, 255)","Light text background")
        try "Updated on disk".write(to:note,atomically:true,encoding:.utf8)
        tab["command"] = ["seq":"two","action":"reload"]
        sync(); wait { !native.view.isLoading && !native.awaitingCommit }
        check(js(native.view,"document.body.innerText") as? String == "Updated on disk","Reload rereads file")
        sync(visible:false); check(native.view.isHidden,"Modal or hidden panel hides native view")
        let html = folder.appendingPathComponent("page.html")
        try "<title>Live title</title><script>document.title='Changed title'</script><h1>Web page</h1>".write(to:html,atomically:true,encoding:.utf8)
        tab["url"] = html.absoluteString; tab["command"] = ["seq":"three","action":"navigate"]
        sync(); wait { !native.view.isLoading && !native.awaitingCommit }
        check(native.view.title == "Changed title","HTML title reflects script updates")
        wait { (js(shell,"events.some(e=>e.title==='Changed title' && e.url.endsWith('/page.html'))") as? Bool) == true }
        let pdf = folder.appendingPathComponent("report.pdf")
        let textView = NSTextView(frame:NSRect(x:0,y:0,width:300,height:200)); textView.string = "PDF document"
        try textView.dataWithPDF(inside:textView.bounds).write(to:pdf)
        tab["url"] = pdf.absoluteString; tab["command"] = ["seq":"pdf","action":"navigate"]
        sync(); wait { !native.view.isLoading && !native.awaitingCommit }
        check(native.view.url == pdf && native.error.isEmpty, "PDF opens as a native document")
        sync(rows:[]); check(browser.tabs.isEmpty,"Closing releases native view")
        if CommandLine.arguments.count == 3 {
            let origin = URL(string: CommandLine.arguments[1])!
            let website = CommandLine.arguments[2]
            let integrated = Browser(origin: origin); integrated.shell = shell
            shell.configuration.userContentController.add(integrated, name: "browser")
            shell.load(URLRequest(url: origin.appendingPathComponent("workspace/")))
            wait { integrated.active != nil && integrated.active?.view.isLoading == false }
            let page = integrated.active!
            check(page.document?.lastPathComponent == "integration.md", "App API opens native file tab")
            _ = js(shell, "document.querySelector('[data-zoom=\"0.1\"]').click()")
            wait { page.view.pageZoom > 1 }
            _ = js(shell, "document.querySelector('[data-browser-action=bookmark]').click()")
            _ = js(shell, "document.querySelector('#workspace-menu').click()")
            wait { page.view.isHidden }
            _ = js(shell, "document.querySelector('#close-modal').click()")
            wait { !page.view.isHidden }
            func navigate(_ address: String) {
                let encoded = String(data: try! JSONSerialization.data(withJSONObject: [address]), encoding: .utf8)!
                _ = js(shell, "document.querySelector('#browser-address').value=\(encoded)[0];document.querySelector('#browser-address-form').requestSubmit()")
            }
            navigate(website + "/redirect")
            wait { page.view.title == "First page" && !page.view.isLoading }
            wait { js(shell, "document.querySelector('#browser-address').value.endsWith('/one')") as? Bool == true }
            check(js(page.view,"document.querySelector('h1').textContent") as? String == "Not embeddable", "Native tab loads a page that denies framing")
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
            check(js(page.view,"getComputedStyle(document.body).backgroundColor") as? String == "rgb(0, 0, 0)", "Remote plain text has black background")
            _ = js(shell,"document.querySelector('[data-close-tab]').click()")
            wait { integrated.tabs.isEmpty }
            shell.configuration.userContentController.removeScriptMessageHandler(forName:"browser")
            print("App integration passed: host bridge, controls, bookmarks, modal overlay, redirect URL, frame-denying website, back/forward, close")
        }
        print("Native browser checks passed: files, escaping, title/URL reporting, isolation, zoom, dark/light, reload, visibility, close")
    }
}
