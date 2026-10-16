import Testing
@testable import SwiftQuery

@MainActor
@Suite("garbage-collection")
struct GarbageCollectionTests {
    @Test("[gc-001] unobserved query removed after default gcTime")
    func defaultGcTime() async throws {
        let t = TestEnv()
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: Immediate("A").fn))
        await t.advance(299_999)
        #expect(t.exists(["a"]))
        await t.advance(1)
        #expect(!t.exists(["a"]))
    }

    @Test("[gc-002] last observer unsubscribes → removed after gcTime")
    func lastObserverLeaves() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a"], gcTime: .milliseconds(1000), queryFn: Immediate("A").fn))
        await t.settle()
        o.unsubscribe()
        await t.advance(999)
        #expect(t.exists(["a"]))
        #expect(t.client.getQueryData(["a"], as: String.self) == "A")
        await t.advance(1)
        #expect(!t.exists(["a"]))
    }

    @Test("[gc-003] new observer before GC rescues the query")
    func rescue() async {
        let t = TestEnv()
        let fn = Immediate("A")
        let o = t.observe(QueryOptions(key: ["a"], gcTime: .milliseconds(1000), queryFn: fn.fn))
        await t.settle()
        o.unsubscribe()
        await t.advance(500)
        let o2 = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, gcTime: .milliseconds(1000), queryFn: fn.fn))
        #expect(o2.current.status == .success)
        #expect(o2.current.data == "A")
        await t.settle()
        #expect(fn.count == 1)
        await t.advance(4500)
        #expect(t.exists(["a"]))
    }

    @Test("[gc-004] gcTime Infinity never collects")
    func infinity() async throws {
        let t = TestEnv()
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], gcTime: .infinity, queryFn: Immediate("A").fn))
        await t.advance(365 * 24 * 3600 * 1000)
        #expect(t.exists(["a"]))
    }

    @Test("[gc-005] largest gcTime wins")
    func largestWins() async throws {
        let t = TestEnv()
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], gcTime: .milliseconds(10_000), queryFn: Immediate("A").fn))
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], gcTime: .milliseconds(1000), queryFn: Immediate("A").fn))
        await t.advance(1000)
        #expect(t.exists(["a"]))
        await t.advance(9000)
        #expect(!t.exists(["a"]))
    }

    @Test("[gc-006] fetching queries are not collected")
    func fetchingNotCollected() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], gcTime: .milliseconds(1000), queryFn: fn.fn))
        await t.settle()
        await t.advance(1000)
        #expect(t.exists(["a"]))
        await t.advance(4000)
        await fn.resolveLast("A")
        await t.advance(999)
        #expect(t.exists(["a"]))
        await t.advance(1)
        #expect(!t.exists(["a"]))
    }

    @Test("[gc-007] gcTime 0")
    func zero() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a"], gcTime: .milliseconds(0), queryFn: Immediate("A").fn))
        await t.settle()
        o.unsubscribe()
        await t.advance(0)
        #expect(!t.exists(["a"]))
    }

    @Test("[gc-008] remaining observer keeps the query")
    func remainingObserver() async {
        let t = TestEnv()
        let fn = Immediate("A")
        let o1 = t.observe(QueryOptions(key: ["a"], gcTime: .milliseconds(1000), queryFn: fn.fn))
        let o2 = t.observe(QueryOptions(key: ["a"], gcTime: .milliseconds(1000), queryFn: fn.fn))
        await t.settle()
        o1.unsubscribe()
        await t.advance(5000)
        #expect(t.exists(["a"]))
        #expect(t.cache.find(["a"])?.observersCount == 1)
        _ = o2
    }
}
