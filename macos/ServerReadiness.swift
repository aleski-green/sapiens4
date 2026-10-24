import Foundation

enum ServerReadiness: Equatable { case ready, unavailable }

func serverReadiness(statusCode: Int, server: String?, data: Data?) -> ServerReadiness {
    guard statusCode == 200, server?.hasPrefix("Sapiens4") == true,
          let data = data,
          let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          health["status"] as? String == "ok" else { return .unavailable }
    return .ready
}
