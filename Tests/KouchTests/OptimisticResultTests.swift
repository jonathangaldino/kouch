import Testing
@testable import Kouch

@MainActor
@Suite("optimistic-result")
struct OptimisticResultTests {
    @Test("[opt-001] unmounted observer, empty cache")
    func unmountedEmpty() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let options = QueryOptions(key: ["a"], queryFn: fn.fn)
        let observer = QueryObserver(client: t.client, options: options)
        let r = observer.getOptimisticResult(QueryObserverOptions(options))
        #expect(r.status == .pending)
        #expect(r.fetchStatus == .fetching)
        #expect(r.isLoading)
        await t.settle()
        #expect(fn.count == 0)
        #expect(t.state(["a"])?.fetchStatus == .idle)
        #expect(observer.currentResult.fetchStatus == .fetching)
    }

    @Test("[opt-002] fresh cached data")
    func freshData() {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let options = QueryOptions(key: ["a"], staleTime: .infinity, queryFn: Controlled<String>().fn)
        let r = QueryObserver(client: t.client, options: options).getOptimisticResult(QueryObserverOptions(options))
        #expect(r.status == .success)
        #expect(r.data == "A")
        #expect(r.fetchStatus == .idle)
    }

    @Test("[opt-003] disabled")
    func disabled() {
        let t = TestEnv()
        let options = QueryOptions(key: ["a"], enabled: false, queryFn: Controlled<String>().fn)
        let r = QueryObserver(client: t.client, options: options).getOptimisticResult(QueryObserverOptions(options))
        #expect(r.status == .pending)
        #expect(r.fetchStatus == .idle)
    }

    @Test("[opt-004] mounted observer, new key")
    func mountedNewKey() async {
        let t = TestEnv()
        let o = t.observe(QueryOptions(key: ["a", 1], queryFn: Immediate("one").fn))
        await t.settle()
        let fn2 = Controlled<String>()
        let r = o.observer.getOptimisticResult(QueryObserverOptions(QueryOptions(key: ["a", 2], queryFn: fn2.fn)))
        #expect(r.status == .pending)
        #expect(r.fetchStatus == .fetching)
        #expect(r.data == nil)
        await t.settle()
        #expect(fn2.count == 0)
        #expect(o.observer.query.queryKey == ["a", 1])
    }
}
