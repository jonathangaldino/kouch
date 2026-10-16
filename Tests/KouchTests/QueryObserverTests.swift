import Testing
@testable import Kouch

@MainActor
@Suite("query-observer")
struct QueryObserverTests {
    @Test("[obs-001] mount with empty cache fetches; result is optimistic")
    func mountFetches() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        #expect(o.current.status == .pending)
        #expect(o.current.fetchStatus == .fetching)
        #expect(o.current.isLoading)
        await t.settle()
        #expect(fn.count == 1)
        await fn.resolveLast("A")
        let last = o.results.last!
        #expect(last.status == .success)
        #expect(last.data == "A")
        #expect(!last.isFetching)
    }

    @Test("[obs-002] fresh cached data is served immediately without fetching")
    func freshServed() async throws {
        let t = TestEnv()
        let fn = Immediate("A")
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn))
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: fn.fn))
        #expect(o.current.status == .success)
        #expect(o.current.data == "A")
        #expect(!o.current.isFetching)
        #expect(!o.current.isStale)
        await t.settle()
        #expect(fn.count == 1)
    }

    @Test("[obs-003] stale cached data is served immediately and refetched in background")
    func staleServedAndRefetched() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        #expect(o.current.status == .success)
        #expect(o.current.data == "A")
        #expect(o.current.isFetching)
        #expect(o.current.isRefetching)
        await t.settle()
        #expect(fn.count == 1)
        await fn.resolveLast("B")
        #expect(o.current.data == "B")
        #expect(!o.current.isFetching)
    }

    @Test("[obs-004] enabled: false")
    func disabled() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], enabled: false, queryFn: fn.fn))
        await t.settle()
        #expect(o.current.status == .pending)
        #expect(o.current.fetchStatus == .idle)
        #expect(!o.current.isLoading)
        #expect(!o.current.isEnabled)
        #expect(!o.current.isStale)
        #expect(fn.count == 0)
        o.observer.setOptions(QueryOptions(key: ["a"], enabled: true, queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 1)
        #expect(o.current.fetchStatus == .fetching)
    }

    @Test("[obs-005] select derives data without changing the cache")
    func select() async {
        let t = TestEnv()
        let o = t.observe(QueryObserverOptions(QueryOptions(key: ["a"], queryFn: Immediate(["count": 2]).fn)) { $0["count"]! * 10 })
        await t.settle()
        #expect(o.current.data == 20)
        #expect(t.client.getQueryData(["a"], as: [String: Int].self) == ["count": 2])
    }

    @Test("[obs-006] placeholderData")
    func placeholder() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryObserverOptions(QueryOptions(key: ["a"], queryFn: fn.fn), placeholderData: .value("ph")))
        #expect(o.current.status == .success)
        #expect(o.current.data == "ph")
        #expect(o.current.isPlaceholderData)
        #expect(o.current.isFetching)
        #expect(t.client.getQueryData(["a"], as: String.self) == nil)
        await t.settle()
        await fn.resolveLast("A")
        #expect(o.current.data == "A")
        #expect(!o.current.isPlaceholderData)
    }

    @Test("[obs-007] refetch() returns the new result")
    func refetch() async {
        let t = TestEnv()
        let fn = Immediate { $0 == 0 ? "A" : "B" }
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        let r = await o.observer.refetch()
        #expect(r.data == "B")
        #expect(fn.count == 2)
    }

    @Test("[obs-008] changing the key switches queries")
    func keyChange() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a", 1], queryFn: fn.fn))
        await t.settle()
        await fn.resolveLast("one")
        o.observer.setOptions(QueryOptions(key: ["a", 2], queryFn: fn.fn))
        await t.settle()
        #expect(fn.last.key == ["a", 2])
        #expect(o.current.status == .pending)
        #expect(o.current.isFetching)
        #expect(o.current.data == nil)
        let q1 = t.cache.find(["a", 1])!
        #expect(q1.observersCount == 0)
        #expect(t.client.getQueryData(["a", 1], as: String.self) == "one")
        await fn.resolveLast("two")
        #expect(o.current.data == "two")
    }

    @Test("[obs-009] listener notifications and unsubscribe")
    func notifications() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await fn.resolveLast("A")
        let fetchingIdx = o.results.firstIndex { $0.isFetching }
        let successIdx = o.results.firstIndex { $0.status == .success && $0.data == "A" }
        #expect(fetchingIdx != nil)
        #expect(successIdx != nil && successIdx! > fetchingIdx!)
        o.unsubscribe()
        let before = o.results.count
        t.client.setQueryData(["a"], "B")
        await t.settle()
        #expect(o.results.count == before)
    }

    @Test("[obs-010] refetchInterval")
    func refetchInterval() async {
        let t = TestEnv()
        let fn = Immediate("A")
        let o = t.observe(QueryOptions(key: ["a"], refetchInterval: .milliseconds(1000), queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 1)
        await t.advance(1000)
        #expect(fn.count == 2)
        await t.advance(1000)
        #expect(fn.count == 3)
        o.unsubscribe()
        await t.advance(5000)
        #expect(fn.count == 3)
    }

    @Test("[obs-011] refetchOnMount")
    func refetchOnMount() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fa = Controlled<String>()
        _ = t.observe(QueryOptions(key: ["a"], refetchOnMount: .never, queryFn: fa.fn))
        await t.settle()
        #expect(fa.count == 0)
        t.client.setQueryData(["b"], "B")
        let fb = Controlled<String>()
        _ = t.observe(QueryOptions(key: ["b"], staleTime: .infinity, refetchOnMount: .always, queryFn: fb.fn))
        await t.settle()
        #expect(fb.count == 1)
    }

    @Test("[obs-012] result becomes stale over time without refetching")
    func becomesStale() async {
        let t = TestEnv()
        let fn = Immediate("A")
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: fn.fn))
        await t.settle()
        #expect(!o.current.isStale)
        await t.advance(1001)
        #expect(o.results.last?.isStale == true)
        #expect(fn.count == 1)
    }

    @Test("[obs-013] isFetchedAfterMount")
    func fetchedAfterMount() async throws {
        let t = TestEnv()
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: Immediate("A").fn))
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        #expect(o.current.isFetched)
        #expect(!o.current.isFetchedAfterMount)
        await fn.resolveLast("B")
        #expect(o.current.isFetchedAfterMount)
    }

    @Test("[obs-014] error results")
    func errorResults() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], retry: false, queryFn: fn.fn))
        await t.settle()
        await fn.rejectLast(TestError())
        #expect(o.current.status == .error)
        #expect(o.current.isError)
        #expect(o.current.isLoadingError)
        #expect(!o.current.isRefetchError)
        #expect(o.current.error as? TestError == TestError())

        t.client.setQueryData(["a"], "A")
        Task { await o.observer.refetch() }
        await t.settle()
        await fn.rejectLast(TestError("E2"))
        #expect(o.current.status == .error)
        #expect(o.current.data == "A")
        #expect(o.current.isRefetchError)
        #expect(!o.current.isLoadingError)
    }

    @Test("[obs-015] staleTime \"static\"")
    func staticStaleTime() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .static, refetchOnMount: .always, queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 0)
        #expect(!o.current.isStale)
        await t.client.invalidateQueries()
        await t.settle()
        #expect(fn.count == 0)
        #expect(!o.current.isStale)
    }
}

@MainActor
@Suite("query-observer results stream")
struct QueryObserverStreamTests {
    @Test("results yields the current result, then changes; ending iteration unmounts")
    func resultsStream() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let observer = QueryObserver(client: t.client, options: QueryOptions(key: ["a"], gcTime: .milliseconds(1000), queryFn: fn.fn))
        let consumer = Task { @MainActor in
            var seen: [QueryObserverResult<String>] = []
            for await result in observer.results {
                seen.append(result)
                if result.data == "A" { break }
            }
            return seen
        }
        await t.settle()
        #expect(observer.hasListeners)
        #expect(fn.count == 1)
        await fn.resolveLast("A")
        let seen = await consumer.value
        #expect(seen.first?.isLoading == true)
        #expect(seen.last?.data == "A")
        await t.settle()
        #expect(!observer.hasListeners)
        #expect(t.cache.find(["a"])?.observersCount == 0)
    }
}
