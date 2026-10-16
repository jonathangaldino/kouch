import Foundation
@testable import Kouch

/// Virtual time: 1 000 000 ms after the epoch, like the TanStack harness.
let T0 = date(ms: 1_000_000)

/// T0 + `value` milliseconds.
func ms(_ value: Int64) -> Date { date(ms: 1_000_000 + value) }

// Integer milliseconds keep virtual timestamps exactly comparable.
private func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

struct TestError: Error, Equatable {
    var message: String
    init(_ message: String = "E") { self.message = message }
}

/// Lets queued main-actor work run without moving virtual time (TanStack harness: `advance(0)`).
@MainActor
func drain() async {
    for _ in 0..<64 { await Task.yield() }
}

/// A clock whose time only moves when the test says so.
@MainActor
final class TestClock: QueryClock {
    private struct Sleeper {
        var id: Int
        var deadline: Int64
        var continuation: CheckedContinuation<Void, any Error>
    }

    private var nowMs: Int64 = 1_000_000
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    var now: Date { date(ms: nowMs) }

    func sleep(for duration: Duration) async throws {
        nextID += 1
        let id = nextID
        let (seconds, attoseconds) = duration.components
        let deadline = nowMs + seconds * 1000 + Int64((Double(attoseconds) / 1e15).rounded(.up))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    private func cancelSleeper(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Moves time forward, firing due timers in deadline order and draining after each.
    func advance(by milliseconds: Int64) async {
        let target = nowMs + milliseconds
        while true {
            await drain()
            let due = sleepers.enumerated()
                .filter { $0.element.deadline <= target }
                .min { ($0.element.deadline, $0.element.id) < ($1.element.deadline, $1.element.id) }
            guard let due else { break }
            sleepers.remove(at: due.offset)
            nowMs = max(nowMs, due.element.deadline)
            due.element.continuation.resume()
        }
        nowMs = target
        await drain()
    }
}

/// Per-test world: virtual clock, device state and a client wired to them.
@MainActor
final class TestEnv {
    let clock = TestClock()
    let online = OnlineManager()
    let focus = FocusManager()
    let client: QueryClient

    init(
        queryCache: QueryCache = QueryCache(),
        mutationCache: MutationCache = MutationCache(),
        defaultOptions: QueryConfiguration = .init()
    ) {
        client = QueryClient(
            queryCache: queryCache, mutationCache: mutationCache, defaultOptions: defaultOptions,
            clock: clock, onlineManager: online, focusManager: focus
        )
    }

    var cache: QueryCache { client.queryCache }
    func settle() async { await drain() }
    func advance(_ ms: Int64) async { await clock.advance(by: ms) }

    func state(_ key: QueryKey) -> QueryState<String>? { client.getQueryState(key, as: String.self) }
    func exists(_ key: QueryKey) -> Bool { cache.find(key) != nil }

    /// Starts `fetchQuery` like a fire-and-forget JS call; await `.value`/`.result` for the outcome.
    @discardableResult
    func fetch<D: Sendable>(_ options: QueryOptions<D>) -> Task<D, any Error> {
        Task { try await client.fetchQuery(options) }
    }

    @discardableResult
    func prefetch<D: Sendable>(_ options: QueryOptions<D>) -> Task<Void, Never> {
        Task { await client.prefetchQuery(options) }
    }

    func observe<D: Sendable>(_ options: QueryOptions<D>) -> Observed<D, D> {
        Observed(QueryObserver(client: client, options: options))
    }

    func observe<D: Sendable, V: Sendable>(_ options: QueryObserverOptions<D, V>) -> Observed<D, V> {
        Observed(QueryObserver(client: client, options: options))
    }
}

/// A subscribed observer that records every result.
@MainActor
final class Observed<D: Sendable, V: Sendable> {
    let observer: QueryObserver<D, V>
    private(set) var results: [QueryObserverResult<V>] = []
    private var subscription: Subscription?

    init(_ observer: QueryObserver<D, V>) {
        self.observer = observer
        subscription = observer.subscribe { [weak self] in self?.results.append($0) }
    }

    var current: QueryObserverResult<V> { observer.currentResult }
    func unsubscribe() { subscription?.cancel() }
}

/// A query function whose calls the test settles by hand.
@MainActor
final class Controlled<T: Sendable> {
    struct Call {
        var key: QueryKey
        var signal: CancellationSignal?
        var continuation: CheckedContinuation<T, any Error>
    }

    private(set) var calls: [Call] = []
    private let readSignal: Bool

    init(readSignal: Bool = false) { self.readSignal = readSignal }

    var count: Int { calls.count }
    var last: Call { calls[calls.count - 1] }

    var fn: QueryFunction<T> {
        { @MainActor [self] context in
            try await withCheckedThrowingContinuation { continuation in
                calls.append(Call(key: context.queryKey, signal: readSignal ? context.signal : nil, continuation: continuation))
            }
        }
    }

    func resolve(_ index: Int, _ value: T) { calls[index].continuation.resume(returning: value) }

    func resolveLast(_ value: T) async {
        last.continuation.resume(returning: value)
        await drain()
    }

    func rejectLast(_ error: any Error) async {
        last.continuation.resume(throwing: error)
        await drain()
    }
}

/// A query function that succeeds immediately with `value(callIndex)`.
@MainActor
final class Immediate<T: Sendable> {
    private(set) var count = 0
    private let value: (Int) -> T

    init(_ value: @escaping (Int) -> T) { self.value = value }
    convenience init(_ constant: T) { self.init { _ in constant } }

    var fn: QueryFunction<T> {
        { @MainActor [self] _ in
            defer { count += 1 }
            return value(count)
        }
    }
}

/// A query function that always fails, recording when it was called.
@MainActor
final class Failing {
    private(set) var count = 0
    private(set) var times: [Date] = []
    private let message: String
    private let clock: TestClock

    init(_ env: TestEnv, message: String = "E") {
        self.message = message
        self.clock = env.clock
    }

    var fn: QueryFunction<String> {
        { @MainActor [self] _ in
            count += 1
            times.append(clock.now)
            throw TestError(message)
        }
    }
}

extension QueryKey {
    var first: QueryKeyValue? { elements.first }
}
