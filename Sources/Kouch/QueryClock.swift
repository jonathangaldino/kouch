import Foundation

/// Source of time for timestamps (`dataUpdatedAt`) and timers (stale, gc, retry, interval).
///
/// Inject a custom clock into ``QueryClient`` to control time in tests.
@MainActor
public protocol QueryClock: AnyObject {
    var now: Date { get }
    /// Suspends for `duration`. Must throw `CancellationError` when the calling task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// Wall-clock time and `Task.sleep`.
public final class SystemQueryClock: QueryClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

extension Date {
    func adding(_ duration: Duration) -> Date { addingTimeInterval(duration.timeInterval) }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    init(timeInterval: TimeInterval) {
        self = .nanoseconds(Int64((timeInterval * 1e9).rounded()))
    }
}

/// The time and device-state sources a client and its queries share.
@MainActor
struct QueryEnvironment {
    let clock: QueryClock
    let onlineManager: OnlineManager
    let focusManager: FocusManager

    func canFetch(_ mode: NetworkMode) -> Bool { mode != .online || onlineManager.isOnline }
}

/// A cancellable one-shot timer on the main actor.
@MainActor
final class QueryTimer {
    private var task: Task<Void, Never>?

    init(clock: QueryClock, after delay: Duration, _ body: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do { try await clock.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            body()
        }
    }

    /// Fires `body` every `interval` until cancelled.
    init(clock: QueryClock, every interval: Duration, _ body: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            while true {
                do { try await clock.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                body()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
