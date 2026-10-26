import Foundation

final class Host {
    var attempts = 0
    var launched = false
    var child: Process?
    let base = URL(string: "http://127.0.0.1:4174")!
    var config: [String: String] = [:]
    let ready: (URL) -> Void
    let fail: (String) -> Void

    init(ready: @escaping (URL) -> Void, fail: @escaping (String) -> Void) {
        self.ready = ready; self.fail = fail
        if let url = Bundle.main.url(forResource: "Launcher", withExtension: "plist"), let data = try? Data(contentsOf: url), let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] { config = values }
    }
    func retryServer() {
        attempts += 1
        if attempts >= 60 {
            fail("The server did not become ready. Choose View → Reload to try again.")
            launched = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkServer() }
    }
    func checkServer() {
        var request = URLRequest(url: base.appendingPathComponent("api/health")); request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse {
                    switch serverReadiness(statusCode: http.statusCode, server: http.value(forHTTPHeaderField: "Server"), data: data) {
                    case .ready:
                        self.attempts = 0
                        self.ready(self.base.appendingPathComponent("workspace/"))
                    case .unavailable:
                        self.fail("Port 4174 is occupied by another service. Stop that service and choose View → Reload.")
                    }
                    return
                }
                if !self.launched {
                    do { try self.startServer(); self.launched = true } catch { self.fail(error.localizedDescription); return }
                }
                self.retryServer()
            }
        }.resume()
    }
    func startServer() throws {
        guard let root = config["Repository"], let python = config["Python"], FileManager.default.fileExists(atPath: root + "/sapiens/__main__.py"), FileManager.default.isExecutableFile(atPath: python) else {
            throw NSError(domain: "Sapiens4", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository or Python was moved. Rebuild the app with macos/build.sh."])
        }
        let logs = URL(fileURLWithPath: config["DataDirectory"] ?? root + "/.sapiens4")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let path = logs.appendingPathComponent("desktop-server.log").path
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); log.seekToEndOfFile()
        let process = Process(); process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "sapiens", "--port", "4174", "--data-dir", logs.path]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = config["Path"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env; process.standardInput = FileHandle.nullDevice
        process.standardOutput = log; process.standardError = log
        try process.run(); child = process
    }
}
