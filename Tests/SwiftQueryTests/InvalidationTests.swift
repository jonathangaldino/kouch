import Testing
@testable import SwiftQuery

@MainActor
@Suite("invalidation")
struct InvalidationTests {
    @Test("[inv-001] active queries refetch, inactive become stale")
    func activeRefetch() async throws {
        let t = TestEnv()
        let f1 = Immediate("one")
        let f2 = Immediate("two")
        _ = t.observe(QueryOptions(key: ["todos", 1], staleTime: .infinity, queryFn: f1.fn))
        _ = try await t.client.fetchQuery(QueryOptions(key: ["todos", 2], staleTime: .infinity, queryFn: f2.fn))
        await t.settle()
        await t.client.invalidateQueries(QueryFilters(queryKey: ["todos"]))
        #expect(t.state(["todos", 1])?.isInvalidated == false) // refetched → cleared
        #expect(t.state(["todos", 2])?.isInvalidated == true)
        #expect(f1.count == 2)
        #expect(f2.count == 1)
        _ = t.observe(QueryOptions(key: ["todos", 2], staleTime: .infinity, queryFn: f2.fn))
        await t.settle()
        #expect(f2.count == 2)
    }

    @Test("[inv-002] filter scope")
    func filterScope() async {
        let t = TestEnv()
        let todos = Immediate("t")
        let posts = Immediate("p")
        _ = t.observe(QueryOptions(key: ["todos"], staleTime: .infinity, queryFn: todos.fn))
        _ = t.observe(QueryOptions(key: ["posts"], staleTime: .infinity, queryFn: posts.fn))
        await t.settle()
        await t.client.invalidateQueries(QueryFilters(queryKey: ["todos"]))
        #expect(todos.count == 2)
        #expect(posts.count == 1)
        #expect(t.state(["posts"])?.isInvalidated == false)
    }

    @Test("[inv-003] refetchType")
    func refetchType() async throws {
        let t = TestEnv()
        let a = Immediate("a")
        let b = Immediate("b")
        _ = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: a.fn))
        _ = try await t.client.fetchQuery(QueryOptions(key: ["b"], queryFn: b.fn))
        await t.settle()
        await t.client.invalidateQueries(refetchType: RefetchType.none)
        #expect(a.count == 1)
        #expect(b.count == 1)
        #expect(t.state(["a"])?.isInvalidated == true)
        #expect(t.state(["b"])?.isInvalidated == true)
        await t.client.invalidateQueries(refetchType: .all)
        #expect(a.count == 2)
        #expect(b.count == 2)
    }

    @Test("[inv-004] invalidateQueries resolves after refetch finishes")
    func resolvesAfterRefetch() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        var calls = 0
        let clock = t.clock
        _ = t.observe(QueryOptions<String>(key: ["a"], staleTime: .infinity, queryFn: { @MainActor _ in
            calls += 1
            try await clock.sleep(for: .milliseconds(1000))
            return "B"
        }))
        var done = false
        Task {
            await t.client.invalidateQueries()
            done = true
        }
        await t.advance(999)
        #expect(!done)
        await t.advance(1)
        #expect(done)
        #expect(t.client.getQueryData(["a"], as: String.self) == "B")
        #expect(t.state(["a"])?.isInvalidated == false)
        #expect(calls == 1)
    }

    @Test("[inv-005] disabled observers are not refetched")
    func disabledNotRefetched() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        _ = t.observe(QueryOptions(key: ["a"], enabled: false, queryFn: fn.fn))
        await t.client.invalidateQueries()
        #expect(fn.count == 0)
        #expect(t.state(["a"])?.isInvalidated == true)
    }

    @Test("[inv-006] invalidating an in-flight query with data restarts it")
    func restartsInFlight() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: fn.fn))
        Task { await o.observer.refetch() }
        await t.settle()
        Task { await t.client.invalidateQueries() }
        await t.settle()
        #expect(fn.count == 2)
        fn.resolve(0, "old")
        await t.settle()
        #expect(t.client.getQueryData(["a"], as: String.self) == "A")
        fn.resolve(1, "new")
        await t.settle()
        #expect(t.client.getQueryData(["a"], as: String.self) == "new")
    }

    @Test("[inv-007] setQueryData clears invalidation")
    func setQueryDataClears() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        await t.client.invalidateQueries()
        #expect(t.state(["a"])?.isInvalidated == true)
        t.client.setQueryData(["a"], "X")
        #expect(t.state(["a"])?.isInvalidated == false)
    }
}
