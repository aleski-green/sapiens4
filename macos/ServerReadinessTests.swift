import Foundation

@main
struct ServerReadinessTests {
    static func main() {
        let fixtures: [(Int, String?, String, ServerReadiness)] = [
            (200, "Sapiens4 Python/3.9.6", "{\"status\":\"ok\",\"desktop_active\":false}", .verifying),
            (200, "Sapiens4 Python/3.9.6", "{\"status\":\"ok\",\"desktop_active\":true}", .ready),
            (200, "Sapiens4 Python/3.9.6", "{\"status\":\"ok\"}", .ready),
            (503, "Sapiens4", "{\"status\":\"ok\"}", .unavailable),
            (200, "Other service", "{\"status\":\"ok\"}", .unavailable),
            (200, nil, "{\"status\":\"ok\"}", .unavailable),
            (200, "Sapiens4", "{\"status\":\"error\"}", .unavailable),
            (200, "Sapiens4", "invalid JSON", .unavailable)
        ]
        for (status, server, body, expected) in fixtures {
            precondition(serverReadiness(statusCode: status, server: server, data: Data(body.utf8)) == expected, body)
        }
        // A healthy candidate must remain in the retry path until activation;
        // the same sequence occurs when the updater reports success first.
        let sequence = [false, false, true].map { active in
            serverReadiness(statusCode: 200, server: "Sapiens4", data:
                Data("{\"status\":\"ok\",\"desktop_active\":\(active)}".utf8))
        }
        precondition(sequence == [.verifying, .verifying, .ready])
        print("9 server readiness checks passed")
    }
}
