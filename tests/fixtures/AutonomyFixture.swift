// Harmless local UI for the opt-in real-agent autonomy benchmark.
import Cocoa

final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var composer: NSTextField!
    var messages: [String] = []
    let ledger = URL(fileURLWithPath: CommandLine.arguments[1])

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A programmatic Cocoa app needs the normal responder-chain editing menu
        // for Command-V to reach its field editor.
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Sapiens Autonomy Fixture")
        appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"),
                                      ("Copy", #selector(NSText.copy(_:)), "c"),
                                      ("Paste", #selector(NSText.paste(_:)), "v"),
                                      ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editItem.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            to: ledger.deletingLastPathComponent().appendingPathComponent("fixture.pid"), atomically: true, encoding: .utf8)
        window = NSWindow(contentRect: NSRect(x: 150, y: 250, width: 680, height: 430),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sapiens Autonomy Fixture"
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func render() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 430))
        let recipient = NSTextField(labelWithString: "Recipient: Local test recipient")
        recipient.frame = NSRect(x: 20, y: 382, width: 640, height: 24)
        view.addSubview(recipient)
        // Vary child indexes after delivery to exercise fresh target discovery.
        if !messages.isEmpty {
            let count = NSTextField(labelWithString: "Verified local deliveries: \(messages.count)")
            count.frame = NSRect(x: 20, y: 350, width: 640, height: 24)
            view.addSubview(count)
        }
        let history = NSTextField(wrappingLabelWithString: messages.enumerated().map {
            "Outgoing \($0.offset+1): \($0.element)"
        }.joined(separator: "\n"))
        history.frame = NSRect(x: 20, y: 145, width: 640, height: 195)
        view.addSubview(history)
        composer = NSTextField(frame: NSRect(x: 20, y: 80, width: 640, height: 40))
        composer.placeholderString = "Message draft"
        composer.setAccessibilityIdentifier("fixture-composer")
        composer.setAccessibilityLabel("Message draft")
        view.addSubview(composer)
        let send = NSButton(title: "Send Message", target: self, action: #selector(deliver))
        send.frame = NSRect(x: 500, y: 22, width: 160, height: 40)
        send.bezelStyle = .rounded
        view.addSubview(send)
        window.contentView = view
    }

    @objc func deliver() {
        let text = composer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let record: [String: Any] = ["recipient": "Local test recipient", "text": text,
                                    "sequence": messages.count+1,
                                    "time": ISO8601DateFormatter().string(from: Date())]
        do {
            var bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            bytes.append(10)
            if !FileManager.default.fileExists(atPath: ledger.path) {
                FileManager.default.createFile(atPath: ledger.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: ledger)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            messages.append(text)
            render()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = Fixture()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
