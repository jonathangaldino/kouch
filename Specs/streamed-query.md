# Streamed Queries

`streamedQuery({streamFn, refetchMode, reducer, initialValue})` builds a query function from a stream
(TanStack `experimental_streamedQuery`). Each chunk is written to the cache as it arrives, so the query is
`success` after the first chunk while it is still `fetching`. By default chunks are collected in an array.

`refetchMode` controls refetches:

| Mode | During a refetch |
|---|---|
| `reset` (default) | Data is cleared to the initial state, then refilled chunk by chunk |
| `append` | Old data stays; new chunks are appended |
| `replace` | Old data stays until the stream ends, then is replaced in one go |

## [sq-001] Chunks are appended as they arrive

When: an observer mounts; the stream yields `"a"`, then `"b"`, then ends.

Then:
1. Before any chunk: `status == pending`.
2. After `"a"`: `data == ["a"]`, `status == success`, `fetchStatus == fetching`.
3. After `"b"`: `data == ["a", "b"]`.
4. After the end: `data == ["a", "b"]`, `fetchStatus == idle`.

## [sq-002] refetchMode reset clears data when a refetch starts

Given: data `["a"]` from a finished stream.

When: `refetch()`.
Then:
1. `status == pending`, `data` undefined, `fetchStatus == fetching`.

When: the new stream yields `"b"`.
2. `data == ["b"]`.

## [sq-003] refetchMode append

Given: data `["a"]`.

When: `refetch()` and the stream yields `"b"`.

Then:
1. During the refetch `data == ["a"]`; then `["a", "b"]`.

## [sq-004] refetchMode replace

Given: data `["a"]`.

When: `refetch()`; the stream yields `"b"`, `"c"`.
Then:
1. While streaming `data == ["a"]`.

When: the stream ends.
2. `data == ["b", "c"]`.

## [sq-005] reducer and initialValue

Given: `reducer: (sum, n) => sum + n`, `initialValue: 0`.

When: the stream yields 2 then 3.

Then:
1. `data == 5`, and stays 5 after the end.

## [sq-006] Cancelling mid-stream keeps received chunks

Given: the stream function reads its signal; chunk `"a"` received.

When: `cancelQueries()`, then the stream yields `"b"`.

Then:
1. `data == ["a"]`, `status == success`, `fetchStatus == idle` (cancel reverts to the last written chunk).
2. The signal is aborted; `"b"` is not written.
