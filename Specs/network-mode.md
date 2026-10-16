# Network Mode

| Mode | Behavior when offline |
|---|---|
| `online` (default) | Do not start or retry; `fetchStatus = paused` until online. |
| `always` | Ignore network state entirely. `refetchOnReconnect` defaults to false. |
| `offlineFirst` | First attempt runs; retries pause while offline. |

Paused fetches resume only through a **mounted** client: `client.mount()` subscribes to the online and
focus managers and forwards events to every query. An unmounted client never resumes paused work.

## [net-001] Offline start pauses

Given: client mounted (`client.mount()`); offline.

When: an observer subscribes to `["a"]`.

Then:
1. `status == pending`, `fetchStatus == paused`, `isPaused == true`, fn not called.

When: online.
2. fn called; `fetchStatus == fetching`; after resolve `status == success`.

## [net-002] networkMode always

Given: offline.

When: an observer with `networkMode: "always"` subscribes.

Then:
1. fn called; `fetchStatus == fetching`.

## [net-003] networkMode offlineFirst

Given: offline; observer `networkMode: "offlineFirst"`, `retry: 1`, `retryDelay: 10`.

When: it subscribes and attempt 1 fails; advance 10.

Then:
1. fn called once; `fetchStatus == paused`.

## [net-004] Reconnect refetches stale active queries

Given: client mounted; active observer on `["stale"]` (staleTime 0) and on `["fresh"]`
(staleTime Infinity); both resolved; offline.

When: online.

Then:
1. `["stale"]` refetched; `["fresh"]` not.

## [net-005] Leaving a paused initial fetch cancels it

Given: offline; observer on `["a"]` paused.

When: the observer unsubscribes, then online.

Then:
1. Query `status == pending`, `fetchStatus == idle`; fn never called.

## [net-006] fetchQuery while offline waits for the network

Given: client mounted; offline.

When: `fetchQuery(["a"])`.

Then:
1. Not resolved; `fetchStatus == paused`; fn not called.

When: online and fn resolves `"A"`.
2. Resolves `"A"`.
