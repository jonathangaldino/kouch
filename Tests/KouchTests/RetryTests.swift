import Testing
@testable import Kouch

@MainActor
@Suite("retries")
struct RetryTests {
    @Test("[retry-001] default: 3 retries with exponential backoff")
    func defaultRetries() async {
        let t = TestEnv()
        let fn = Failing(t)
        let o = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        #expect(o.current.failureCount == 1)
        #expect(o.current.status == .pending)
        #expect(o.current.fetchStatus == .fetching)
        await t.advance(7000)
        #expect(fn.times == [T0, ms(1000), ms(3000), ms(7000)])
        #expect(o.current.status == .error)
        #expect((o.current.error as? TestError)?.message == "E")
        #expect(o.current.failureCount == 4)
        #expect(fn.count == 4)
    }

    @Test("[retry-002] retry: false makes one attempt")
    func noRetry() async {
        let t = TestEnv()
        let fn = Failing(t)
        let o = t.observe(QueryOptions(key: ["a"], retry: false, queryFn: fn.fn))
        await t.advance(10_000)
        #expect(fn.count == 1)
        #expect(o.current.status == .error)
    }

    @Test("[retry-003] retry: N")
    func retryN() async {
        let t = TestEnv()
        let fn = Failing(t)
        let o = t.observe(QueryOptions(key: ["a"], retry: 1, retryDelay: .fixed(.milliseconds(10)), queryFn: fn.fn))
        await t.advance(1000)
        #expect(fn.count == 2)
        #expect(o.current.status == .error)
    }

    @Test("[retry-004] retry function")
    func retryFunction() async {
        let t = TestEnv()
        let retry = RetryPolicy.custom { count, error in (error as? TestError)?.message == "retryable" && count < 2 }
        let r = Failing(t, message: "retryable")
        _ = t.observe(QueryOptions(key: ["a"], retry: retry, retryDelay: .fixed(.milliseconds(10)), queryFn: r.fn))
        await t.advance(1000)
        #expect(r.count == 3)
        let f = Failing(t, message: "fatal")
        _ = t.observe(QueryOptions(key: ["b"], retry: retry, retryDelay: .fixed(.milliseconds(10)), queryFn: f.fn))
        await t.advance(1000)
        #expect(f.count == 1)
    }

    @Test("[retry-005] retryDelay function receives failureCount")
    func retryDelayFunction() async {
        let t = TestEnv()
        let fn = Failing(t)
        _ = t.observe(QueryOptions(key: ["a"], retry: 2, retryDelay: .custom { n, _ in .milliseconds((n + 1) * 100) }, queryFn: fn.fn))
        await t.advance(1000)
        #expect(fn.times == [T0, ms(100), ms(300)])
    }

    @Test("[retry-006] success after retry resets failures")
    func successAfterRetry() async {
        let t = TestEnv()
        let calls = Immediate(0)
        let fn: QueryFunction<String> = { @MainActor ctx in
            let n = try await calls.fn(ctx)
            _ = n
            if calls.count == 1 { throw TestError() }
            return "A"
        }
        let o = t.observe(QueryOptions(key: ["a"], retry: 3, retryDelay: .fixed(.milliseconds(10)), queryFn: fn))
        await t.settle()
        #expect(o.current.failureCount == 1)
        #expect((o.current.failureReason as? TestError)?.message == "E")
        await t.advance(10)
        #expect(o.current.status == .success)
        #expect(o.current.failureCount == 0)
        #expect(o.current.failureReason == nil)
    }

    @Test("[retry-007] fetchQuery does not retry unless asked")
    func fetchQueryRetry() async {
        let t = TestEnv()
        let a = Failing(t)
        _ = try? await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: a.fn))
        #expect(a.count == 1)
        let b = Failing(t)
        let p = t.fetch(QueryOptions(key: ["b"], retry: 2, retryDelay: .fixed(.milliseconds(10)), queryFn: b.fn))
        await t.advance(100)
        _ = await p.result
        #expect(b.count == 3)
    }

    @Test("[retry-008] retry pauses while offline")
    func pausesOffline() async {
        let t = TestEnv()
        t.client.mount()
        let fn = Failing(t)
        let o = t.observe(QueryOptions(key: ["a"], retry: 1, retryDelay: .fixed(.milliseconds(1000)), queryFn: fn.fn))
        await t.settle()
        t.online.setOnline(false)
        await t.advance(1000)
        #expect(o.current.fetchStatus == .paused)
        #expect(fn.count == 1)
        t.online.setOnline(true)
        await t.settle()
        #expect(fn.count == 2)
    }

    @Test("[retry-009] retry pauses while unfocused")
    func pausesUnfocused() async {
        let t = TestEnv()
        t.client.mount()
        let fn = Failing(t)
        let o = t.observe(QueryOptions(key: ["a"], retry: 1, retryDelay: .fixed(.milliseconds(1000)), queryFn: fn.fn))
        await t.settle()
        t.focus.setFocused(false)
        await t.advance(1000)
        #expect(o.current.fetchStatus == .paused)
        #expect(fn.count == 1)
        t.focus.setFocused(true)
        await t.settle()
        #expect(fn.count == 2)
    }

    @Test("[retry-010] unsubscribing stops further retries (signal not consumed)")
    func unsubscribeStopsRetries() async {
        let t = TestEnv()
        let fn = Failing(t)
        let o = t.observe(QueryOptions(key: ["a"], retry: 3, retryDelay: .fixed(.milliseconds(1000)), queryFn: fn.fn))
        await t.settle()
        o.unsubscribe()
        await t.advance(10_000)
        #expect(fn.count == 1)
        let s = t.state(["a"])!
        #expect(s.status == .error)
        #expect(s.fetchStatus == .idle)
    }
}
