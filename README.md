# SwiftQuery

A behavioral port of [TanStack Query](https://tanstack.com/query) (`@tanstack/query-core@5.104.3`) to Swift.
TanStack is the **specification**, not code to translate: given the same scenario, SwiftQuery behaves like
TanStack Query, built with idiomatic Swift underneath (`@MainActor` classes, `async`/`await`, `AsyncStream`).

The `SwiftQuery` target has no UI dependencies (no SwiftUI or UIKit). It targets iOS 17+ and macOS 14+ in Swift 6 language mode.

```swift
import SwiftQuery

let client = QueryClient()
client.mount() // react to focus / reconnect

let observer = QueryObserver(
    client: client,
    options: QueryOptions(key: ["user", 123], staleTime: .seconds(30)) { context in
        try await api.user(id: 123)
    }
)

for await result in observer.results {
    if result.isLoading { showSpinner() }
    if let user = result.data { render(user) }
}

await client.invalidateQueries(QueryFilters(queryKey: ["user"]))
```

## Layout

| Path | What |
|---|---|
| `Specs/` | Behavioral contracts. Each scenario has an ID, for example `[dedup-001]`. |
| `Conformance/tanstack/` | Every scenario run against real TanStack (vitest with fake timers). |
| `Sources/SwiftQuery/` | The implementation. |
| `Tests/SwiftQueryTests/` | Every scenario, mirrored in Swift Testing with a virtual `TestClock`. |
| `Scripts/check-parity.sh` | Fails if a scenario ID is missing from the specs or from either suite. |

## Verify

```bash
(cd Conformance/tanstack && npm install && npx vitest run)   # TanStack obeys the spec
swift test                                                  # SwiftQuery obeys the spec
Scripts/check-parity.sh                                     # same scenarios on both sides
xcodebuild -scheme SwiftQuery -destination 'generic/platform=iOS' build
```

## Scope

Implemented: query keys, query state machine, `Query`, `QueryCache`, `QueryClient`, `QueryObserver`,
stale time, garbage collection, deduplication, retries and backoff, cancellation (including
abort-on-unmount when the signal is consumed), invalidation, network modes, focus refetching, and mutations
(`Mutation`, `MutationCache`, `MutationObserver`, scopes).

Not yet: infinite queries, hydration, streamed queries, `QueriesObserver`, suspense, and the
`SwiftQuerySwiftUI` adapter.

## Deliberate Swift differences

| TanStack | SwiftQuery | Why |
|---|---|---|
| Keys are hashed with JSON.stringify, so `1` and `1.0` are the same key | `QueryKeyValue.int(1)` and `.double(1.0)` are different keys | Swift typing |
| `staleTime`, `enabled`, etc. can be functions | They are values only | Smaller API. Can be added later. |
| Structural sharing (`replaceEqualDeep`) | Not needed | Value types. Change detection uses `Equatable` when `Data` conforms, and otherwise a data version counter. |
| Tracked-props notifications (`notifyOnChangeProps`) | A listener is notified when the derived result changes | No proxies in Swift |
| A key can hold any type | One `Data` type per key; a mismatch traps | Type safety (see the `shortcut:` note in `QueryCache.build`) |
| Global `onlineManager` / `focusManager` | Injected per client. `OnlineManager.shared` uses `NWPathMonitor`. `FocusManager` is fed by the host app | Testability, and no UI dependency in core |
| An `AbortSignal` is passed to the query function | `context.signal` (a `CancellationSignal`). The query function's `Task` is also cancelled on abort | Swift cooperative cancellation |
| Cancelling a caller's promise does nothing | Cancelling the task that awaits `fetchQuery` does not cancel the shared fetch either | Other consumers may share that fetch |
