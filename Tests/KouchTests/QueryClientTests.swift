import Foundation
import Testing
@testable import Kouch

@MainActor
@Suite("query-client")
struct QueryClientTests {
    @Test("[client-001] fetchQuery fetches, caches and resolves")
    func fetchQuery() async throws {
        let t = TestEnv()
        let data = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: Immediate("A").fn))
        #expect(data == "A")
        #expect(t.client.getQueryData(["a"], as: String.self) == "A")
    }

    @Test("[client-002] fetchQuery returns fresh cached data without calling fn")
    func fetchQueryFresh() async throws {
        let t = TestEnv()
        let fn = Immediate("A")
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.advance(500)
        #expect(try await t.client.fetchQuery(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: fn.fn)) == "A")
        #expect(fn.count == 1)
        await t.advance(500)
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], staleTime: .milliseconds(1000), queryFn: fn.fn))
        #expect(fn.count == 2)
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn))
        #expect(fn.count == 3)
    }

    @Test("[client-003] fetchQuery does not retry by default")
    func fetchQueryNoRetry() async {
        let t = TestEnv()
        let fn = Failing(t)
        await #expect(throws: TestError()) { try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: fn.fn)) }
        #expect(fn.count == 1)
    }

    @Test("[client-004] prefetchQuery never throws")
    func prefetchNeverThrows() async {
        let t = TestEnv()
        await t.client.prefetchQuery(QueryOptions(key: ["a"], queryFn: Failing(t).fn))
        #expect(t.state(["a"])?.status == .error)
    }

    @Test("[client-005] ensureQueryData")
    func ensureQueryData() async throws {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        let fn = Immediate("fetched")
        #expect(try await t.client.ensureQueryData(QueryOptions(key: ["a"], queryFn: fn.fn)) == "A")
        #expect(fn.count == 0)
        #expect(try await t.client.ensureQueryData(QueryOptions(key: ["missing"], queryFn: fn.fn)) == "fetched")
        #expect(fn.count == 1)
        let fn2 = Controlled<String>()
        #expect(try await t.client.ensureQueryData(QueryOptions(key: ["a"], queryFn: fn2.fn), revalidateIfStale: true) == "A")
        await t.settle()
        #expect(fn2.count == 1)
    }

    @Test("[client-006] getQueryData / setQueryData")
    func getSetQueryData() {
        let t = TestEnv()
        #expect(t.client.getQueryData(["none"], as: String.self) == nil)
        #expect(t.cache.getAll().isEmpty)
        #expect(t.client.setQueryData(["a"], "A") == "A")
        let s = t.state(["a"])!
        #expect(s.status == .success)
        #expect(s.data == "A")
        #expect(s.dataUpdatedAt == T0)
        #expect(s.fetchStatus == .idle)
        var received: String?
        t.client.setQueryData(["a"], as: String.self) { prev in
            received = prev
            return prev! + "!"
        }
        #expect(received == "A")
        #expect(t.client.getQueryData(["a"], as: String.self) == "A!")
        #expect(t.client.setQueryData(["a"], as: String.self) { _ in nil } == nil)
        #expect(t.client.getQueryData(["a"], as: String.self) == "A!")
        t.client.setQueryData(["b"], "B", updatedAt: Date(timeIntervalSince1970: 0.042))
        #expect(t.state(["b"])?.dataUpdatedAt == Date(timeIntervalSince1970: 0.042))
    }

    @Test("[client-007] setQueryData updates observers without fetching")
    func setQueryDataNotifies() async {
        let t = TestEnv()
        let fn = Immediate("A")
        let o = t.observe(QueryOptions(key: ["a"], staleTime: .infinity, queryFn: fn.fn))
        await t.settle()
        t.client.setQueryData(["a"], "B")
        #expect(o.results.last?.data == "B")
        #expect(fn.count == 1)
    }

    @Test("[client-008] setQueryData during an in-flight fetch")
    func setQueryDataInFlight() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fn.fn))
        await t.settle()
        t.client.setQueryData(["a"], "manual")
        #expect(t.state(["a"])?.data == "manual")
        #expect(t.state(["a"])?.fetchStatus == .fetching)
        await fn.resolveLast("server")
        #expect(t.state(["a"])?.data == "server")
        #expect(t.state(["a"])?.fetchStatus == .idle)
    }

    @Test("[client-009] getQueryState and removeQueries")
    func removeQueries() {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        #expect(t.state(["a"])?.status == .success)
        t.client.removeQueries(QueryFilters(queryKey: ["a"]))
        #expect(t.state(["a"]) == nil)
        #expect(t.client.getQueryData(["a"], as: String.self) == nil)
    }

    @Test("[client-010] isFetching counts fetching queries")
    func isFetching() async {
        let t = TestEnv()
        let fa = Controlled<String>()
        let fb = Controlled<String>()
        t.prefetch(QueryOptions(key: ["a"], queryFn: fa.fn))
        t.prefetch(QueryOptions(key: ["b"], queryFn: fb.fn))
        await t.settle()
        #expect(t.client.isFetching() == 2)
        #expect(t.client.isFetching(QueryFilters(queryKey: ["a"])) == 1)
        await fa.resolveLast("A")
        await fb.resolveLast("B")
        #expect(t.client.isFetching() == 0)
    }

    @Test("[client-011] default options")
    func defaultOptions() async throws {
        let t = TestEnv(defaultOptions: QueryConfiguration(staleTime: .milliseconds(1000)))
        t.client.setQueryDefaults(["todos"], QueryConfiguration(staleTime: .infinity))
        let todos = Immediate("t")
        let other = Immediate("o")
        _ = try await t.client.fetchQuery(QueryOptions(key: ["todos", 1], queryFn: todos.fn))
        _ = try await t.client.fetchQuery(QueryOptions(key: ["other"], queryFn: other.fn))
        await t.advance(5000)
        _ = try await t.client.fetchQuery(QueryOptions(key: ["todos", 1], queryFn: todos.fn))
        _ = try await t.client.fetchQuery(QueryOptions(key: ["other"], queryFn: other.fn))
        #expect(todos.count == 1)
        #expect(other.count == 2)
    }
}
