import Testing
@testable import SwiftQuery

@MainActor
@Suite("query-lifecycle")
struct QueryLifecycleTests {
    @Test("[life-001] a new query starts pending and idle")
    func initialState() {
        let t = TestEnv()
        let q = t.cache.build(QueryOptions<String>(key: ["a"]))
        #expect(q.state.status == .pending)
        #expect(q.state.fetchStatus == .idle)
        #expect(q.state.data == nil)
        #expect(q.state.error == nil)
        #expect(q.state.dataUpdatedAt == nil)
        #expect(q.state.dataUpdateCount == 0)
        #expect(q.state.errorUpdateCount == 0)
        #expect(q.state.isInvalidated == false)
    }

    @Test("[life-002] starting a fetch moves fetchStatus to fetching")
    func fetchStarts() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        let s = t.state(["a"])!
        #expect(s.status == .pending)
        #expect(s.fetchStatus == .fetching)
        #expect(fn.count == 1)
        #expect(fn.last.key == ["a"])
    }

    @Test("[life-003] successful fetch")
    func success() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await t.advance(100)
        await fn.resolveLast("A")
        let s = t.state(["a"])!
        #expect(s.status == .success)
        #expect(s.fetchStatus == .idle)
        #expect(s.data == "A")
        #expect(s.error == nil)
        #expect(s.dataUpdatedAt == ms(100))
        #expect(s.dataUpdateCount == 1)
        #expect(s.fetchFailureCount == 0)
        #expect(s.isInvalidated == false)
    }

    @Test("[life-004] failed fetch without data")
    func failure() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], retry: 0, queryFn: fn.fn))
        await t.settle()
        await fn.rejectLast(TestError())
        let s = t.state(["a"])!
        #expect(s.status == .error)
        #expect(s.fetchStatus == .idle)
        #expect(s.error as? TestError == TestError())
        #expect(s.data == nil)
        #expect(s.errorUpdateCount == 1)
        #expect(s.fetchFailureCount == 1)
        #expect(s.fetchFailureReason as? TestError == TestError())
        #expect(s.isInvalidated == true)
    }

    @Test("[life-005] failed refetch keeps previous data")
    func failedRefetch() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.client.setQueryData(["a"], "A")
        t.prefetch(QueryOptions(key: ["a"], retry: 0, queryFn: fn.fn))
        await t.settle()
        await fn.rejectLast(TestError())
        let s = t.state(["a"])!
        #expect(s.status == .error)
        #expect(s.error as? TestError == TestError())
        #expect(s.data == "A")
    }

    @Test("[life-006] initial data seeds a success state")
    func initialData() {
        let t = TestEnv()
        let q = t.cache.build(QueryOptions<String>(key: ["a"], initialData: "init"))
        #expect(q.state.status == .success)
        #expect(q.state.fetchStatus == .idle)
        #expect(q.state.data == "init")
        #expect(q.state.dataUpdatedAt == T0)
        #expect(q.state.dataUpdateCount == 0)
        let q2 = t.cache.build(QueryOptions<String>(key: ["b"], initialData: "init", initialDataUpdatedAt: .init(timeIntervalSince1970: 0.042)))
        #expect(q2.state.dataUpdatedAt == .init(timeIntervalSince1970: 0.042))
    }

    @Test("[life-007] refetch with data stays success while fetching")
    func refetchWithData() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.client.setQueryData(["a"], "A")
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        var s = t.state(["a"])!
        #expect(s.status == .success)
        #expect(s.fetchStatus == .fetching)
        #expect(s.data == "A")
        await fn.resolveLast("B")
        s = t.state(["a"])!
        #expect(s.status == .success)
        #expect(s.fetchStatus == .idle)
        #expect(s.data == "B")
        #expect(s.dataUpdateCount == 2)
    }

    @Test("[life-008] reset returns to the initial state")
    func reset() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        await fn.resolveLast("A")
        _ = t.cache.build(QueryOptions<String>(key: ["b"], initialData: "init"))
        t.client.setQueryData(["b"], "changed")
        await t.client.resetQueries()
        let a = t.state(["a"])!
        #expect(a.status == .pending)
        #expect(a.data == nil)
        #expect(a.dataUpdateCount == 0)
        let b = t.state(["b"])!
        #expect(b.status == .success)
        #expect(b.data == "init")
    }
}
