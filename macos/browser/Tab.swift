import Cocoa
import WebKit

final class BrowserTab {
    let owner: String
    let id: String
    let files = TextFiles()
    let view: WKWebView
    var sequence = ""
    var document: URL?
    var requested: URL?
    var error = ""
    var awaitingCommit = false
    var observations: [NSKeyValueObservation] = []
    init(owner: String, id: String, script: String) {
        self.owner = owner; self.id = id
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(files, forURLScheme:"sapiens-file")
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
    }
}
