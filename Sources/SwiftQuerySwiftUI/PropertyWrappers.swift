import SwiftQuery
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
        nonisolated(unsafe) let options = options
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: options) }
    }
}

/// An infinite query result that keeps the view up to date (TanStack `useInfiniteQuery`).
/// `$feed` is the ``InfiniteQueryObserver`` (for `fetchNextPage()`).
@propertyWrapper
public struct ObservedInfiniteQuery<Page: Sendable, PageParam: Sendable>: DynamicProperty {
    public typealias Observer = InfiniteQueryObserver<Page, PageParam, InfiniteData<Page, PageParam>>
    @Environment(\.queryClient) private var client
    @State private var model = ObserverModel<Observer>()
    private let options: InfiniteQueryOptions<Page, PageParam>

    public init(_ options: InfiniteQueryOptions<Page, PageParam>) { self.options = options }

    @MainActor public var wrappedValue: InfiniteQueryObserverResult<InfiniteData<Page, PageParam>> { model.result }
    @MainActor public var projectedValue: Observer { model.observer! }

    // SwiftUI always calls update() on the main thread, so the options never leave it.
    public nonisolated func update() {
        let model = model
        let client = client
        nonisolated(unsafe) let options = options
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: options) }
    }
}

/// A mutation's latest state (TanStack `useMutation`). `$save` is the ``MutationObserver``:
/// `try await $save.mutate(draft)`.
@propertyWrapper
public struct ObservedMutation<Variables: Sendable, Data: Sendable, Context: Sendable>: DynamicProperty {
    public typealias Observer = MutationObserver<Variables, Data, Context>
    @Environment(\.queryClient) private var client
    @State private var model = ObserverModel<Observer>()
    private let options: MutationOptions<Variables, Data, Context>

    public init(_ options: MutationOptions<Variables, Data, Context>) { self.options = options }

    @MainActor public var wrappedValue: MutationObserverResult<Variables, Data, Context> { model.result }
    @MainActor public var projectedValue: Observer { model.observer! }

    // SwiftUI always calls update() on the main thread, so the options never leave it.
    public nonisolated func update() {
        let model = model
        let client = client
        nonisolated(unsafe) let options = options
        MainActor.assumeIsolated { model.update(client: requireClient(client), options: options) }
    }
}
