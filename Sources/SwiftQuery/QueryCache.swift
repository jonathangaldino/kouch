/// Which queries a filter or refetch applies to, by observer activity.
public enum QueryTypeFilter: Sendable {
    case all
    /// Queries with at least one enabled observer.
    case active
    case inactive
}

/// Selects queries for bulk operations (`invalidateQueries`, `cancelQueries`, …).
public struct QueryFilters {
    /// Prefix (or exact, see ``exact``) key to match. `nil` matches every query.
    public var queryKey: QueryKey?
    public var exact: Bool
    public var type: QueryTypeFilter
    public var stale: Bool?
    public var fetchStatus: FetchStatus?
    public var predicate: (@MainActor (AnyQuery) -> Bool)?

    public init(
        queryKey: QueryKey? = nil,
        exact: Bool = false,
        type: QueryTypeFilter = .all,
        stale: Bool? = nil,
        fetchStatus: FetchStatus? = nil,
        predicate: (@MainActor (AnyQuery) -> Bool)? = nil
    ) {
        self.queryKey = queryKey
        self.exact = exact
        self.type = type
        self.stale = stale
        self.fetchStatus = fetchStatus
        self.predicate = predicate
    }

    @MainActor
    public func matches(_ query: AnyQuery) -> Bool {
        if let queryKey, !query.queryKey.matches(queryKey, exact: exact) { return false }
        switch type {
        case .all: break
        case .active: if !query.isActive() { return false }
        case .inactive: if query.isActive() { return false }
        }
        if let stale, query.isStale() != stale { return false }
        if let fetchStatus, query.stateSummary.fetchStatus != fetchStatus { return false }
        if let predicate, !predicate(query) { return false }
        return true
    }
}

public enum QueryCacheEvent {
    case added(AnyQuery)
    case removed(AnyQuery)
    case updated(AnyQuery)
    case observerAdded(AnyQuery)
    case observerRemoved(AnyQuery)
    case observerResultsUpdated(AnyQuery)

    @MainActor
    public var query: AnyQuery {
        switch self {
        case .added(let q), .removed(let q), .updated(let q), .observerAdded(let q), .observerRemoved(let q),
             .observerResultsUpdated(let q): q
        }
    }
}

/// Global callbacks for every query in a cache.
public struct QueryCacheConfig {
    public var onSuccess: (@MainActor (_ data: Any, _ query: AnyQuery) -> Void)?
    public var onError: (@MainActor (_ error: any Error, _ query: AnyQuery) -> Void)?
    public var onSettled: (@MainActor (_ data: Any?, _ error: (any Error)?, _ query: AnyQuery) -> Void)?

    public init(
        onSuccess: (@MainActor (Any, AnyQuery) -> Void)? = nil,
        onError: (@MainActor (any Error, AnyQuery) -> Void)? = nil,
        onSettled: (@MainActor (Any?, (any Error)?, AnyQuery) -> Void)? = nil
    ) {
        self.onSuccess = onSuccess
        self.onError = onError
        self.onSettled = onSettled
    }
}

/// Stores queries by key. One key, one query.
@MainActor
public final class QueryCache {
    public let config: QueryCacheConfig
    var environment: QueryEnvironment!
    private var queries: [QueryKey: AnyQuery] = [:]
    private var order: [QueryKey] = []
    private let listeners = Listeners<QueryCacheEvent>()

    public init(config: QueryCacheConfig = .init()) { self.config = config }

    /// Returns the query for `options.key`, creating it if needed.
    ///
    /// shortcut: one key must always be used with one `Data` type; a mismatch traps. Upgrade to a
    /// typed-key scheme if apps need heterogeneous data under one key.
    func build<Data: Sendable>(_ options: QueryOptions<Data>) -> Query<Data> {
        if let existing = queries[options.key] {
            if let retyped = retypeIfUntyped(existing, as: options) { return retyped }
            guard let typed = existing as? Query<Data> else {
                preconditionFailure("Query \(options.key) holds \(type(of: existing)), not Query<\(Data.self)>")
            }
            return typed
        }
        let query = Query(options: options, cache: self, environment: environment)
        add(query)
        return query
    }

    func add(_ query: AnyQuery) {
        guard queries[query.queryKey] == nil else { return }
        queries[query.queryKey] = query
        order.append(query.queryKey)
        notify(.added(query))
    }

    public func remove(_ query: AnyQuery) {
        guard queries[query.queryKey] === query else { return }
        query.destroy()
        queries[query.queryKey] = nil
        order.removeAll { $0 == query.queryKey }
        notify(.removed(query))
    }

    public func clear() { getAll().forEach(remove) }

    public func get(_ key: QueryKey) -> AnyQuery? { queries[key] }
    public func get<Data: Sendable>(_ key: QueryKey, as: Data.Type = Data.self) -> Query<Data>? {
        guard let existing = queries[key] else { return nil }
        return existing as? Query<Data> ?? retypeIfUntyped(existing, as: QueryOptions<Data>(key: key))
    }

    /// A query hydrated without data has no known type yet; the first typed access fixes it.
    private func retypeIfUntyped<Data: Sendable>(_ existing: AnyQuery, as options: QueryOptions<Data>) -> Query<Data>? {
        guard let untyped = existing as? Query<UntypedData>, untyped.observersCount == 0 else { return nil }
        var typedOptions = options
        typedOptions.config = options.config.merged(over: untyped.options.config)
        let query = Query(options: typedOptions, cache: self, environment: environment, state: untyped.state.map { _ in nil })
        untyped.clearGcTimer()
        queries[options.key] = query
        return query
    }

    /// All queries in insertion order.
    public func getAll() -> [AnyQuery] { order.compactMap { queries[$0] } }

    /// First match; `exact` defaults to `true` here (unlike `findAll`).
    public func find(_ filters: QueryFilters) -> AnyQuery? {
        var filters = filters
        if filters.queryKey != nil && !filters.exact { filters.exact = true }
        return getAll().first(where: filters.matches)
    }

    public func find(_ key: QueryKey) -> AnyQuery? { find(QueryFilters(queryKey: key, exact: true)) }

    public func findAll(_ filters: QueryFilters = .init()) -> [AnyQuery] { getAll().filter(filters.matches) }

    func notify(_ event: QueryCacheEvent) { listeners.send(event) }

    /// Receives every cache event synchronously.
    public func subscribe(_ listener: @escaping @MainActor (QueryCacheEvent) -> Void) -> Subscription {
        listeners.add(listener)
    }

    func onFocus() { getAll().forEach { $0.onFocus() } }
    func onOnline() { getAll().forEach { $0.onOnline() } }
}

extension QueryFilters {
    /// Like `find`, a key filter with exact matching.
    static func exact(_ key: QueryKey) -> QueryFilters { QueryFilters(queryKey: key, exact: true) }
}
