# Query Deduplication

## [dedup-001] Two consumers request the same query

Given: `queryKey = ["user", 123]`, no cached data.

When: Consumer A (observer) subscribes and starts fetching.
And: Consumer B (observer) subscribes with the same query key.

Then:
1. Only one network operation (fn call) is created.
2. Both consumers observe the same Query instance.
3. Both consumers observe `status == pending`, `fetchStatus == fetching`.
4. When the request succeeds, both receive `data`.
5. The cache contains exactly one Query.

## [dedup-002] Concurrent fetchQuery calls share one request

When: `fetchQuery(["a"])` twice before fn resolves; fn resolves `"A"`.

Then:
1. fn called once.
2. Both calls resolve `"A"`.

## [dedup-003] Observer and fetchQuery share one request

When: an observer subscribes to `["a"]`, then `fetchQuery(["a"])`.

Then:
1. fn called once; both see `"A"`.

## [dedup-004] refetch with cancelRefetch: false joins the in-flight request

Given: an observer with data `"A"` and a refetch in flight.

When: `refetch({cancelRefetch: false})`.

Then:
1. fn called once for the two refetches.

## [dedup-005] cancelRefetch (default) replaces an in-flight request only when data exists

Given: an observer with data `"A"`, refetch #1 in flight.

When: `refetch()` (#2), then #1 resolves `"old"`, then #2 resolves `"new"`.
Then:
1. fn called twice in total for the refetches.
2. Final `data == "new"`; `"old"` was never written.

Given: no data yet, initial fetch in flight.
When: `refetch()`.
3. No new fn call (dedupes; nothing to cancel in favor of).

## [dedup-006] A completed request is not reused

Given: `fetchQuery(["a"])` resolved.

When: `fetchQuery(["a"])` again (staleTime 0).

Then:
1. fn called twice in total.
