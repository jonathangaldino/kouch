import Foundation

/// Describes the data: has the query ever produced it?
public enum QueryStatus: Sendable, Equatable {
    case pending
    case error
    case success
}

/// Which way an infinite query is loading more pages.
public enum FetchDirection: Sendable, Equatable {
    case forward
    case backward
}

/// Describes the query function: is it running?
public enum FetchStatus: Sendable, Equatable {
    case fetching
    case paused
    case idle
}

public struct QueryState<Data: Sendable>: Sendable {
    public var data: Data?
    public var dataUpdateCount = 0
    /// `nil` until data is first set.
    public var dataUpdatedAt: Date?
    public var error: (any Error)?
    public var errorUpdateCount = 0
    public var errorUpdatedAt: Date?
    public var fetchFailureCount = 0
    public var fetchFailureReason: (any Error)?
    public var isInvalidated = false
    public var status: QueryStatus = .pending
    public var fetchStatus: FetchStatus = .idle
    /// Set while loading more pages of an infinite query (TanStack `fetchMeta.fetchMore.direction`).
    public var fetchDirection: FetchDirection?

    public init() {}

    /// The same state with data transformed (`nil` drops it).
    func map<T: Sendable>(_ transform: (Data) -> T?) -> QueryState<T> {
        var s = QueryState<T>()
        s.data = data.flatMap(transform)
        s.dataUpdateCount = dataUpdateCount
        s.dataUpdatedAt = dataUpdatedAt
        s.error = error
        s.errorUpdateCount = errorUpdateCount
        s.errorUpdatedAt = errorUpdatedAt
        s.fetchFailureCount = fetchFailureCount
        s.fetchFailureReason = fetchFailureReason
        s.isInvalidated = isInvalidated
        s.status = status
        s.fetchStatus = fetchStatus
        s.fetchDirection = fetchDirection
        return s
    }

    static func initial(_ options: QueryOptions<Data>, now: Date) -> QueryState {
        var state = QueryState()
        if let data = options.initialData {
            state.data = data
            state.dataUpdatedAt = options.initialDataUpdatedAt ?? now
            state.status = .success
        }
        return state
    }
}

/// The type-independent part of a query's state, for filters and tooling.
public struct QueryStateSummary: Sendable, Equatable {
    public var status: QueryStatus
    public var fetchStatus: FetchStatus
    public var isInvalidated: Bool
    public var dataUpdatedAt: Date?
    public var hasData: Bool
}
