import Testing
@testable import Kouch

@MainActor
@Suite("deduplication")
struct DeduplicationTests {
    @Test("[dedup-001] two consumers request the same query")
    func twoConsumers() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let a = t.observe(QueryOptions(key: ["user", 123], queryFn: fn.fn))
        let b = t.observe(QueryOptions(key: ["user", 123], queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 1)
        #expect(a.observer.query === b.observer.query)
        for o in [a, b] {
            #expect(o.current.status == .pending)
            #expect(o.current.fetchStatus == .fetching)
        }
        await fn.resolveLast("user")
        #expect(a.current.data == "user")
        #expect(b.current.data == "user")
        #expect(t.cache.getAll().count == 1)
    }

    @Test("[dedup-002] concurrent fetchQuery calls share one request")
    func concurrentFetchQuery() async throws {
        let t = TestEnv()
        let fn = Controlled<String>()
        let p1 = t.fetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        let p2 = t.fetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 1)
        await fn.resolveLast("A")
        #expect(try await p1.value == "A")
        #expect(try await p2.value == "A")
    }

    @Test("[dedup-003] observer and fetchQuery share one request")
    func observerAndFetchQuery() async throws {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        let p = t.fetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 1)
        await fn.resolveLast("A")
        #expect(try await p.value == "A")
        #expect(o.current.data == "A")
    }

    @Test("[dedup-004] refetch with cancelRefetch: false joins the in-flight request")
    func refetchJoins() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: fn.fn))
        Task { await o.observer.refetch() }
        await t.settle()
        Task { await o.observer.refetch(cancelRefetch: false) }
        await t.settle()
        #expect(fn.count == 1)
    }

    @Test("[dedup-005] cancelRefetch replaces an in-flight request only when data exists")
    func cancelRefetchReplaces() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: fn.fn))
        Task { await o.observer.refetch() }
        await t.settle()
        Task { await o.observer.refetch() }
        await t.settle()
        #expect(fn.count == 2)
        fn.resolve(0, "old")
        await t.settle()
        #expect(t.client.getQueryData(["a"], as: String.self) == "A")
        fn.resolve(1, "new")
        await t.settle()
        #expect(t.client.getQueryData(["a"], as: String.self) == "new")

        let fn2 = Controlled<String>()
        let o2 = t.observe(QueryOptions(key: ["b"], queryFn: fn2.fn))
        await t.settle()
        Task { await o2.observer.refetch() }
        await t.settle()
        #expect(fn2.count == 1)
    }

    @Test("[dedup-006] a completed request is not reused")
    func completedNotReused() async throws {
        let t = TestEnv()
        let fn = Immediate("A")
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn))
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn))
        #expect(fn.count == 2)
    }
}
