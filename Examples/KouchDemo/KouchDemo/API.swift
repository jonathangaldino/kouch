import Foundation

// SWAPI models. Codable so the persister can save them across launches.
struct Page<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var count: Int
    var next: String?
    var results: [Item]
}

struct Person: Codable, Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var height: String
    var mass: String
    var birthYear: String
    var homeworld: String
    var films: [String]
    var url: String
    var id: String { url }
}

struct Planet: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var climate: String
    var terrain: String
    var population: String
    var url: String
    var id: String { url }
}

struct Film: Codable, Sendable, Equatable {
    var title: String
    var episodeId: Int
    var director: String
    var openingCrawl: String
    var url: String
}

enum SWAPI {
    static let base = "https://swapi.dev/api"

    /// URLSession cancels when the calling task is cancelled, so Kouch's cancellation reaches the network.
    static func get<T: Decodable>(_ url: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

/// SWAPI is read-only, so mutations go to this fake server.
actor FavoritesServer {
    static let shared = FavoritesServer()
    private var names: Set<String> = []
    private(set) var failRate = 0.0

    func setFailRate(_ rate: Double) { failRate = rate }

    func fetch() async throws -> Set<String> {
        try await Task.sleep(for: .milliseconds(400))
        return names
    }

    func toggle(_ name: String) async throws -> Set<String> {
        try await Task.sleep(for: .milliseconds(1200))
        if Double.random(in: 0..<1) < failRate { throw DemoError("Server rejected \(name)") }
        names.formSymmetricDifference([name])
        return names
    }
}

/// Fails the first two attempts of every fetch round, to show retries.
actor FlakyServer {
    static let shared = FlakyServer()
    private var attempt = 0

    func fetch() async throws -> String {
        attempt += 1
        try await Task.sleep(for: .milliseconds(300))
        if attempt % 3 != 0 { throw DemoError("Attempt \(attempt) failed") }
        return "Succeeded on attempt \(attempt)"
    }
}

struct DemoError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
