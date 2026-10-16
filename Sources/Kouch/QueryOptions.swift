import Foundation
import os

/// How long fetched data stays fresh.
public enum StaleTime: Sendable, Equatable {
    case duration(Duration)
    /// Fresh until invalidated.
    case infinity
    /// Fresh forever, even when invalidated. Never refetched automatically.
    case `static`
    /// Decided per query when needed (TanStack `staleTime: (query) => ...`).
    case dynamic(@MainActor @Sendable (AnyQuery) -> StaleTime)

    public static let zero = StaleTime.duration(.zero)
    public static func seconds(_ s: Double) -> StaleTime { .duration(.milliseconds(s * 1000)) }
    public static func milliseconds(_ ms: Int) -> StaleTime { .duration(.milliseconds(ms)) }

    /// Dynamic values never compare equal (closures can't be compared); resolve them first.
    public static func == (lhs: StaleTime, rhs: StaleTime) -> Bool {
        switch (lhs, rhs) {
        case (.duration(let a), .duration(let b)): a == b
        case (.infinity, .infinity), (.static, .static): true
        default: false
        }
    }

    @MainActor
    func resolved(for query: AnyQuery) -> StaleTime {
        if case .dynamic(let fn) = self { return fn(query).resolved(for: query) }
        return self
    }
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
    /// Decided per query when the event happens.
    case dynamic(@MainActor @Sendable (AnyQuery) -> RefetchTrigger)

    public init(booleanLiteral value: Bool) { self = value ? .ifStale : .never }

    @MainActor
    func resolved(for query: AnyQuery) -> RefetchTrigger {
        if case .dynamic(let fn) = self { return fn(query).resolved(for: query) }
        return self
    }
}

/// How often to refetch while observed.
public enum RefetchInterval: Sendable {
    case every(Duration)
    /// Decided per query after each update; `nil` stops refetching.
    case dynamic(@MainActor @Sendable (AnyQuery) -> Duration?)

    public static func milliseconds(_ ms: Int) -> RefetchInterval { .every(.milliseconds(ms)) }
    public static func seconds(_ s: Double) -> RefetchInterval { .every(.milliseconds(s * 1000)) }

    @MainActor
    func resolved(for query: AnyQuery) -> Duration? {
        switch self {
        case .every(let interval): interval
        case .dynamic(let fn): fn(query)
        }
    }
}

/// Whether a query may fetch automatically.
public enum QueryEnabled: Sendable {
    case value(Bool)
    /// Decided per query when needed (TanStack `enabled: (query) => ...`).
    case dynamic(@MainActor @Sendable (AnyQuery) -> Bool)

    @MainActor
    func resolved(for query: AnyQuery) -> Bool {
        switch self {
        case .value(let enabled): enabled
        case .dynamic(let fn): fn(query)
        }
    }
}

/// Free-form information attached to a query or mutation, available to its function and to cache callbacks.
public typealias QueryMeta = [String: any Sendable]

/// Tunables shared by query options, client defaults and per-key defaults. `nil` means "inherit".
public struct QueryConfiguration: Sendable {
    public var staleTime: StaleTime?
    public var gcTime: GCTime?
    public var retry: RetryPolicy?
    public var retryDelay: RetryDelay?
    public var networkMode: NetworkMode?
    public var enabled: QueryEnabled?
    public var refetchOnMount: RefetchTrigger?
    public var refetchOnWindowFocus: RefetchTrigger?
    public var refetchOnReconnect: RefetchTrigger?
    public var refetchInterval: RefetchInterval?
    public var refetchIntervalInBackground: Bool?
    /// With `false`, a query in error state is not refetched when an observer mounts. Default `true`.
    public var retryOnMount: Bool?
    public var meta: QueryMeta?

    public init(
        staleTime: StaleTime? = nil,
        gcTime: GCTime? = nil,
        retry: RetryPolicy? = nil,
        retryDelay: RetryDelay? = nil,
        networkMode: NetworkMode? = nil,
        enabled: Bool? = nil,
        enabledWhen: (@MainActor @Sendable (AnyQuery) -> Bool)? = nil,
        refetchOnMount: RefetchTrigger? = nil,
        refetchOnWindowFocus: RefetchTrigger? = nil,
        refetchOnReconnect: RefetchTrigger? = nil,
        refetchInterval: RefetchInterval? = nil,
        refetchIntervalInBackground: Bool? = nil,
        retryOnMount: Bool? = nil,
        meta: QueryMeta? = nil
    ) {
        self.staleTime = staleTime
        self.gcTime = gcTime
        self.retry = retry
        self.retryDelay = retryDelay
        self.networkMode = networkMode
        self.enabled = enabledWhen.map(QueryEnabled.dynamic) ?? enabled.map(QueryEnabled.value)
        self.refetchOnMount = refetchOnMount
        self.refetchOnWindowFocus = refetchOnWindowFocus
        self.refetchOnReconnect = refetchOnReconnect
        self.refetchInterval = refetchInterval
        self.refetchIntervalInBackground = refetchIntervalInBackground
        self.retryOnMount = retryOnMount
        self.meta = meta
    }

    /// `self` wins; unset values come from `base`.
    func merged(over base: QueryConfiguration) -> QueryConfiguration {
        var merged = QueryConfiguration(
            staleTime: staleTime ?? base.staleTime,
            gcTime: gcTime ?? base.gcTime,
            retry: retry ?? base.retry,
            retryDelay: retryDelay ?? base.retryDelay,
            networkMode: networkMode ?? base.networkMode,
            refetchOnMount: refetchOnMount ?? base.refetchOnMount,
            refetchOnWindowFocus: refetchOnWindowFocus ?? base.refetchOnWindowFocus,
            refetchOnReconnect: refetchOnReconnect ?? base.refetchOnReconnect,
            refetchInterval: refetchInterval ?? base.refetchInterval,
            refetchIntervalInBackground: refetchIntervalInBackground ?? base.refetchIntervalInBackground,
            retryOnMount: retryOnMount ?? base.retryOnMount,
            meta: meta ?? base.meta
        )
        merged.enabled = enabled ?? base.enabled
        return merged
    }

    // Resolved values with TanStack defaults.
    var resolvedNetworkMode: NetworkMode { networkMode ?? .online }
    @MainActor func staleTime(for query: AnyQuery) -> StaleTime { (staleTime ?? .zero).resolved(for: query) }
    @MainActor func isEnabled(for query: AnyQuery) -> Bool { enabled?.resolved(for: query) ?? true }
    @MainActor func refetchInterval(for query: AnyQuery) -> Duration? { refetchInterval?.resolved(for: query) }
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
    /// The client running the fetch.
    public let client: QueryClient
    public let meta: QueryMeta?
    private let _signal: CancellationSignal
    private let consumed: ConsumedFlag

    init(queryKey: QueryKey, client: QueryClient, meta: QueryMeta?, signal: CancellationSignal, consumed: ConsumedFlag) {
        self.queryKey = queryKey
        self.client = client
        self.meta = meta
        self._signal = signal
        self.consumed = consumed
    }

    /// Whether the fetch was aborted, without opting into abort-on-unmount.
    var isAborted: Bool { _signal.isCancelled }

    /// The abort signal for this attempt. Reading it opts the request into abort-on-unmount.
    public var signal: CancellationSignal {
        consumed.value = true
        return _signal
    }
}

public typealias QueryFunction<Data> = @Sendable (QueryFunctionContext) async throws -> Data

/// Replaces the query function for one fetch, given the load-more direction and the data before the
/// fetch. Infinite queries use it to fetch pages.
typealias QueryBehavior<Data> = @Sendable (_ direction: FetchDirection?, _ oldData: Data?, _ context: QueryFunctionContext) async throws -> Data

/// Everything that defines a query: its key, how to fetch it and its tunables.
public struct QueryOptions<Data: Sendable> {
    public var key: QueryKey
    public var queryFn: QueryFunction<Data>?
    /// TanStack `skipToken`: the query is disabled and a manual `refetch` fails with
    /// ``MissingQueryFunctionError``. Handy as `skipToken: id == nil`.
    public var skipToken: Bool
    public var initialData: Data?
    /// Computes initial data when the query is created (TanStack `initialData: () => ...`).
    public var initialDataFunction: (@Sendable () -> Data?)?
    public var initialDataUpdatedAt: Date?
    public var config: QueryConfiguration
    var behavior: QueryBehavior<Data>?

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
        refetchInterval: RefetchInterval? = nil,
        refetchIntervalInBackground: Bool? = nil,
        retryOnMount: Bool? = nil,
        meta: QueryMeta? = nil,
        skipToken: Bool = false,
        initialData: Data? = nil,
        initialDataUpdatedAt: Date? = nil,
        queryFn: QueryFunction<Data>? = nil
    ) {
        self.key = key
        self.queryFn = queryFn
        self.skipToken = skipToken
        self.initialData = initialData
        self.initialDataUpdatedAt = initialDataUpdatedAt
        self.config = QueryConfiguration(
            staleTime: staleTime, gcTime: gcTime, retry: retry, retryDelay: retryDelay,
            networkMode: networkMode, enabled: enabled, refetchOnMount: refetchOnMount,
            refetchOnWindowFocus: refetchOnWindowFocus, refetchOnReconnect: refetchOnReconnect,
            refetchInterval: refetchInterval, refetchIntervalInBackground: refetchIntervalInBackground,
            retryOnMount: retryOnMount, meta: meta
        )
    }

    // Closure-valued options are modifiers, so a trailing closure always means `queryFn`.

    /// Decides `enabled` per query when needed (TanStack `enabled: (query) => ...`).
    public func enabled(_ isEnabled: @escaping @MainActor @Sendable (AnyQuery) -> Bool) -> Self {
        var copy = self
        copy.config.enabled = .dynamic(isEnabled)
        return copy
    }

    /// Computes initial data when the query is created (TanStack `initialData: () => ...`).
    public func initialData(_ make: @escaping @Sendable () -> Data?) -> Self {
        var copy = self
        copy.initialDataFunction = make
        return copy
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
