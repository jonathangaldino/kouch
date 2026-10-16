import Foundation

/// Describes the data: has the query ever produced it?
public enum QueryStatus: Sendable, Equatable {
    case pending
    case error
    case success
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

    public init() {}

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
