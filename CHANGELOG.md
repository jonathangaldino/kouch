# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is below 1.0, minor releases may
contain breaking changes.

## [Unreleased]

## [0.1.0] - Unreleased

First release: a behavioral port of TanStack Query (`@tanstack/query-core` 5.104.3,
`@tanstack/query-persist-client-core` 5.104.3 and `@tanstack/query-async-storage-persister` 5.104.3). It is checked
by 176 scenarios that run against both TanStack and SwiftQuery.

### Added

- `SwiftQuery` core:
  - Query keys, query state, `Query`, `QueryCache`, `QueryClient` and `QueryObserver`, including
    `getOptimisticResult` and an `AsyncStream` of results.
  - Stale time, garbage collection, deduplication, retries and backoff, cancellation (including abort when the last
    observer leaves) and invalidation.
  - Network modes and focus/reconnect refetching (`OnlineManager` backed by `NWPathMonitor`, `FocusManager`).
  - Mutations: `Mutation`, `MutationCache`, `MutationObserver`, scopes, and defaults set with `setMutationDefaults`.
  - Infinite queries: `InfiniteQueryObserver`, `fetchInfiniteQuery`, `maxPages`.
  - `QueriesObserver` with `combine`.
  - Streamed queries: `streamedQuery` with the reset, append and replace modes.
  - `dehydrate` / `hydrate`.
  - Persistence: `restore`, `save`, `subscribePersistence`, `persist`, and `StoragePersister` with throttling and
    `removeOldestQuery` retry. Storage options are `FileQueryStorage` and `InMemoryQueryStorage`. Persisted data is
    `Codable` and decoded lazily.
  - Options:
    - `meta`, and function contexts carrying `client`, `meta` and `mutationKey`.
    - Values computed per query: `StaleTime.dynamic`, `RefetchTrigger.dynamic`, `RefetchInterval.dynamic`,
      `.enabled { }`, `.initialData { }`.
    - `retryOnMount`, `skipToken`, and `throwOnError` on refetches.
    - `getQueriesData` / `setQueriesData`, `mutationCache.find`.
- `SwiftQuerySwiftUI`:
  - `.queryClient(_:)` and `.queryClient(_:persister:)`, which restores the cache before queries mount.
  - `@ObservedQuery`, `@ObservedSelectQuery`, `@ObservedInfiniteQuery`, `@ObservedQueries`, `@ObservedMutation`,
    `@ObservedIsFetching`, `@ObservedIsMutating` and `@ObservedMutationState`.

[Unreleased]: https://github.com/OWNER/REPO/compare/0.1.0...HEAD
[0.1.0]: https://github.com/OWNER/REPO/releases/tag/0.1.0
