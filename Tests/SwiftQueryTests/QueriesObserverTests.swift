import Testing
@testable import SwiftQuery

@MainActor
private final class RecordedQueries<Combined: Sendable> {
    let observer: QueriesObserver<String, String, Combined>
    private(set) var notifications = 0
    private var subscription: Subscription?
    init(_ observer: QueriesObserver<String, String, Combined>) {
        self.observer = observer
        subscription = observer.subscribe { [weak self] _ in self?.notifications += 1 }
    }
    func unsubscribe() { subscription?.cancel() }
}

@MainActor
@Suite("queries-observer")
struct QueriesObserverTests {
    @Test("[qs-001] results in input order; each query fetched once")
    func inputOrder() async {
        let t = TestEnv()
        let a = Controlled<String>()
        let b = Controlled<String>()
        let o = RecordedQueries(QueriesObserver(client: t.client, queries: [
            QueryOptions(key: ["a"], queryFn: a.fn), QueryOptions(key: ["b"], queryFn: b.fn),
        ]))
        await t.settle()
        #expect(a.count == 1)
        #expect(b.count == 1)
        let before = o.notifications
        await a.resolveLast("A")
        #expect(o.notifications > before)
        let mid = o.notifications
        await b.resolveLast("B")
        #expect(o.notifications > mid)
        #expect(o.observer.results.map(\.data) == ["A", "B"])
    }

    @Test("[qs-002] shares the cache with other observers")
    func sharesCache() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        _ = t.observe(QueryOptions(key: ["a"], queryFn: fn.fn))
        _ = RecordedQueries(QueriesObserver(client: t.client, queries: [QueryOptions(key: ["a"], queryFn: fn.fn)]))
        await t.settle()
        #expect(fn.count == 1)
    }

    @Test("[qs-003] setQueries adds and removes entries")
    func setQueries() async {
        let t = TestEnv()
        let a = Immediate("A")
        let b = Immediate("B")
        let c = Controlled<String>()
        let o = RecordedQueries(QueriesObserver(client: t.client, queries: [
            QueryOptions(key: ["a"], staleTime: .infinity, queryFn: a.fn),
            QueryOptions(key: ["b"], staleTime: .infinity, queryFn: b.fn),
        ]))
        await t.settle()
        o.observer.setQueries([
            QueryOptions(key: ["b"], staleTime: .infinity, queryFn: b.fn),
            QueryOptions(key: ["c"], staleTime: .infinity, queryFn: c.fn),
        ])
        await t.settle()
        #expect(t.cache.find(["a"])?.observersCount == 0)
        #expect(t.cache.find(["b"])?.observersCount == 1)
        #expect(b.count == 1)
        #expect(c.count == 1)
        #expect(o.observer.queries.map(\.queryKey) == [["b"], ["c"]])
    }

    @Test("[qs-004] reordering keeps observers")
    func reorder() async {
        let t = TestEnv()
        let a = Immediate("A")
        let b = Immediate("B")
        let qa = QueryOptions(key: ["a"], staleTime: .infinity, queryFn: a.fn)
        let qb = QueryOptions(key: ["b"], staleTime: .infinity, queryFn: b.fn)
        let o = RecordedQueries(QueriesObserver(client: t.client, queries: [qa, qb]))
        await t.settle()
        o.observer.setQueries([qb, qa])
        await t.settle()
        #expect(a.count == 1)
        #expect(b.count == 1)
        #expect(o.observer.results.map(\.data) == ["B", "A"])
    }

    @Test("[qs-005] combine")
    func combine() async {
        let t = TestEnv()
        let a = Controlled<String>()
        let b = Controlled<String>()
        let o = RecordedQueries(QueriesObserver(
            client: t.client,
            queries: [QueryOptions(key: ["a"], queryFn: a.fn), QueryOptions(key: ["b"], queryFn: b.fn)],
            combine: { results in results.allSatisfy(\.isSuccess) }
        ))
        await t.settle()
        #expect(o.observer.combinedResult == false)
        await a.resolveLast("A")
        await b.resolveLast("B")
        #expect(o.observer.combinedResult == true)
    }

    @Test("[qs-006] unsubscribing unmounts every entry")
    func unsubscribe() async {
        let t = TestEnv()
        let o = RecordedQueries(QueriesObserver(client: t.client, queries: [
            QueryOptions(key: ["a"], queryFn: Controlled<String>().fn),
            QueryOptions(key: ["b"], queryFn: Controlled<String>().fn),
        ]))
        await t.settle()
        o.unsubscribe()
        #expect(t.cache.find(["a"])?.observersCount == 0)
        #expect(t.cache.find(["b"])?.observersCount == 0)
    }

    @Test("[qs-007] entries succeed and fail independently")
    func independent() async {
        let t = TestEnv()
        let ok = Controlled<String>()
        let bad = Controlled<String>()
        let o = RecordedQueries(QueriesObserver(client: t.client, queries: [
            QueryOptions(key: ["ok"], retry: false, queryFn: ok.fn),
            QueryOptions(key: ["bad"], retry: false, queryFn: bad.fn),
        ]))
        await t.settle()
        await ok.resolveLast("A")
        await bad.rejectLast(TestError())
        #expect(o.observer.results.map(\.status) == [.success, .error])
    }

    @Test("combine with Equatable output suppresses unchanged notifications")
    func combineSuppresses() async {
        let t = TestEnv()
        let a = Controlled<String>()
        let o = RecordedQueries(QueriesObserver(
            client: t.client, queries: [QueryOptions(key: ["a"], queryFn: a.fn)], combine: { $0.count }
        ))
        await t.settle()
        let before = o.notifications
        await a.resolveLast("A")
        #expect(o.notifications == before)
    }
}
