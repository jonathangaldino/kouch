# SwiftQuery

A behavioral port of [TanStack Query](https://tanstack.com/query) (`@tanstack/query-core@5.104.3`) to Swift.
TanStack is the **specification**, not code to translate: given the same scenario, SwiftQuery behaves like
TanStack Query, built with idiomatic Swift underneath (`@MainActor` classes, `async`/`await`, `AsyncStream`).

Two libraries, both iOS 17+ / macOS 14+, Swift 6 language mode:

- `SwiftQuery`: the core. No UI dependencies (no SwiftUI or UIKit).
- `SwiftQuerySwiftUI`: property wrappers and environment integration on top of the core.

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

With SwiftUI:

```swift
import SwiftQuerySwiftUI

@main struct MyApp: App {
    let client = QueryClient()
    var body: some Scene { WindowGroup { UserView(id: 123).queryClient(client) } } // mounts + scene-phase focus
}

struct UserView: View {
    @ObservedQuery var user: QueryObserverResult<User>
    init(id: Int) { _user = ObservedQuery(QueryOptions(key: ["user", .int(id)]) { _ in try await api.user(id: id) }) }

    var body: some View {
        if let user = user.data { Text(user.name) } else if user.isLoading { ProgressView() }
        Button("Reload") { Task { await $user.refetch() } }
    }
}
```

To keep the cache across launches (instant data at cold start, offline launch, paused mutations that survive
the app being killed), give the client a persister. It restores before any query mounts, then saves on
every change (throttled to once per second):

```swift
WindowGroup {
    RootView().queryClient(client, persister: StoragePersister()) { await client.resumePausedMutations() }
}
```

Persisted data must be `Codable`. It is stored as JSON and decoded the first time its key is read with a type.

`@ObservedInfiniteQuery` (`$feed.fetchNextPage()`) and `@ObservedMutation` (`try await $save.mutate(draft)`)
work the same way. Like TanStack's React adapter, the wrappers render `getOptimisticResult` during the
view update and subscribe / apply new options right after it, so no observable state changes mid-update.

## Layout

| Path | What |
|---|---|
| `Specs/` | Behavioral contracts (19 files, 155 scenarios). Each scenario has an ID, for example `[dedup-001]`. |
| `Conformance/tanstack/` | Every scenario run against real TanStack (vitest with fake timers), including `query-persist-client-core` and `query-async-storage-persister`. |
| `Sources/SwiftQuery/` | The core implementation. |
| `Sources/SwiftQuerySwiftUI/` | The SwiftUI adapter. |
| `Tests/SwiftQueryTests/` | Every scenario, mirrored in Swift Testing with a virtual `TestClock`, plus SwiftUI adapter tests (including a real `NSHostingView` render). |
| `Scripts/check-parity.sh` | Fails if a scenario ID is missing from the specs or from either suite. |

## Verify

```bash
(cd Conformance/tanstack && npm install && npx vitest run)   # TanStack obeys the spec
swift test                                                  # SwiftQuery obeys the spec
Scripts/check-parity.sh                                     # same scenarios on both sides
xcodebuild -scheme SwiftQuery -destination 'generic/platform=iOS' build
xcodebuild -scheme SwiftQuerySwiftUI -destination 'generic/platform=iOS' build
```

## Scope

Implemented: query keys, query state machine, `Query`, `QueryCache`, `QueryClient`, `QueryObserver`
(including `getOptimisticResult`), stale time, garbage collection, deduplication, retries and backoff,
cancellation (including abort-on-unmount when the signal is consumed), invalidation, network modes,
focus refetching, mutations (`Mutation`, `MutationCache`, `MutationObserver`, scopes), infinite queries
(`InfiniteQueryObserver`, `fetchInfiniteQuery`, `maxPages`), `QueriesObserver` with `combine`,
`dehydrate` / `hydrate`, persistence (`restore` / `save` / `subscribePersistence` / `persist`,
`StoragePersister` with throttling and `removeOldestQuery` retry, `FileQueryStorage`), and the SwiftUI adapter
(including restore-before-mount).

Not yet: streamed queries, suspense, per-query persisters (`experimental_createQueryPersister`), and the
smaller options listed below. Dehydrating pending queries' promises is deliberately out: it only serves
server-side rendering.

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
| `useQueries` takes queries of any types | `QueriesObserver<Data, Value, Combined>`: all entries share one type | Typed results (see the `shortcut:` note) |
| `combine` output is deduped with `replaceEqualDeep` | Deduped with `==` when `Combined` is `Equatable`, otherwise every change notifies | No structural sharing |
| Dehydrated data is any JSON value | Snapshot data is `any Sendable`; hydrating rebuilds each query with the data's dynamic type, and `deserializeData` gets the key so persisted bytes can be decoded to the right type. A query hydrated without data gets its type on first typed access | Swift generics need concrete types |
| `hydrate` restores paused mutations using `setMutationDefaults({ mutationFn })` | Same, but the defaults must be registered with the typed `setMutationDefaults(_:_: MutationOptions)` overload; mutations with unregistered keys are skipped | The mutation function and its types must be known to resume |
| Persisted data is whatever `JSON.stringify` makes of it | Data, variables and context must be `Encodable` to be persisted (others are skipped). They are stored as JSON and decoded lazily with the type of the first typed read; data that no longer decodes is dropped. Errors are not persisted | No runtime type information on disk |
| `useQuery` supports `select` | `@ObservedQuery<Data>` has no `select`; use `QueryObserver` directly or derive in `body` | Lets the wrapper infer its type from `QueryObserverResult<Data>` |
