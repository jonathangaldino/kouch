# Query Lifecycle

A query has two orthogonal status axes:

- `status`: `pending` (no data yet) → `success` | `error`. Describes **data**.
- `fetchStatus`: `idle` | `fetching` | `paused`. Describes the **query function**.

## [life-001] A new query starts pending and idle

Given: an empty cache, time = T0.

When: a query is built for `["a"]` without initial data.

Then:
1. `status == pending`, `fetchStatus == idle`.
2. `data` is undefined, `error` is null.
3. `dataUpdatedAt == 0`, `dataUpdateCount == 0`, `errorUpdateCount == 0`.
4. `isInvalidated == false`.

## [life-002] Starting a fetch moves fetchStatus to fetching

Given: a new query `["a"]`.

When: a fetch starts and the query function has not resolved.

Then:
1. `status == pending`, `fetchStatus == fetching`.
2. fn was called once with a context whose `queryKey == ["a"]`.

## [life-003] Successful fetch

Given: a fetch of `["a"]` in flight, time = T0.

When: advance 100, then fn resolves with `"A"`.

Then:
1. `status == success`, `fetchStatus == idle`.
2. `data == "A"`, `error == null`.
3. `dataUpdatedAt == T0 + 100`, `dataUpdateCount == 1`.
4. `fetchFailureCount == 0`, `isInvalidated == false`.

## [life-004] Failed fetch without data

Given: a fetch of `["a"]` with `retry: 0`.

When: fn rejects with error E.

Then:
1. `status == error`, `fetchStatus == idle`.
2. `error == E`, `data` undefined.
3. `errorUpdateCount == 1`, `fetchFailureCount == 1`, `fetchFailureReason == E`.
4. `isInvalidated == true`.

## [life-005] Failed refetch keeps previous data

Given: query `["a"]` with `data == "A"`.

When: a refetch with `retry: 0` rejects with E.

Then:
1. `status == error`, `error == E`.
2. `data == "A"` (not cleared).

## [life-006] Initial data seeds a success state

Given: time = T0.

When: a query is built for `["a"]` with `initialData: "init"`.

Then:
1. `status == success`, `fetchStatus == idle`, `data == "init"`.
2. `dataUpdatedAt == T0`, `dataUpdateCount == 0`.

And when built instead with `initialData: "init"` and `initialDataUpdatedAt: 42`:
3. `dataUpdatedAt == 42`.

## [life-007] Refetch with data stays success while fetching

Given: query `["a"]` with `data == "A"`.

When: a refetch starts.

Then:
1. `status == success`, `fetchStatus == fetching`, `data == "A"`.

When: fn resolves `"B"`.
2. `status == success`, `fetchStatus == idle`, `data == "B"`, `dataUpdateCount == 2`.

## [life-008] Reset returns to the initial state

Given: query `["a"]` fetched successfully with `"A"`, and query `["b"]` built with `initialData: "init"` then `setQueryData(["b"], "changed")`.

When: `resetQueries()`.

Then:
1. `["a"]`: `status == pending`, `data` undefined, `dataUpdateCount == 0`.
2. `["b"]`: `status == success`, `data == "init"`.
