# Query Observer

A QueryObserver watches one query and derives a **result** from the query state and the
observer's options. Subscribing (first listener) **mounts** it: it attaches to the query and may
fetch. Unsubscribing the last listener **unmounts** it.

Result fields: `status`, `fetchStatus`, `data`, `error`, `isPending`, `isSuccess`, `isError`,
`isLoading` (= pending && fetching), `isFetching`, `isRefetching` (fetching && !pending),
`isPaused`, `isStale`, `isPlaceholderData`, `isFetched`, `isFetchedAfterMount`,
`isLoadingError` (error && no data), `isRefetchError` (error && data), `isEnabled`,
`dataUpdatedAt`, `errorUpdatedAt`, `failureCount`, `failureReason`, `errorUpdateCount`.

## [obs-001] Mount with empty cache fetches; result is optimistic

When: an observer for `["a"]` is created and subscribed.

Then:
1. Immediately: `status == pending`, `fetchStatus == fetching`, `isLoading == true`.
2. fn called exactly once.

When: fn resolves `"A"`.
3. Listener receives `status == success`, `data == "A"`, `isFetching == false`.

## [obs-002] Fresh cached data is served immediately without fetching

Given: `["a"]` has data `"A"` (just fetched).

When: an observer with `staleTime: 1000` subscribes.

Then:
1. Current result: `status == success`, `data == "A"`, `isFetching == false`, `isStale == false`.
2. fn not called again.

## [obs-003] Stale cached data is served immediately and refetched in background

Given: `["a"]` has data `"A"` (default staleTime 0 → stale).

When: an observer subscribes.

Then:
1. Current result: `status == success`, `data == "A"`, `isFetching == true`, `isRefetching == true`.
2. fn called once.

When: fn resolves `"B"`.
3. `data == "B"`, `isFetching == false`.

## [obs-004] enabled: false

When: an observer for `["a"]` with `enabled: false` subscribes.

Then:
1. `status == pending`, `fetchStatus == idle`, `isLoading == false`, `isEnabled == false`.
2. fn not called; `isStale == false`.

When: options are updated to `enabled: true`.
3. fn called once; result `fetchStatus == fetching`.

## [obs-005] select derives data without changing the cache

Given: fn resolves `{count: 2}`.

When: an observer with `select: d => d.count * 10` subscribes and the fetch resolves.

Then:
1. Result `data == 20`.
2. `getQueryData(["a"]) == {count: 2}`.

## [obs-006] placeholderData

When: an observer with `placeholderData: "ph"` subscribes to empty `["a"]`.

Then:
1. Result: `status == success`, `data == "ph"`, `isPlaceholderData == true`, `isFetching == true`.
2. `getQueryData(["a"])` is undefined.

When: fn resolves `"A"`.
3. `data == "A"`, `isPlaceholderData == false`.

## [obs-007] refetch() returns the new result

Given: a subscribed observer with data `"A"`.

When: `refetch()` is called and fn resolves `"B"`.

Then:
1. The returned result has `data == "B"`.
2. fn total calls == 2.

## [obs-008] Changing the key switches queries

Given: an observer subscribed to `["a", 1]`, resolved `"one"`.

When: options change to key `["a", 2]`.

Then:
1. fn called for `["a", 2]`; result `status == pending`, `isFetching == true`, data undefined.
2. The `["a", 1]` query has 0 observers and still holds `"one"`.

When: fn resolves `"two"`.
3. Result `data == "two"`.

## [obs-009] Listener notifications and unsubscribe

Given: a listener subscribed to an observer for empty `["a"]`.

When: fn resolves `"A"`.

Then:
1. The listener observed (in order) a result with `isFetching == true`... then a result with `status == success, data == "A"`.

When: the listener unsubscribes and `setQueryData(["a"], "B")`.
2. The listener receives nothing further.

## [obs-010] refetchInterval

Given: an observer with `refetchInterval: 1000`, subscribed, initial fetch resolved.

When: advance 1000 (fn resolves immediately each time) → advance 1000 again.

Then:
1. fn calls: 1 initially, 2 after first interval, 3 after second.

When: unsubscribed and advance 5000.
2. No further calls.

## [obs-011] refetchOnMount

Given: `["a"]` has stale data.

When: an observer with `refetchOnMount: false` subscribes.
Then:
1. No fetch.

Given: `["b"]` has fresh data (observer `staleTime: Infinity`).
When: an observer with `refetchOnMount: "always"` and `staleTime: Infinity` subscribes.
2. fn called.

## [obs-012] Result becomes stale over time without refetching

Given: an observer with `staleTime: 1000` subscribed; data resolved at T0.

Then:
1. At T0: `isStale == false`.

When: advance 1001.
2. Listener received a result with `isStale == true`; fn not called again.

## [obs-013] isFetchedAfterMount

Given: `["a"]` has data from a previous fetch.

When: an observer subscribes (refetch starts).
Then:
1. `isFetched == true`, `isFetchedAfterMount == false`.

When: refetch resolves.
2. `isFetchedAfterMount == true`.

## [obs-014] Error results

Given: an observer with `retry: false`.

When: fn rejects E on the initial fetch.
Then:
1. `status == error`, `isError`, `isLoadingError == true`, `isRefetchError == false`, `error == E`.

Given: data `"A"`, when a `refetch()` rejects E2.
2. `status == error`, `data == "A"`, `isRefetchError == true`, `isLoadingError == false`.

## [obs-015] staleTime "static"

Given: `["a"]` has data and an observer with `staleTime: "static"` and `refetchOnMount: "always"`.

When: it subscribes.
Then:
1. No fetch, `isStale == false`.

When: `invalidateQueries()`.
2. No fetch, `isStale == false`.
