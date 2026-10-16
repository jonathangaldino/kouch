import Testing
@testable import Kouch

@MainActor
@Suite("stale-time")
struct StaleTimeTests {
    @Test("[stale-001] default staleTime 0: stale immediately")
    func defaultZero() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: Immediate("A").fn))
        await t.settle()
        #expect(o.current.status == .success)
        #expect(o.current.isStale)
    }

    @Test("[stale-002] boundary of staleTime")
    func boundary() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: Immediate("A").fn))
        await t.settle()
        await t.advance(999)
        #expect(!o.current.isStale)
        await t.advance(2)
        #expect(o.current.isStale)
    }

    @Test("[stale-003] staleTime Infinity")
    func infinity() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: Immediate("A").fn))
        await t.settle()
        await t.advance(24 * 3600 * 1000)
        #expect(!o.current.isStale)
        await t.client.invalidateQueries(refetchType: RefetchType.none)
        #expect(o.current.isStale)
    }

    @Test("[stale-004] staleTime \"static\" survives invalidation")
    func staticSurvives() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .static, queryFn: Immediate("A").fn))
        await t.settle()
        await t.client.invalidateQueries(refetchType: RefetchType.none)
        #expect(!o.current.isStale)
        #expect(t.state(["a"])?.isInvalidated == true)
    }

    @Test("[stale-005] no data is stale; disabled observer is not")
    func noData() async {
        let t = TestEnv()
        let q = t.cache.build(QueryOptions<String>(key: ["a"]))
        #expect(q.isStale())
        let o = t.observe(QueryOptions(key: ["b"], enabled: false, queryFn: Controlled<String>().fn))
        await t.settle()
        #expect(!o.current.isStale)
    }

    @Test("[stale-006] mount behavior follows freshness")
    func mountFollowsFreshness() async throws {
        let t = TestEnv()
        let fn = Immediate("A")
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.advance(500)
        let o1 = t.observe(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 1)
        o1.unsubscribe()
        await t.advance(1000)
        _ = t.observe(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 2)
    }

    @Test("[stale-007] query is stale if any observer considers it stale")
    func anyObserverStale() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        let o1 = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: fn.fn))
        let o2 = t.observe(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: fn.fn))
        await t.advance(1001)
        #expect(!o1.current.isStale)
        #expect(o2.current.isStale)
        let q = t.cache.find(["a"])!
        #expect(q.isStale())
        #expect(t.cache.findAll(QueryFilters(stale: true)).contains { $0 === q })
    }
}
