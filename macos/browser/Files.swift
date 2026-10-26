import Cocoa
import WebKit

final class TextFiles: NSObject, WKURLSchemeHandler {
    var allowed = Set<String>()
    static func fileURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return url.scheme == "sapiens-file" ? URL(fileURLWithPath: url.path) : url
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, allowed.contains(url.path) else {
            task.didFailWithError(NSError(domain:NSURLErrorDomain,code:NSURLErrorNoPermissionsToReadFile)); return
        }
        do {
            let text = try String(contentsOfFile:url.path,encoding:.utf8)
            let data = Browser.textDocument(text,title:url.lastPathComponent).data(using:.utf8)!
            task.didReceive(URLResponse(url:url,mimeType:"text/html",expectedContentLength:data.count,textEncodingName:"utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
