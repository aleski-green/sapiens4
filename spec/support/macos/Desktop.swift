import Cocoa
import WebKit

// A native window around the shipped workspace and production browser adapter.
// RSpec interacts only through Blindly4. No script evaluation or test bridge.
@main
final class Desktop: NSObject {
    let app = NSApplication.shared
    var shell: WKWebView!
    var browser: Browser!
    var window: NSWindow!

    @objc func reload() { shell.reload() }
    @objc func quit() { app.terminate(nil) }

    static func main() {
        let fixture = Desktop()
        fixture.run()
    }

    func run() {
        app.setActivationPolicy(.regular)
        let origin = URL(string: CommandLine.arguments[1])!
        browser = Browser(origin: origin)
        let config = WKWebViewConfiguration()
        // Each process owns an isolated browser profile; reload retains its data.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(browser!, name: "browser")
        shell = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 820), configuration: config)
        browser.shell = shell
        let container = NSView(frame: shell.frame)
        container.addSubview(shell)
        window = NSWindow(contentRect: shell.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sapiens4 behavior fixture"
        window.contentView = container
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        item.submenu = NSMenu(title: "Sapiens4")
        for (title, action, key) in [("Reload workspace", #selector(reload), "r"), ("Quit", #selector(quit), "q")] {
            let command = NSMenuItem(title: title, action: action, keyEquivalent: key)
            command.target = self
            item.submenu!.addItem(command)
        }
        app.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        shell.load(URLRequest(url: origin.path == "/" || origin.path.isEmpty ? origin.appendingPathComponent("workspace/") : origin))
        DispatchQueue.global().async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let size = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                      let width = size["width"], let height = size["height"] else { continue }
                DispatchQueue.main.async {
                    self.window.setContentSize(NSSize(width: width, height: height))
                    self.shell.frame = NSRect(x: 0, y: 0, width: width, height: height - (size["top"] ?? 0))
                }
            }
            DispatchQueue.main.async { self.app.terminate(nil) }
        }
        print("READY"); fflush(stdout)
        app.run()
    }
}
