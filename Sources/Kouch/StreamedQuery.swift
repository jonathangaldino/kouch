/// What a streamed query does with its data when it refetches.
public enum StreamRefetchMode: Sendable {
    /// Clear data to the initial state, then refill chunk by chunk.
    case reset
    /// Keep old data and append new chunks.
    case append
    /// Keep old data until the stream ends, then replace it in one go.
    case replace
}

/// A query function that writes each chunk of a stream to the cache as it arrives (TanStack
/// `experimental_streamedQuery`). The query is `success` after the first chunk, while still fetching.
///
/// ```swift
/// QueryOptions(key: ["chat", id], queryFn: streamedQuery(initialValue: "", reducer: { $0 + $1 }) { _ in
///     api.messageTokens(chat: id) // some AsyncSequence<String>
/// })
/// ```
public func streamedQuery<Chunk: Sendable, Result: Sendable, Stream: AsyncSequence & Sendable>(
    refetchMode: StreamRefetchMode = .reset,
    initialValue: Result,
    reducer: @escaping @Sendable (Result, Chunk) -> Result,
    streamFn: @escaping @Sendable (QueryFunctionContext) async throws -> Stream
) -> QueryFunction<Result> where Stream.Element == Chunk {
    // Runs on the main actor: every chunk is written to the (main-actor) cache anyway.
    { @MainActor context in
        let client = context.client
        let key = context.queryKey
        let query = client.queryCache.get(key, as: Result.self)
        let isRefetch = query?.isFetched ?? false
        if isRefetch && refetchMode == .reset { query?.resetWhileFetching() }
        let replacing = isRefetch && refetchMode == .replace
        var result = initialValue
        let stream = try await streamFn(context)
        for try await chunk in stream {
            // Swift cancels the fetch task on abort, so this stops even if the stream never read its signal
            // (TanStack keeps writing chunks in that case).
            if context.isAborted { break }
            if replacing {
                result = reducer(result, chunk)
            } else {
                client.setQueryData(key, as: Result.self) { reducer($0 ?? initialValue, chunk) }
            }
        }
        if replacing && !context.isAborted { client.setQueryData(key, result) }
        return client.getQueryData(key, as: Result.self) ?? initialValue
    }
}

/// A streamed query collecting chunks in an array.
public func streamedQuery<Chunk: Sendable, Stream: AsyncSequence & Sendable>(
    refetchMode: StreamRefetchMode = .reset,
    streamFn: @escaping @Sendable (QueryFunctionContext) async throws -> Stream
) -> QueryFunction<[Chunk]> where Stream.Element == Chunk {
    streamedQuery(refetchMode: refetchMode, initialValue: [], reducer: { $0 + [$1] }, streamFn: streamFn)
}
