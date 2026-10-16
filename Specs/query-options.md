# Query Options (extras)

Options beyond the basics: `meta`, function contexts, options given as functions of the query, `retryOnMount`,
`skipToken`, `throwOnError` on refetches, bulk data access and mutation defaults.

## [qo-001] meta reaches the query function and cache callbacks

When: `fetchQuery({queryKey: ["a"], meta: {source: "test"}})` with a cache `onSuccess` recorder.

Then:
1. The query function context has `meta == {source: "test"}`.
2. Cache `onSuccess` sees `query.meta == {source: "test"}`; `query.meta` is readable on the cached query.

## [qo-002] The query function context carries the client

Then:
1. `context.client` is the client that runs the fetch.

## [qo-003] The mutation function context carries client, meta and key

When: a mutation with `mutationKey: ["m"]`, `meta: {tag: 1}` runs.

Then:
1. The mutation function's context has `client`, `meta == {tag: 1}`, `mutationKey == ["m"]`.
2. `mutation.meta == {tag: 1}`.

## [qo-004] staleTime as a function of the query

Given: `staleTime: query => query.state.data == "fresh" ? Infinity : 0`, cached `["fresh"] = "fresh"`, `["old"] = "old"`.

When: observers mount on both.

Then:
1. `["fresh"]` does not refetch; `["old"]` refetches.

## [qo-005] enabled as a function of the query

Given: `enabled: () => allowed`, `allowed == false`.

Then:
1. Mounting does not fetch; `isEnabled == false`.

When: `allowed = true` and `setOptions` with the same function.
2. No fetch: the previous options' function is re-evaluated too and now also returns `true`, so there is no
   "was disabled" transition.

When: `invalidateQueries()`.
3. The query is active now and refetches; `isEnabled == true`.

## [qo-006] refetchInterval as a function of the query

Given: `refetchInterval: query => query.state.dataUpdateCount < 3 ? 1000 : false`.

When: advance 10 000.

Then:
1. fn called 3 times in total (the interval stops once the function returns false).

## [qo-007] refetchOnWindowFocus as a function of the query

Given: client mounted; `refetchOnWindowFocus: query => query.state.data == "refocus" ? "always" : false`;
`["a"]` holds `"refocus"` (`staleTime: Infinity`), `["b"]` holds `"other"` (stale).

When: focus is regained.

Then:
1. `["a"]` refetches (`always`); `["b"]` does not (`false`), even though it is stale.

## [qo-008] initialData as a function

When: a query is built twice for `["a"]` with `initialData: () => "init"`.

Then:
1. `data == "init"`; the function ran once.

## [qo-009] retryOnMount

Given: `["a"]` in error state.

Then:
1. An observer with `retryOnMount: false` mounts without fetching.
2. An observer with the default (`true`) fetches on mount.

## [qo-010] skipToken disables the query

When: an observer uses `queryFn: skipToken`.

Then:
1. `isEnabled == false`, `fetchStatus == idle`.
2. Without observers, the query `isDisabled()`.
3. `refetch()` on a skipToken observer results in `status == error` with a "Missing queryFn" error.

## [qo-011] refetch throwOnError

Given: an observer whose fn fails (`retry: false`).

Then:
1. `refetch()` returns a result with `status == error`.
2. `refetch(throwOnError: true)` throws the error.

## [qo-012] refetchQueries / invalidateQueries throwOnError

Given: an active query whose fn fails (`retry: false`).

Then:
1. `refetchQueries()` completes without throwing.
2. `refetchQueries(throwOnError: true)` and `invalidateQueries(throwOnError: true)` throw.

## [qo-013] getQueriesData / setQueriesData

Given: `["todos", 1] = "one"`, `["todos", 2] = "two"`, `["posts"] = "post"`.

Then:
1. `getQueriesData({queryKey: ["todos"]})` → `[(["todos", 1], "one"), (["todos", 2], "two")]`.
2. `setQueriesData({queryKey: ["todos"]}, prev => prev + "!")` updates both and returns the new pairs;
   `["posts"]` is untouched.

## [qo-014] mutationCache.find

Given: a mutation with key `["todos", "add"]`.

Then:
1. `find({mutationKey: ["todos", "add"]})` finds it; `find({mutationKey: ["todos"]})` does not (exact by default).
2. `find({mutationKey: ["todos"], exact: false})` and `findAll({mutationKey: ["todos"]})` find it.

## [qo-015] Mutations take mutationFn and callbacks from setMutationDefaults

Given: `setMutationDefaults(["add"], {mutationFn, onSuccess})`.

When: an observer with only `mutationKey: ["add"]` mutates with `"v"`.

Then:
1. The defaults' `mutationFn` runs with `"v"` and its `onSuccess` runs; `mutate` resolves with the result.
