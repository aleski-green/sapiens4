import Foundation

@main
struct NavigationPolicyTests {
    static func main() {
        let fixtures: [(String, Bool?, NavigationDecision)] = [
            ("about:srcdoc", false, .allow),
            ("about:blank", false, .allow),
            ("https://example.com/document", false, .allow),
            ("http://example.com/document", false, .allow),
            ("blob:http://127.0.0.1:4174/document", false, .allow),
            ("data:text/html,hello", false, .allow),
            ("http://127.0.0.1:4174/workspace/", true, .allow),
            ("about:blank", true, .allow),
            ("https://example.com", true, .external),
            ("https://example.com", nil, .external),
            ("mailto:example@example.com", nil, .external),
            ("about:srcdoc", true, .cancel),
            ("data:text/html,hello", true, .cancel),
            ("file:///etc/passwd", false, .cancel),
            ("javascript:alert(1)", false, .cancel)
        ]
        for (url, frame, expected) in fixtures {
            precondition(navigationDecision(url: URL(string: url)!, isMainFrame: frame) == expected, url)
        }
        print("15 navigation policy checks passed")
    }
}
