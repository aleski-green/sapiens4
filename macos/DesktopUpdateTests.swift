import Foundation

@main
struct DesktopUpdateTests {
    static func main() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let info = app.appendingPathComponent("Contents/Info.plist")
        func install(_ revision: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["SapiensDesktopRevision": revision], format: .xml, options: 0)
            try data.write(to: info, options: .atomic)
        }
        precondition(desktopUpdateNotice(expected: "new", running: "old", app: app)?.contains("could not be verified") == true)
        try install("old")
        // Reproduce the loop: status claims new, but reopening still starts old.
        for _ in 0..<3 {
            precondition(desktopUpdateNotice(expected: "new", running: "old", app: app)?.contains("could not be verified") == true)
        }
        try install("new")
        precondition(desktopUpdateNotice(expected: "new", running: "old", app: app)?.contains("when you are ready") == true)
        precondition(desktopUpdateNotice(expected: "new", running: "new", app: app) == nil)
        precondition(desktopUpdateNotice(expected: nil, running: "old", app: app) == nil)
        try install("")
        precondition(desktopUpdateNotice(expected: "", running: "old", app: app) == nil)
        try Data("invalid plist".utf8).write(to: info)
        precondition(desktopUpdateNotice(expected: "new", running: "old", app: app)?.contains("could not be verified") == true)
        print("Desktop restart regression checks passed")
    }
}
