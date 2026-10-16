import Testing
@testable import Kouch

@MainActor
@Suite("query-key")
struct QueryKeyTests {
    private func keys(_ queries: [AnyQuery]) -> [String] { queries.map(\.queryKey.description).sorted() }

    @Test("[key-001] object key order does not affect identity")
    func objectKeyOrder() {
        let t = TestEnv()
        let a = t.cache.build(QueryOptions<String>(key: ["todos", ["status": "done", "page": 1]]))
        let b = t.cache.build(QueryOptions<String>(key: ["todos", ["page": 1, "status": "done"]]))
        #expect(a === b)
        #expect(t.cache.getAll().count == 1)
    }

    @Test("[key-002] different keys are different queries")
    func differentKeys() {
        let t = TestEnv()
        #expect(t.cache.build(QueryOptions<String>(key: ["user", 1])) !== t.cache.build(QueryOptions<String>(key: ["user", 2])))
        #expect(t.cache.getAll().count == 2)
    }

    @Test("[key-003] array element order matters")
    func arrayOrder() {
        let t = TestEnv()
        #expect(t.cache.build(QueryOptions<String>(key: ["a", 1, 2])) !== t.cache.build(QueryOptions<String>(key: ["a", 2, 1])))
    }

    @Test("[key-004] prefix filter matches by leading elements")
    func prefixFilter() {
        let t = TestEnv()
        let all: [QueryKey] = [["todos"], ["todos", 1], ["todos", ["done": true]], ["todo"], ["posts"]]
        for key in all { _ = t.cache.build(QueryOptions<String>(key: key)) }
        let expected: [QueryKey] = [["todos"], ["todos", 1], ["todos", ["done": true]]]
        #expect(keys(t.cache.findAll(QueryFilters(queryKey: ["todos"]))) == expected.map(\.description).sorted())
    }

    @Test("[key-005] object filter element matches by subset")
    func objectSubset() {
        let t = TestEnv()
        _ = t.cache.build(QueryOptions<String>(key: ["todos", ["status": "done", "page": 1]]))
        _ = t.cache.build(QueryOptions<String>(key: ["todos", ["status": "open", "page": 1]]))
        let found = t.cache.findAll(QueryFilters(queryKey: ["todos", ["status": "done"]]))
        #expect(found.map(\.queryKey) == [["todos", ["status": "done", "page": 1]]])
    }

    @Test("[key-006] exact filter matches only the identical key")
    func exactFilter() {
        let t = TestEnv()
        _ = t.cache.build(QueryOptions<String>(key: ["todos"]))
        _ = t.cache.build(QueryOptions<String>(key: ["todos", 1]))
        #expect(t.cache.findAll(QueryFilters(queryKey: ["todos"], exact: true)).map(\.queryKey) == [["todos"]])
    }
}
