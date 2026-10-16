import Foundation

/// Key-value byte storage for ``StoragePersister`` (TanStack `AsyncStorage`).
public protocol QueryStorage: Sendable {
    func getItem(_ key: String) async throws -> Foundation.Data?
    func setItem(_ key: String, _ value: Foundation.Data) async throws
    func removeItem(_ key: String) async throws
}

/// Stores each item as a file in `directory`.
public struct FileQueryStorage: QueryStorage {
    public let directory: URL

    /// Defaults to `Application Support/SwiftQuery`.
    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "SwiftQuery", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    private func url(_ key: String) -> URL { directory.appending(path: key) }

    public func getItem(_ key: String) async throws -> Foundation.Data? {
        let url = url(key)
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        return try Foundation.Data(contentsOf: url)
    }

    public func setItem(_ key: String, _ value: Foundation.Data) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try value.write(to: url(key), options: .atomic)
    }

    public func removeItem(_ key: String) async throws {
        let url = url(key)
        if FileManager.default.fileExists(atPath: url.path()) { try FileManager.default.removeItem(at: url) }
    }
}

/// Keeps items in memory (tests, previews).
public actor InMemoryQueryStorage: QueryStorage {
    private var items: [String: Foundation.Data] = [:]
    public init() {}
    public func getItem(_ key: String) -> Foundation.Data? { items[key] }
    public func setItem(_ key: String, _ value: Foundation.Data) { items[key] = value }
    public func removeItem(_ key: String) { items[key] = nil }
}

/// Decides what to write after a failed write (e.g. storage full); `nil` gives up.
public typealias PersistRetryer = @MainActor (_ client: PersistedClient, _ error: any Error, _ errorCount: Int) -> PersistedClient?

/// Drops the query with the oldest data, so the next write is smaller.
public let removeOldestQuery: PersistRetryer = { client, _, _ in
    var client = client
    let queries = client.clientState.queries
    guard let oldest = queries.indices.min(by: {
        (queries[$0].state.dataUpdatedAt ?? .distantPast) < (queries[$1].state.dataUpdatedAt ?? .distantPast)
    }) else { return nil }
    client.clientState.queries.remove(at: oldest)
    return client
}

/// Persists the client as JSON in a ``QueryStorage`` (TanStack `createAsyncStoragePersister`).
/// Writes are throttled: the first runs immediately, later ones at most once per `throttle`, with the
/// latest snapshot.
@MainActor
public final class StoragePersister: QueryPersister {
    private let storage: any QueryStorage
    private let key: String
    private let throttle: Duration
    private let clock: QueryClock
    private let retry: PersistRetryer?
    private let encode: (PersistedClient) throws -> Foundation.Data
    private let decode: (Foundation.Data) throws -> PersistedClient

    private var nextExecution = Date.distantPast
    private var latest: PersistedClient?
    private var isExecuting = false
    private var isScheduled = false

    public init(
        storage: any QueryStorage = FileQueryStorage(),
        key: String = "SWIFT_QUERY_OFFLINE_CACHE",
        throttle: Duration = .seconds(1),
        clock: QueryClock = SystemQueryClock(),
        retry: PersistRetryer? = nil,
        encode: @escaping (PersistedClient) throws -> Foundation.Data = { try JSONEncoder().encode($0) },
        decode: @escaping (Foundation.Data) throws -> PersistedClient = { try JSONDecoder().decode(PersistedClient.self, from: $0) }
    ) {
        self.storage = storage
        self.key = key
        self.throttle = throttle
        self.clock = clock
        self.retry = retry
        self.encode = encode
        self.decode = decode
    }

    public func persistClient(_ client: PersistedClient) async throws {
        latest = client
        guard !isScheduled else { return }
        isScheduled = true
        while isExecuting { try? await clock.sleep(for: throttle) }
        while clock.now < nextExecution {
            try? await clock.sleep(for: Duration(timeInterval: nextExecution.timeIntervalSince(clock.now)))
        }
        isScheduled = false
        isExecuting = true
        if let latest { await save(latest) }
        nextExecution = clock.now.adding(throttle)
        isExecuting = false
    }

    public func restoreClient() async throws -> PersistedClient? {
        guard let bytes = try await storage.getItem(key) else { return nil }
        return try decode(bytes)
    }

    public func removeClient() async throws { try await storage.removeItem(key) }

    private func save(_ client: PersistedClient) async {
        var client: PersistedClient? = client
        var errorCount = 0
        while let current = client {
            do {
                try await storage.setItem(key, encode(current))
                return
            } catch {
                errorCount += 1
                client = retry?(current, error, errorCount)
            }
        }
    }
}
