# Garbage Collection

A query with **no observers** and **idle** fetchStatus is removed from the cache `gcTime` ms after it
became unused. Unused means: created without observers, last observer removed, or a fetch finished
with no observers.

## [gc-001] Unobserved query removed after default gcTime

Given: `fetchQuery(["a"])` resolved at T0.

Then:
1. At T0 + 299 999: query exists.
2. At T0 + 300 000: query removed.

## [gc-002] Last observer unsubscribes → removed after gcTime

Given: an observer with `gcTime: 1000` subscribed and resolved.

When: it unsubscribes at T1.

Then:
1. At T1 + 999: query exists, data intact.
2. At T1 + 1000: query removed.

## [gc-003] New observer before GC rescues the query

Given: as gc-002, unsubscribed at T1.

When: at T1 + 500 a new observer with `staleTime: Infinity` subscribes.

Then:
1. Its first result has the cached data, `status == success`, no fetch.
2. At T1 + 5000: query still exists.

## [gc-004] gcTime Infinity never collects

Given: `fetchQuery({queryKey: ["a"], gcTime: Infinity})` resolved.

When: advance 1 year.
Then:
1. Query exists.

## [gc-005] Largest gcTime wins

Given: `fetchQuery({queryKey: ["a"], gcTime: 10000})` resolved at T0.

When: `fetchQuery({queryKey: ["a"], gcTime: 1000})` resolved at T0 (same tick, staleTime 0).

Then:
1. At T0 + 1000: query exists.
2. At T0 + 10000: query removed.

## [gc-006] Fetching queries are not collected

Given: `prefetchQuery({queryKey: ["a"], gcTime: 1000})` in flight at T0 (fn takes 5000).

Then:
1. At T0 + 1000: query exists (fetching).

When: fn resolves at T0 + 5000.
2. At T0 + 5999 exists; at T0 + 6000 removed.

## [gc-007] gcTime 0

Given: an observer with `gcTime: 0`, subscribed and resolved.

When: it unsubscribes and timers flush (advance 0).

Then:
1. Query removed.

## [gc-008] Remaining observer keeps the query

Given: two observers with `gcTime: 1000` subscribed to `["a"]`.

When: one unsubscribes; advance 5000.

Then:
1. Query exists, one observer.
