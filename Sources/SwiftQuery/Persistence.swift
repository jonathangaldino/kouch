import Foundation

/// A persisted snapshot (TanStack `PersistedClient`).
public struct PersistedClient: Sendable, Codable {
    public var buster: String
    public var timestamp: Date
    public var clientState: DehydratedState

    public init(buster: String, timestamp: Date, clientState: DehydratedState) {
        self.buster = buster
        self.timestamp = timestamp
        self.clientState = clientState
    }
}

/// Stores and loads one persisted client (TanStack `Persister`).
@MainActor
public protocol QueryPersister: AnyObject {
    func persistClient(_ client: PersistedClient) async throws
    func restoreClient() async throws -> PersistedClient?
    func removeClient() async throws
}

public struct PersistOptions {
    /// Older snapshots are discarded on restore. Default 24 hours.
    public var maxAge: Duration
    /// Change it (e.g. per app version) to discard snapshots written by other versions.
    public var buster: String
    public var dehydrateOptions: DehydrateOptions
    public var hydrateOptions: HydrateOptions

    public init(
        maxAge: Duration = .seconds(24 * 3600), buster: String = "",
        dehydrateOptions: DehydrateOptions = .init(), hydrateOptions: HydrateOptions = .init()
    ) {
        self.maxAge = maxAge
        self.buster = buster
        self.dehydrateOptions = dehydrateOptions
        self.hydrateOptions = hydrateOptions
    }
}

/// A running ``QueryClient/persist(to:options:)``: restoring, then saving on every change.
@MainActor
public final class PersistSession {
    private var subscription: Subscription?
    private var isCancelled = false
    /// Finishes when the restore is done; throws if it failed.
    public private(set) var restored: Task<Void, any Error>!

    init(start: @escaping @MainActor (PersistSession) async throws -> Void) {
        restored = Task { try await start(self) }
    }

    func attach(_ subscription: Subscription) {
        if isCancelled { subscription.cancel() } else { self.subscription = subscription }
    }

    /// Stops saving. If the restore is still running, saving never starts.
    public func cancel() {
        isCancelled = true
        subscription?.cancel()
        subscription = nil
    }
}

extension QueryClient {
    /// Loads the persisted snapshot and hydrates it, unless it is older than `maxAge` or has another
    /// `buster` (then it is removed). On error the stored snapshot is removed and the error rethrown.
    public func restore(from persister: QueryPersister, options: PersistOptions = .init()) async throws {
        do {
            guard let persisted = try await persister.restoreClient() else { return }
            let expired = clock.now.timeIntervalSince(persisted.timestamp) > options.maxAge.timeInterval
            if expired || persisted.buster != options.buster {
                try await persister.removeClient()
            } else {
                hydrate(persisted.clientState, options: options.hydrateOptions)
            }
        } catch {
            try? await persister.removeClient()
            throw error
        }
    }

    /// Writes a snapshot of the client now.
    public func save(to persister: QueryPersister, options: PersistOptions = .init()) async throws {
        try await persister.persistClient(snapshot(options))
    }

    /// Saves after every query or mutation cache change (`added`, `updated`, `removed`). The snapshot is
    /// taken at the change; writing happens asynchronously and its errors are ignored.
    public func subscribePersistence(_ persister: QueryPersister, options: PersistOptions = .init()) -> Subscription {
        let save: @MainActor () -> Void = { [weak self, weak persister] in
            guard let self, let persister else { return }
            let snapshot = snapshot(options)
            Task { try? await persister.persistClient(snapshot) }
        }
        let queries = queryCache.subscribe { event in
            switch event {
            case .added, .updated, .removed: save()
            default: break
            }
        }
        let mutations = mutationCache.subscribe { _ in save() }
        return Subscription {
            queries.cancel()
            mutations.cancel()
        }
    }

    /// Restores, then keeps the persisted snapshot up to date (TanStack `persistQueryClient`).
    @discardableResult
    public func persist(to persister: QueryPersister, options: PersistOptions = .init()) -> PersistSession {
        PersistSession { [weak self] session in
            guard let self else { return }
            try await restore(from: persister, options: options)
            session.attach(subscribePersistence(persister, options: options))
        }
    }

    private func snapshot(_ options: PersistOptions) -> PersistedClient {
        PersistedClient(buster: options.buster, timestamp: clock.now, clientState: dehydrate(options.dehydrateOptions))
    }
}

// MARK: - Encoding

/// Persisted data whose Swift type is not known yet. It is decoded on the first typed read of its key.
struct EncodedQueryData: Sendable {
    var json: QueryKeyValue
}

/// `value` as a JSON value, if it can be encoded.
func jsonValue(_ value: (any Sendable)?) -> QueryKeyValue? {
    switch value {
    case nil: return nil
    case let encoded as EncodedQueryData: return encoded.json
    case let encodable as any Encodable:
        guard let bytes = try? JSONEncoder().encode(encodable) else { return nil }
        return try? JSONDecoder().decode(QueryKeyValue.self, from: bytes)
    default: return nil
    }
}

/// `()` when `T` is `Void` (which can't be encoded, but needs no data to restore).
func voidValue<T>(_ type: T.Type) -> T? { T.self == Void.self ? (() as! T) : nil }

/// `value` as `T`, decoding it first if it is still encoded.
func castOrDecode<T>(_ value: (any Sendable)?, as type: T.Type) -> T? {
    if let typed = value as? T { return typed }
    guard let encoded = value as? EncodedQueryData, let decodable = T.self as? any Decodable.Type,
          let bytes = try? JSONEncoder().encode(encoded.json) else { return nil }
    return (try? JSONDecoder().decode(decodable, from: bytes)) as? T
}

extension DehydratedState: Codable {
    private enum Keys: String, CodingKey { case queries, mutations }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            queries: try c.decode([CodableQuery].self, forKey: .queries).map(\.query),
            mutations: try c.decode([CodableMutation].self, forKey: .mutations).map(\.mutation)
        )
    }

    /// Queries whose data is not `Encodable` are left out; errors are not persisted.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(queries.compactMap(CodableQuery.init), forKey: .queries)
        try c.encode(mutations.map(CodableMutation.init), forKey: .mutations)
    }
}

private struct CodableQuery: Codable {
    var queryKey: QueryKey
    var dehydratedAt: Date
    var data: QueryKeyValue?
    var dataUpdateCount: Int
    var dataUpdatedAt: Date?
    var errorUpdateCount: Int
    var errorUpdatedAt: Date?
    var fetchFailureCount: Int
    var isInvalidated: Bool
    var status: QueryStatus

    init?(_ query: DehydratedQuery) {
        let s = query.state
        let json = jsonValue(s.data)
        if s.data != nil && json == nil { return nil }
        queryKey = query.queryKey
        dehydratedAt = query.dehydratedAt
        data = json
        dataUpdateCount = s.dataUpdateCount
        dataUpdatedAt = s.dataUpdatedAt
        errorUpdateCount = s.errorUpdateCount
        errorUpdatedAt = s.errorUpdatedAt
        fetchFailureCount = s.fetchFailureCount
        isInvalidated = s.isInvalidated
        status = s.status
    }

    var query: DehydratedQuery {
        var s = DehydratedQueryState()
        s.data = data.map { EncodedQueryData(json: $0) }
        s.dataUpdateCount = dataUpdateCount
        s.dataUpdatedAt = dataUpdatedAt
        s.errorUpdateCount = errorUpdateCount
        s.errorUpdatedAt = errorUpdatedAt
        s.fetchFailureCount = fetchFailureCount
        s.isInvalidated = isInvalidated
        s.status = status
        return DehydratedQuery(queryKey: queryKey, state: s, dehydratedAt: dehydratedAt)
    }
}

private struct CodableMutation: Codable {
    var mutationKey: QueryKey?
    var scope: String?
    var context: QueryKeyValue?
    var data: QueryKeyValue?
    var failureCount: Int
    var isPaused: Bool
    var status: MutationStatus
    var variables: QueryKeyValue?
    var submittedAt: Date?

    init(_ mutation: DehydratedMutation) {
        let s = mutation.state
        mutationKey = mutation.mutationKey
        scope = mutation.scope
        context = jsonValue(s.context)
        data = jsonValue(s.data)
        failureCount = s.failureCount
        isPaused = s.isPaused
        status = s.status
        variables = jsonValue(s.variables)
        submittedAt = s.submittedAt
    }

    var mutation: DehydratedMutation {
        let wrap = { (json: QueryKeyValue?) -> (any Sendable)? in json.map { EncodedQueryData(json: $0) } }
        return DehydratedMutation(mutationKey: mutationKey, scope: scope, state: DehydratedMutationState(
            context: wrap(context), data: wrap(data), error: nil, failureCount: failureCount, failureReason: nil,
            isPaused: isPaused, status: status, variables: wrap(variables), submittedAt: submittedAt
        ))
    }
}
