import Foundation

func desktopUpdateNotice(expected: String?, running: String?, app: URL) -> String? {
    guard let expected = expected, !expected.isEmpty, expected != running else { return nil }
    // Read the installed bundle directly; Bundle caches the running version.
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          info["SapiensDesktopRevision"] as? String == expected else {
        return "Desktop update could not be verified. You can keep using Sapiens4."
    }
    // Updates never close the window or launch another instance automatically.
    return "Desktop update installed. Quit and reopen Sapiens4 when you are ready."
}
