# Hydration

`dehydrate(client)` snapshots the caches into a plain value. `hydrate(client, state)` merges a snapshot into
another client. Persisting a snapshot (for example to disk) is up to the app.

Swift note: a snapshot holds data as `Any`, so hydrating it back creates each query with the data's dynamic
type. `deserializeData` receives the query key, so an app can decode persisted bytes into the right type.

## [hyd-001] dehydrate keeps successful queries by default

Given: `["ok"]` with data `"A"` updated at T0, `["pending"]` with a fetch in flight, `["bad"]` in error state.
At T0 + 100:

When: `dehydrate(client)`.

Then:
1. Exactly one query: `queryKey == ["ok"]`, `state.data == "A"`, `state.dataUpdatedAt == T0`, `state.status == success`.
2. `dehydratedAt == T0 + 100`.

## [hyd-002] hydrate creates idle queries without fetching

Given: a snapshot of `["ok"]` = `"A"` (updated at T0).

When: it is hydrated into a fresh client.

Then:
1. `getQueryData(["ok"]) == "A"`, `dataUpdatedAt == T0`, `status == success`, `fetchStatus == idle`.
2. Nothing was fetched.

## [hyd-003] Older snapshots do not overwrite newer data

Given: the target client has `["ok"] = "new"` updated at T0 + 1000; the snapshot has `"old"` from T0.

When: hydrate.

Then:
1. `getQueryData(["ok"]) == "new"`.

## [hyd-004] Newer snapshots overwrite older data

Given: the target client has `["ok"] = "old"` from T0; the snapshot has `"new"` from T0 + 1000.

When: hydrate.

Then:
1. `getQueryData(["ok"]) == "new"`, `dataUpdatedAt == T0 + 1000`.

## [hyd-005] shouldDehydrateQuery

When: `dehydrate(client, {shouldDehydrateQuery: () => true})` with an error query `["bad"]`.

Then:
1. The snapshot contains `["bad"]` with `status == error`.

When: hydrated into a fresh client.
2. `getQueryState(["bad"]).status == error`.

## [hyd-006] Hydrated data keeps its age

Given: a snapshot of `["ok"]` updated at T0, hydrated at T0 + 5000.

When: an observer with `staleTime: 1000` subscribes.
Then:
1. It refetches.

When (instead): an observer with `staleTime: 10000` subscribes.
2. It does not refetch.

## [hyd-007] serializeData / deserializeData

When: `dehydrate(client, {serializeData: d => d + "|s"})`, then `hydrate(client2, snapshot, {defaultOptions: {deserializeData: d => d + "|d"}})`.

Then:
1. The snapshot holds `"A|s"`; the hydrated query holds `"A|s|d"`.

## [hyd-008] Paused mutations survive dehydration

Given: offline; a mutation with key `["add"]` called with variables `"v"` is paused. A successful mutation also exists.

When: `dehydrate`.
Then:
1. One mutation in the snapshot: `mutationKey == ["add"]`, `state.isPaused == true`, `state.variables == "v"`.

When: hydrated into a fresh client that has `setMutationDefaults(["add"], {mutationFn})`, online, and `resumePausedMutations()`.
2. mutationFn is called with `"v"`; the mutation ends `success`.

## [hyd-009] Hydrate default options

When: hydrate with `defaultOptions.queries.gcTime = 1000` into a fresh client.

Then:
1. The hydrated query is removed after 1000 ms without observers.
