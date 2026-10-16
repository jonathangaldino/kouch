import Foundation

/// What a query needs from the observers attached to it.
@MainActor
protocol QueryObserving: AnyObject {
    var isEnabled: Bool { get }
    var staleTime: StaleTime { get }
    var resultIsStale: Bool { get }
    /// The observer's query options, as `QueryOptions<Data>` of the query it observes.
    var anyQueryOptions: Any { get }
    func onQueryUpdate()
    func shouldFetchOnWindowFocus() -> Bool
    func shouldFetchOnReconnect() -> Bool
    func refetchFromEvent()
}

/// Type-erased view of a cached query, used by filters, cache events and bulk client operations.
@MainActor
public class AnyQuery: Removable {
    public let queryKey: QueryKey
    weak var cache: QueryCache?
    var observers: [any QueryObserving] = []

    init(queryKey: QueryKey, cache: QueryCache, environment: QueryEnvironment) {
        self.queryKey = queryKey
        self.cache = cache
        super.init(environment: environment)
    }

    public var stateSummary: QueryStateSummary { fatalError("abstract") }
    public var observersCount: Int { observers.count }

    /// Has at least one enabled observer.
    public func isActive() -> Bool { observers.contains { $0.isEnabled } }

    public func isDisabled() -> Bool {
        observers.isEmpty ? (isSkipped || !isFetched) : !isActive()
    }

    var isSkipped: Bool { false }
    /// The query's `meta` option.
    public var meta: QueryMeta? { nil }

    public func isStatic() -> Bool { observers.contains { $0.staleTime == .static } }

    /// With observers: stale if any observer's result is stale. Without: only missing or invalidated
    /// data counts as stale.
    public func isStale() -> Bool {
        if !observers.isEmpty { return observers.contains { $0.resultIsStale } }
        let s = stateSummary
        return !s.hasData || s.isInvalidated
    }

    var isFetched: Bool { fatalError("abstract") }

    // MARK: Erased operations

    public func invalidate() { fatalError("abstract") }
    /// Cancels the in-flight fetch, if any, and waits for it to settle.
    public func cancel(revert: Bool = false, silent: Bool = false) async { fatalError("abstract") }
    func cancelNow(_ error: CancelledError) { fatalError("abstract") }
    func reset() { fatalError("abstract") }
    func dehydrated(at date: Date, serialize: ((QueryKey, any Sendable) -> any Sendable)?) -> DehydratedQuery { fatalError("abstract") }
    func applyHydrated(_ query: DehydratedQuery, data: (any Sendable)?) { fatalError("abstract") }
    func destroy() {
        clearGcTimer()
        cancelNow(CancelledError(silent: true))
    }
    /// Starts (or joins) a fetch; returns a task that finishes when it settles. `nil` if paused.
    func refetch(cancelRefetch: Bool, throwOnError: Bool) -> Task<Void, any Error> { fatalError("abstract") }
    func onFocus() { fatalError("abstract") }
    func onOnline() { fatalError("abstract") }

    // MARK: Garbage collection

    override func optionalRemove() {
        if observers.isEmpty && stateSummary.fetchStatus == .idle { cache?.remove(self) }
    }
}

/// Something a cache drops `gcTime` after it became unused.
@MainActor
public class Removable {
    let environment: QueryEnvironment
    private(set) var gcTime: GCTime?
    private var gcTimer: QueryTimer?

    init(environment: QueryEnvironment) { self.environment = environment }

    /// Keeps the largest gcTime ever applied (default 5 minutes).
    func updateGcTime(_ new: GCTime?) {
        gcTime = max(gcTime ?? .duration(.zero), new ?? .fiveMinutes)
    }

    func scheduleGc() {
        clearGcTimer()
        guard case .duration(let delay) = gcTime else { return }
        gcTimer = QueryTimer(clock: environment.clock, after: delay) { [weak self] in self?.optionalRemove() }
    }

    func clearGcTimer() {
        gcTimer?.cancel()
        gcTimer = nil
    }

    func optionalRemove() {}
}

/// A cached query: its state, the in-flight fetch and the observers watching it.
@MainActor
public final class Query<Data: Sendable>: AnyQuery {
    public private(set) var options: QueryOptions<Data>
    public private(set) var state: QueryState<Data>
    private var initialState: QueryState<Data>
    private var revertState: QueryState<Data>?
    private var retryer: Retryer<Data>?
    private let signalConsumed = ConsumedFlag()

    init(options: QueryOptions<Data>, cache: QueryCache, environment: QueryEnvironment, state: QueryState<Data>? = nil) {
        self.options = options
        let initial = QueryState.initial(options, now: environment.clock.now)
        self.initialState = initial
        self.state = state ?? initial
        super.init(queryKey: options.key, cache: cache, environment: environment)
        updateGcTime(options.config.gcTime)
        scheduleGc()
    }

    public override var stateSummary: QueryStateSummary {
        QueryStateSummary(
            status: state.status, fetchStatus: state.fetchStatus, isInvalidated: state.isInvalidated,
            dataUpdatedAt: state.dataUpdatedAt, hasData: state.data != nil
        )
    }

    override var isFetched: Bool { state.dataUpdateCount + state.errorUpdateCount > 0 }
    override var isSkipped: Bool { options.skipToken }
    public override var meta: QueryMeta? { options.config.meta }

    func setOptions(_ options: QueryOptions<Data>) {
        var options = options
        // Like TanStack's sticky queryType: once infinite, always fetched page by page.
        if options.behavior == nil { options.behavior = self.options.behavior }
        self.options = options
        updateGcTime(options.config.gcTime)
        if state.data == nil {
            let defaultState = QueryState.initial(options, now: environment.clock.now)
            if defaultState.data != nil {
                var s = state
                s.data = defaultState.data
                s.dataUpdatedAt = defaultState.dataUpdatedAt
                s.error = nil
                s.isInvalidated = false
                s.status = .success
                setState(s)
                initialState = defaultState
            }
        }
    }

    public func isStaleByTime(_ staleTime: StaleTime) -> Bool {
        let staleTime = staleTime.resolved(for: self)
        guard state.data != nil else { return true }
        if staleTime == .static { return false }
        if state.isInvalidated { return true }
        return timeUntilStale(staleTime) == .zero
    }

    /// Remaining freshness; `nil` means forever.
    func timeUntilStale(_ staleTime: StaleTime) -> Duration? {
        switch staleTime.resolved(for: self) {
        case .infinity, .static, .dynamic: return nil
        case .duration(let d):
            let updated = state.dataUpdatedAt ?? .distantPast
            let remaining = updated.adding(d).timeIntervalSince(environment.clock.now)
            return remaining > 0 ? Duration(timeInterval: remaining) : .zero
        }
    }

    // MARK: Data

    @discardableResult
    func setData(_ data: Data, updatedAt: Date? = nil, manual: Bool) -> Data {
        dispatch(.success(data: data, updatedAt: updatedAt, manual: manual))
        return data
    }

    func setState(_ newState: QueryState<Data>) { dispatch(.setState(newState)) }

    public override func invalidate() {
        if !state.isInvalidated { dispatch(.invalidate) }
    }

    public override func cancel(revert: Bool = false, silent: Bool = false) async {
        let promise = retryer?.promise
        cancelNow(CancelledError(revert: revert, silent: silent))
        _ = try? await promise?.value
    }

    override func cancelNow(_ error: CancelledError) { retryer?.cancel(error) }

    override func reset() {
        destroy()
        setState(initialState)
    }

    /// Back to the initial state while a fetch keeps running (streamed queries in `reset` mode).
    func resetWhileFetching() {
        var s = initialState
        s.fetchStatus = .fetching
        setState(s)
    }

    override func dehydrated(at date: Date, serialize: ((QueryKey, any Sendable) -> any Sendable)?) -> DehydratedQuery {
        var erased: DehydratedQueryState = state.map { $0 as any Sendable }
        if let data = state.data, let serialize { erased.data = serialize(queryKey, data) }
        return DehydratedQuery(queryKey: queryKey, state: erased, dehydratedAt: date)
    }

    /// Merges a newer snapshot into this query (TanStack `hydrate` on an existing query).
    override func applyHydrated(_ query: DehydratedQuery, data: (any Sendable)?) {
        let typed = castOrDecode(data, as: Data.self)
        // shortcut: snapshot data of another type is ignored; deserializeData must return `Data`.
        if data != nil && typed == nil { return }
        var s = query.state.typed(data: typed)
        s.fetchStatus = state.fetchStatus
        if query.state.status == .pending && typed != nil {
            s.status = .success
            s.dataUpdatedAt = query.dehydratedAt
            if state.fetchStatus != .fetching { s.fetchStatus = .idle }
        }
        setState(s)
    }

    // MARK: Observers

    func addObserver(_ observer: any QueryObserving) {
        guard !observers.contains(where: { $0 === observer }) else { return }
        observers.append(observer)
        clearGcTimer()
        cache?.notify(.observerAdded(self))
    }

    func removeObserver(_ observer: any QueryObserving) {
        guard let index = observers.firstIndex(where: { $0 === observer }) else { return }
        observers.remove(at: index)
        if observers.isEmpty {
            if let retryer {
                if signalConsumed.value || (state.fetchStatus == .paused && state.status == .pending) {
                    retryer.cancel(CancelledError(revert: true))
                } else {
                    retryer.cancelRetry()
                }
            }
            scheduleGc()
        }
        cache?.notify(.observerRemoved(self))
    }

    override func onFocus() {
        observers.first { $0.shouldFetchOnWindowFocus() }?.refetchFromEvent()
        retryer?.continue()
    }

    override func onOnline() {
        observers.first { $0.shouldFetchOnReconnect() }?.refetchFromEvent()
        retryer?.continue()
    }

    // MARK: Fetching

    override func refetch(cancelRefetch: Bool, throwOnError: Bool) -> Task<Void, any Error> {
        let promise = fetch(cancelRefetch: cancelRefetch)
        if state.fetchStatus == .paused { return Task {} }
        return Task {
            do { _ = try await promise.value } catch where throwOnError { throw error } catch {}
        }
    }

    /// Starts a fetch, or joins the one in flight. All callers of an in-flight fetch share one
    /// request. With `cancelRefetch` and existing data, the in-flight request is replaced instead.
    @discardableResult
    func fetch(_ newOptions: QueryOptions<Data>? = nil, cancelRefetch: Bool = false, direction: FetchDirection? = nil) -> Promise<Data> {
        if state.fetchStatus != .idle && !(retryer?.isRejected ?? false) {
            if state.data != nil && cancelRefetch {
                cancelNow(CancelledError(silent: true))
            } else if let retryer {
                retryer.continueRetry()
                return retryer.promise
            }
        }

        if let newOptions { setOptions(newOptions) }
        if options.queryFn == nil && options.behavior == nil,
           let observerOptions = observers.lazy.compactMap({ $0.anyQueryOptions as? QueryOptions<Data> })
               .first(where: { $0.queryFn != nil || $0.behavior != nil })
        {
            setOptions(observerOptions)
        }

        let abort = AbortController()
        let key = queryKey
        let consumed = signalConsumed
        let queryFn = options.skipToken ? nil : options.queryFn
        let behavior = options.behavior
        let oldData = state.data
        guard let client = cache?.client else { preconditionFailure("Query \(queryKey) is not in a client's cache") }
        let meta = options.config.meta
        let run: @MainActor () -> Task<Data, any Error> = {
            let context = QueryFunctionContext(queryKey: key, client: client, meta: meta, signal: abort.signal, consumed: consumed)
            consumed.value = false
            let task = Task<Data, any Error> {
                if let behavior { return try await behavior(direction, oldData, context) }
                guard let queryFn else { throw MissingQueryFunctionError(queryKey: key) }
                return try await queryFn(context)
            }
            abort.cancelTask = { task.cancel() }
            return task
        }

        revertState = state
        if state.fetchStatus == .idle || state.fetchDirection != direction { dispatch(.fetch(direction)) }

        let config = options.config
        let retryer = Retryer<Data>(.init(
            run: run,
            onCancel: { [weak self] error in
                if error.revert, let self, var reverted = revertState {
                    reverted.fetchStatus = .idle
                    setState(reverted)
                }
                abort.abort()
            },
            onFail: { [weak self] count, error in self?.dispatch(.failed(count: count, error: error)) },
            onPause: { [weak self] in self?.dispatch(.pause) },
            onContinue: { [weak self] in self?.dispatch(.continue) },
            retry: config.retry ?? 3,
            retryDelay: config.retryDelay ?? .exponential,
            networkMode: config.resolvedNetworkMode,
            environment: environment
        ))
        self.retryer = retryer

        let outer = Promise<Data>()
        retryer.start().onSettle { [weak self] result in
            guard let self else { return outer.settle(result) }
            defer {
                if self.retryer === retryer { self.retryer = nil }
                scheduleGc()
            }
            switch result {
            case .success(let data):
                setData(data, manual: false)
                cache?.config.onSuccess?(data, self)
                cache?.config.onSettled?(data, nil, self)
                outer.resolve(data)
            case .failure(let error as CancelledError) where error.silent:
                // Replaced by a newer fetch: settle with it.
                if let current = self.retryer, current !== retryer { outer.follow(current.promise) } else { outer.reject(error) }
            case .failure(let error as CancelledError) where error.revert:
                if let data = state.data { outer.resolve(data) } else { outer.reject(error) }
            case .failure(let error):
                dispatch(.error(error))
                cache?.config.onError?(error, self)
                cache?.config.onSettled?(state.data, error, self)
                outer.reject(error)
            }
        }
        return outer
    }

    // MARK: Reducer

    private enum Action {
        case failed(count: Int, error: any Error)
        case pause
        case `continue`
        case fetch(FetchDirection?)
        case success(data: Data, updatedAt: Date?, manual: Bool)
        case error(any Error)
        case invalidate
        case setState(QueryState<Data>)
    }

    private func dispatch(_ action: Action) {
        let now = environment.clock.now
        var s = state
        switch action {
        case .failed(let count, let error):
            s.fetchFailureCount = count
            s.fetchFailureReason = error
        case .pause:
            s.fetchStatus = .paused
        case .continue:
            s.fetchStatus = .fetching
        case .fetch(let direction):
            s.fetchDirection = direction
            s.fetchFailureCount = 0
            s.fetchFailureReason = nil
            s.fetchStatus = environment.canFetch(options.config.resolvedNetworkMode) ? .fetching : .paused
            if s.data == nil {
                s.error = nil
                s.status = .pending
            }
        case .success(let data, let updatedAt, let manual):
            s.data = data
            s.dataUpdatedAt = updatedAt ?? now
            s.error = nil
            s.isInvalidated = false
            s.status = .success
            s.dataUpdateCount += 1
            if !manual {
                s.fetchStatus = .idle
                s.fetchFailureCount = 0
                s.fetchFailureReason = nil
            }
            revertState = manual ? s : nil
        case .error(let error):
            s.error = error
            s.errorUpdateCount += 1
            s.errorUpdatedAt = now
            s.fetchFailureCount += 1
            s.fetchFailureReason = error
            s.fetchStatus = .idle
            s.status = .error
            s.isInvalidated = true
        case .invalidate:
            s.isInvalidated = true
        case .setState(let newState):
            s = newState
        }
        state = s
        for observer in observers { observer.onQueryUpdate() }
        cache?.notify(.updated(self))
    }
}

/// Aborts one fetch: cancels the signal handed to the query function and its task.
@MainActor
private final class AbortController {
    let signal = CancellationSignal()
    var cancelTask: (() -> Void)?

    func abort() {
        signal.cancel()
        cancelTask?()
    }
}
