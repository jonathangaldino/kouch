# Stale Time

Data is **fresh** while `now < dataUpdatedAt + staleTime`, otherwise **stale**.
Missing data is always stale. Invalidated data is stale (unless `staleTime == "static"`).

## [stale-001] Default staleTime 0: stale immediately

Given: an observer with default options, fetch resolved.

Then:
1. `isStale == true` right after success.

## [stale-002] Boundary of staleTime

Given: an observer with `staleTime: 1000`, data at T0.

Then:
1. At T0 + 999: `isStale == false`.
2. At T0 + 1000 (+1 for the timer to fire): `isStale == true`.

## [stale-003] staleTime Infinity

Given: an observer with `staleTime: Infinity`, data resolved.

When: advance 1 day.
Then:
1. `isStale == false`.

When: query is invalidated (refetchType none).
2. `isStale == true`.

## [stale-004] staleTime "static" survives invalidation

Given: an observer with `staleTime: "static"`, data resolved.

When: `invalidateQueries({refetchType: "none"})`.
Then:
1. `isStale == false`, `state.isInvalidated == true`.

## [stale-005] No data is stale; disabled observer is not

Given: an empty query `["a"]` with no observers.
Then:
1. `query.isStale() == true`.

Given: an observer with `enabled: false` on empty `["b"]`.
2. Its result `isStale == false`.

## [stale-006] Mount behavior follows freshness

Given: `fetchQuery(["a"])` resolved at T0.

When: at T0 + 500 an observer with `staleTime: 1000` subscribes.
Then:
1. No fetch.

When: it unsubscribes; at T0 + 1500 a new observer with `staleTime: 1000` subscribes.
2. fn called (second call overall).

## [stale-007] Query is stale if any observer considers it stale

Given: `["a"]` with data at T0, observer O1 `staleTime: Infinity`, observer O2 `staleTime: 1000`, both subscribed.

When: advance 1001.

Then:
1. O1 `isStale == false`, O2 `isStale == true`.
2. `query.isStale() == true`; `findAll({stale: true})` includes `["a"]`.
