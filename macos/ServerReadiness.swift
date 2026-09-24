import Foundation

enum ServerReadiness: Equatable { case ready, verifying, unavailable }

func serverReadiness(statusCode: Int, server: String?, data: Data?) -> ServerReadiness {
    guard statusCode == 200, server?.hasPrefix("Sapiens4") == true,
          let data = data,
          let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          health["status"] as? String == "ok" else { return .unavailable }
    // Legacy backends omit desktop_active. Managed candidates expose health
    // before activation while all workspace requests still return HTTP 503.
    return health["desktop_active"] as? Bool == false ? .verifying : .ready
}
