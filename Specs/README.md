# Kouch Behavioral Specification

These documents are **behavioral contracts**, not architecture. They describe what TanStack Query
(`@tanstack/query-core@5.104.3`) does in a given scenario. Kouch must do the same.

Every scenario has a stable ID (`[dedup-001]`). The same ID appears in:

- `Conformance/tanstack/tests/*.test.ts` — proves the scenario against real TanStack.
- `Tests/KouchTests/*.swift` — proves Kouch behaves identically.

`Scripts/check-parity.sh` fails if an ID is missing from either suite.

## Vocabulary

| Term | Meaning |
|---|---|
| **query** | Cache entry identified by a query key. Holds state, options and observers. |
| **observer** | Consumer of one query. Derives a *result* from query state + its own options. |
| **active** | Query with at least one *enabled* observer subscribed. |
| **inactive** | Query with no observers, or only disabled observers. |
| **fresh / stale** | Data age vs. `staleTime`. Missing data or invalidated data is stale. |
| **settle** | Let pending async work complete (microtasks / main actor jobs). No virtual time passes. |
| **advance T** | Move virtual time forward by T milliseconds, firing due timers in order. |
| **fn** | A controllable query function: each call is recorded; the test resolves or rejects it. |

## Defaults (both implementations must agree)

| Option | Default |
|---|---|
| `staleTime` | `0` |
| `gcTime` | `5 min` (300 000 ms). Query keeps the **largest** gcTime ever applied to it. |
| `retry` (observer / query) | `3` |
| `retry` (`fetchQuery`, `prefetchQuery`, `ensureQueryData`) | `false` |
| `retry` (mutations) | `0` |
| `retryDelay` | `min(1000 · 2^failureCount, 30 000)` → 1000, 2000, 4000, … |
| `networkMode` | `online` |
| `refetchOnMount` / `refetchOnWindowFocus` | `true` (refetch if stale) |
| `refetchOnReconnect` | `true`, but `false` when `networkMode == always` |
| `refetchInterval` | off |
| `invalidateQueries` `refetchType` | `active` |
| `refetch()` / `refetchQueries` / `invalidateQueries` `cancelRefetch` | `true` |

## Files

| File | Topic |
|---|---|
| [query-key.md](query-key.md) | identity, hashing, partial matching |
| [query-lifecycle.md](query-lifecycle.md) | state machine of a single query |
| [query-cache.md](query-cache.md) | storage, lookup, filters, events |
| [query-client.md](query-client.md) | imperative API |
| [query-observer.md](query-observer.md) | derived results, mount behavior, options |
| [stale-time.md](stale-time.md) | fresh/stale semantics |
| [garbage-collection.md](garbage-collection.md) | gcTime |
| [deduplication.md](deduplication.md) | one request per key |
| [retries.md](retries.md) | retry/backoff |
| [cancellation.md](cancellation.md) | cancel, revert, abort signal |
| [invalidation.md](invalidation.md) | invalidateQueries |
| [mutations.md](mutations.md) | mutations |
| [network-mode.md](network-mode.md) | offline / paused / reconnect |
| [focus-refetch.md](focus-refetch.md) | window focus |

## Out of scope (not specified yet)

Infinite queries, hydration, streamed queries, `QueriesObserver`, suspense, structural sharing,
tracked-props notification filtering (`notifyOnChangeProps`).
