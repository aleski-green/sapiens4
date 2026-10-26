import Foundation

enum NavigationDecision: Equatable { case allow, external, cancel }

// Keep embedded workspace documents inside their existing HTML sandbox.
// Only top-level web navigation and new windows go to the system browser.
func navigationDecision(url: URL, isMainFrame: Bool?) -> NavigationDecision {
    let local = url.scheme == "http" && url.host == "127.0.0.1" && url.port == 4174
    if isMainFrame == false {
        if ["about:blank", "about:srcdoc"].contains(url.absoluteString) { return .allow }
        if ["http", "https", "blob", "data"].contains(url.scheme ?? "") { return .allow }
    }
    if local || (isMainFrame == true && url.absoluteString == "about:blank") { return .allow }
    if ["http", "https", "mailto"].contains(url.scheme ?? "") { return .external }
    return .cancel
}
