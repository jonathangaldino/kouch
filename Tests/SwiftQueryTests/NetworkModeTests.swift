import Testing
@testable import SwiftQuery

@MainActor
@Suite("network-mode")
struct NetworkModeTests {
    @Test("[net-001] offline start pauses")
    func offlineStart() async {
        let t = TestEnv()
        t.client.mount()
        t.online.setOnline(false)
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        #expect(o.current.status == .pending)
        #expect(o.current.fetchStatus == .paused)
        #expect(o.current.isPaused)
        #expect(fn.count == 0)
        t.online.setOnline(true)
        await t.settle()
        #expect(fn.count == 1)
        #expect(o.current.fetchStatus == .fetching)
        await fn.resolveLast("A")
        #expect(o.current.status == .success)
    }

    @Test("[net-002] networkMode always")
    func always() async {
        let t = TestEnv()
        t.online.setOnline(false)
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], networkMode: .always, queryFn: fn.fn))
        await t.settle()
        #expect(fn.count == 1)
        #expect(o.current.fetchStatus == .fetching)
    }

    @Test("[net-003] networkMode offlineFirst")
    func offlineFirst() async {
        let t = TestEnv()
        t.online.setOnline(false)
        let fn = Failing(t)
        let o = t.observe(QueryOptions(key: ["a"], retry: 1, retryDelay: .fixed(.milliseconds(10)), networkMode: .offlineFirst, queryFn: fn.fn))
        await t.settle()
        await t.advance(10)
        #expect(fn.count == 1)
        #expect(o.current.fetchStatus == .paused)
    }

    @Test("[net-004] reconnect refetches stale active queries")
    func reconnect() async {
        let t = TestEnv()
        t.client.mount()
        let stale = Immediate("s")
        let fresh = Immediate("f")
        _ = t.observe(QueryOptions(key: ["stale"], queryFn: stale.fn))
        _ = t.observe(QueryOptions(key: ["fresh"], staleTime: .infinity, queryFn: fresh.fn))
        await t.settle()
        t.online.setOnline(false)
        t.online.setOnline(true)
        await t.settle()
        #expect(stale.count == 2)
        #expect(fresh.count == 1)
        t.client.unmount()
    }

    @Test("[net-005] leaving a paused initial fetch cancels it")
    func leavePaused() async {
        let t = TestEnv()
        t.online.setOnline(false)
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        o.unsubscribe()
        t.online.setOnline(true)
        await t.settle()
        let s = t.state(["a"])!
        #expect(s.status == .pending)
        #expect(s.fetchStatus == .idle)
        #expect(fn.count == 0)
    }

    @Test("[net-006] fetchQuery while offline waits for the network")
    func fetchQueryOffline() async throws {
        let t = TestEnv()
        t.client.mount()
        t.online.setOnline(false)
        let fn = Controlled<String>()
        var result: String?
        Task { result = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn)) }
        await t.advance(10_000)
        #expect(result == nil)
        #expect(t.state(["a"])?.fetchStatus == .paused)
        #expect(fn.count == 0)
        t.online.setOnline(true)
        await t.settle()
        await fn.resolveLast("A")
        #expect(result == "A")
    }
}
