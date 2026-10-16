/// Global callbacks for every mutation in a cache. Values are type-erased.
public struct MutationCacheConfig {
    public var onMutate: (@MainActor (_ variables: Any, _ mutation: AnyMutation) async -> Void)?
    public var onSuccess: (@MainActor (_ data: Any, _ variables: Any, _ context: Any?, _ mutation: AnyMutation) async -> Void)?
    public var onError: (@MainActor (_ error: any Error, _ variables: Any, _ context: Any?, _ mutation: AnyMutation) async -> Void)?
    public var onSettled: (@MainActor (_ data: Any?, _ error: (any Error)?, _ variables: Any, _ context: Any?, _ mutation: AnyMutation) async -> Void)?

    public init(
        onMutate: (@MainActor (Any, AnyMutation) async -> Void)? = nil,
        onSuccess: (@MainActor (Any, Any, Any?, AnyMutation) async -> Void)? = nil,
        onError: (@MainActor (any Error, Any, Any?, AnyMutation) async -> Void)? = nil,
        onSettled: (@MainActor (Any?, (any Error)?, Any, Any?, AnyMutation) async -> Void)? = nil
    ) {
        self.onMutate = onMutate
        self.onSuccess = onSuccess
        self.onError = onError
        self.onSettled = onSettled
    }
}

public enum MutationCacheEvent {
    case added(AnyMutation)
    case removed(AnyMutation)
    case updated(AnyMutation)
}

public struct MutationFilters {
    public var mutationKey: QueryKey?
    public var exact: Bool
    public var status: MutationStatus?
    public var predicate: (@MainActor (AnyMutation) -> Bool)?

    public init(mutationKey: QueryKey? = nil, exact: Bool = false, status: MutationStatus? = nil, predicate: (@MainActor (AnyMutation) -> Bool)? = nil) {
        self.mutationKey = mutationKey
        self.exact = exact
        self.status = status
        self.predicate = predicate
    }

    @MainActor
    public func matches(_ mutation: AnyMutation) -> Bool {
        if let mutationKey {
            guard let key = mutation.mutationKey, key.matches(mutationKey, exact: exact) else { return false }
        }
        if let status, mutation.status != status { return false }
        if let predicate, !predicate(mutation) { return false }
        return true
    }
}

/// Holds every mutation (each `mutate` call creates one) and serializes scoped mutations.
@MainActor
public final class MutationCache {
    public let config: MutationCacheConfig
    var environment: QueryEnvironment!
    private var mutations: [AnyMutation] = []
    private var nextId = 0
    private let listeners = Listeners<MutationCacheEvent>()

    public init(config: MutationCacheConfig = .init()) { self.config = config }

    func build<V, D, C>(_ options: MutationOptions<V, D, C>, state: MutationState<V, D, C>? = nil) -> Mutation<V, D, C> {
        nextId += 1
        let mutation = Mutation(options: options, mutationId: nextId, cache: self, environment: environment, state: state)
        mutations.append(mutation)
        notify(.added(mutation))
        return mutation
    }

    public func remove(_ mutation: AnyMutation) {
        guard let index = mutations.firstIndex(where: { $0 === mutation }) else { return }
        mutations.remove(at: index)
        notify(.removed(mutation))
    }

    public func clear() {
        let all = mutations
        mutations = []
        all.forEach { notify(.removed($0)) }
    }

    public func getAll() -> [AnyMutation] { mutations }

    public func findAll(_ filters: MutationFilters = .init()) -> [AnyMutation] { mutations.filter(filters.matches) }

    public func subscribe(_ listener: @escaping @MainActor (MutationCacheEvent) -> Void) -> Subscription {
        listeners.add(listener)
    }

    func notify(_ event: MutationCacheEvent) { listeners.send(event) }

    /// A scoped mutation may run only if no earlier mutation of its scope is pending.
    func canRun(_ mutation: AnyMutation) -> Bool {
        guard let scope = mutation.scope else { return true }
        let firstPending = mutations.first { $0.scope == scope && $0.status == .pending }
        return firstPending == nil || firstPending === mutation
    }

    /// After a scoped mutation settles, wakes the next paused one in its scope.
    func runNext(_ mutation: AnyMutation) {
        guard let scope = mutation.scope,
              let next = mutations.first(where: { $0 !== mutation && $0.scope == scope && $0.isPaused }) else { return }
        Task { await next.continue() }
    }

    func resumePausedMutations() async {
        let tasks = mutations.filter(\.isPaused).map { mutation in Task { await mutation.continue() } }
        for task in tasks { await task.value }
    }
}

extension QueryClient {
    public func isMutating(_ filters: MutationFilters = .init()) -> Int {
        var filters = filters
        filters.status = .pending
        return mutationCache.findAll(filters).count
    }
}
