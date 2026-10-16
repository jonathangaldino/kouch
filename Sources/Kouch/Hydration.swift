import Foundation

/// A query's state with its data type erased.
public typealias DehydratedQueryState = QueryState<any Sendable>

extension QueryState where Data == any Sendable {
    func typed<T: Sendable>(data: T?) -> QueryState<T> {
        var state = map { _ in nil as T? }
        state.data = data
        return state
    }
}

public struct DehydratedQuery: Sendable {
    public var queryKey: QueryKey
    public var state: DehydratedQueryState
    public var dehydratedAt: Date
}

public struct DehydratedMutationState: Sendable {
    public var context: (any Sendable)?
    public var data: (any Sendable)?
    public var error: (any Error)?
    public var failureCount: Int
    public var failureReason: (any Error)?
    public var isPaused: Bool
    public var status: MutationStatus
    public var variables: (any Sendable)?
    public var submittedAt: Date?
}

public struct DehydratedMutation: Sendable {
    public var mutationKey: QueryKey?
    public var scope: String?
    public var state: DehydratedMutationState
}

/// A snapshot of a client's caches. Persisting it is up to the app (see `serializeData`).
public struct DehydratedState: Sendable {
    public var queries: [DehydratedQuery]
    public var mutations: [DehydratedMutation]

    public init(queries: [DehydratedQuery] = [], mutations: [DehydratedMutation] = []) {
        self.queries = queries
        self.mutations = mutations
    }
}

public struct DehydrateOptions {
    /// Default: successful queries only.
    public var shouldDehydrateQuery: (@MainActor (AnyQuery) -> Bool)?
    /// Default: paused mutations only (so they can resume after a restart).
    public var shouldDehydrateMutation: (@MainActor (AnyMutation) -> Bool)?
    /// Transforms data on the way out, e.g. to encoded bytes.
    public var serializeData: (@MainActor (QueryKey, any Sendable) -> any Sendable)?

    public init(
        shouldDehydrateQuery: (@MainActor (AnyQuery) -> Bool)? = nil,
        shouldDehydrateMutation: (@MainActor (AnyMutation) -> Bool)? = nil,
        serializeData: (@MainActor (QueryKey, any Sendable) -> any Sendable)? = nil
    ) {
        self.shouldDehydrateQuery = shouldDehydrateQuery
        self.shouldDehydrateMutation = shouldDehydrateMutation
        self.serializeData = serializeData
    }
}

public struct HydrateOptions {
    /// Applied to queries created by hydration.
    public var queries: QueryConfiguration
    /// Applied to mutations created by hydration.
    public var mutations: MutationConfiguration
    /// Transforms data on the way in. Must return the type the app will read the key as; it gets the
    /// key so persisted bytes can be decoded into the right type.
    public var deserializeData: (@MainActor (QueryKey, any Sendable) -> any Sendable)?

    public init(
        queries: QueryConfiguration = .init(),
        mutations: MutationConfiguration = .init(),
        deserializeData: (@MainActor (QueryKey, any Sendable) -> any Sendable)? = nil
    ) {
        self.queries = queries
        self.mutations = mutations
        self.deserializeData = deserializeData
    }
}

/// Placeholder data type of a query hydrated without data; retyped on first typed access.
struct UntypedData: Sendable {}

extension QueryClient {
    /// Snapshots the caches (TanStack `dehydrate`).
    public func dehydrate(_ options: DehydrateOptions = .init()) -> DehydratedState {
        let now = clock.now
        let shouldQuery = options.shouldDehydrateQuery ?? { $0.stateSummary.status == .success }
        let shouldMutation = options.shouldDehydrateMutation ?? { $0.isPaused }
        return DehydratedState(
            queries: queryCache.getAll().filter(shouldQuery).map { $0.dehydrated(at: now, serialize: options.serializeData) },
            mutations: mutationCache.getAll().filter(shouldMutation).map { $0.dehydrated() }
        )
    }

    /// Merges a snapshot into the caches (TanStack `hydrate`). Existing queries are only overwritten by
    /// newer data. Mutations are restored only for keys registered with a typed `setMutationDefaults`.
    public func hydrate(_ dehydrated: DehydratedState, options: HydrateOptions = .init()) {
        for mutation in dehydrated.mutations {
            guard let key = mutation.mutationKey, let factory = mutationFactory(for: key) else { continue }
            factory(mutation, options.mutations)
        }

        for dehydratedQuery in dehydrated.queries {
            let key = dehydratedQuery.queryKey
            let data = dehydratedQuery.state.data.map { raw in options.deserializeData?(key, raw) ?? raw }
            if let existing = queryCache.get(key) {
                let existingUpdatedAt = existing.stateSummary.dataUpdatedAt ?? .distantPast
                if (dehydratedQuery.state.dataUpdatedAt ?? .distantPast) > existingUpdatedAt {
                    existing.applyHydrated(dehydratedQuery, data: data)
                }
            } else if let data {
                buildHydrated(dehydratedQuery, value: data, config: options.queries)
            } else {
                buildHydrated(dehydratedQuery, data: UntypedData?.none, config: options.queries)
            }
        }
    }

    /// Opens the `any Sendable` so the query gets the data's dynamic type.
    private func buildHydrated<T: Sendable>(_ dehydrated: DehydratedQuery, value: T, config: QueryConfiguration) {
        buildHydrated(dehydrated, data: Optional(value), config: config)
    }

    private func buildHydrated<T: Sendable>(_ dehydrated: DehydratedQuery, data: T?, config: QueryConfiguration) {
        var state = dehydrated.state.typed(data: data)
        state.fetchStatus = .idle
        if dehydrated.state.status == .pending && data != nil {
            state.status = .success
            state.dataUpdatedAt = dehydrated.dehydratedAt
        }
        var options = QueryOptions<T>(key: dehydrated.queryKey)
        options.config = config
        let query = Query(options: defaultQueryOptions(options), cache: queryCache, environment: environment, state: state)
        queryCache.add(query)
    }
}
