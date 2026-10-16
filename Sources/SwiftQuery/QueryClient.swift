import Foundation

/// Which matching queries `invalidateQueries` refetches.
public enum RefetchType: Sendable {
    case active
    case inactive
    case all
    case none
}

/// Entry point: owns the query and mutation caches, defaults, time and device-state sources.
@MainActor
public final class QueryClient {
    public let queryCache: QueryCache
    public let mutationCache: MutationCache
    /// Client-wide query defaults. Per-key defaults and per-query options override them.
    public var defaultOptions: QueryConfiguration
    public var defaultMutationOptions: MutationConfiguration
    public var clock: QueryClock { environment.clock }
    public var onlineManager: OnlineManager { environment.onlineManager }
    public var focusManager: FocusManager { environment.focusManager }

    let environment: QueryEnvironment
    private var queryDefaults: [(key: QueryKey, config: QueryConfiguration)] = []
    private var mutationDefaults: [(key: QueryKey, config: MutationConfiguration)] = []
    private var mountCount = 0
    private var focusSubscription: Subscription?
    private var onlineSubscription: Subscription?

    public init(
        queryCache: QueryCache = QueryCache(),
        mutationCache: MutationCache = MutationCache(),
        defaultOptions: QueryConfiguration = .init(),
        defaultMutationOptions: MutationConfiguration = .init(),
        clock: QueryClock = SystemQueryClock(),
        onlineManager: OnlineManager = .shared,
        focusManager: FocusManager = .shared
    ) {
        self.queryCache = queryCache
        self.mutationCache = mutationCache
        self.defaultOptions = defaultOptions
        self.defaultMutationOptions = defaultMutationOptions
        self.environment = QueryEnvironment(clock: clock, onlineManager: onlineManager, focusManager: focusManager)
        queryCache.environment = environment
        mutationCache.environment = environment
    }

    // MARK: Mounting

    /// Starts reacting to focus and reconnect events (refetches, resuming paused work).
    /// Balanced by ``unmount()``; nested calls are counted.
    public func mount() {
        mountCount += 1
        guard mountCount == 1 else { return }
        focusSubscription = focusManager.subscribe { [weak self] focused in
            guard focused, let self else { return }
            Task { await self.resumePausedMutations(); self.queryCache.onFocus() }
        }
        onlineSubscription = onlineManager.subscribe { [weak self] online in
            guard online, let self else { return }
            Task { await self.resumePausedMutations(); self.queryCache.onOnline() }
        }
    }

    public func unmount() {
        mountCount -= 1
        guard mountCount == 0 else { return }
        focusSubscription?.cancel()
        onlineSubscription?.cancel()
        focusSubscription = nil
        onlineSubscription = nil
    }

    // MARK: Defaults

    public func setQueryDefaults(_ key: QueryKey, _ config: QueryConfiguration) {
        queryDefaults.removeAll { $0.key == key }
        queryDefaults.append((key, config))
    }

    /// Merged defaults of every registered key that prefixes `key` (later registrations win).
    public func queryDefaults(for key: QueryKey) -> QueryConfiguration {
        queryDefaults.filter { key.matches($0.key) }.reduce(QueryConfiguration()) { $1.config.merged(over: $0) }
    }

    public func defaultQueryOptions<Data: Sendable>(_ options: QueryOptions<Data>) -> QueryOptions<Data> {
        var options = options
        options.config = options.config.merged(over: queryDefaults(for: options.key).merged(over: defaultOptions))
        return options
    }

    public func setMutationDefaults(_ key: QueryKey, _ config: MutationConfiguration) {
        mutationDefaults.removeAll { $0.key == key }
        mutationDefaults.append((key, config))
    }

    func defaultMutationConfiguration(for key: QueryKey?) -> MutationConfiguration {
        let keyed = key.map { key in
            mutationDefaults.filter { key.matches($0.key) }.reduce(MutationConfiguration()) { $1.config.merged(over: $0) }
        } ?? MutationConfiguration()
        return keyed.merged(over: defaultMutationOptions)
    }

    // MARK: Reading & writing data

    public func getQueryData<Data: Sendable>(_ key: QueryKey, as: Data.Type = Data.self) -> Data? {
        queryCache.get(key, as: Data.self)?.state.data
    }

    public func getQueryState<Data: Sendable>(_ key: QueryKey, as: Data.Type = Data.self) -> QueryState<Data>? {
        queryCache.get(key, as: Data.self)?.state
    }

    /// Writes data as if it was fetched now (or at `updatedAt`). Creates the query if needed.
    @discardableResult
    public func setQueryData<Data: Sendable>(_ key: QueryKey, _ data: Data, updatedAt: Date? = nil) -> Data {
        setQueryData(key, as: Data.self, updatedAt: updatedAt) { _ in data }!
    }

    /// Updates data from its previous value. Returning `nil` leaves the cache untouched.
    @discardableResult
    public func setQueryData<Data: Sendable>(
        _ key: QueryKey, as: Data.Type = Data.self, updatedAt: Date? = nil, _ updater: (Data?) -> Data?
    ) -> Data? {
        guard let data = updater(getQueryData(key, as: Data.self)) else { return nil }
        return queryCache.build(defaultQueryOptions(QueryOptions<Data>(key: key)))
            .setData(data, updatedAt: updatedAt, manual: true)
    }

    // MARK: Fetching

    /// Resolves with fresh cached data, or fetches. Does not retry unless `options` says so.
    public func fetchQuery<Data: Sendable>(_ options: QueryOptions<Data>) async throws -> Data {
        try await startFetchQuery(options).value
    }

    /// Like ``fetchQuery(_:)`` but never throws and discards the data.
    public func prefetchQuery<Data: Sendable>(_ options: QueryOptions<Data>) async {
        _ = try? await startFetchQuery(options).value
    }

    /// Cached data if any (fresh or stale), otherwise fetches.
    public func ensureQueryData<Data: Sendable>(
        _ options: QueryOptions<Data>, revalidateIfStale: Bool = false
    ) async throws -> Data {
        let defaulted = defaultQueryOptions(options)
        let query = queryCache.build(defaulted)
        guard let cached = query.state.data else { return try await fetchQuery(options) }
        if revalidateIfStale && query.isStaleByTime(defaulted.config.resolvedStaleTime) {
            _ = startFetchQuery(options)
        }
        return cached
    }

    private func startFetchQuery<Data: Sendable>(_ options: QueryOptions<Data>) -> Promise<Data> {
        var defaulted = defaultQueryOptions(options)
        if defaulted.config.retry == nil { defaulted.config.retry = .never }
        let query = queryCache.build(defaulted)
        if query.isStaleByTime(defaulted.config.resolvedStaleTime) {
            return query.fetch(defaulted)
        }
        let promise = Promise<Data>()
        promise.resolve(query.state.data!)
        return promise
    }

    // MARK: Bulk operations

    public func isFetching(_ filters: QueryFilters = .init()) -> Int {
        var filters = filters
        filters.fetchStatus = .fetching
        return queryCache.findAll(filters).count
    }

    public func removeQueries(_ filters: QueryFilters = .init()) {
        queryCache.findAll(filters).forEach(queryCache.remove)
    }

    /// Resets matching queries to their initial state and refetches the active ones.
    public func resetQueries(_ filters: QueryFilters = .init(), cancelRefetch: Bool = true) async {
        let matched = queryCache.findAll(filters)
        matched.forEach { $0.reset() }
        let ids = Set(matched.map(ObjectIdentifier.init))
        await refetchQueries(QueryFilters(type: .active, predicate: { ids.contains(ObjectIdentifier($0)) }), cancelRefetch: cancelRefetch)
    }

    /// Cancels in-flight fetches. With `revert` (default) queries return to their pre-fetch state.
    public func cancelQueries(_ filters: QueryFilters = .init(), revert: Bool = true, silent: Bool = false) async {
        // Cancelling settles each fetch synchronously, so awaiting one by one does not delay the next.
        for query in queryCache.findAll(filters) { await query.cancel(revert: revert, silent: silent) }
    }

    /// Marks matching queries stale and refetches those of `refetchType` (default: active ones).
    public func invalidateQueries(
        _ filters: QueryFilters = .init(), refetchType: RefetchType? = nil, cancelRefetch: Bool = true
    ) async {
        let matched = queryCache.findAll(filters)
        matched.forEach { $0.invalidate() }
        let type: QueryTypeFilter
        switch refetchType {
        case .none?: return
        case .active?: type = .active
        case .inactive?: type = .inactive
        case .all?: type = .all
        case nil: type = filters.type == .all ? .active : filters.type
        }
        var refetchFilters = filters
        refetchFilters.type = type
        await refetchQueries(refetchFilters, cancelRefetch: cancelRefetch)
    }

    /// Refetches matching queries that are neither disabled nor static. Waits for completion,
    /// except for paused queries.
    public func refetchQueries(_ filters: QueryFilters = .init(), cancelRefetch: Bool = true) async {
        let tasks = queryCache.findAll(filters)
            .filter { !$0.isDisabled() && !$0.isStatic() }
            .map { $0.refetch(cancelRefetch: cancelRefetch, throwOnError: false) }
        for task in tasks { _ = try? await task.value }
    }

    public func resumePausedMutations() async {
        guard onlineManager.isOnline else { return }
        await mutationCache.resumePausedMutations()
    }

    public func clear() {
        queryCache.clear()
        mutationCache.clear()
    }
}
