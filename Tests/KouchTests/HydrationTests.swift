import Testing
@testable import Kouch

@MainActor
@Suite("hydration")
struct HydrationTests {
    @Test("[hyd-001] dehydrate keeps successful queries by default")
    func dehydrateDefault() async {
        let t = TestEnv()
        t.client.setQueryData(["ok"], "A")
        t.prefetch(QueryOptions(key: ["pending"], queryFn: Controlled<String>().fn))
        await t.client.prefetchQuery(QueryOptions(key: ["bad"], queryFn: Failing(t).fn))
        await t.advance(100)
        let snapshot = t.client.dehydrate()
        #expect(snapshot.queries.count == 1)
        let q = snapshot.queries[0]
        #expect(q.queryKey == ["ok"])
        #expect(q.state.data as? String == "A")
        #expect(q.state.dataUpdatedAt == T0)
        #expect(q.state.status == .success)
        #expect(q.dehydratedAt == ms(100))
    }

    @Test("[hyd-002] hydrate creates idle queries without fetching")
    func hydrateCreates() async {
        let source = TestEnv()
        source.client.setQueryData(["ok"], "A")
        let snapshot = source.client.dehydrate()
        let t = TestEnv()
        t.client.hydrate(snapshot)
        await t.settle()
        let s = t.state(["ok"])!
        #expect(s.data == "A")
        #expect(s.dataUpdatedAt == T0)
        #expect(s.status == .success)
        #expect(s.fetchStatus == .idle)
        #expect(t.client.isFetching() == 0)
    }

    @Test("[hyd-003] older snapshots do not overwrite newer data")
    func olderIgnored() async {
        let source = TestEnv()
        source.client.setQueryData(["ok"], "old")
        let snapshot = source.client.dehydrate()
        let t = TestEnv()
        await t.advance(1000)
        t.client.setQueryData(["ok"], "new")
        t.client.hydrate(snapshot)
        #expect(t.client.getQueryData(["ok"], as: String.self) == "new")
    }

    @Test("[hyd-004] newer snapshots overwrite older data")
    func newerApplied() async {
        let t = TestEnv()
        t.client.setQueryData(["ok"], "old")
        let source = TestEnv()
        await source.advance(1000)
        source.client.setQueryData(["ok"], "new")
        t.client.hydrate(source.client.dehydrate())
        #expect(t.client.getQueryData(["ok"], as: String.self) == "new")
        #expect(t.state(["ok"])?.dataUpdatedAt == ms(1000))
    }

    @Test("[hyd-005] shouldDehydrateQuery")
    func customFilter() async {
        let source = TestEnv()
        await source.client.prefetchQuery(QueryOptions(key: ["bad"], queryFn: Failing(source).fn))
        let snapshot = source.client.dehydrate(DehydrateOptions(shouldDehydrateQuery: { _ in true }))
        #expect(snapshot.queries.map(\.queryKey) == [["bad"]])
        #expect(snapshot.queries.map(\.state.status) == [.error])
        let t = TestEnv()
        t.client.hydrate(snapshot)
        #expect(t.client.getQueryState(["bad"], as: String.self)?.status == .error)
    }

    @Test("[hyd-006] hydrated data keeps its age")
    func keepsAge() async {
        let source = TestEnv()
        source.client.setQueryData(["ok"], "A")
        let snapshot = source.client.dehydrate()

        let t1 = TestEnv()
        await t1.advance(5000)
        t1.client.hydrate(snapshot)
        let f1 = Immediate("B")
        _ = t1.observe(QueryOptions(key: ["ok"], staleTime: .milliseconds(1000), queryFn: f1.fn))
        await t1.settle()
        #expect(f1.count == 1)

        let t2 = TestEnv()
        await t2.advance(5000)
        t2.client.hydrate(snapshot)
        let f2 = Immediate("B")
        _ = t2.observe(QueryOptions(key: ["ok"], staleTime: .milliseconds(10_000), queryFn: f2.fn))
        await t2.settle()
        #expect(f2.count == 0)
    }

    @Test("[hyd-007] serializeData / deserializeData")
    func transforms() {
        let source = TestEnv()
        source.client.setQueryData(["ok"], "A")
        let snapshot = source.client.dehydrate(DehydrateOptions(serializeData: { _, data in (data as! String) + "|s" }))
        #expect(snapshot.queries[0].state.data as? String == "A|s")
        let t = TestEnv()
        t.client.hydrate(snapshot, options: HydrateOptions(deserializeData: { _, data in (data as! String) + "|d" }))
        #expect(t.client.getQueryData(["ok"], as: String.self) == "A|s|d")
    }

    @Test("[hyd-008] paused mutations survive dehydration")
    func pausedMutations() async throws {
        let source = TestEnv()
        _ = try await MutationObserver(client: source.client, options: MutationOptions<Void, String, Void>(mutationKey: ["done"]) { _ in "ok" }).mutate(())
        source.online.setOnline(false)
        let paused = MutationObserver(client: source.client, options: MutationOptions<String, String, Void>(mutationKey: ["add"]) { _ in "x" })
        Task { try await paused.mutate("v") }
        await source.settle()
        let snapshot = source.client.dehydrate()
        #expect(snapshot.mutations.count == 1)
        let m = snapshot.mutations[0]
        #expect(m.mutationKey == ["add"])
        #expect(m.state.isPaused)
        #expect(m.state.variables as? String == "v")

        let t = TestEnv()
        let received = Log()
        t.client.setMutationDefaults(["add"], MutationOptions<String, String, Void> { @MainActor vars in
            received.append(vars)
            return "added"
        })
        t.client.hydrate(snapshot)
        await t.client.resumePausedMutations()
        await t.settle()
        #expect(received.entries == ["v"])
        #expect(t.client.mutationCache.getAll().first?.status == .success)
    }

    @Test("[hyd-009] hydrate default options")
    func hydrateDefaults() async {
        let source = TestEnv()
        source.client.setQueryData(["ok"], "A")
        let t = TestEnv()
        t.client.hydrate(source.client.dehydrate(), options: HydrateOptions(queries: QueryConfiguration(gcTime: .milliseconds(1000))))
        await t.advance(999)
        #expect(t.exists(["ok"]))
        await t.advance(1)
        #expect(!t.exists(["ok"]))
    }
}

@MainActor
private final class Log {
    var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}
