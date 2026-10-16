# Persistence

Persistence saves a dehydrated snapshot of the client and restores it at the next launch
(TanStack `@tanstack/query-persist-client-core` and `@tanstack/query-async-storage-persister`).

A **persister** has three operations: `persistClient(client)`, `restoreClient()` and `removeClient()`.
A persisted client is `{buster, timestamp, clientState}`, where `clientState` is a dehydrated snapshot.

Defaults: `maxAge` 24 h, `buster` `""`, storage persister throttle 1000 ms.

## [per-001] save writes a timestamped snapshot

Given: `["a"] = "A"`; at T0 + 100.

When: `save(client, persister, buster: "v1")`.

Then:
1. `persistClient` called once with `buster == "v1"`, `timestamp == T0 + 100`.
2. Its `clientState` contains `["a"]` with data `"A"`.

## [per-002] restore hydrates the snapshot

Given: the persister holds a client saved now with `["a"] = "A"`.

When: `restore(freshClient, persister)`.

Then:
1. `getQueryData(["a"]) == "A"`; `removeClient` not called.

## [per-003] Nothing persisted

Given: `restoreClient()` returns nothing.

When: `restore`.

Then:
1. The cache is empty; `removeClient` not called.

## [per-004] maxAge

Given: a client persisted at T0, `maxAge: 1000`.

When: restore at T0 + 1000.
Then:
1. Hydrated (only strictly older than `maxAge` is expired).

When (instead): restore at T0 + 1001.
2. Not hydrated; `removeClient` called once.

## [per-005] Default maxAge is 24 hours

Given: a client persisted at T0.

Then:
1. Restore at T0 + 24 h hydrates.
2. Restore at T0 + 24 h + 1 ms discards it (`removeClient`).

## [per-006] buster mismatch discards the cache

Given: a client persisted with `buster: "v1"`.

When: restore with `buster: "v2"`.

Then:
1. Not hydrated; `removeClient` called once.

## [per-007] Restore errors discard the cache

Given: `restoreClient()` throws E.

When: restore.

Then:
1. `removeClient` called once.
2. restore throws E.

## [per-008] subscribe saves on every cache change

Given: `subscribe(client, persister)`.

When: `fetchQuery(["a"])` resolves.
Then:
1. `persistClient` called 3 times (query added, fetch started, fetch succeeded).

When: a mutation runs to success (no `onMutate`).
2. 3 more calls (mutation added, pending, success).

When: unsubscribed, then `setQueryData(["a"], "B")`.
3. No more calls.

## [per-009] persistQueryClient restores first, then subscribes

Given: the persister holds `["a"] = "A"`.

When: `persistQueryClient(freshClient, persister)` and its restore finishes.

Then:
1. `getQueryData(["a"]) == "A"`; `persistClient` was not called by the restore itself.

When: `setQueryData(["b"], "B")`.
2. `persistClient` called (added + updated: 2 calls).

When (instead): unsubscribed before the restore finished.
3. Changes after the restore never call `persistClient`.

## [per-010] Storage persister throttles writes

Given: a storage persister with `throttleTime: 1000`.

When: `persistClient(c1)` at T0, `persistClient(c2)` at T0 + 100, `persistClient(c3)` at T0 + 200.

Then:
1. One write at T0 (c1).
2. At T0 + 999 still one write.
3. At T0 + 1000 a second write, holding c3 (c2 is skipped).

## [per-011] Storage persister round trip

Given: a storage persister.

When: `persistClient(c)`, then `restoreClient()`.
Then:
1. Restores a client equal to `c` (same buster, timestamp, query keys and data).

When: `removeClient()`, then `restoreClient()`.
2. Restores nothing.

## [per-012] Storage persister retry: removeOldestQuery

Given: storage whose first write fails; queries `["old"]` (updated T0) and `["new"]` (updated T0 + 100);
a storage persister with `retry: removeOldestQuery`.

When: the client is saved.

Then:
1. Two writes attempted; the stored snapshot holds only `["new"]`.
