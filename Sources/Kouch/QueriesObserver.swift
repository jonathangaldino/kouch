/// Observes a dynamic list of queries (one ``QueryObserver`` per entry) and reports their results in
/// input order, optionally combined into one value.
///
/// shortcut: every entry shares one `Data`/`Value` type; use separate observers for mixed types, or
/// upgrade to parameter packs if apps need heterogeneous lists.
@MainActor
public final class QueriesObserver<Data: Sendable, Value: Sendable, Combined: Sendable> {
    public let client: QueryClient
    private var observers: [QueryObserver<Data, Value>] = []
    private var subscriptions: [ObjectIdentifier: Subscription] = [:]
    public private(set) var results: [QueryObserverResult<Value>] = []
    private let combine: ([QueryObserverResult<Value>]) -> Combined
    public private(set) var combinedResult: Combined
    private let listeners = Listeners<[QueryObserverResult<Value>]>()

    /// - Parameter combine: Derives one value from the results. When `Combined` is `Equatable`,
    ///   listeners are only notified if it changed.
    public init(
        client: QueryClient,
        queries: [QueryObserverOptions<Data, Value>],
        combine: @escaping ([QueryObserverResult<Value>]) -> Combined
    ) {
        self.client = client
        self.combine = combine
        self.combinedResult = combine([])
        setQueries(queries)
    }

    public var hasListeners: Bool { !listeners.isEmpty }
    public var queries: [Query<Data>] { observers.map(\.query) }

    public func subscribe(_ listener: @escaping @MainActor ([QueryObserverResult<Value>]) -> Void) -> Subscription {
        let subscription = listeners.add(listener) { [weak self] in
            guard let self, listeners.isEmpty else { return }
            destroy()
        }
        if listeners.count == 1 { observers.forEach(attach) }
        return subscription
    }

    /// The combined value, then every change. Iterating mounts every entry.
    public var combinedResults: AsyncStream<Combined> {
        let (stream, continuation) = AsyncStream.makeStream(of: Combined.self)
        let subscription = subscribe { [unowned self] _ in continuation.yield(combinedResult) }
        continuation.yield(combinedResult)
        continuation.onTermination = { _ in Task { @MainActor in subscription.cancel() } }
        return stream
    }

    public func destroy() {
        listeners.removeAll()
        subscriptions.values.forEach { $0.cancel() }
        subscriptions = [:]
        observers.forEach { $0.destroy() }
    }

    /// What the observer will show for `queries` once applied, without side effects visible to listeners
    /// (TanStack `getOptimisticResult`). Existing observers are matched by key, as in ``setQueries(_:)``.
    public func getOptimisticResult(_ queries: [QueryObserverOptions<Data, Value>], isRestoring: Bool = false) -> [QueryObserverResult<Value>] {
        var available: [QueryKey: [QueryObserver<Data, Value>]] = [:]
        for observer in observers { available[observer.options.query.key, default: []].append(observer) }
        return queries.map { options in
            if var matches = available[options.query.key], !matches.isEmpty {
                let observer = matches.removeFirst()
                available[options.query.key] = matches
                return observer.getOptimisticResult(options, isRestoring: isRestoring)
            }
            return QueryObserver(client: client, options: options).getOptimisticResult(options, isRestoring: isRestoring)
        }
    }

    /// Replaces the list. Entries are matched to existing observers by key, so unchanged keys keep
    /// their observer (no refetch); removed keys unmount; new keys mount.
    public func setQueries(_ queries: [QueryObserverOptions<Data, Value>]) {
        var available: [QueryKey: [QueryObserver<Data, Value>]] = [:]
        for observer in observers { available[observer.options.query.key, default: []].append(observer) }

        let newObservers = queries.map { options -> QueryObserver<Data, Value> in
            if var matches = available[options.query.key], !matches.isEmpty {
                let observer = matches.removeFirst()
                available[options.query.key] = matches
                observer.setOptions(options)
                return observer
            }
            return QueryObserver(client: client, options: options)
        }

        let structuralChange = newObservers.count != observers.count || zip(newObservers, observers).contains { $0 !== $1 }
        let newResults = newObservers.map(\.currentResult)
        let resultChange = structuralChange || zip(newResults, results).contains { !$0.isSame(as: $1) }
        guard resultChange else { return }

        let previous = observers
        observers = newObservers
        let combinedChanged = setResults(newResults)
        guard hasListeners else { return }
        if structuralChange {
            let kept = Set(newObservers.map(ObjectIdentifier.init))
            let old = Set(previous.map(ObjectIdentifier.init))
            for observer in previous where !kept.contains(ObjectIdentifier(observer)) { detach(observer) }
            for observer in newObservers where !old.contains(ObjectIdentifier(observer)) { attach(observer) }
        }
        if combinedChanged || structuralChange { listeners.send(results) }
    }

    private func attach(_ observer: QueryObserver<Data, Value>) {
        subscriptions[ObjectIdentifier(observer)] = observer.subscribe { [weak self, unowned observer] result in
            self?.onUpdate(observer, result)
        }
    }

    private func detach(_ observer: QueryObserver<Data, Value>) {
        subscriptions.removeValue(forKey: ObjectIdentifier(observer))?.cancel()
        observer.destroy()
    }

    private func onUpdate(_ observer: QueryObserver<Data, Value>, _ result: QueryObserverResult<Value>) {
        guard let index = observers.firstIndex(where: { $0 === observer }) else { return }
        var updated = results
        updated[index] = result
        if setResults(updated) { listeners.send(results) }
    }

    /// Stores results and recombines; `false` when an `Equatable` combined value did not change.
    private func setResults(_ newResults: [QueryObserverResult<Value>]) -> Bool {
        results = newResults
        let previous = combinedResult
        combinedResult = combine(newResults)
        return isEqualIfEquatable(previous, combinedResult) != true
    }
}

extension QueriesObserver where Combined == [QueryObserverResult<Value>] {
    public convenience init(client: QueryClient, queries: [QueryObserverOptions<Data, Value>]) {
        self.init(client: client, queries: queries, combine: { $0 })
    }
}

extension QueriesObserver where Value == Data, Combined == [QueryObserverResult<Value>] {
    public convenience init(client: QueryClient, queries: [QueryOptions<Data>]) {
        self.init(client: client, queries: queries.map { QueryObserverOptions($0) }, combine: { $0 })
    }
}

extension QueriesObserver where Value == Data {
    public convenience init(
        client: QueryClient, queries: [QueryOptions<Data>], combine: @escaping ([QueryObserverResult<Value>]) -> Combined
    ) {
        self.init(client: client, queries: queries.map { QueryObserverOptions($0) }, combine: combine)
    }

    public func setQueries(_ queries: [QueryOptions<Data>]) { setQueries(queries.map { QueryObserverOptions($0) }) }
}
