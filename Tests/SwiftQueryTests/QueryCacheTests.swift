import Testing
@testable import SwiftQuery

@MainActor
@Suite("query-cache")
struct QueryCacheTests {
    @Test("[cache-001] build is idempotent per key")
    func buildIdempotent() {
        let t = TestEnv()
        var added = 0
        let sub = t.cache.subscribe { if case .added = $0 { added += 1 } }
        defer { sub.cancel() }
        let a = t.cache.build(QueryOptions<String>(key: ["a"]))
        let b = t.cache.build(QueryOptions<String>(key: ["a"]))
        #expect(a === b)
        #expect(t.cache.getAll().count == 1)
        #expect(added == 1)
    }

    @Test("[cache-002] find defaults to exact matching")
    func findExact() {
        let t = TestEnv()
        let todos = t.cache.build(QueryOptions<String>(key: ["todos"]))
        let todo1 = t.cache.build(QueryOptions<String>(key: ["todos", 1]))
        #expect(t.cache.find(QueryFilters(queryKey: ["todos"])) === todos)
        #expect(t.cache.find(QueryFilters(queryKey: ["todos", 1])) === todo1)
        #expect(t.cache.find(QueryFilters(queryKey: ["nope"])) == nil)
    }

    @Test("[cache-003] findAll filters by type, stale and fetchStatus")
    func findAllFilters() async throws {
        let t = TestEnv()
        _ = t.observe(QueryOptions(key: ["active"], staleTime: .infinity, queryFn: Immediate("x").fn))
        _ = try await t.client.fetchQuery(QueryOptions(key: ["inactive"], queryFn: Immediate("y").fn))
        t.fetch(QueryOptions(key: ["fetching"], queryFn: Controlled<String>().fn))
        await t.settle()
        func k(_ f: QueryFilters) -> [String] {
            t.cache.findAll(f).compactMap { if case .string(let s) = $0.queryKey.first { s } else { nil } }.sorted()
        }
        #expect(k(QueryFilters(type: .active)) == ["active"])
        #expect(k(QueryFilters(type: .inactive)) == ["fetching", "inactive"])
        #expect(k(QueryFilters(stale: false)) == ["active", "inactive"])
        #expect(k(QueryFilters(fetchStatus: .fetching)) == ["fetching"])
        #expect(k(QueryFilters(predicate: { $0.queryKey.first == "inactive" })) == ["inactive"])
    }

    @Test("[cache-004] cache events")
    func events() async throws {
        let t = TestEnv()
        var events: [String] = []
        let sub = t.cache.subscribe { event in
            switch event {
            case .added: events.append("added")
            case .updated: events.append("updated")
            case .removed: events.append("removed")
            default: break
            }
        }
        defer { sub.cancel() }
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: Immediate("A").fn))
        t.client.removeQueries(QueryFilters(queryKey: ["a"]))
        #expect(events == ["added", "updated", "updated", "removed"])
    }

    @Test("[cache-005] remove and clear")
    func removeAndClear() {
        let t = TestEnv()
        let a = t.cache.build(QueryOptions<String>(key: ["a"]))
        _ = t.cache.build(QueryOptions<String>(key: ["b"]))
        t.cache.remove(a)
        #expect(t.cache.find(["a"]) == nil)
        #expect(t.cache.getAll().count == 1)
        t.cache.clear()
        #expect(t.cache.getAll().isEmpty)
    }

    @Test("[cache-006] cache-level callbacks")
    func callbacks() async {
        var calls: [String] = []
        let config = QueryCacheConfig(
            onSuccess: { data, q in calls.append("success \(data) \(q.queryKey)") },
            onError: { error, q in calls.append("error \((error as! TestError).message) \(q.queryKey)") },
            onSettled: { data, error, q in
                calls.append("settled \(data.map { "\($0)" } ?? "nil") \((error as? TestError)?.message ?? "nil") \(q.queryKey)")
            }
        )
        let t = TestEnv(queryCache: QueryCache(config: config))
        _ = try? await t.client.fetchQuery(QueryOptions<String>(key: ["ok"], queryFn: Immediate("A").fn))
        _ = try? await t.client.fetchQuery(QueryOptions<String>(key: ["bad"], queryFn: { _ in throw TestError() }))
        #expect(calls == [
            "success A [\"ok\"]",
            "settled A nil [\"ok\"]",
            "error E [\"bad\"]",
            "settled nil E [\"bad\"]",
        ])
    }
}
