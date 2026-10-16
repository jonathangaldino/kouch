import Testing
@testable import SwiftQuery

/// A mutation function whose calls the test settles by hand.
@MainActor
private final class DeferredMutation {
    private(set) var calls: [(vars: String, continuation: CheckedContinuation<String, any Error>)] = []

    var fn: @Sendable (String) async throws -> String {
        { @MainActor [self] vars in
            try await withCheckedThrowingContinuation { calls.append((vars, $0)) }
        }
    }

    func resolve(_ index: Int, _ value: String) { calls[index].continuation.resume(returning: value) }
}

@MainActor
private final class CallCounter {
    var count = 0
}

@MainActor
private final class Log {
    var entries: [String] = []
    func callAsFunction(_ entry: String) { entries.append(entry) }
}

@MainActor
private final class Recorded<V: Sendable, D: Sendable, C: Sendable> {
    let observer: MutationObserver<V, D, C>
    private var subscription: Subscription?
    init(_ observer: MutationObserver<V, D, C>) {
        self.observer = observer
        subscription = observer.subscribe { _ in }
    }
    var current: MutationObserverResult<V, D, C> { observer.currentResult }
    func unsubscribe() { subscription?.cancel() }
}

@MainActor
@Suite("mutations")
struct MutationTests {
    @Test("[mut-001] observer starts idle")
    func startsIdle() {
        let t = TestEnv()
        let o = MutationObserver(client: t.client, options: MutationOptions<String, String, Void> { _ in "x" })
        let r = o.currentResult
        #expect(r.status == .idle)
        #expect(r.isIdle)
        #expect(r.data == nil)
        #expect(r.variables == nil)
    }

    @Test("[mut-002] successful mutate")
    func success() async throws {
        let t = TestEnv()
        let fn = DeferredMutation()
        let o = Recorded(MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(mutationFn: fn.fn)))
        let p = Task { try await o.observer.mutate("vars") }
        await t.settle()
        #expect(o.current.status == .pending)
        #expect(o.current.variables == "vars")
        #expect(o.current.submittedAt == T0)
        fn.resolve(0, "done")
        await t.settle()
        #expect(o.current.status == .success)
        #expect(o.current.data == "done")
        #expect(try await p.value == "done")
        #expect(fn.calls[0].vars == "vars")
    }

    @Test("[mut-003] callback order on success")
    func successCallbackOrder() async throws {
        let log = Log()
        var onSuccessArgs: (String, String, String?)?
        let cache = MutationCache(config: MutationCacheConfig(
            onMutate: { _, _ in log("cache.onMutate") },
            onSuccess: { _, _, _, _ in log("cache.onSuccess") },
            onSettled: { _, _, _, _, _ in log("cache.onSettled") }
        ))
        let t = TestEnv(mutationCache: cache)
        let o = Recorded(MutationObserver(client: t.client, options: MutationOptions<String, String, String>(
            onMutate: { _ in log("onMutate"); return "ctx" },
            onSuccess: { d, v, c in log("onSuccess"); onSuccessArgs = (d, v, c) },
            onSettled: { _, _, _, _ in log("onSettled") },
            mutationFn: { @MainActor _ in log("mutationFn"); return "d" }
        )))
        _ = try await o.observer.mutate("v", onSuccess: { _, _, _ in log("mutate.onSuccess") }, onSettled: { _, _, _, _ in log("mutate.onSettled") })
        await t.settle()
        #expect(log.entries == [
            "cache.onMutate", "onMutate", "mutationFn", "cache.onSuccess", "onSuccess",
            "cache.onSettled", "onSettled", "mutate.onSuccess", "mutate.onSettled",
        ])
        #expect(onSuccessArgs?.0 == "d" && onSuccessArgs?.1 == "v" && onSuccessArgs?.2 == "ctx")
        #expect(o.current.context == "ctx")
    }

    @Test("[mut-004] error")
    func error() async {
        let log = Log()
        let cache = MutationCache(config: MutationCacheConfig(
            onError: { _, _, _, _ in log("cache.onError") },
            onSettled: { _, _, _, _, _ in log("cache.onSettled") }
        ))
        let t = TestEnv(mutationCache: cache)
        let o = Recorded(MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(
            onError: { _, _, _ in log("onError") },
            onSettled: { _, _, _, _ in log("onSettled") },
            mutationFn: { _ in throw TestError() }
        )))
        var thrown: (any Error)?
        do {
            _ = try await o.observer.mutate("v", onError: { _, _, _ in log("mutate.onError") }, onSettled: { _, _, _, _ in log("mutate.onSettled") })
        } catch { thrown = error }
        await t.settle()
        #expect(log.entries == ["cache.onError", "onError", "cache.onSettled", "onSettled", "mutate.onError", "mutate.onSettled"])
        #expect(o.current.status == .error)
        #expect(o.current.error as? TestError == TestError())
        #expect(o.current.failureCount == 1)
        #expect(o.current.data == nil)
        #expect(thrown as? TestError == TestError())
    }

    @Test("[mut-005] retries are off by default")
    func noRetryByDefault() async {
        let t = TestEnv()
        let counter = CallCounter()
        let fn: @Sendable (Void) async throws -> String = { @MainActor _ in
            counter.count += 1
            throw TestError()
        }
        _ = try? await MutationObserver(client: t.client, options: MutationOptions<Void, String, Void>(mutationFn: fn)).mutate(())
        #expect(counter.count == 1)
        let retrying = MutationObserver(client: t.client, options: MutationOptions<Void, String, Void>(retry: 2, retryDelay: .fixed(.milliseconds(10)), mutationFn: fn))
        let p = Task { try await retrying.mutate(()) }
        await t.advance(100)
        _ = await p.result
        #expect(counter.count == 4)
    }

    @Test("[mut-006] offline mutations pause and resume")
    func offline() async {
        let t = TestEnv()
        t.client.mount()
        t.online.setOnline(false)
        var called = 0
        let o = Recorded(MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(mutationFn: { @MainActor _ in
            called += 1
            return "ok"
        })))
        Task { try await o.observer.mutate("v") }
        await t.settle()
        #expect(o.current.status == .pending)
        #expect(o.current.isPaused)
        #expect(called == 0)
        t.online.setOnline(true)
        await t.settle()
        #expect(called == 1)
        #expect(o.current.status == .success)
        #expect(!o.current.isPaused)
        t.client.unmount()
    }

    @Test("[mut-007] same scope runs serially")
    func scoped() async {
        let t = TestEnv()
        let fn = DeferredMutation()
        let a = Recorded(MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(scope: "s", mutationFn: fn.fn)))
        let b = Recorded(MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(scope: "s", mutationFn: fn.fn)))
        Task { try await a.observer.mutate("1") }
        Task { try await b.observer.mutate("2") }
        await t.settle()
        #expect(b.current.status == .pending)
        #expect(b.current.isPaused)
        #expect(fn.calls.map(\.vars) == ["1"])
        fn.resolve(0, "r1")
        await t.settle()
        #expect(fn.calls.map(\.vars) == ["1", "2"])

        let free = DeferredMutation()
        let x = MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(mutationFn: free.fn))
        let y = MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(mutationFn: free.fn))
        Task { try await x.mutate("x") }
        Task { try await y.mutate("y") }
        await t.settle()
        #expect(free.calls.count == 2)
    }

    @Test("[mut-008] mutation garbage collection")
    func garbageCollection() async throws {
        let t = TestEnv()
        let o = Recorded(MutationObserver(client: t.client, options: MutationOptions<Void, String, Void>(gcTime: .milliseconds(1000)) { _ in "ok" }))
        _ = try await o.observer.mutate(())
        o.unsubscribe()
        await t.advance(999)
        #expect(t.client.mutationCache.getAll().count == 1)
        await t.advance(1)
        #expect(t.client.mutationCache.getAll().isEmpty)
    }

    @Test("[mut-009] reset")
    func reset() async throws {
        let t = TestEnv()
        let o = Recorded(MutationObserver(client: t.client, options: MutationOptions<Void, String, Void> { _ in "ok" }))
        _ = try await o.observer.mutate(())
        #expect(o.current.status == .success)
        o.observer.reset()
        #expect(o.current.status == .idle)
        #expect(o.current.data == nil)
    }

    @Test("[mut-010] invalidate from onSuccess")
    func invalidateOnSuccess() async throws {
        let t = TestEnv()
        let todos = Immediate("t")
        _ = t.observe(QueryOptions(key: ["todos"], staleTime: .infinity, queryFn: todos.fn))
        await t.settle()
        let client = t.client
        let o = Recorded(MutationObserver(client: client, options: MutationOptions<Void, String, Void>(
            onSuccess: { _, _, _ in await client.invalidateQueries(QueryFilters(queryKey: ["todos"])) },
            mutationFn: { _ in "ok" }
        )))
        _ = try await o.observer.mutate(())
        await t.settle()
        #expect(todos.count == 2)
    }

    @Test("[mut-011] isMutating")
    func isMutating() async {
        let t = TestEnv()
        let fn = DeferredMutation()
        let a = MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(mutationFn: fn.fn))
        let b = MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(mutationFn: fn.fn))
        Task { try await a.mutate("a") }
        Task { try await b.mutate("b") }
        await t.settle()
        #expect(t.client.isMutating() == 2)
        fn.resolve(0, "x")
        fn.resolve(1, "x")
        await t.settle()
        #expect(t.client.isMutating() == 0)
    }
}
