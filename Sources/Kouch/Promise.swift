/// A single-assignment result that many callers can await.
///
/// In-flight fetches are shared through a `Promise`: every consumer that joins a fetch awaits the same
/// instance, which is how one network operation serves many consumers. Settling is synchronous;
/// continuations run asynchronously on the main actor (like JS promise callbacks).
@MainActor
final class Promise<Value: Sendable> {
    private(set) var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Value, any Error>] = []
    private var callbacks: [@MainActor (Result<Value, any Error>) -> Void] = []

    var isSettled: Bool { result != nil }

    func resolve(_ value: Value) { settle(.success(value)) }
    func reject(_ error: any Error) { settle(.failure(error)) }

    func settle(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiters = self.waiters
        let callbacks = self.callbacks
        self.waiters = []
        self.callbacks = []
        for waiter in waiters { waiter.resume(with: result) }
        if !callbacks.isEmpty {
            Task { @MainActor in callbacks.forEach { $0(result) } }
        }
    }

    /// Settles `self` with whatever `other` settles with.
    func follow(_ other: Promise<Value>) {
        other.onSettle { [self] in settle($0) }
    }

    /// Runs `callback` asynchronously after the promise settles.
    func onSettle(_ callback: @escaping @MainActor (Result<Value, any Error>) -> Void) {
        if let result {
            Task { @MainActor in callback(result) }
        } else {
            callbacks.append(callback)
        }
    }

    var value: Value {
        get async throws {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
    }
}
