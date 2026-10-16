import Testing
@testable import SwiftQuery

/// A page function whose calls the test settles by hand.
@MainActor
private final class ControlledPages {
    struct Call {
        var pageParam: Int
        var direction: FetchDirection
        var continuation: CheckedContinuation<String, any Error>
    }

    private(set) var calls: [Call] = []
    var count: Int { calls.count }
    var last: Call { calls[calls.count - 1] }

    var fn: @Sendable (InfiniteQueryFunctionContext<Int>) async throws -> String {
        { @MainActor [self] context in
            try await withCheckedThrowingContinuation {
                calls.append(Call(pageParam: context.pageParam, direction: context.direction, continuation: $0))
            }
        }
    }

    func resolveLast(_ value: String) async {
        last.continuation.resume(returning: value)
        await drain()
    }

    func rejectLast(_ error: any Error) async {
        last.continuation.resume(throwing: error)
        await drain()
    }
}

@MainActor
private final class Counter {
    var count = 0
    var fn: @Sendable (InfiniteQueryFunctionContext<Int>) async throws -> String {
        { @MainActor [self] context in
            count += 1
            return "p\(context.pageParam)"
        }
    }
}

private let next: PageParamFunction<String, Int> = { _, _, param, _ in param < 2 ? param + 1 : nil }

@MainActor
private final class Recorded {
    let observer: InfiniteQueryObserver<String, Int, InfiniteData<String, Int>>
    private var subscription: Subscription?
    init(_ observer: InfiniteQueryObserver<String, Int, InfiniteData<String, Int>>) {
        self.observer = observer
        subscription = observer.subscribe { _ in }
    }
    var current: InfiniteQueryObserverResult<InfiniteData<String, Int>> { observer.currentResult }
}

@MainActor
@Suite("infinite-queries")
struct InfiniteQueryTests {
    private func infinite(
        _ t: TestEnv,
        initialPageParam: Int = 0,
        getNextPageParam: @escaping PageParamFunction<String, Int> = next,
        getPreviousPageParam: PageParamFunction<String, Int>? = nil,
        maxPages: Int? = nil,
        staleTime: StaleTime? = nil,
        retry: RetryPolicy? = nil,
        queryFn: @escaping @Sendable (InfiniteQueryFunctionContext<Int>) async throws -> String
    ) -> Recorded {
        Recorded(InfiniteQueryObserver(client: t.client, options: InfiniteQueryOptions(
            key: ["list"], initialPageParam: initialPageParam, getNextPageParam: getNextPageParam,
            getPreviousPageParam: getPreviousPageParam, maxPages: maxPages, staleTime: staleTime, retry: retry,
            queryFn: queryFn
        )))
    }

    @Test("[inf-001] initial fetch loads the first page")
    func initialPage() async {
        let t = TestEnv()
        let fn = ControlledPages()
        let o = infinite(t, queryFn: fn.fn)
        await t.settle()
        #expect(fn.count == 1)
        #expect(fn.last.pageParam == 0)
        #expect(fn.last.direction == .forward)
        await fn.resolveLast("p0")
        #expect(o.current.data == InfiniteData(pages: ["p0"], pageParams: [0]))
        #expect(o.current.hasNextPage)
        #expect(!o.current.hasPreviousPage)
    }

    @Test("[inf-002] fetchNextPage appends the next page")
    func nextPage() async {
        let t = TestEnv()
        let fn = ControlledPages()
        let o = infinite(t, queryFn: fn.fn)
        await t.settle()
        await fn.resolveLast("p0")
        Task { await o.observer.fetchNextPage() }
        await t.settle()
        #expect(o.current.isFetchingNextPage)
        #expect(!o.current.isRefetching)
        #expect(o.current.isFetching)
        #expect(fn.last.pageParam == 1)
        #expect(fn.last.direction == .forward)
        await fn.resolveLast("p1")
        #expect(o.current.data?.pages == ["p0", "p1"])
        #expect(o.current.data?.pageParams == [0, 1])
        #expect(!o.current.isFetchingNextPage)
    }

    @Test("[inf-003] no next page")
    func noNextPage() async {
        let t = TestEnv()
        let counter = Counter()
        let o = infinite(t, queryFn: counter.fn)
        await t.settle()
        await o.observer.fetchNextPage()
        await o.observer.fetchNextPage()
        #expect(!o.current.hasNextPage)
        let before = counter.count
        await o.observer.fetchNextPage()
        await t.settle()
        #expect(counter.count == before)
        #expect(o.current.data?.pages == ["p0", "p1", "p2"])
    }

    @Test("[inf-004] fetchPreviousPage prepends")
    func previousPage() async {
        let t = TestEnv()
        let fn = ControlledPages()
        let o = infinite(
            t, initialPageParam: 5, getNextPageParam: { _, _, _, _ in nil },
            getPreviousPageParam: { _, _, first, _ in first - 1 }, queryFn: fn.fn
        )
        await t.settle()
        await fn.resolveLast("p5")
        #expect(o.current.hasPreviousPage)
        Task { await o.observer.fetchPreviousPage() }
        await t.settle()
        #expect(o.current.isFetchingPreviousPage)
        #expect(fn.last.pageParam == 4)
        #expect(fn.last.direction == .backward)
        await fn.resolveLast("p4")
        #expect(o.current.data?.pages == ["p4", "p5"])
        #expect(o.current.data?.pageParams == [4, 5])
    }

    @Test("[inf-005] refetch reloads every page in order")
    func refetchAll() async {
        let t = TestEnv()
        let fn = ControlledPages()
        let o = infinite(t, staleTime: .infinity, queryFn: fn.fn)
        await t.settle()
        await fn.resolveLast("p0")
        Task { await o.observer.fetchNextPage() }
        await t.settle()
        await fn.resolveLast("p1")
        Task { await o.observer.refetch() }
        await t.settle()
        #expect(fn.count == 3)
        #expect(fn.last.pageParam == 0)
        await fn.resolveLast("p0-v2")
        #expect(fn.count == 4)
        #expect(fn.last.pageParam == 1)
        await fn.resolveLast("p1-v2")
        #expect(o.current.data?.pages == ["p0-v2", "p1-v2"])
        #expect(o.current.data?.pageParams == [0, 1])
    }

    @Test("[inf-006] refetch stops when there is no next page anymore")
    func refetchStops() async {
        let t = TestEnv()
        let stop = Flag()
        let counter = Counter()
        let o = infinite(t, getNextPageParam: { page, all, param, params in
            stop.isSet ? nil : next(page, all, param, params)
        }, staleTime: .infinity, queryFn: counter.fn)
        await t.settle()
        await o.observer.fetchNextPage()
        await o.observer.fetchNextPage()
        #expect(o.current.data?.pageParams == [0, 1, 2])
        stop.set()
        counter.count = 0
        await o.observer.refetch()
        #expect(counter.count == 1)
        #expect(o.current.data?.pages.count == 1)
    }

    @Test("[inf-007] maxPages")
    func maxPages() async {
        let t = TestEnv()
        let o = infinite(t, maxPages: 2, queryFn: Counter().fn)
        await t.settle()
        await o.observer.fetchNextPage()
        await o.observer.fetchNextPage()
        #expect(o.current.data?.pageParams == [1, 2])
        #expect(o.current.data?.pages == ["p1", "p2"])
    }

    @Test("[inf-008] fetchNextPage error")
    func nextPageError() async {
        let t = TestEnv()
        let fn = ControlledPages()
        let o = infinite(t, retry: false, queryFn: fn.fn)
        await t.settle()
        await fn.resolveLast("p0")
        Task { await o.observer.fetchNextPage() }
        await t.settle()
        await fn.rejectLast(TestError())
        #expect(o.current.status == .error)
        #expect(o.current.isFetchNextPageError)
        #expect(!o.current.isRefetchError)
        #expect(o.current.data?.pages == ["p0"])
    }

    @Test("[inf-009] fetchInfiniteQuery with pages")
    func fetchInfiniteQueryPages() async throws {
        let t = TestEnv()
        let counter = Counter()
        let data = try await t.client.fetchInfiniteQuery(InfiniteQueryOptions(
            key: ["list"], initialPageParam: 0, getNextPageParam: next, pages: 3, queryFn: counter.fn
        ))
        #expect(data.pageParams == [0, 1, 2])
        #expect(counter.count == 3)
    }

    @Test("[inf-010] fetchNextPage joins an in-flight fetch with cancelRefetch: false")
    func nextPageJoins() async {
        let t = TestEnv()
        let fn = ControlledPages()
        let o = infinite(t, queryFn: fn.fn)
        await t.settle()
        await fn.resolveLast("p0")
        Task { await o.observer.fetchNextPage() }
        await t.settle()
        Task { await o.observer.fetchNextPage(cancelRefetch: false) }
        await t.settle()
        #expect(fn.count == 2)
    }
}

/// A thread-safe boolean for `@Sendable` page-param functions.
final class Flag: @unchecked Sendable {
    private var value = false
    var isSet: Bool { value }
    func set() { value = true }
}
