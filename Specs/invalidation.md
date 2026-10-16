# Invalidation

`invalidateQueries(filters)` marks matching queries invalidated (stale regardless of staleTime) and
refetches the matching ones of `refetchType` (default: `active`).

## [inv-001] Active queries refetch, inactive become stale

Given: `["todos", 1]` with an observer (`staleTime: Infinity`) subscribed; `["todos", 2]` fetched via
`fetchQuery` with no observers (`staleTime: Infinity`).

When: `invalidateQueries({queryKey: ["todos"]})`.

Then:
1. Both have `isInvalidated == true`.
2. fn for `["todos", 1]` called again; fn for `["todos", 2]` not.

When: an observer (`staleTime: Infinity`) subscribes to `["todos", 2]`.
3. It refetches (invalidated data is stale).

## [inv-002] Filter scope

Given: active observers on `["todos"]` and `["posts"]`.

When: `invalidateQueries({queryKey: ["todos"]})`.

Then:
1. Only `["todos"]` refetches; `["posts"].isInvalidated == false`.

## [inv-003] refetchType

Given: active `["a"]`, inactive `["b"]`.

When: `invalidateQueries({refetchType: "none"})`.
Then:
1. No fetches; both invalidated.

When: `invalidateQueries({refetchType: "all"})`.
2. Both refetch.

## [inv-004] invalidateQueries resolves after refetch finishes

When: `invalidateQueries()` on an active query; fn resolves `"B"` after 1000.

Then:
1. The call has not resolved at +999.
2. It resolved after fn resolved; data is `"B"`, `isInvalidated == false`.

## [inv-005] Disabled observers are not refetched

Given: observer `enabled: false` on `["a"]`, which has data from `setQueryData`.

When: `invalidateQueries()`.

Then:
1. No fn call; `isInvalidated == true`.

## [inv-006] Invalidating an in-flight query with data restarts it

Given: active `["a"]` with data, refetch #1 in flight.

When: `invalidateQueries()`.

Then:
1. Request #1 cancelled silently; a new fn call made; final data from the new call.

## [inv-007] setQueryData clears invalidation

Given: `["a"]` invalidated.

When: `setQueryData(["a"], "X")`.

Then:
1. `isInvalidated == false`.
