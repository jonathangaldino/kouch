import Foundation
import os

/// How long fetched data stays fresh.
public enum StaleTime: Sendable, Equatable {
    case duration(Duration)
    /// Fresh until invalidated.
    case infinity
    /// Fresh forever, even when invalidated. Never refetched automatically.
    case `static`

    public static let zero = StaleTime.duration(.zero)
    public static func seconds(_ s: Double) -> StaleTime { .duration(.milliseconds(s * 1000)) }
    public static func milliseconds(_ ms: Int) -> StaleTime { .duration(.milliseconds(ms)) }
}

/// How long an unused query or mutation is kept before garbage collection.
public enum GCTime: Sendable, Equatable, Comparable {
    case duration(Duration)
    case infinity

    public static let fiveMinutes = GCTime.duration(.seconds(300))
    public static func seconds(_ s: Double) -> GCTime { .duration(.milliseconds(s * 1000)) }
    public static func milliseconds(_ ms: Int) -> GCTime { .duration(.milliseconds(ms)) }

    public static func < (lhs: GCTime, rhs: GCTime) -> Bool {
        switch (lhs, rhs) {
        case (.duration(let a), .duration(let b)): a < b
        case (.duration, .infinity): true
        case (.infinity, _): false
        }
    }
}

/// Whether to retry a failed attempt, given the number of failures so far and the error.
public enum RetryPolicy: Sendable, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    case count(Int)
    case forever
    case custom(@Sendable (_ failureCount: Int, _ error: any Error) -> Bool)

    public static let never = RetryPolicy.count(0)
    public init(integerLiteral value: Int) { self = .count(value) }
    public init(booleanLiteral value: Bool) { self = value ? .forever : .never }

    func shouldRetry(failureCount: Int, error: any Error) -> Bool {
        switch self {
        case .count(let max): failureCount < max
        case .forever: true
        case .custom(let fn): fn(failureCount, error)
        }
    }
}

/// Delay before the next attempt, given the number of failures so far.
public enum RetryDelay: Sendable {
    case fixed(Duration)
    case custom(@Sendable (_ failureCount: Int, _ error: any Error) -> Duration)

    /// `min(1s · 2^failureCount, 30s)`.
    public static let exponential = RetryDelay.custom { n, _ in .milliseconds(min(1000 * Int(pow(2, Double(n))), 30_000)) }

    func delay(failureCount: Int, error: any Error) -> Duration {
        switch self {
        case .fixed(let d): d
        case .custom(let fn): fn(failureCount, error)
        }
    }
}

public enum NetworkMode: Sendable {
    /// Fetch only while online; otherwise pause.
    case online
    /// Ignore the network state.
    case always
    /// Run the first attempt regardless; pause retries while offline.
    case offlineFirst
}

/// When an event (mount, focus, reconnect) should trigger a refetch.
public enum RefetchTrigger: Sendable, ExpressibleByBooleanLiteral {
    case never
    case ifStale
    case always

    public init(booleanLiteral value: Bool) { self = value ? .ifStale : .never }
}

/// Tunables shared by query options, client defaults and per-key defaults. `nil` means "inherit".
public struct QueryConfiguration: Sendable {
    public var staleTime: StaleTime?
    public var gcTime: GCTime?
    public var retry: RetryPolicy?
    public var retryDelay: RetryDelay?
    public var networkMode: NetworkMode?
    public var enabled: Bool?
    public var refetchOnMount: RefetchTrigger?
    public var refetchOnWindowFocus: RefetchTrigger?
    public var refetchOnReconnect: RefetchTrigger?
    public var refetchInterval: Duration?
    public var refetchIntervalInBackground: Bool?

    public init(
        staleTime: StaleTime? = nil,
        gcTime: GCTime? = nil,
        retry: RetryPolicy? = nil,
        retryDelay: RetryDelay? = nil,
        networkMode: NetworkMode? = nil,
        enabled: Bool? = nil,
        refetchOnMount: RefetchTrigger? = nil,
        refetchOnWindowFocus: RefetchTrigger? = nil,
        refetchOnReconnect: RefetchTrigger? = nil,
        refetchInterval: Duration? = nil,
        refetchIntervalInBackground: Bool? = nil
    ) {
        self.staleTime = staleTime
        self.gcTime = gcTime
        self.retry = retry
        self.retryDelay = retryDelay
        self.networkMode = networkMode
        self.enabled = enabled
        self.refetchOnMount = refetchOnMount
        self.refetchOnWindowFocus = refetchOnWindowFocus
        self.refetchOnReconnect = refetchOnReconnect
        self.refetchInterval = refetchInterval
        self.refetchIntervalInBackground = refetchIntervalInBackground
    }

    /// `self` wins; unset values come from `base`.
    func merged(over base: QueryConfiguration) -> QueryConfiguration {
        QueryConfiguration(
            staleTime: staleTime ?? base.staleTime,
            gcTime: gcTime ?? base.gcTime,
            retry: retry ?? base.retry,
            retryDelay: retryDelay ?? base.retryDelay,
            networkMode: networkMode ?? base.networkMode,
            enabled: enabled ?? base.enabled,
            refetchOnMount: refetchOnMount ?? base.refetchOnMount,
            refetchOnWindowFocus: refetchOnWindowFocus ?? base.refetchOnWindowFocus,
            refetchOnReconnect: refetchOnReconnect ?? base.refetchOnReconnect,
            refetchInterval: refetchInterval ?? base.refetchInterval,
            refetchIntervalInBackground: refetchIntervalInBackground ?? base.refetchIntervalInBackground
        )
    }

    // Resolved values with TanStack defaults.
    var resolvedStaleTime: StaleTime { staleTime ?? .zero }
    var resolvedNetworkMode: NetworkMode { networkMode ?? .online }
    var isEnabled: Bool { enabled ?? true }
    var resolvedRefetchOnReconnect: RefetchTrigger {
        refetchOnReconnect ?? (resolvedNetworkMode == .always ? .never : .ifStale)
    }
}

/// Cancellation signal handed to query functions.
///
/// Reading ``QueryFunctionContext/signal`` marks the request as abortable: if the last observer
/// leaves mid-fetch, the fetch is cancelled. Requests that never read it are allowed to finish.
/// The query function's `Task` is also cancelled on abort, so `URLSession` calls stop automatically.
public final class CancellationSignal: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (cancelled: false, handlers: [@Sendable () -> Void]()))

    init() {}

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Calls `handler` once the signal is cancelled (immediately if it already is).
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.handlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    func cancel() {
        let handlers = state.withLock { s -> [@Sendable () -> Void] in
            guard !s.cancelled else { return [] }
            s.cancelled = true
            defer { s.handlers = [] }
            return s.handlers
        }
        handlers.forEach { $0() }
    }
}

final class ConsumedFlag: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var value: Bool {
        get { flag.withLock { $0 } }
        set { flag.withLock { $0 = newValue } }
    }
}

public struct QueryFunctionContext: Sendable {
    public let queryKey: QueryKey
    private let _signal: CancellationSignal
    private let consumed: ConsumedFlag

    init(queryKey: QueryKey, signal: CancellationSignal, consumed: ConsumedFlag) {
        self.queryKey = queryKey
        self._signal = signal
        self.consumed = consumed
    }

    /// The abort signal for this attempt. Reading it opts the request into abort-on-unmount.
    public var signal: CancellationSignal {
        consumed.value = true
        return _signal
    }
}

public typealias QueryFunction<Data> = @Sendable (QueryFunctionContext) async throws -> Data

/// Everything that defines a query: its key, how to fetch it and its tunables.
public struct QueryOptions<Data: Sendable> {
    public var key: QueryKey
    public var queryFn: QueryFunction<Data>?
    public var initialData: Data?
    public var initialDataUpdatedAt: Date?
    public var config: QueryConfiguration

    public init(
        key: QueryKey,
        staleTime: StaleTime? = nil,
        gcTime: GCTime? = nil,
        retry: RetryPolicy? = nil,
        retryDelay: RetryDelay? = nil,
        networkMode: NetworkMode? = nil,
        enabled: Bool? = nil,
        refetchOnMount: RefetchTrigger? = nil,
        refetchOnWindowFocus: RefetchTrigger? = nil,
        refetchOnReconnect: RefetchTrigger? = nil,
        refetchInterval: Duration? = nil,
        refetchIntervalInBackground: Bool? = nil,
        initialData: Data? = nil,
        initialDataUpdatedAt: Date? = nil,
        queryFn: QueryFunction<Data>? = nil
    ) {
        self.key = key
        self.queryFn = queryFn
        self.initialData = initialData
        self.initialDataUpdatedAt = initialDataUpdatedAt
        self.config = QueryConfiguration(
            staleTime: staleTime, gcTime: gcTime, retry: retry, retryDelay: retryDelay,
            networkMode: networkMode, enabled: enabled, refetchOnMount: refetchOnMount,
            refetchOnWindowFocus: refetchOnWindowFocus, refetchOnReconnect: refetchOnReconnect,
            refetchInterval: refetchInterval, refetchIntervalInBackground: refetchIntervalInBackground
        )
    }
}

/// Thrown to callers awaiting a fetch that was cancelled.
public struct CancelledError: Error, Sendable {
    public var revert: Bool
    public var silent: Bool
    public init(revert: Bool = false, silent: Bool = false) {
        self.revert = revert
        self.silent = silent
    }
}

public struct MissingQueryFunctionError: Error, Sendable {
    public let queryKey: QueryKey
}
