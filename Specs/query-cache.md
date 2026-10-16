# Query Cache

The cache stores queries by key hash and broadcasts events.

## [cache-001] build is idempotent per key

When: `build(["a"])` twice.

Then:
1. Same instance returned both times.
2. `getAll().count == 1`.
3. Exactly one `added` event was emitted.

## [cache-002] find defaults to exact matching

Given: queries `["todos"]` and `["todos", 1]`.

Then:
1. `find({queryKey: ["todos"]})` returns the `["todos"]` query.
2. `find({queryKey: ["todos", 1]})` returns the `["todos", 1]` query.
3. `find({queryKey: ["nope"]})` returns nothing.

## [cache-003] findAll filters by type, stale and fetchStatus

Given:
- `["active"]` with a subscribed enabled observer, fetched (staleTime Infinity on the observer).
- `["inactive"]` fetched via `fetchQuery`, no observers (staleTime 0, so stale).
- `["fetching"]` with a `fetchQuery` in flight.

Then:
1. `findAll({type: "active"})` → `["active"]` only.
2. `findAll({type: "inactive"})` → `["inactive"]`, `["fetching"]`.
3. `findAll({stale: false})` → `["active"]`, `["inactive"]`. A query **without observers** is stale only when it
   has no data or is invalidated; elapsed time is not considered (`["fetching"]` has no data → stale).
4. `findAll({fetchStatus: "fetching"})` → `["fetching"]` only.
5. `findAll({predicate: q => q.queryKey[0] == "inactive"})` → `["inactive"]` only.

## [cache-004] Cache events

Given: a cache subscriber recording event types for query `["a"]`.

When: `fetchQuery(["a"])` resolves, then `removeQueries({queryKey: ["a"]})`.

Then the recorded sequence of `added | updated | removed` types is:
1. `added`, `updated` (fetch), `updated` (success), `removed`.

## [cache-005] remove and clear

Given: queries `["a"]`, `["b"]`.

When: `remove(query a)`.
Then:
1. `find(["a"])` is nothing, `getAll().count == 1`.

When: `clear()`.
2. `getAll().count == 0`.

## [cache-006] Cache-level callbacks

Given: cache config with `onSuccess`, `onError`, `onSettled` recorders.

When: `fetchQuery(["ok"])` resolves `"A"` and `fetchQuery(["bad"])` rejects with E.

Then:
1. `onSuccess` called once with (`"A"`, query ok).
2. `onError` called once with (E, query bad).
3. `onSettled` called twice: (`"A"`, null, ok) and (undefined, E, bad).
