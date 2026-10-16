# Query Client

Imperative entry point over the query cache.

## [client-001] fetchQuery fetches, caches and resolves

When: `fetchQuery({queryKey: ["a"], queryFn: fn})`, fn resolves `"A"`.

Then:
1. The call resolves with `"A"`.
2. `getQueryData(["a"]) == "A"`.

## [client-002] fetchQuery returns fresh cached data without calling fn

Given: `["a"]` has data `"A"` fetched at T0.

When: at T0 + 500, `fetchQuery({queryKey: ["a"], staleTime: 1000})`.
Then:
1. Resolves `"A"`, fn not called again.

When: at T0 + 1000 the same call is made.
2. fn is called again (data is stale).

And with default `staleTime` (0) every `fetchQuery` calls fn.

## [client-003] fetchQuery does not retry by default

When: `fetchQuery(["a"])` and fn rejects with E.

Then:
1. The call rejects with E after exactly one fn call.

## [client-004] prefetchQuery never throws

When: `prefetchQuery(["a"])` and fn rejects.

Then:
1. The call resolves (no throw).
2. Query state is `error`.

## [client-005] ensureQueryData

Given: `["a"]` has stale data `"A"`.

When: `ensureQueryData(["a"])`.
Then:
1. Resolves `"A"`, fn not called.

When: `ensureQueryData(["missing"])`.
2. fn is called, resolves with its value.

When: `ensureQueryData(["a"], revalidateIfStale: true)`.
3. Resolves `"A"` immediately and starts a background fetch (fn called once).

## [client-006] getQueryData / setQueryData

Then:
1. `getQueryData(["none"])` is undefined; no query is created.

When: at T0, `setQueryData(["a"], "A")`.
2. Returns `"A"`; query exists with `status == success`, `data == "A"`, `dataUpdatedAt == T0`, `fetchStatus == idle`.

When: `setQueryData(["a"], prev => prev + "!")`.
3. Updater received `"A"`; data is `"A!"`.

When: `setQueryData(["a"], () => undefined)`.
4. Returns undefined; data stays `"A!"`.

When: `setQueryData(["b"], "B", {updatedAt: 42})`.
5. `dataUpdatedAt == 42`.

## [client-007] setQueryData updates observers without fetching

Given: an observer subscribed to `["a"]` with `staleTime: Infinity`, data `"A"`.

When: `setQueryData(["a"], "B")`.

Then:
1. The observer's listener receives a result with `data == "B"`.
2. fn was not called again.

## [client-008] setQueryData during an in-flight fetch

Given: a fetch of `["a"]` is in flight.

When: `setQueryData(["a"], "manual")`, then fn resolves `"server"`.

Then:
1. Immediately after setQueryData: `data == "manual"`, `fetchStatus == fetching`.
2. After resolve: `data == "server"`, `fetchStatus == idle`.

## [client-009] getQueryState and removeQueries

Given: `["a"]` with data.

Then:
1. `getQueryState(["a"]).status == success`.

When: `removeQueries({queryKey: ["a"]})`.
2. `getQueryState(["a"])` is undefined, `getQueryData(["a"])` undefined.

## [client-010] isFetching counts fetching queries

When: fetches of `["a"]` and `["b"]` are in flight.

Then:
1. `isFetching() == 2`, `isFetching({queryKey: ["a"]}) == 1`.

When: both resolve.
2. `isFetching() == 0`.

## [client-011] Default options

Given: client `defaultOptions.queries.staleTime = 1000` and `setQueryDefaults(["todos"], {staleTime: Infinity})`.

When: `fetchQuery(["todos", 1])` and `fetchQuery(["other"])` resolve; advance 5000; repeat both.

Then:
1. `["todos", 1]` fn called once total (query default wins over client default).
2. `["other"]` fn called twice (client default 1000 elapsed).
