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
