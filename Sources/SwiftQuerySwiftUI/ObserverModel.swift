import Observation
import SwiftQuery

/// An observer a SwiftUI property wrapper can drive.
@MainActor
public protocol AdaptableObserver: AnyObject {
    associatedtype Options
    associatedtype Result

    static func make(client: QueryClient, options: Options) -> Self
    /// What the observer will show for `options`, computed without side effects visible to SwiftUI.
    func optimisticResult(for options: Options, isRestoring: Bool) -> Result
    func apply(_ options: Options)
    func subscribe(_ listener: @escaping @MainActor (Result) -> Void) -> Subscription
}

/// Backs one property wrapper instance. Mirrors TanStack's React adapter: while SwiftUI updates the view
/// it only reads the optimistic result; subscribing and applying new options happen right after, so
/// no observable state changes during a view update.
@MainActor
@Observable
final class ObserverModel<Observer: AdaptableObserver> {
    @ObservationIgnored private(set) var observer: Observer?
    @ObservationIgnored private var displayed: Observer.Result?
    @ObservationIgnored private var subscription: Subscription?
    /// Bumped by every observer notification; reading it makes the view depend on the observer.
    private var version = 0

    nonisolated init() {}

    var result: Observer.Result {
        _ = version
        guard let displayed else { preconditionFailure("Read before SwiftUI called update()") }
        return displayed
    }

    /// While `isRestoring`, nothing mounts or fetches; the view updates again once restoring ends.
    func update(client: QueryClient, options: Observer.Options, isRestoring: Bool = false) {
        if let observer {
            displayed = observer.optimisticResult(for: options, isRestoring: isRestoring)
            if !isRestoring {
                Task { [weak self] in
                    self?.observer?.apply(options)
                    self?.mount()
                }
            }
            return
        }
        let observer = Observer.make(client: client, options: options)
        self.observer = observer
        displayed = observer.optimisticResult(for: options, isRestoring: isRestoring)
        if !isRestoring { Task { [weak self] in self?.mount() } }
    }

    private func mount() {
        guard subscription == nil, let observer else { return }
        subscription = observer.subscribe { [weak self] result in
            guard let self else { return }
            displayed = result
            version += 1
        }
    }

    deinit {
        let subscription = subscription
        Task { @MainActor in subscription?.cancel() }
    }
}

extension QueryObserver: AdaptableObserver {
    public static func make(client: QueryClient, options: QueryObserverOptions<Data, Value>) -> Self {
        Self(client: client, options: options)
    }

    public func optimisticResult(for options: QueryObserverOptions<Data, Value>, isRestoring: Bool) -> QueryObserverResult<Value> {
        getOptimisticResult(options, isRestoring: isRestoring)
    }

    public func apply(_ options: QueryObserverOptions<Data, Value>) { setOptions(options) }
}

extension InfiniteQueryObserver: AdaptableObserver where Value == InfiniteData<Page, PageParam> {
    public static func make(client: QueryClient, options: InfiniteQueryOptions<Page, PageParam>) -> Self {
        Self(client: client, options: options, placeholderData: nil, select: { $0 })
    }

    public func optimisticResult(for options: InfiniteQueryOptions<Page, PageParam>, isRestoring: Bool) -> InfiniteQueryObserverResult<Value> {
        getOptimisticResult(options, isRestoring: isRestoring)
    }

    public func apply(_ options: InfiniteQueryOptions<Page, PageParam>) { setOptions(options) }
}

extension MutationObserver: AdaptableObserver {
    public static func make(client: QueryClient, options: MutationOptions<Variables, Data, Context>) -> Self {
        Self(client: client, options: options)
    }

    public func optimisticResult(
        for options: MutationOptions<Variables, Data, Context>, isRestoring: Bool
    ) -> MutationObserverResult<Variables, Data, Context> {
        currentResult
    }

    public func apply(_ options: MutationOptions<Variables, Data, Context>) { setOptions(options) }
}

extension QueriesObserver: AdaptableObserver where Value == Data, Combined == [QueryObserverResult<Data>] {
    public static func make(client: QueryClient, options: [QueryObserverOptions<Data, Data>]) -> Self {
        Self(client: client, queries: options, combine: { $0 })
    }

    public func optimisticResult(for options: [QueryObserverOptions<Data, Data>], isRestoring: Bool) -> [QueryObserverResult<Data>] {
        getOptimisticResult(options, isRestoring: isRestoring)
    }

    public func apply(_ options: [QueryObserverOptions<Data, Data>]) { setQueries(options) }
}

/// Backs wrappers that derive one value from a cache (TanStack `useIsFetching`, `useMutationState`).
@MainActor
@Observable
final class CacheValueModel<Value> {
    @ObservationIgnored private var subscriptions: [Subscription]?
    private(set) var value: Value?

    nonisolated init() {}

    func update(client: QueryClient, compute: @escaping @MainActor (QueryClient) -> Value) {
        guard subscriptions == nil else { return }
        if value == nil { value = compute(client) }
        // Subscribe after the view update; every cache event recomputes the value.
        Task { [weak self, weak client] in
            guard let self, let client, subscriptions == nil else { return }
            let recompute: @MainActor () -> Void = { [weak self, weak client] in
                guard let self, let client else { return }
                value = compute(client)
            }
            subscriptions = [
                client.queryCache.subscribe { _ in recompute() },
                client.mutationCache.subscribe { _ in recompute() },
            ]
            recompute()
        }
    }

    deinit {
        let subscriptions = subscriptions
        Task { @MainActor in subscriptions?.forEach { $0.cancel() } }
    }
}
