import Foundation

/// Data to show while a query has none yet. Not written to the cache.
public enum PlaceholderData<Data> {
    case value(Data)
    /// Receives the data of the last query this observer saw with data (e.g. the previous page).
    case function((_ previousData: Data?) -> Data?)

    /// Keeps showing the previous query's data while the new key loads.
    public static var keepPreviousData: PlaceholderData { .function { $0 } }

    func resolve(previous: Data?) -> Data? {
        switch self {
        case .value(let data): data
        case .function(let fn): fn(previous)
        }
    }
}

/// Options for a ``QueryObserver``: the query plus how to derive the result's value.
public struct QueryObserverOptions<Data: Sendable, Value: Sendable> {
    public var query: QueryOptions<Data>
    public var select: ((Data) throws -> Value)?
    public var placeholderData: PlaceholderData<Data>?

    public init(_ query: QueryOptions<Data>, placeholderData: PlaceholderData<Data>? = nil, select: @escaping (Data) throws -> Value) {
        self.query = query
        self.select = select
        self.placeholderData = placeholderData
    }
}

extension QueryObserverOptions where Value == Data {
    public init(_ query: QueryOptions<Data>, placeholderData: PlaceholderData<Data>? = nil) {
        self.query = query
        self.select = nil
        self.placeholderData = placeholderData
    }
}

/// What a consumer renders: query state derived through the observer's options.
public struct QueryObserverResult<Value: Sendable>: Sendable {
    public var status: QueryStatus
    public var fetchStatus: FetchStatus
    public var data: Value?
    public var dataUpdatedAt: Date?
    public var error: (any Error)?
    public var errorUpdatedAt: Date?
    public var errorUpdateCount: Int
    public var failureCount: Int
    public var failureReason: (any Error)?
    public var isFetched: Bool
    public var isFetchedAfterMount: Bool
    public var isPlaceholderData: Bool
    public var isStale: Bool
    public var isEnabled: Bool
    /// Changes whenever `data` may have changed; lets non-`Equatable` data be compared.
    var dataVersion: Int

    public var isPending: Bool { status == .pending }
    public var isSuccess: Bool { status == .success }
    public var isError: Bool { status == .error }
    public var isFetching: Bool { fetchStatus == .fetching }
    public var isPaused: Bool { fetchStatus == .paused }
    /// First load in progress: no data and fetching.
    public var isLoading: Bool { isPending && isFetching }
    /// Background refetch: fetching while data (or an error) is shown.
    public var isRefetching: Bool { isFetching && !isPending }
    public var isLoadingError: Bool { isError && data == nil }
    public var isRefetchError: Bool { isError && data != nil }

    /// Same visible result. Non-`Equatable` data is compared by its update timestamp.
    func isSame(as other: Self) -> Bool {
        status == other.status && fetchStatus == other.fetchStatus && dataUpdatedAt == other.dataUpdatedAt
            && errorUpdatedAt == other.errorUpdatedAt && errorUpdateCount == other.errorUpdateCount
            && failureCount == other.failureCount && (error == nil) == (other.error == nil)
            && (failureReason == nil) == (other.failureReason == nil) && isFetched == other.isFetched
            && isFetchedAfterMount == other.isFetchedAfterMount && isPlaceholderData == other.isPlaceholderData
            && isStale == other.isStale && isEnabled == other.isEnabled
            && sameData(data, other.data, dataVersion == other.dataVersion)
    }
}

private func sameData<Value>(_ a: Value?, _ b: Value?, _ sameVersion: Bool) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case (let a?, let b?): isEqualIfEquatable(a, b) ?? sameVersion
    default: false
    }
}

/// `a == b` when the dynamic type is `Equatable`, otherwise `nil`.
func isEqualIfEquatable(_ a: Any, _ b: Any) -> Bool? {
    (a as? any Equatable)?.isEqual(to: b)
}

extension Equatable {
    fileprivate func isEqual(to other: Any) -> Bool { (other as? Self) == self }
}

/// Watches one query and derives a ``QueryObserverResult`` from its state and this observer's
/// options. Subscribing the first listener mounts it (attaches to the query, maybe fetches);
/// removing the last one unmounts it.
///
/// ```swift
/// let observer = QueryObserver(client: client, options: .init(key: ["user", 123]) { _ in try await api.user(123) })
/// for await result in observer.results { render(result) }
/// ```
@MainActor
public final class QueryObserver<Data: Sendable, Value: Sendable> {
    public let client: QueryClient
    public private(set) var options: QueryObserverOptions<Data, Value>
    private var optionsVersion = 0

    private var currentQuery: Query<Data>
    private var currentQueryInitialState: QueryState<Data>
    private var result: QueryObserverResult<Value>?
    private var lastQueryWithData: Query<Data>?

    private var selectMemo: (key: SelectMemoKey, value: Value)?
    private var selectError: (any Error)?

    private var staleTimer: QueryTimer?
    private var intervalTimer: QueryTimer?
    private var currentRefetchInterval: Duration?
    private let listeners = Listeners<QueryObserverResult<Value>>()

    public init(client: QueryClient, options: QueryObserverOptions<Data, Value>) {
        self.client = client
        var options = options
        options.query = client.defaultQueryOptions(options.query)
        self.options = options
        let query = client.queryCache.build(options.query)
        self.currentQuery = query
        self.currentQueryInitialState = query.state
        query.setOptions(options.query)
        updateResult()
    }

    /// The latest result. Always reflects the query synchronously.
    public var currentResult: QueryObserverResult<Value> { result! }
    public var query: Query<Data> { currentQuery }
    public var hasListeners: Bool { !listeners.isEmpty }

    // MARK: Subscribing

    /// Receives every new result synchronously on the main actor. The first subscriber mounts.
    public func subscribe(_ listener: @escaping @MainActor (QueryObserverResult<Value>) -> Void) -> Subscription {
        let subscription = listeners.add(listener) { [weak self] in
            guard let self, listeners.isEmpty else { return }
            destroy()
        }
        if listeners.count == 1 { onMount() }
        return subscription
    }

    /// The current result followed by every change. Iterating mounts the observer; ending the
    /// iteration (or cancelling its task) unsubscribes.
    public var results: AsyncStream<QueryObserverResult<Value>> {
        let (stream, continuation) = AsyncStream.makeStream(of: QueryObserverResult<Value>.self)
        var emitted = false
        let subscription = subscribe {
            emitted = true
            continuation.yield($0)
        }
        // Mounting may already have emitted (e.g. a fetch started); otherwise start from the current result.
        if !emitted { continuation.yield(currentResult) }
        continuation.onTermination = { _ in Task { @MainActor in subscription.cancel() } }
        return stream
    }

    private func onMount() {
        currentQuery.addObserver(self)
        if shouldFetchOnMount(currentQuery, config) { _ = executeFetch() } else { updateResult() }
        updateTimers()
    }

    /// Detaches from the query and drops all listeners.
    public func destroy() {
        listeners.removeAll()
        clearStaleTimer()
        clearIntervalTimer()
        currentQuery.removeObserver(self)
    }

    // MARK: Options

    public func setOptions(_ newOptions: QueryObserverOptions<Data, Value>) {
        let prevOptions = options
        let prevQuery = currentQuery
        var newOptions = newOptions
        newOptions.query = client.defaultQueryOptions(newOptions.query)
        options = newOptions
        optionsVersion += 1

        updateQuery()
        currentQuery.setOptions(options.query)

        let mounted = hasListeners
        let queryChanged = currentQuery !== prevQuery
        let enabledChanged = config.isEnabled(for: currentQuery) != prevOptions.query.config.isEnabled(for: currentQuery)
        if mounted && shouldFetchOptionally(currentQuery, prevQuery, config, prevOptions.query.config) {
            _ = executeFetch()
        }
        updateResult()
        if mounted && (queryChanged || enabledChanged || config.staleTime(for: currentQuery) != prevOptions.query.config.staleTime(for: currentQuery)) {
            updateStaleTimer()
        }
        let nextInterval = config.refetchInterval(for: currentQuery)
        if mounted && (queryChanged || enabledChanged || nextInterval != currentRefetchInterval) {
            updateIntervalTimer(nextInterval)
        }
    }

    public func setOptions(_ query: QueryOptions<Data>) where Value == Data {
        setOptions(QueryObserverOptions(query, placeholderData: options.placeholderData))
    }

    private var config: QueryConfiguration { options.query.config }

    // MARK: Fetching

    /// Refetches (replacing an in-flight fetch that has data, unless `cancelRefetch` is false) and
    /// returns the resulting result.
    @discardableResult
    public func refetch(cancelRefetch: Bool = true) async -> QueryObserverResult<Value> {
        await fetch(cancelRefetch: cancelRefetch)
    }

    /// Like ``refetch(cancelRefetch:)``; with `throwOnError`, a failed fetch throws instead of returning
    /// an error result.
    @discardableResult
    public func refetch(cancelRefetch: Bool = true, throwOnError: Bool) async throws -> QueryObserverResult<Value> {
        try await fetch(cancelRefetch: cancelRefetch, throwOnError: throwOnError)
    }

    /// Fetches (optionally loading more pages in `direction`) and returns the resulting result.
    @discardableResult
    func fetch(cancelRefetch: Bool, direction: FetchDirection? = nil) async -> QueryObserverResult<Value> {
        (try? await fetch(cancelRefetch: cancelRefetch, direction: direction, throwOnError: false)) ?? currentResult
    }

    func fetch(cancelRefetch: Bool, direction: FetchDirection? = nil, throwOnError: Bool) async throws -> QueryObserverResult<Value> {
        do {
            _ = try await executeFetch(cancelRefetch: cancelRefetch, direction: direction).value
        } catch where throwOnError {
            updateResult()
            throw error
        } catch {}
        updateResult()
        return currentResult
    }

    private func executeFetch(cancelRefetch: Bool = false, direction: FetchDirection? = nil) -> Promise<Data> {
        updateQuery()
        return currentQuery.fetch(options.query, cancelRefetch: cancelRefetch, direction: direction)
    }

    /// What this observer will show for `options` once mounted, without fetching or notifying.
    /// Adapters call it while rendering, before they subscribe or apply new options. It creates the
    /// query in the cache and becomes the current result. While a persisted cache is being restored
    /// (`isRestoring`), the result never shows a fetch, because none starts until the restore is done.
    public func getOptimisticResult(_ options: QueryObserverOptions<Data, Value>, isRestoring: Bool = false) -> QueryObserverResult<Value> {
        var options = options
        options.query = client.defaultQueryOptions(options.query)
        let query = client.queryCache.build(options.query)
        var next = createResult(query: query, options: options, optimistic: true)
        if isRestoring { next.fetchStatus = .idle }
        if result.map({ !next.isSame(as: $0) }) ?? true { result = next }
        return next
    }

    private func updateQuery() {
        let query = client.queryCache.build(options.query)
        guard query !== currentQuery else { return }
        let prevQuery = currentQuery
        currentQuery = query
        currentQueryInitialState = query.state
        if hasListeners {
            prevQuery.removeObserver(self)
            query.addObserver(self)
        }
    }

    // MARK: Fetch decisions

    private func isStale(_ query: Query<Data>, _ config: QueryConfiguration) -> Bool {
        config.isEnabled(for: query) && query.isStaleByTime(config.staleTime(for: query))
    }

    private func shouldFetchOnMount(_ query: Query<Data>, _ config: QueryConfiguration) -> Bool {
        let blockedByError = query.state.status == .error && config.retryOnMount == false
        let shouldLoad = config.isEnabled(for: query) && query.state.data == nil && !blockedByError
        return shouldLoad || (query.state.data != nil && shouldFetch(query, config, on: config.refetchOnMount ?? .ifStale))
    }

    /// After an options change: fetch if the query changed or was disabled, and is stale.
    private func shouldFetchOptionally(
        _ query: Query<Data>, _ prevQuery: Query<Data>, _ config: QueryConfiguration, _ prevConfig: QueryConfiguration
    ) -> Bool {
        (query !== prevQuery || !prevConfig.isEnabled(for: query)) && isStale(query, config)
    }

    private func shouldFetch(_ query: Query<Data>, _ config: QueryConfiguration, on trigger: RefetchTrigger) -> Bool {
        guard config.isEnabled(for: query), config.staleTime(for: query) != .static else { return false }
        switch trigger.resolved(for: query) {
        case .always: return true
        case .ifStale: return isStale(query, config)
        case .never, .dynamic: return false
        }
    }

    // MARK: Timers

    private func updateTimers() {
        updateStaleTimer()
        updateIntervalTimer(config.refetchInterval(for: currentQuery))
    }

    private func updateStaleTimer() {
        clearStaleTimer()
        guard !currentResult.isStale, config.isEnabled(for: currentQuery),
              let remaining = currentQuery.timeUntilStale(config.staleTime(for: currentQuery)) else { return }
        staleTimer = QueryTimer(clock: client.clock, after: remaining + .milliseconds(1)) { [weak self] in
            guard let self, !currentResult.isStale else { return }
            updateResult()
        }
    }

    private func updateIntervalTimer(_ interval: Duration?) {
        clearIntervalTimer()
        currentRefetchInterval = interval
        guard let interval, interval > .zero, config.isEnabled(for: currentQuery) else { return }
        intervalTimer = QueryTimer(clock: client.clock, every: interval) { [weak self] in
            guard let self else { return }
            if config.refetchIntervalInBackground == true || client.focusManager.isFocused { _ = executeFetch() }
        }
    }

    private func clearStaleTimer() {
        staleTimer?.cancel()
        staleTimer = nil
    }

    private func clearIntervalTimer() {
        intervalTimer?.cancel()
        intervalTimer = nil
    }

    // MARK: Result

    private struct SelectMemoKey: Equatable {
        var query: ObjectIdentifier
        var dataUpdateCount: Int
        var dataUpdatedAt: Date?
        var optionsVersion: Int
    }

    private func createResult(
        query: Query<Data>? = nil, options: QueryObserverOptions<Data, Value>? = nil, optimistic: Bool = false
    ) -> QueryObserverResult<Value> {
        let query = query ?? currentQuery
        let options = options ?? self.options
        let config = options.query.config
        var state = query.state
        if optimistic {
            let fetchOnMount = !hasListeners && shouldFetchOnMount(query, config)
            let fetchOptionally = hasListeners && shouldFetchOptionally(query, currentQuery, config, self.options.query.config)
            if fetchOnMount || fetchOptionally {
                state.fetchFailureCount = 0
                state.fetchFailureReason = nil
                state.fetchStatus = environmentCanFetch(query.options) ? .fetching : .paused
                if state.data == nil {
                    state.error = nil
                    state.status = .pending
                }
            }
        }
        let initialState = query === currentQuery ? currentQueryInitialState : query.state
        var status = state.status
        var error = state.error
        var errorUpdatedAt = state.errorUpdatedAt
        var isPlaceholderData = false
        var rawData = state.data
        var data: Value?
        var skipSelect = false

        if let placeholder = options.placeholderData, rawData == nil, status == .pending {
            if let prev = result, prev.isPlaceholderData, prev.data != nil {
                data = prev.data
                skipSelect = true
            } else {
                rawData = placeholder.resolve(previous: lastQueryWithData?.state.data)
            }
            if rawData != nil || data != nil {
                status = .success
                isPlaceholderData = true
            }
        }

        if !skipSelect {
            if let raw = rawData {
                if let select = options.select {
                    let key = SelectMemoKey(
                        query: ObjectIdentifier(query), dataUpdateCount: isPlaceholderData ? -1 : state.dataUpdateCount,
                        dataUpdatedAt: state.dataUpdatedAt, optionsVersion: optionsVersion
                    )
                    if let memo = selectMemo, memo.key == key {
                        data = memo.value
                    } else {
                        do {
                            let value = try select(raw)
                            selectMemo = (key, value)
                            selectError = nil
                            data = value
                        } catch {
                            selectError = error
                        }
                    }
                } else {
                    data = raw as? Value
                }
            } else {
                selectError = nil
            }
        }

        if let selectError {
            error = selectError
            data = selectMemo?.value
            errorUpdatedAt = client.clock.now
            status = .error
            isPlaceholderData = false
        }

        return QueryObserverResult(
            status: status,
            fetchStatus: state.fetchStatus,
            data: data,
            dataUpdatedAt: state.dataUpdatedAt,
            error: error,
            errorUpdatedAt: errorUpdatedAt,
            errorUpdateCount: state.errorUpdateCount,
            failureCount: state.fetchFailureCount,
            failureReason: state.fetchFailureReason,
            isFetched: query.isFetched,
            isFetchedAfterMount: state.dataUpdateCount > initialState.dataUpdateCount
                || state.errorUpdateCount > initialState.errorUpdateCount,
            isPlaceholderData: isPlaceholderData,
            isStale: isStale(query, config),
            isEnabled: config.isEnabled(for: query),
            dataVersion: isPlaceholderData ? -1 : state.dataUpdateCount
        )
    }

    private func updateResult() {
        let next = createResult()
        if currentQuery.state.data != nil { lastQueryWithData = currentQuery }
        if let prev = result, next.isSame(as: prev) { return }
        result = next
        listeners.send(next)
        client.queryCache.notify(.observerResultsUpdated(currentQuery))
    }
}

extension QueryObserver where Value == Data {
    public convenience init(client: QueryClient, options: QueryOptions<Data>) {
        self.init(client: client, options: QueryObserverOptions(options))
    }
}

extension QueryObserver: QueryObserving {
    var isEnabled: Bool { config.isEnabled(for: currentQuery) }
    var staleTime: StaleTime { config.staleTime(for: currentQuery) }
    var resultIsStale: Bool { currentResult.isStale }
    var anyQueryOptions: Any { options.query }

    func onQueryUpdate() {
        updateResult()
        if hasListeners { updateTimers() }
    }

    func shouldFetchOnWindowFocus() -> Bool { shouldFetch(currentQuery, config, on: config.refetchOnWindowFocus ?? .ifStale) }
    func shouldFetchOnReconnect() -> Bool { shouldFetch(currentQuery, config, on: config.resolvedRefetchOnReconnect) }

    private func environmentCanFetch(_ options: QueryOptions<Data>) -> Bool {
        client.environment.canFetch(options.config.resolvedNetworkMode)
    }

    func refetchFromEvent() {
        executeFetch(cancelRefetch: false).onSettle { [weak self] _ in self?.updateResult() }
    }
}
