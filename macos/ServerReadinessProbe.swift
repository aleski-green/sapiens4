import Foundation

// Native API adapter. RSpec supplies cases and evaluates readiness.
@main
struct ServerReadinessProbe {
    struct Input: Decodable { let status: Int; let server: String?; let body: String }
    static func main() throws {
        let inputs = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let states = inputs.map { String(describing: serverReadiness(statusCode: $0.status, server: $0.server, data: Data($0.body.utf8))) }
        print(String(data: try JSONEncoder().encode(states), encoding: .utf8)!)
    }
}
