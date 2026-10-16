import SwiftUI
import Testing
@testable import SwiftQuery
@testable import SwiftQuerySwiftUI

@MainActor
@Suite("swiftui-adapter")
struct SwiftUIAdapterTests {
    @Test("first update shows the loading state without fetching; mounting happens after")
    func firstUpdate() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let model = ObserverModel<QueryObserver<String, String>>()
        model.update(client: t.client, options: QueryObserverOptions(QueryOptions(key: ["a"], queryFn: fn.fn)))
        #expect(model.result.isLoading)
        #expect(fn.count == 0)
        await t.settle()
        #expect(fn.count == 1)
        #expect(model.observer?.hasListeners == true)
        await fn.resolveLast("A")
        #expect(model.result.data == "A")
    }

    @Test("a new key shows its optimistic state at once, then switches queries")
    func keyChange() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let model = ObserverModel<QueryObserver<String, String>>()
        model.update(client: t.client, options: QueryObserverOptions(QueryOptions(key: ["a", 1], queryFn: fn.fn)))
        await t.settle()
        await fn.resolveLast("one")
        model.update(client: t.client, options: QueryObserverOptions(QueryOptions(key: ["a", 2], queryFn: fn.fn)))
        #expect(model.result.isLoading)
        #expect(model.result.data == nil)
        #expect(fn.count == 1)
        await t.settle()
        #expect(fn.last.key == ["a", 2])
        #expect(t.cache.find(["a", 1])?.observersCount == 0)
    }

    @Test("releasing the model unsubscribes")
    func teardown() async {
        let t = TestEnv()
        var model: ObserverModel<QueryObserver<String, String>>? = ObserverModel()
        model?.update(client: t.client, options: QueryObserverOptions(QueryOptions(key: ["a"], queryFn: Immediate("A").fn)))
        await t.settle()
        #expect(t.cache.find(["a"])?.observersCount == 1)
        model = nil
        await t.settle()
        #expect(t.cache.find(["a"])?.observersCount == 0)
    }

    @Test("mutation model reflects mutate()")
    func mutation() async throws {
        let t = TestEnv()
        let model = ObserverModel<MutationObserver<String, String, Void>>()
        model.update(client: t.client, options: MutationOptions<String, String, Void> { "saved \($0)" })
        await t.settle()
        #expect(model.result.isIdle)
        _ = try await model.observer?.mutate("x")
        #expect(model.result.data == "saved x")
    }

    @Test("infinite model loads more pages")
    func infinite() async {
        let t = TestEnv()
        let model = ObserverModel<InfiniteQueryObserver<String, Int, InfiniteData<String, Int>>>()
        model.update(client: t.client, options: InfiniteQueryOptions(
            key: ["feed"], initialPageParam: 0, getNextPageParam: { _, _, p, _ in p + 1 }
        ) { @MainActor ctx in "p\(ctx.pageParam)" })
        await t.settle()
        await model.observer?.fetchNextPage()
        #expect(model.result.data?.pages == ["p0", "p1"])
        #expect(model.result.hasNextPage)
    }

    #if os(macOS)
    @Test("@ObservedQuery renders inside a real view hierarchy")
    func hostedView() async {
        let t = TestEnv()
        let fn = Immediate("hello")
        let view = HostedQueryView(options: QueryOptions(key: ["greeting"], queryFn: fn.fn)).queryClient(t.client)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        host.layoutSubtreeIfNeeded()
        await t.settle()
        host.layoutSubtreeIfNeeded()
        #expect(fn.count == 1)
        #expect(t.client.getQueryData(["greeting"], as: String.self) == "hello")
        #expect(t.cache.find(["greeting"])?.observersCount == 1)
    }

    @Test("persisting .queryClient restores before queries fetch")
    func hostedPersistedView() async throws {
        let source = TestEnv()
        source.client.setQueryData(["greeting"], "from disk")
        let storage = InMemoryQueryStorage()
        try await source.client.save(to: StoragePersister(storage: storage, clock: source.clock))

        let t = TestEnv()
        let fn = Immediate("network")
        let persister = StoragePersister(storage: storage, clock: t.clock)
        let view = HostedQueryView(options: QueryOptions(key: ["greeting"], staleTime: .infinity, queryFn: fn.fn))
            .queryClient(t.client, persister: persister)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            await t.settle()
        }
        #expect(fn.count == 0)
        #expect(t.client.getQueryData(["greeting"], as: String.self) == "from disk")
        #expect(t.cache.find(["greeting"])?.observersCount == 1)
    }

    @Test("list, select and counter wrappers work in a real view")
    func hostedWrappers() async {
        let t = TestEnv()
        let fn = Immediate("hello")
        let probe = WrapperProbe()
        let view = WrappersView(fn: fn.fn, probe: probe).queryClient(t.client)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            await t.settle()
        }
        #expect(probe.lastLengths == [5, 5])
        #expect(probe.lastSelected == 5)
        #expect(probe.lastFetching == 0)
        #expect(probe.lastMutations == 0)
    }
    #endif
}

@MainActor
private final class WrapperProbe {
    var lastLengths: [Int?] = []
    var lastSelected: Int?
    var lastFetching = -1
    var lastMutations = -1
}

private struct WrappersView: View {
    @ObservedQueries var items: [QueryObserverResult<String>]
    @ObservedSelectQuery<String, Int> var length: QueryObserverResult<Int>
    @ObservedIsFetching var fetching: Int
    @ObservedMutationState var mutations: [DehydratedMutationState]
    let probe: WrapperProbe

    init(fn: @escaping QueryFunction<String>, probe: WrapperProbe) {
        _items = ObservedQueries([QueryOptions(key: ["x", 1], queryFn: fn), QueryOptions(key: ["x", 2], queryFn: fn)])
        _length = ObservedSelectQuery(QueryOptions(key: ["x", 1], queryFn: fn)) { $0.count }
        _fetching = ObservedIsFetching()
        _mutations = ObservedMutationState()
        self.probe = probe
    }

    var body: some View {
        probe.lastLengths = items.map { $0.data?.count }
        probe.lastSelected = length.data
        probe.lastFetching = fetching
        probe.lastMutations = mutations.count
        return Text("\(items.count)")
    }
}

private struct HostedQueryView: View {
    @ObservedQuery var greeting: QueryObserverResult<String>
    init(options: QueryOptions<String>) { _greeting = ObservedQuery(options) }
    var body: some View { Text(greeting.data ?? "loading") }
}

@MainActor
@Suite("swiftui-adapter (lists and counters)")
struct SwiftUIAdapterListTests {
    @Test("queries model reports results in order and follows list changes")
    func queries() async {
        let t = TestEnv()
        let a = Immediate("A")
        let b = Immediate("B")
        let model = ObserverModel<QueriesObserver<String, String, [QueryObserverResult<String>]>>()
        let qa = QueryObserverOptions(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: a.fn))
        let qb = QueryObserverOptions(QueryOptions(key: ["b"], staleTime: .infinity, queryFn: b.fn))
        model.update(client: t.client, options: [qa, qb])
        #expect(model.result.map(\.isLoading) == [true, true])
        await t.settle()
        #expect(model.result.map(\.data) == ["A", "B"])
        model.update(client: t.client, options: [qb])
        #expect(model.result.map(\.data) == ["B"])
        await t.settle()
        #expect(t.cache.find(["a"])?.observersCount == 0)
        #expect(a.count == 1)
    }

    @Test("counter model follows fetching and mutating counts")
    func counters() async {
        let t = TestEnv()
        let fetching = CacheValueModel<Int>()
        fetching.update(client: t.client) { $0.isFetching() }
        await t.settle()
        #expect(fetching.value == 0)
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        #expect(fetching.value == 1)
        await fn.resolveLast("A")
        #expect(fetching.value == 0)

        let states = CacheValueModel<[MutationStatus]>()
        states.update(client: t.client) { $0.mutationCache.findAll().map(\.status) }
        await t.settle()
        _ = try? await MutationObserver(client: t.client, options: MutationOptions<Void, String, Void> { _ in "ok" }).mutate(())
        await t.settle()
        #expect(states.value == [.success])
    }

    @Test("select model derives the value")
    func select() async {
        let t = TestEnv()
        let model = ObserverModel<QueryObserver<String, Int>>()
        model.update(client: t.client, options: QueryObserverOptions(QueryOptions(key: ["a"], queryFn: Immediate("hello").fn)) { $0.count })
        await t.settle()
        #expect(model.result.data == 5)
    }
}
