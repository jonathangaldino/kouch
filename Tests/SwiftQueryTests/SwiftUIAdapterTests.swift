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
    #endif
}

private struct HostedQueryView: View {
    @ObservedQuery var greeting: QueryObserverResult<String>
    init(options: QueryOptions<String>) { _greeting = ObservedQuery(options) }
    var body: some View { Text(greeting.data ?? "loading") }
}
