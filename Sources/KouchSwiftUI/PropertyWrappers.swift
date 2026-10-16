import Kouch
import SwiftUI

/// A query result that keeps the view up to date (TanStack `useQuery`).
///
/// ```swift
/// struct UserView: View {
///     @ObservedQuery var user: QueryObserverResult<User>
///     init(id: Int) {
///         _user = ObservedQuery(QueryOptions(key: ["user", .int(id)]) { _ in try await api.user(id) })
///     }
///     var body: some View {
///         if let user = user.data { Text(user.name) } else if user.isLoading { ProgressView() }
///     }
/// }
/// ```
/// `$user` is the underlying ``QueryObserver`` (for `refetch()`). For `select`, use a ``QueryObserver``
/// directly; in views, deriving values in `body` is usually enough.
@propertyWrapper
public struct ObservedQuery<Data: Sendable>: DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.isRestoringQueries) private var isRestoring
    @State private var model = ObserverModel<QueryObserver<Data, Data>>()
    private let options: QueryObserverOptions<Data, Data>

    public init(_ options: QueryOptions<Data>, placeholderData: PlaceholderData<Data>? = nil) {
        self.options = QueryObserverOptions(options, placeholderData: placeholderData)
    }

    @MainActor public var wrappedValue: QueryObserverResult<Data> { model.result }
    @MainActor public var projectedValue: QueryObserver<Data, Data> { model.observer! }

    // SwiftUI always calls update() on the main thread, so the options never leave it.
    public nonisolated func update() {
        let model = model
        let client = client
        let isRestoring = isRestoring
        nonisolated(unsafe) let options = options
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: options, isRestoring: isRestoring) }
    }
}

/// An infinite query result that keeps the view up to date (TanStack `useInfiniteQuery`).
/// `$feed` is the ``InfiniteQueryObserver`` (for `fetchNextPage()`).
@propertyWrapper
public struct ObservedInfiniteQuery<Page: Sendable, PageParam: Sendable>: DynamicProperty {
    public typealias Observer = InfiniteQueryObserver<Page, PageParam, InfiniteData<Page, PageParam>>
    @Environment(\.queryClient) private var client
    @Environment(\.isRestoringQueries) private var isRestoring
    @State private var model = ObserverModel<Observer>()
    private let options: InfiniteQueryOptions<Page, PageParam>

    public init(_ options: InfiniteQueryOptions<Page, PageParam>) { self.options = options }

    @MainActor public var wrappedValue: InfiniteQueryObserverResult<InfiniteData<Page, PageParam>> { model.result }
    @MainActor public var projectedValue: Observer { model.observer! }

    // SwiftUI always calls update() on the main thread, so the options never leave it.
    public nonisolated func update() {
        let model = model
        let client = client
        let isRestoring = isRestoring
        nonisolated(unsafe) let options = options
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: options, isRestoring: isRestoring) }
    }
}

/// A mutation's latest state (TanStack `useMutation`). `$save` is the ``MutationObserver``:
/// `try await $save.mutate(draft)`.
@propertyWrapper
public struct ObservedMutation<Variables: Sendable, Data: Sendable, Context: Sendable>: DynamicProperty {
    public typealias Observer = MutationObserver<Variables, Data, Context>
    @Environment(\.queryClient) private var client
    @Environment(\.isRestoringQueries) private var isRestoring
    @State private var model = ObserverModel<Observer>()
    private let options: MutationOptions<Variables, Data, Context>

    public init(_ options: MutationOptions<Variables, Data, Context>) { self.options = options }

    @MainActor public var wrappedValue: MutationObserverResult<Variables, Data, Context> { model.result }
    @MainActor public var projectedValue: Observer { model.observer! }

    // SwiftUI always calls update() on the main thread, so the options never leave it.
    public nonisolated func update() {
        let model = model
        let client = client
        let isRestoring = isRestoring
        nonisolated(unsafe) let options = options
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: options, isRestoring: isRestoring) }
    }
}

/// A query result derived through `select` (TanStack `useQuery({ select })`). Declare both types:
/// `@ObservedSelectQuery<User, String> var name: QueryObserverResult<String>`.
@propertyWrapper
public struct ObservedSelectQuery<Data: Sendable, Value: Sendable>: DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.isRestoringQueries) private var isRestoring
    @State private var model = ObserverModel<QueryObserver<Data, Value>>()
    private let options: QueryObserverOptions<Data, Value>

    public init(_ options: QueryOptions<Data>, placeholderData: PlaceholderData<Data>? = nil, select: @escaping (Data) throws -> Value) {
        self.options = QueryObserverOptions(options, placeholderData: placeholderData, select: select)
    }

    @MainActor public var wrappedValue: QueryObserverResult<Value> { model.result }
    @MainActor public var projectedValue: QueryObserver<Data, Value> { model.observer! }

    // SwiftUI always calls update() on the main thread, so the options never leave it.
    public nonisolated func update() {
        let model = model
        let client = client
        let isRestoring = isRestoring
        nonisolated(unsafe) let options = options
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: options, isRestoring: isRestoring) }
    }
}

/// Results of a dynamic list of queries, in order (TanStack `useQueries`). `$items` is the ``QueriesObserver``.
@propertyWrapper
public struct ObservedQueries<Data: Sendable>: DynamicProperty {
    @Environment(\.queryClient) private var client
    @Environment(\.isRestoringQueries) private var isRestoring
    @State private var model = ObserverModel<QueriesObserver<Data, Data, [QueryObserverResult<Data>]>>()
    private let queries: [QueryObserverOptions<Data, Data>]

    public init(_ queries: [QueryOptions<Data>]) { self.queries = queries.map { QueryObserverOptions($0) } }

    @MainActor public var wrappedValue: [QueryObserverResult<Data>] { model.result }
    @MainActor public var projectedValue: QueriesObserver<Data, Data, [QueryObserverResult<Data>]> { model.observer! }

    // SwiftUI always calls update() on the main thread, so the options never leave it.
    public nonisolated func update() {
        let model = model
        let client = client
        let isRestoring = isRestoring
        nonisolated(unsafe) let queries = queries
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: queries, isRestoring: isRestoring) }
    }
}

/// How many matching queries are fetching (TanStack `useIsFetching`).
@propertyWrapper
public struct ObservedIsFetching: DynamicProperty {
    @Environment(\.queryClient) private var client
    @State private var model = CacheValueModel<Int>()
    private let filters: QueryFilters

    public init(_ filters: QueryFilters = .init()) { self.filters = filters }

    @MainActor public var wrappedValue: Int { model.value ?? 0 }

    public nonisolated func update() {
        let model = model
        let client = client
        nonisolated(unsafe) let filters = filters
        MainActor.assumeIsolated { model.update(client: requireClient(client)) { $0.isFetching(filters) } }
    }
}

/// How many matching mutations are pending (TanStack `useIsMutating`).
@propertyWrapper
public struct ObservedIsMutating: DynamicProperty {
    @Environment(\.queryClient) private var client
    @State private var model = CacheValueModel<Int>()
    private let filters: MutationFilters

    public init(_ filters: MutationFilters = .init()) { self.filters = filters }

    @MainActor public var wrappedValue: Int { model.value ?? 0 }

    public nonisolated func update() {
        let model = model
        let client = client
        nonisolated(unsafe) let filters = filters
        MainActor.assumeIsolated { model.update(client: requireClient(client)) { $0.isMutating(filters) } }
    }
}

/// Values selected from every matching mutation, oldest first (TanStack `useMutationState`).
/// The default selection is each mutation's type-erased state.
@propertyWrapper
public struct ObservedMutationState<Value>: DynamicProperty {
    @Environment(\.queryClient) private var client
    @State private var model = CacheValueModel<[Value]>()
    private let filters: MutationFilters
    private let select: @MainActor (AnyMutation) -> Value

    public init(_ filters: MutationFilters = .init(), select: @escaping @MainActor (AnyMutation) -> Value) {
        self.filters = filters
        self.select = select
    }

    @MainActor public var wrappedValue: [Value] { model.value ?? [] }

    public nonisolated func update() {
        let model = model
        let client = client
        nonisolated(unsafe) let filters = filters
        nonisolated(unsafe) let select = select
        MainActor.assumeIsolated { model.update(client: requireClient(client)) { $0.mutationCache.findAll(filters).map(select) } }
    }
}

extension ObservedMutationState where Value == DehydratedMutationState {
    public init(_ filters: MutationFilters = .init()) { self.init(filters, select: { $0.stateSnapshot }) }
}
