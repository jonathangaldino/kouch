import Foundation
import Testing
@testable import Kouch
@testable import KouchSwiftUI

@MainActor
private final class MemoryPersister: QueryPersister {
    var stored: PersistedClient?
    var restoreError: (any Error)?
    private(set) var persistCalls = 0
    private(set) var removeCalls = 0

    init(_ stored: PersistedClient? = nil, restoreError: (any Error)? = nil) {
        self.stored = stored
        self.restoreError = restoreError
    }

    func persistClient(_ client: PersistedClient) async throws {
        persistCalls += 1
        stored = client
    }

    func restoreClient() async throws -> PersistedClient? {
        if let restoreError { throw restoreError }
        return stored
    }

    func removeClient() async throws {
        removeCalls += 1
        stored = nil
    }
}

private actor CountingStorage: QueryStorage {
    private var items: [String: Foundation.Data] = [:]
    private(set) var writes = 0
    private var failures: Int

    init(failures: Int = 0) { self.failures = failures }

    func getItem(_ key: String) -> Foundation.Data? { items[key] }
    func setItem(_ key: String, _ value: Foundation.Data) throws {
        writes += 1
        if failures > 0 {
            failures -= 1
            throw TestError("quota")
        }
        items[key] = value
    }
    func removeItem(_ key: String) { items[key] = nil }
}

@MainActor
private func snapshot(_ t: TestEnv, _ key: QueryKeyValue, _ data: String, buster: String = "") -> PersistedClient {
    let source = TestEnv()
    source.client.setQueryData([key], data)
    return PersistedClient(buster: buster, timestamp: t.clock.now, clientState: source.client.dehydrate())
}

private func keysAndData(_ client: PersistedClient) -> [String] {
    client.clientState.queries.map { "\($0.queryKey)=\(castOrDecode($0.state.data, as: String.self) ?? "nil")" }
}

@MainActor
@Suite("persistence")
struct PersistenceTests {
    @Test("[per-001] save writes a timestamped snapshot")
    func save() async throws {
        let t = TestEnv()
        t.client.setQueryData(["a"], "A")
        await t.advance(100)
        let p = MemoryPersister()
        try await t.client.save(to: p, options: PersistOptions(buster: "v1"))
        #expect(p.persistCalls == 1)
        #expect(p.stored?.buster == "v1")
        #expect(p.stored?.timestamp == ms(100))
        #expect(p.stored.map(keysAndData) == ["[\"a\"]=A"])
    }

    @Test("[per-002] restore hydrates the snapshot")
    func restore() async throws {
        let t = TestEnv()
        let p = MemoryPersister(snapshot(t, "a", "A"))
        try await t.client.restore(from: p)
        #expect(t.client.getQueryData(["a"], as: String.self) == "A")
        #expect(p.removeCalls == 0)
    }

    @Test("[per-003] nothing persisted")
    func nothing() async throws {
        let t = TestEnv()
        let p = MemoryPersister()
        try await t.client.restore(from: p)
        #expect(t.cache.getAll().isEmpty)
        #expect(p.removeCalls == 0)
    }

    @Test("[per-004] maxAge")
    func maxAge() async throws {
        let t = TestEnv()
        let saved = snapshot(t, "a", "A")
        await t.advance(1000)
        let fresh = TestEnv()
        await fresh.advance(1000)
        try await fresh.client.restore(from: MemoryPersister(saved), options: PersistOptions(maxAge: .milliseconds(1000)))
        #expect(fresh.client.getQueryData(["a"], as: String.self) == "A")

        let late = TestEnv()
        await late.advance(1001)
        let p = MemoryPersister(saved)
        try await late.client.restore(from: p, options: PersistOptions(maxAge: .milliseconds(1000)))
        #expect(late.client.getQueryData(["a"], as: String.self) == nil)
        #expect(p.removeCalls == 1)
    }

    @Test("[per-005] default maxAge is 24 hours")
    func defaultMaxAge() async throws {
        let t = TestEnv()
        let saved = snapshot(t, "a", "A")
        let day: Int64 = 24 * 3600 * 1000
        let t1 = TestEnv()
        await t1.advance(day)
        try await t1.client.restore(from: MemoryPersister(saved))
        #expect(t1.client.getQueryData(["a"], as: String.self) == "A")
        let t2 = TestEnv()
        await t2.advance(day + 1)
        let p = MemoryPersister(saved)
        try await t2.client.restore(from: p)
        #expect(t2.client.getQueryData(["a"], as: String.self) == nil)
        #expect(p.removeCalls == 1)
    }

    @Test("[per-006] buster mismatch discards the cache")
    func buster() async throws {
        let t = TestEnv()
        let p = MemoryPersister(snapshot(t, "a", "A", buster: "v1"))
        try await t.client.restore(from: p, options: PersistOptions(buster: "v2"))
        #expect(t.client.getQueryData(["a"], as: String.self) == nil)
        #expect(p.removeCalls == 1)
    }

    @Test("[per-007] restore errors discard the cache")
    func restoreError() async {
        let t = TestEnv()
        let p = MemoryPersister(restoreError: TestError("corrupt"))
        await #expect(throws: TestError("corrupt")) { try await t.client.restore(from: p) }
        #expect(p.removeCalls == 1)
    }

    @Test("[per-008] subscribe saves on every cache change")
    func subscribe() async throws {
        let t = TestEnv()
        let p = MemoryPersister()
        let subscription = t.client.subscribePersistence(p)
        _ = try await t.client.fetchQuery(QueryOptions(key: ["a"], queryFn: Immediate("A").fn))
        await t.settle()
        #expect(p.persistCalls == 3)
        _ = try await MutationObserver(client: t.client, options: MutationOptions<Void, String, Void> { _ in "ok" }).mutate(())
        await t.settle()
        #expect(p.persistCalls == 6)
        subscription.cancel()
        t.client.setQueryData(["a"], "B")
        await t.settle()
        #expect(p.persistCalls == 6)
    }

    @Test("[per-009] persistQueryClient restores first, then subscribes")
    func persistQueryClient() async throws {
        let t = TestEnv()
        let p = MemoryPersister(snapshot(t, "a", "A"))
        let session = t.client.persist(to: p)
        try await session.restored.value
        #expect(t.client.getQueryData(["a"], as: String.self) == "A")
        #expect(p.persistCalls == 0)
        t.client.setQueryData(["b"], "B")
        await t.settle()
        #expect(p.persistCalls == 2)

        let t2 = TestEnv()
        let p2 = MemoryPersister(snapshot(t2, "a", "A"))
        let session2 = t2.client.persist(to: p2)
        session2.cancel()
        try await session2.restored.value
        t2.client.setQueryData(["b"], "B")
        await t2.settle()
        #expect(p2.persistCalls == 0)
    }

    @Test("[per-010] storage persister throttles writes")
    func throttle() async throws {
        let t = TestEnv()
        let storage = CountingStorage()
        let persister = StoragePersister(storage: storage, throttle: .milliseconds(1000), clock: t.clock)
        let c = { (n: Int) in PersistedClient(buster: "c\(n)", timestamp: t.clock.now, clientState: DehydratedState()) }
        Task { try? await persister.persistClient(c(1)) }
        await t.settle()
        await t.advance(100)
        Task { try? await persister.persistClient(c(2)) }
        await t.advance(100)
        Task { try? await persister.persistClient(c(3)) }
        await t.settle()
        #expect(await storage.writes == 1)
        await t.advance(799)
        #expect(await storage.writes == 1)
        await t.advance(1)
        #expect(await storage.writes == 2)
        #expect(try await persister.restoreClient()?.buster == "c3")
    }

    @Test("[per-011] storage persister round trip")
    func roundTrip() async throws {
        let t = TestEnv()
        let persister = StoragePersister(storage: InMemoryQueryStorage(), clock: t.clock)
        let c = snapshot(t, "a", "A", buster: "v1")
        try await persister.persistClient(c)
        let restored = try #require(try await persister.restoreClient())
        #expect(restored.buster == "v1")
        #expect(restored.timestamp == c.timestamp)
        #expect(keysAndData(restored) == ["[\"a\"]=A"])
        try await persister.removeClient()
        #expect(try await persister.restoreClient() == nil)
    }

    @Test("[per-012] storage persister retry: removeOldestQuery")
    func retryRemovesOldest() async throws {
        let t = TestEnv()
        let storage = CountingStorage(failures: 1)
        let persister = StoragePersister(storage: storage, clock: t.clock, retry: removeOldestQuery)
        t.client.setQueryData(["old"], "O")
        await t.advance(100)
        t.client.setQueryData(["new"], "N")
        try await t.client.save(to: persister)
        await t.settle()
        #expect(await storage.writes == 2)
        #expect(try await persister.restoreClient()?.clientState.queries.map(\.queryKey) == [["new"]])
    }
}

private struct User: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var joined: Date
}

@MainActor
@Suite("persistence (Swift)")
struct PersistenceSwiftTests {
    @Test("Codable data survives a disk round trip and decodes on first typed read")
    func codableRoundTrip() async throws {
        let source = TestEnv()
        let user = User(id: 1, name: "Ada", joined: Date(timeIntervalSince1970: 1_700_000_000))
        source.client.setQueryData(["user", 1], user)
        let storage = InMemoryQueryStorage()
        try await source.client.save(to: StoragePersister(storage: storage, clock: source.clock))

        let t = TestEnv()
        try await t.client.restore(from: StoragePersister(storage: storage, clock: t.clock))
        #expect(t.cache.find(["user", 1])?.stateSummary.status == .success)
        #expect(t.client.getQueryData(["user", 1], as: User.self) == user)
        #expect(t.client.getQueryState(["user", 1], as: User.self)?.dataUpdatedAt == T0)

        let fn = Immediate(user)
        let o = t.observe(QueryOptions(key: ["user", 1], staleTime: .infinity, queryFn: fn.fn))
        #expect(o.current.data == user)
        await t.settle()
        #expect(fn.count == 0)
    }

    @Test("data that no longer decodes is dropped instead of crashing")
    func undecodable() async throws {
        let source = TestEnv()
        source.client.setQueryData(["user", 1], "not a user")
        let storage = InMemoryQueryStorage()
        try await source.client.save(to: StoragePersister(storage: storage, clock: source.clock))
        let t = TestEnv()
        try await t.client.restore(from: StoragePersister(storage: storage, clock: t.clock))
        #expect(t.client.getQueryData(["user", 1], as: User.self) == nil)
        #expect(t.client.getQueryState(["user", 1], as: User.self)?.status == .pending)
    }

    @Test("a paused mutation resumes after a disk round trip")
    func mutationRoundTrip() async throws {
        let source = TestEnv()
        source.online.setOnline(false)
        let paused = MutationObserver(client: source.client, options: MutationOptions<String, String, Void>(mutationKey: ["add"]) { _ in "x" })
        Task { _ = try? await paused.mutate("draft") }
        await source.settle()
        let storage = InMemoryQueryStorage()
        try await source.client.save(to: StoragePersister(storage: storage, clock: source.clock))

        let t = TestEnv()
        var received: [String] = []
        t.client.setMutationDefaults(["add"], MutationOptions<String, String, Void> { @MainActor vars in
            received.append(vars)
            return "added"
        })
        try await t.client.restore(from: StoragePersister(storage: storage, clock: t.clock))
        await t.client.resumePausedMutations()
        await t.settle()
        #expect(received == ["draft"])
    }

    @Test("a paused mutation with Void variables resumes after a disk round trip")
    func voidMutationRoundTrip() async throws {
        let source = TestEnv()
        source.online.setOnline(false)
        let paused = MutationObserver(client: source.client, options: MutationOptions<Void, String, Void>(mutationKey: ["sync"]) { _ in "x" })
        Task { _ = try? await paused.mutate(()) }
        await source.settle()
        let storage = InMemoryQueryStorage()
        try await source.client.save(to: StoragePersister(storage: storage, clock: source.clock))

        let t = TestEnv()
        let runs = CallCount()
        t.client.setMutationDefaults(["sync"], MutationOptions<Void, String, Void> { _ in
            runs.increment()
            return "synced"
        })
        try await t.client.restore(from: StoragePersister(storage: storage, clock: t.clock))
        await t.client.resumePausedMutations()
        await t.settle()
        #expect(runs.value == 1)
        #expect(t.client.mutationCache.getAll().first?.status == .success)
    }

    @Test("FileQueryStorage writes, reads and removes files")
    func fileStorage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "kouch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileQueryStorage(directory: directory)
        #expect(try await storage.getItem("k") == nil)
        try await storage.setItem("k", Foundation.Data("hello".utf8))
        #expect(try await storage.getItem("k") == Foundation.Data("hello".utf8))
        try await storage.removeItem("k")
        #expect(try await storage.getItem("k") == nil)
    }

    @Test("while restoring, adapters render without fetching, then mount")
    func restoringAdapter() async {
        let t = TestEnv()
        let fn = Controlled<String>()
        let options = QueryObserverOptions(QueryOptions(key: ["a"], queryFn: fn.fn))
        let model = ObserverModel<QueryObserver<String, String>>()
        model.update(client: t.client, options: options, isRestoring: true)
        #expect(model.result.status == .pending)
        #expect(model.result.fetchStatus == .idle)
        await t.settle()
        #expect(fn.count == 0)
        t.client.setQueryData(["a"], "restored") // the restore lands
        model.update(client: t.client, options: options, isRestoring: false)
        await t.settle()
        #expect(model.observer?.hasListeners == true)
        #expect(model.result.data != nil)
    }
}
