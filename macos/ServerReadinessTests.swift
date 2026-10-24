import Foundation

@main
struct ServerReadinessTests {
    static func main() {
        let fixtures: [(Int, String?, String, ServerReadiness)] = [
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
        print("6 server readiness checks passed")
    }
}
