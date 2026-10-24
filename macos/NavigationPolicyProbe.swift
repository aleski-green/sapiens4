import Foundation

// Native API adapter. RSpec supplies cases and evaluates the returned decisions.
@main
struct NavigationPolicyProbe {
    struct Input: Decodable { let url: String; let mainFrame: Bool? }
    static func main() throws {
        let inputs = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let decisions = inputs.map { String(describing: navigationDecision(url: URL(string: $0.url)!, isMainFrame: $0.mainFrame)) }
        print(String(data: try JSONEncoder().encode(decisions), encoding: .utf8)!)
    }
}
