import Testing
@testable import SwiftQuery

/// A stream the test feeds chunk by chunk; each `streamFn` call opens a new one.
@MainActor
private final class Channel<T: Sendable> {
    private var continuation: AsyncStream<T>.Continuation?
    private let readSignal: Bool
    private(set) var signal: CancellationSignal?

    init(readSignal: Bool = false) { self.readSignal = readSignal }

    var streamFn: @Sendable (QueryFunctionContext) async throws -> AsyncStream<T> {
        { @MainActor [self] context in
            if readSignal { signal = context.signal }
            let (stream, continuation) = AsyncStream.makeStream(of: T.self)
            self.continuation = continuation
            return stream
        }
    }

    func push(_ value: T) async {
        continuation?.yield(value)
        await drain()
    }

    func end() async {
        continuation?.finish()
        await drain()
    }
}

@MainActor
@Suite("streamed-query")
struct StreamedQueryTests {
    @Test("[sq-001] chunks are appended as they arrive")
    func appends() async {
        let t = TestEnv()
        let ch = Channel<String>()
        let o = t.observe(QueryOptions(key: ["s"], queryFn: streamedQuery(streamFn: ch.streamFn)))
        await t.settle()
        #expect(o.current.status == .pending)
        await ch.push("a")
        #expect(o.current.data == ["a"])
        #expect(o.current.status == .success)
        #expect(o.current.fetchStatus == .fetching)
        await ch.push("b")
        #expect(o.current.data == ["a", "b"])
        await ch.end()
        #expect(o.current.data == ["a", "b"])
        #expect(o.current.fetchStatus == .idle)
    }

    @Test("[sq-002] refetchMode reset (default) clears data when a refetch starts")
    func reset() async {
        let t = TestEnv()
        let ch = Channel<String>()
        let o = t.observe(QueryOptions(key: ["s"], queryFn: streamedQuery(streamFn: ch.streamFn)))
        await t.settle()
        await ch.push("a")
        await ch.end()
        Task { await o.observer.refetch() }
        await t.settle()
        #expect(o.current.status == .pending)
        #expect(o.current.data == nil)
        #expect(o.current.fetchStatus == .fetching)
        await ch.push("b")
        #expect(o.current.data == ["b"])
        await ch.end()
    }

    @Test("[sq-003] refetchMode append keeps old data and appends")
    func append() async {
        let t = TestEnv()
        let ch = Channel<String>()
        let o = t.observe(QueryOptions(key: ["s"], queryFn: streamedQuery(refetchMode: .append, streamFn: ch.streamFn)))
        await t.settle()
        await ch.push("a")
        await ch.end()
        Task { await o.observer.refetch() }
        await t.settle()
        #expect(o.current.data == ["a"])
        await ch.push("b")
        #expect(o.current.data == ["a", "b"])
        await ch.end()
    }

    @Test("[sq-004] refetchMode replace swaps data in once the stream ends")
    func replace() async {
        let t = TestEnv()
        let ch = Channel<String>()
        let o = t.observe(QueryOptions(key: ["s"], queryFn: streamedQuery(refetchMode: .replace, streamFn: ch.streamFn)))
        await t.settle()
        await ch.push("a")
        await ch.end()
        Task { await o.observer.refetch() }
        await t.settle()
        await ch.push("b")
        await ch.push("c")
        #expect(o.current.data == ["a"])
        await ch.end()
        #expect(o.current.data == ["b", "c"])
    }

    @Test("[sq-005] reducer and initialValue")
    func reducer() async {
        let t = TestEnv()
        let ch = Channel<Int>()
        let o = t.observe(QueryOptions(key: ["sum"], queryFn: streamedQuery(initialValue: 0, reducer: { $0 + $1 }, streamFn: ch.streamFn)))
        await t.settle()
        await ch.push(2)
        await ch.push(3)
        #expect(o.current.data == 5)
        await ch.end()
        #expect(o.current.data == 5)
    }

    @Test("[sq-006] cancelling mid-stream keeps received chunks and stops listening")
    func cancel() async {
        let t = TestEnv()
        let ch = Channel<String>(readSignal: true)
        _ = t.observe(QueryOptions(key: ["s"], queryFn: streamedQuery(streamFn: ch.streamFn)))
        await t.settle()
        await ch.push("a")
        await t.client.cancelQueries()
        await ch.push("b")
        let s = t.client.getQueryState(["s"], as: [String].self)!
        #expect(s.data == ["a"])
        #expect(s.status == .success)
        #expect(s.fetchStatus == .idle)
        #expect(ch.signal?.isCancelled == true)
    }
}
