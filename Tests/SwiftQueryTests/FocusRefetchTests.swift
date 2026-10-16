import Testing
@testable import SwiftQuery

@MainActor
@Suite("focus-refetch")
struct FocusRefetchTests {
    @Test("[focus-001] focus refetches stale active queries")
    func focusRefetches() async {
        let t = TestEnv()
        t.client.mount()
        let fn = Immediate("A")
        _ = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        t.focus.setFocused(false)
        t.focus.setFocused(true)
        await t.settle()
        #expect(fn.count == 2)
        t.client.unmount()
    }

    @Test("[focus-002] focus respects freshness and the option")
    func focusOptions() async {
        let t = TestEnv()
        t.client.mount()
        let fresh = Immediate("f")
        let off = Immediate("o")
        let always = Immediate("a")
        _ = t.observe(QueryOptions(key: ["fresh"], staleTime: .infinity, queryFn: fresh.fn))
        _ = t.observe(QueryOptions(key: ["off"], refetchOnWindowFocus: .never, queryFn: off.fn))
        _ = t.observe(QueryOptions(key: ["always"], staleTime: .infinity, refetchOnWindowFocus: .always, queryFn: always.fn))
        await t.settle()
        t.focus.setFocused(false)
        t.focus.setFocused(true)
        await t.settle()
        #expect(fresh.count == 1)
        #expect(off.count == 1)
        #expect(always.count == 2)
        t.client.unmount()
    }

    @Test("[focus-003] refetchInterval pauses in background")
    func intervalBackground() async {
        let t = TestEnv()
        let fg = Immediate("x")
        _ = t.observe(QueryOptions(key: ["a"], refetchInterval: .milliseconds(1000), queryFn: fg.fn))
        await t.settle()
        t.focus.setFocused(false)
        await t.advance(3000)
        #expect(fg.count == 1)

        let bg = Immediate("y")
        _ = t.observe(QueryOptions(key: ["b"], refetchInterval: .milliseconds(1000), refetchIntervalInBackground: true, queryFn: bg.fn))
        await t.settle()
        await t.advance(3000)
        #expect(bg.count == 4)
    }

    @Test("[focus-004] inactive queries are not refetched on focus")
    func inactiveNotRefetched() async throws {
        let t = TestEnv()
        t.client.mount()
        let fn = Immediate("A")
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn))
        t.focus.setFocused(false)
        t.focus.setFocused(true)
        await t.settle()
        #expect(fn.count == 1)
        t.client.unmount()
    }
}
