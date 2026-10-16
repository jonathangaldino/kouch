import Testing
@testable import SwiftQuery

@MainActor
@Suite("cancellation")
struct CancellationTests {
    @Test("[cancel-001] cancel the initial fetch → revert to pending")
    func cancelInitial() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let p = t.fetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await t.client.cancelQueries(QueryFilters(queryKey: ["a"]))
        let s = t.state(["a"])!
        #expect(s.status == .pending)
        #expect(s.fetchStatus == .idle)
        #expect(s.data == nil)
        #expect(s.error == nil)
        let result = await p.result
        #expect(throws: CancelledError.self) { try result.get() }
        await fn.resolveLast("late")
        #expect(t.state(["a"])?.data == nil)
    }

    @Test("[cancel-002] cancel a refetch → revert to previous data")
    func cancelRefetch() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await t.client.cancelQueries()
        var s = t.state(["a"])!
        #expect(s.status == .success)
        #expect(s.data == "A")
        #expect(s.fetchStatus == .idle)
        await fn.resolveLast("B")
        s = t.state(["a"])!
        #expect(s.data == "A")
    }

    @Test("[cancel-003] cancel aborts the signal")
    func abortsSignal() async {
        let t = TestEnv()
        let fn = Controlled<String>(readSignal: true)
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await t.client.cancelQueries()
        #expect(fn.last.signal?.isCancelled == true)
    }

    @Test("[cancel-004] last observer leaves; signal consumed → abort and revert")
    func leaveConsumed() async {
        let t = TestEnv()
        let fn = Controlled<String>(readSignal: true)
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        o.unsubscribe()
        await t.settle()
        #expect(fn.last.signal?.isCancelled == true)
        let s = t.state(["a"])!
        #expect(s.status == .pending)
        #expect(s.fetchStatus == .idle)
    }

    @Test("[cancel-005] last observer leaves; signal not consumed → fetch completes")
    func leaveNotConsumed() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        o.unsubscribe()
        await fn.resolveLast("A")
        let s = t.state(["a"])!
        #expect(s.data == "A")
        #expect(s.status == .success)
    }

    @Test("[cancel-006] cancel without revert results in an error state")
    func cancelNoRevert() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await t.cache.find(["a"])!.cancel(revert: false)
        await t.settle()
        let s = t.state(["a"])!
        #expect(s.status == .error)
        #expect(s.fetchStatus == .idle)
        #expect(s.error is CancelledError)
    }

    @Test("[cancel-007] cancelling an idle query is a no-op")
    func cancelIdle() async {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        await t.client.cancelQueries()
        let s = t.state(["a"])!
        #expect(s.status == .success)
        #expect(s.data == "A")
    }

    @Test("[cancel-008] fetchQuery after cancel starts fresh")
    func fetchAfterCancel() async throws {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.fetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await t.client.cancelQueries()
        let p = t.fetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await fn.resolveLast("A")
        #expect(try await p.value == "A")
        #expect(fn.count == 2)
    }
}
