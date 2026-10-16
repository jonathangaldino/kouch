import Testing
@testable import SwiftQuery

@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
@Suite("query-options")
struct QueryOptionsTests {
    @Test("[qo-001] meta reaches the query function and cache callbacks")
    func meta() async throws {
        let seen = Box<[String]>([])
        let t = TestEnv(queryCache: QueryCache(config: QueryCacheConfig(onSuccess: { _, q in
            seen.value.append(q.meta?["source"] as? String ?? "nil")
        })))
        let ctxMeta = Box<String?>(nil)
        _ = try await t.client.fetchQuery(QueryOptions<String>(key: ["a"], meta: ["source": "test"]) { @MainActor ctx in
            ctxMeta.value = ctx.meta?["source"] as? String
            return "A"
        })
        #expect(ctxMeta.value == "test")
        #expect(seen.value == ["test"])
        #expect(t.cache.find(["a"])?.meta?["source"] as? String == "test")
    }

    @Test("[qo-002] the query function context carries the client")
    func contextClient() async throws {
        let t = TestEnv()
        let seen = Box<QueryClient?>(nil)
        _ = try await t.client.fetchQuery(QueryOptions<String>(key: ["a"]) { @MainActor ctx in
            seen.value = ctx.client
            return "A"
        })
        #expect(seen.value === t.client)
    }

    @Test("[qo-003] the mutation function context carries client, meta and key")
    func mutationContext() async throws {
        let t = TestEnv()
        let seen = Box<MutationFunctionContext?>(nil)
        let o = MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(
            mutationKey: ["m"], meta: ["tag": 1], mutationFn: { @MainActor _, ctx in
                seen.value = ctx
                return "ok"
            }
        ))
        _ = try await o.mutate("v")
        #expect(seen.value?.client === t.client)
        #expect(seen.value?.meta?["tag"] as? Int == 1)
        #expect(seen.value?.mutationKey == ["m"])
        #expect(t.client.mutationCache.getAll().first.map { ($0 as? Mutation<String, String, Void>)?.meta?["tag"] as? Int } == 1)
    }

    @Test("[qo-004] staleTime as a function of the query")
    func dynamicStaleTime() async {
        let t = TestEnv()
        t.client.setQueryData(["fresh"], "fresh")
        t.client.setQueryData(["old"], "old")
        let staleTime = StaleTime.dynamic { query in
            (query as? Query<String>)?.state.data == "fresh" ? .infinity : .zero
        }
        let f = Controlled<String>()
        let o = Controlled<String>()
        _ = t.observe(QueryOptions(key: ["fresh"], staleTime: staleTime, queryFn: f.fn))
        _ = t.observe(QueryOptions(key: ["old"], staleTime: staleTime, queryFn: o.fn))
        await t.settle()
        #expect(f.count == 0)
        #expect(o.count == 1)
    }

    @Test("[qo-005] enabled as a function of the query")
    func dynamicEnabled() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let allowed = Box(false)
        let options = QueryOptions(key: ["a"], queryFn: fn.fn).enabled { _ in allowed.value }
        let o = t.observe(options)
        await t.settle()
        #expect(fn.count == 0)
        #expect(!o.current.isEnabled)
        allowed.value = true
        o.observer.setOptions(options)
        await t.settle()
        #expect(fn.count == 0) // the previous options' function now also says true: no "was disabled" edge
        Task { await t.client.invalidateQueries() }
        await t.settle()
        #expect(fn.count == 1)
        #expect(o.current.isEnabled)
    }

    @Test("[qo-006] refetchInterval as a function of the query")
    func dynamicInterval() async {
        let t = TestEnv()
        let fn = Immediate("A")
        _ = t.observe(QueryOptions(key: ["a"], refetchInterval: .dynamic { query in
            (query as? Query<String>).map { $0.state.dataUpdateCount < 3 ? .milliseconds(1000) : nil } ?? nil
        }, queryFn: fn.fn))
        await t.settle()
        await t.advance(10_000)
        #expect(fn.count == 3)
    }

    @Test("[qo-007] refetchOnWindowFocus as a function of the query")
    func dynamicFocus() async {
        let t = TestEnv()
        t.client.mount()
        let always = Immediate("refocus")
        let never = Immediate("other")
        let trigger = RefetchTrigger.dynamic { query in
            (query as? Query<String>)?.state.data == "refocus" ? .always : .never
        }
        _ = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, refetchOnWindowFocus: trigger, queryFn: always.fn))
        _ = t.observe(QueryOptions(key: ["b"], refetchOnWindowFocus: trigger, queryFn: never.fn))
        await t.settle()
        t.focus.setFocused(false)
        t.focus.setFocused(true)
        await t.settle()
        #expect(always.count == 2)
        #expect(never.count == 1)
        t.client.unmount()
    }

    @Test("[qo-008] initialData as a function is evaluated lazily, once per query")
    func lazyInitialData() {
        let t = TestEnv()
        let calls = CallCount()
        let options = QueryOptions<String>(key: ["a"]).initialData { calls.increment(); return "init" }
        let q = t.cache.build(options)
        #expect(q.state.data == "init")
        _ = t.cache.build(options)
        #expect(calls.value == 1)
    }

    @Test("[qo-009] retryOnMount")
    func retryOnMount() async {
        let t = TestEnv()
        await t.client.prefetchQuery(QueryOptions(key: ["a"], queryFn: Failing(t).fn))
        let noRetry = Failing(t)
        _ = t.observe(QueryOptions(key: ["a"], retry: false, retryOnMount: false, queryFn: noRetry.fn))
        await t.settle()
        #expect(noRetry.count == 0)
        let retry = Failing(t)
        _ = t.observe(QueryOptions(key: ["a"], retry: false, queryFn: retry.fn))
        await t.settle()
        #expect(retry.count == 1)
    }

    @Test("[qo-010] skipToken disables the query")
    func skipToken() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions<String>(key: ["a"], skipToken: true))
        await t.settle()
        #expect(!o.current.isEnabled)
        #expect(o.current.fetchStatus == .idle)
        let q = t.cache.find(["a"])!
        o.unsubscribe()
        #expect(q.isDisabled())
        let r = await QueryObserver(client: t.client, options: QueryOptions<String>(key: ["a"], retry: false, skipToken: true)).refetch()
        #expect(r.status == .error)
        #expect(r.error is MissingQueryFunctionError)
    }

    @Test("[qo-011] refetch throwOnError")
    func refetchThrows() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a"], retry: false, queryFn: Failing(t).fn))
        await t.settle()
        let r = await o.observer.refetch()
        #expect(r.status == .error)
        await #expect(throws: TestError()) { try await o.observer.refetch(throwOnError: true) }
    }

    @Test("[qo-012] refetchQueries / invalidateQueries throwOnError")
    func bulkThrows() async {
        let t = TestEnv()
        _ = t.observe(QueryOptions(key: ["a"], retry: false, queryFn: Failing(t).fn))
        await t.settle()
        await t.client.refetchQueries()
        await #expect(throws: TestError()) { try await t.client.refetchQueries(throwOnError: true) }
        await #expect(throws: TestError()) { try await t.client.invalidateQueries(throwOnError: true) }
    }

    @Test("[qo-013] getQueriesData / setQueriesData")
    func queriesData() {
        let t = TestEnv()
        t.client.setQueryData(["todos", 1], "one")
        t.client.setQueryData(["todos", 2], "two")
        t.client.setQueryData(["posts"], "post")
        let read = t.client.getQueriesData(QueryFilters(queryKey: ["todos"]), as: String.self)
        #expect(read.map(\.0) == [["todos", 1], ["todos", 2]])
        #expect(read.map(\.1) == ["one", "two"])
        let updated = t.client.setQueriesData(QueryFilters(queryKey: ["todos"]), as: String.self) { $0.map { $0 + "!" } }
        #expect(updated.map(\.1) == ["one!", "two!"])
        #expect(t.client.getQueryData(["posts"], as: String.self) == "post")
    }

    @Test("[qo-014] mutationCache.find")
    func mutationFind() async throws {
        let t = TestEnv()
        _ = try await MutationObserver(client: t.client, options: MutationOptions<Void, String, Void>(mutationKey: ["todos", "add"]) { _ in "ok" }).mutate(())
        let cache = t.client.mutationCache
        #expect(cache.find(mutationKey: ["todos", "add"]) != nil)
        #expect(cache.find(mutationKey: ["todos"]) == nil)
        #expect(cache.find(mutationKey: ["todos"], exact: false) != nil)
        #expect(cache.findAll(MutationFilters(mutationKey: ["todos"])).count == 1)
    }

    @Test("[qo-015] mutations take mutationFn and callbacks from setMutationDefaults")
    func mutationDefaults() async throws {
        let t = TestEnv()
        let log = Box<[String]>([])
        t.client.setMutationDefaults(["add"], MutationOptions<String, String, Void>(
            onSuccess: { _, _, _ in log.value.append("defaults.onSuccess") },
            mutationFn: { @MainActor v in
                log.value.append("fn \(v)")
                return "done"
            }
        ))
        let data = try await MutationObserver(client: t.client, options: MutationOptions<String, String, Void>(mutationKey: ["add"])).mutate("v")
        #expect(data == "done")
        #expect(log.value == ["fn v", "defaults.onSuccess"])
    }
}

/// Counter usable from `@Sendable` closures that run on the main actor.
final class CallCount: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}
