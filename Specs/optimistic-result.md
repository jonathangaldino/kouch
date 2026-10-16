# Optimistic Results

`observer.getOptimisticResult(options)` answers: "what will this observer show for these options once it is
mounted?" Framework adapters call it while rendering, before they subscribe or apply new options, so the
first frame already shows the loading state. It never calls the query function, but it does create the query in
the cache and becomes the observer's current result.

## [opt-001] Unmounted observer, empty cache

Given: an observer for `["a"]`, not subscribed.

When: `getOptimisticResult(options for ["a"])`.

Then:
1. `status == pending`, `fetchStatus == fetching`, `isLoading == true`.
2. fn not called; the cache contains `["a"]` with `fetchStatus == idle`.
3. `getCurrentResult()` equals the optimistic result (`fetchStatus == fetching`).

## [opt-002] Fresh cached data

Given: `["a"]` has fresh data `"A"` (observer `staleTime: Infinity`).

When: `getOptimisticResult(...)`.

Then:
1. `status == success`, `data == "A"`, `fetchStatus == idle`.

## [opt-003] Disabled

When: `getOptimisticResult` with `enabled: false`.

Then:
1. `status == pending`, `fetchStatus == idle`.

## [opt-004] Mounted observer, new key

Given: a subscribed observer on `["a", 1]` with data.

When: `getOptimisticResult(options for ["a", 2])`.

Then:
1. `status == pending`, `fetchStatus == fetching`, data undefined.
2. fn not called for `["a", 2]`; the observer still observes `["a", 1]`.
