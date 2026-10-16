import Foundation

/// The data of an infinite query: loaded pages and the params that produced them, in order.
public struct InfiniteData<Page: Sendable, PageParam: Sendable>: Sendable {
    public var pages: [Page]
    public var pageParams: [PageParam]

    public init(pages: [Page] = [], pageParams: [PageParam] = []) {
        self.pages = pages
        self.pageParams = pageParams
    }
}

extension InfiniteData: Equatable where Page: Equatable, PageParam: Equatable {}

public struct InfiniteQueryFunctionContext<PageParam: Sendable>: Sendable {
    public let pageParam: PageParam
    public let direction: FetchDirection
    private let base: QueryFunctionContext

    init(base: QueryFunctionContext, pageParam: PageParam, direction: FetchDirection) {
        self.base = base
        self.pageParam = pageParam
        self.direction = direction
    }

    public var queryKey: QueryKey { base.queryKey }
    /// See ``QueryFunctionContext/signal``.
    public var signal: CancellationSignal { base.signal }
}

/// Computes the param of the page after the last one (or before the first one); `nil` means none.
public typealias PageParamFunction<Page, PageParam> =
    @Sendable (_ page: Page, _ allPages: [Page], _ pageParam: PageParam, _ allPageParams: [PageParam]) -> PageParam?

public struct InfiniteQueryOptions<Page: Sendable, PageParam: Sendable> {
    public var key: QueryKey
    public var queryFn: @Sendable (InfiniteQueryFunctionContext<PageParam>) async throws -> Page
    public var initialPageParam: PageParam
    public var getNextPageParam: PageParamFunction<Page, PageParam>
    public var getPreviousPageParam: PageParamFunction<Page, PageParam>?
    /// Keeps at most this many pages, dropping from the opposite end.
    public var maxPages: Int?
    /// Pages to load on a fresh fetch (used by `fetchInfiniteQuery` to prefetch several pages).
    public var pages: Int?
    public var initialData: InfiniteData<Page, PageParam>?
    public var config: QueryConfiguration

    public init(
        key: QueryKey,
        initialPageParam: PageParam,
        getNextPageParam: @escaping PageParamFunction<Page, PageParam>,
        getPreviousPageParam: PageParamFunction<Page, PageParam>? = nil,
        maxPages: Int? = nil,
        pages: Int? = nil,
        staleTime: StaleTime? = nil,
        gcTime: GCTime? = nil,
        retry: RetryPolicy? = nil,
        retryDelay: RetryDelay? = nil,
        networkMode: NetworkMode? = nil,
        enabled: Bool? = nil,
        refetchOnMount: RefetchTrigger? = nil,
        refetchOnWindowFocus: RefetchTrigger? = nil,
        refetchOnReconnect: RefetchTrigger? = nil,
        refetchInterval: Duration? = nil,
        refetchIntervalInBackground: Bool? = nil,
        initialData: InfiniteData<Page, PageParam>? = nil,
        queryFn: @escaping @Sendable (InfiniteQueryFunctionContext<PageParam>) async throws -> Page
    ) {
        self.key = key
        self.queryFn = queryFn
        self.initialPageParam = initialPageParam
        self.getNextPageParam = getNextPageParam
        self.getPreviousPageParam = getPreviousPageParam
        self.maxPages = maxPages
        self.pages = pages
        self.initialData = initialData
        self.config = QueryConfiguration(
            staleTime: staleTime, gcTime: gcTime, retry: retry, retryDelay: retryDelay,
            networkMode: networkMode, enabled: enabled, refetchOnMount: refetchOnMount,
            refetchOnWindowFocus: refetchOnWindowFocus, refetchOnReconnect: refetchOnReconnect,
            refetchInterval: refetchInterval, refetchIntervalInBackground: refetchIntervalInBackground
        )
    }

    /// The plain query these options describe: its data is the `InfiniteData`, fetched page by page.
    public var queryOptions: QueryOptions<InfiniteData<Page, PageParam>> {
        var options = QueryOptions<InfiniteData<Page, PageParam>>(key: key, initialData: initialData)
        options.config = config
        options.behavior = behavior
        return options
    }

    func hasNextPage(_ data: InfiniteData<Page, PageParam>?) -> Bool {
        data.map { nextParam(getNextPageParam, $0) != nil } ?? false
    }

    func hasPreviousPage(_ data: InfiniteData<Page, PageParam>?) -> Bool {
        guard let data, let getPreviousPageParam else { return false }
        return previousParam(getPreviousPageParam, data) != nil
    }

    private var behavior: QueryBehavior<InfiniteData<Page, PageParam>> {
        let queryFn = queryFn
        let initialPageParam = initialPageParam
        let getNext = getNextPageParam
        let getPrevious = getPreviousPageParam
        let maxPages = maxPages
        let pagesToLoad = pages

        return { direction, oldData, context in
            let old = oldData ?? InfiniteData()

            func fetchPage(_ data: InfiniteData<Page, PageParam>, _ param: PageParam?, previous: Bool) async throws -> InfiniteData<Page, PageParam> {
                try Task.checkCancellation()
                guard let param else { return data }
                let page = try await queryFn(InfiniteQueryFunctionContext(
                    base: context, pageParam: param, direction: previous ? .backward : .forward
                ))
                var result = data
                if previous {
                    result.pages.insert(page, at: 0)
                    result.pageParams.insert(param, at: 0)
                    if let maxPages, result.pages.count > maxPages {
                        result.pages.removeLast()
                        result.pageParams.removeLast()
                    }
                } else {
                    result.pages.append(page)
                    result.pageParams.append(param)
                    if let maxPages, result.pages.count > maxPages {
                        result.pages.removeFirst()
                        result.pageParams.removeFirst()
                    }
                }
                return result
            }

            if let direction, !old.pages.isEmpty {
                let previous = direction == .backward
                let param = previous ? getPrevious.flatMap { previousParam($0, old) } : nextParam(getNext, old)
                return try await fetchPage(old, param, previous: previous)
            }

            // Fresh fetch or refetch: reload as many pages as before, starting from the first param.
            let remaining = pagesToLoad ?? old.pages.count
            var result = InfiniteData<Page, PageParam>()
            var current = 0
            repeat {
                let param = current == 0 ? (old.pageParams.first ?? initialPageParam) : nextParam(getNext, result)
                if current > 0 && param == nil { break }
                result = try await fetchPage(result, param, previous: false)
                current += 1
            } while current < remaining
            return result
        }
    }
}

private func nextParam<Page, PageParam>(_ fn: PageParamFunction<Page, PageParam>, _ data: InfiniteData<Page, PageParam>) -> PageParam? {
    guard let page = data.pages.last, let param = data.pageParams.last else { return nil }
    return fn(page, data.pages, param, data.pageParams)
}

private func previousParam<Page, PageParam>(_ fn: PageParamFunction<Page, PageParam>, _ data: InfiniteData<Page, PageParam>) -> PageParam? {
    guard let page = data.pages.first, let param = data.pageParams.first else { return nil }
    return fn(page, data.pages, param, data.pageParams)
}

/// A ``QueryObserverResult`` plus page-loading state. Every base field is available directly.
@dynamicMemberLookup
public struct InfiniteQueryObserverResult<Value: Sendable>: Sendable {
    public var base: QueryObserverResult<Value>
    public var hasNextPage: Bool
    public var hasPreviousPage: Bool
    public var isFetchingNextPage: Bool
    public var isFetchingPreviousPage: Bool
    public var isFetchNextPageError: Bool
    public var isFetchPreviousPageError: Bool
    /// Background refetch of all pages (not loading more).
    public var isRefetching: Bool
    /// A refetch of all pages failed (not loading more).
    public var isRefetchError: Bool

    public subscript<T>(dynamicMember keyPath: KeyPath<QueryObserverResult<Value>, T>) -> T { base[keyPath: keyPath] }
}

/// Observes an infinite query and loads more pages.
///
/// ```swift
/// let feed = InfiniteQueryObserver(client: client, options: InfiniteQueryOptions(
///     key: ["feed"], initialPageParam: 0, getNextPageParam: { page, _, param, _ in page.hasMore ? param + 1 : nil }
/// ) { context in try await api.feed(page: context.pageParam) })
/// await feed.fetchNextPage()
/// ```
@MainActor
public final class InfiniteQueryObserver<Page: Sendable, PageParam: Sendable, Value: Sendable> {
    public typealias Data = InfiniteData<Page, PageParam>
    public private(set) var options: InfiniteQueryOptions<Page, PageParam>
    public let base: QueryObserver<Data, Value>

    public init(
        client: QueryClient,
        options: InfiniteQueryOptions<Page, PageParam>,
        placeholderData: PlaceholderData<Data>? = nil,
        select: @escaping (Data) throws -> Value
    ) {
        self.options = options
        self.base = QueryObserver(client: client, options: QueryObserverOptions(options.queryOptions, placeholderData: placeholderData, select: select))
    }

    public var currentResult: InfiniteQueryObserverResult<Value> { makeResult(base.currentResult) }
    public var hasListeners: Bool { base.hasListeners }

    public func subscribe(_ listener: @escaping @MainActor (InfiniteQueryObserverResult<Value>) -> Void) -> Subscription {
        base.subscribe { [unowned self] in listener(makeResult($0)) }
    }

    public var results: AsyncStream<InfiniteQueryObserverResult<Value>> {
        let (stream, continuation) = AsyncStream.makeStream(of: InfiniteQueryObserverResult<Value>.self)
        var emitted = false
        let subscription = subscribe {
            emitted = true
            continuation.yield($0)
        }
        if !emitted { continuation.yield(currentResult) }
        continuation.onTermination = { _ in Task { @MainActor in subscription.cancel() } }
        return stream
    }

    public func setOptions(_ options: InfiniteQueryOptions<Page, PageParam>) {
        self.options = options
        var observerOptions = base.options
        observerOptions.query = options.queryOptions
        base.setOptions(observerOptions)
    }

    public func getOptimisticResult(_ options: InfiniteQueryOptions<Page, PageParam>, isRestoring: Bool = false) -> InfiniteQueryObserverResult<Value> {
        var observerOptions = base.options
        observerOptions.query = options.queryOptions
        return makeResult(base.getOptimisticResult(observerOptions, isRestoring: isRestoring), options: options)
    }

    /// Loads the page after the last one. With `cancelRefetch` (default) an in-flight fetch is replaced.
    @discardableResult
    public func fetchNextPage(cancelRefetch: Bool = true) async -> InfiniteQueryObserverResult<Value> {
        makeResult(await base.fetch(cancelRefetch: cancelRefetch, direction: .forward))
    }

    /// Loads the page before the first one.
    @discardableResult
    public func fetchPreviousPage(cancelRefetch: Bool = true) async -> InfiniteQueryObserverResult<Value> {
        makeResult(await base.fetch(cancelRefetch: cancelRefetch, direction: .backward))
    }

    /// Refetches every loaded page, in order.
    @discardableResult
    public func refetch(cancelRefetch: Bool = true) async -> InfiniteQueryObserverResult<Value> {
        makeResult(await base.refetch(cancelRefetch: cancelRefetch))
    }

    public func destroy() { base.destroy() }

    private func makeResult(
        _ result: QueryObserverResult<Value>, options: InfiniteQueryOptions<Page, PageParam>? = nil
    ) -> InfiniteQueryObserverResult<Value> {
        let options = options ?? self.options
        let state = base.query.state
        let direction = state.fetchDirection
        let nextError = result.isError && direction == .forward
        let previousError = result.isError && direction == .backward
        let fetchingNext = result.isFetching && direction == .forward
        let fetchingPrevious = result.isFetching && direction == .backward
        return InfiniteQueryObserverResult(
            base: result,
            hasNextPage: options.hasNextPage(state.data),
            hasPreviousPage: options.hasPreviousPage(state.data),
            isFetchingNextPage: fetchingNext,
            isFetchingPreviousPage: fetchingPrevious,
            isFetchNextPageError: nextError,
            isFetchPreviousPageError: previousError,
            isRefetching: result.isRefetching && !fetchingNext && !fetchingPrevious,
            isRefetchError: result.isRefetchError && !nextError && !previousError
        )
    }
}

extension InfiniteQueryObserver where Value == InfiniteData<Page, PageParam> {
    public convenience init(
        client: QueryClient, options: InfiniteQueryOptions<Page, PageParam>, placeholderData: PlaceholderData<Data>? = nil
    ) {
        self.init(client: client, options: options, placeholderData: placeholderData, select: { $0 })
    }
}

extension QueryClient {
    public func fetchInfiniteQuery<Page: Sendable, PageParam: Sendable>(
        _ options: InfiniteQueryOptions<Page, PageParam>
    ) async throws -> InfiniteData<Page, PageParam> {
        try await fetchQuery(options.queryOptions)
    }

    public func prefetchInfiniteQuery<Page: Sendable, PageParam: Sendable>(_ options: InfiniteQueryOptions<Page, PageParam>) async {
        await prefetchQuery(options.queryOptions)
    }

    public func ensureInfiniteQueryData<Page: Sendable, PageParam: Sendable>(
        _ options: InfiniteQueryOptions<Page, PageParam>, revalidateIfStale: Bool = false
    ) async throws -> InfiniteData<Page, PageParam> {
        try await ensureQueryData(options.queryOptions, revalidateIfStale: revalidateIfStale)
    }
}
