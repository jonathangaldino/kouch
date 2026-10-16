# Queries Observer

A `QueriesObserver` watches a list of queries through one QueryObserver per entry and reports their results
as an array in input order. An optional `combine` derives one value from the array.

## [qs-001] Results in input order; each query fetched once

When: a QueriesObserver for `[["a"], ["b"]]` subscribes, fn for `a` resolves `"A"`, then fn for `b` resolves `"B"`.

Then:
1. fn called once per key.
2. Result `[a, b]` with `data` `"A"`, `"B"` in that order.
3. The listener received an array after each resolution.

## [qs-002] Shares the cache with other observers

Given: a plain observer on `["a"]` already fetching.

When: a QueriesObserver for `[["a"]]` subscribes.

Then:
1. fn for `["a"]` called once in total.

## [qs-003] setQueries adds and removes entries

Given: a subscribed QueriesObserver for `[["a"], ["b"]]`, both resolved.

When: `setQueries([["b"], ["c"]])`.

Then:
1. `["a"]` has 0 observers; `["b"]` keeps 1 observer and is not refetched (`staleTime: Infinity`).
2. `["c"]` is fetched.
3. Result order is `[b, c]`.

## [qs-004] Reordering keeps observers

Given: subscribed `[["a"], ["b"]]`, resolved (`staleTime: Infinity`).

When: `setQueries([["b"], ["a"]])`.

Then:
1. No fn calls; result data order is `["B", "A"]`.

## [qs-005] combine

Given: `combine: results => results.every(r => r.isSuccess)`, queries `[["a"], ["b"]]`.

Then:
1. Before anything resolves the combined value is `false`.
2. After both resolve it is `true`.

## [qs-006] Unsubscribing unmounts every entry

Given: subscribed `[["a"], ["b"]]`.

When: the listener unsubscribes.

Then:
1. Both queries have 0 observers.

## [qs-007] Entries succeed and fail independently

Given: `[["ok"], ["bad"]]`, `retry: false`.

When: `ok` resolves and `bad` rejects.

Then:
1. Results: `ok.status == success`, `bad.status == error`.
