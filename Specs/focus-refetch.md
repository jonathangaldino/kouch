# Window Focus Refetching

When the client is mounted and the app regains focus, every query with an observer whose
`refetchOnWindowFocus` allows it refetches (`cancelRefetch: false`).

## [focus-001] Focus refetches stale active queries

Given: client mounted; active observer on `["a"]` (staleTime 0), resolved; unfocused.

When: focused.

Then:
1. fn called again.

## [focus-002] Focus respects freshness and the option

Given: client mounted, all resolved, unfocused:
- `["fresh"]` with `staleTime: Infinity`
- `["off"]` with `refetchOnWindowFocus: false` (stale)
- `["always"]` with `staleTime: Infinity`, `refetchOnWindowFocus: "always"`

When: focused.

Then:
1. Only `["always"]` refetches.

## [focus-003] refetchInterval pauses in background

Given: observer `refetchInterval: 1000`, resolved; unfocused.

When: advance 3000.
Then:
1. No interval fetches.

Given: `refetchIntervalInBackground: true`, unfocused.
When: advance 3000.
2. Three interval fetches.

## [focus-004] Inactive queries are not refetched on focus

Given: client mounted; `["a"]` fetched via `fetchQuery` (no observers); unfocused.

When: focused.

Then:
1. fn not called again.
