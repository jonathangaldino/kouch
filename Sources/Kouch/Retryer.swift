/// Runs an async operation with retries, backoff, pausing (offline / unfocused) and cancellation.
///
/// Semantics follow TanStack's `createRetryer`: the result ``promise`` settles exactly once, even
/// if the underlying operation keeps running after a cancel.
@MainActor
final class Retryer<Value: Sendable> {
    struct Config {
        var run: @MainActor () -> Task<Value, any Error>
        var onCancel: @MainActor (CancelledError) -> Void = { _ in }
        var onFail: @MainActor (_ failureCount: Int, _ error: any Error) -> Void = { _, _ in }
        var onPause: @MainActor () -> Void = {}
        var onContinue: @MainActor () -> Void = {}
        var retry: RetryPolicy
        var retryDelay: RetryDelay
        var networkMode: NetworkMode
        var canRun: @MainActor () -> Bool = { true }
        var environment: QueryEnvironment
    }

    let promise = Promise<Value>()
    private let config: Config
    private var isRetryCancelled = false
    private var failureCount = 0
    private var continueFn: (() -> Void)?

    init(_ config: Config) { self.config = config }

    var isResolved: Bool { promise.isSettled }
    var isRejected: Bool { if case .failure = promise.result { true } else { false } }

    private var online: OnlineManager { config.environment.onlineManager }
    private var focus: FocusManager { config.environment.focusManager }

    func canStart() -> Bool {
        (config.networkMode != .online || online.isOnline) && config.canRun()
    }

    private func canContinue() -> Bool {
        focus.isFocused && (config.networkMode == .always || online.isOnline) && config.canRun()
    }

    func start() -> Promise<Value> {
        if canStart() {
            run()
        } else {
            Task { await pause(until: canStart); run() }
        }
        return promise
    }

    func cancel(_ error: CancelledError = CancelledError()) {
        guard !isResolved else { return }
        reject(error)
        config.onCancel(error)
    }

    func cancelRetry() { isRetryCancelled = true }
    func continueRetry() { isRetryCancelled = false }

    /// Wakes a paused retryer if it may continue now.
    @discardableResult
    func `continue`() -> Promise<Value> {
        continueFn?()
        return promise
    }

    private func resolve(_ value: Value) {
        guard !isResolved else { return }
        promise.resolve(value)
        continueFn?() // settled first so a paused wait wakes up instead of leaking

    }

    private func reject(_ error: any Error) {
        guard !isResolved else { return }
        promise.reject(error)
        continueFn?()
    }

    private func pause(until canResume: @escaping @MainActor () -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            continueFn = { [unowned self] in
                guard !resumed, isResolved || canResume() else { return }
                resumed = true
                continuation.resume()
            }
            config.onPause()
        }
        continueFn = nil
        if !isResolved { config.onContinue() }
    }

    private func run() {
        guard !isResolved else { return }
        let attempt = config.run()
        Task {
            do {
                resolve(try await attempt.value)
            } catch {
                await handleFailure(error)
            }
        }
    }

    private func handleFailure(_ error: any Error) async {
        guard !isResolved else { return }
        let retry = config.retry
        let delay = config.retryDelay.delay(failureCount: failureCount, error: error)
        guard !isRetryCancelled, retry.shouldRetry(failureCount: failureCount, error: error) else {
            reject(error)
            return
        }
        failureCount += 1
        config.onFail(failureCount, error)
        try? await config.environment.clock.sleep(for: delay)
        if !canContinue() { await pause(until: canContinue) }
        if isRetryCancelled { reject(error) } else { run() }
    }
}
