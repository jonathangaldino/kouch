import Foundation
import Kouch

// One place for keys and fetchers (TanStack's `queryOptions` pattern), shared by views and prefetching.
@MainActor
enum Queries {
    static var people: InfiniteQueryOptions<Page<Person>, Int> {
        InfiniteQueryOptions(
            key: ["people"],
            initialPageParam: 1,
            getNextPageParam: { page, _, param, _ in page.next == nil ? nil : param + 1 }
        ) { context in
            try await SWAPI.get("\(SWAPI.base)/people/?page=\(context.pageParam)")
        }
    }

    /// `initialData` comes from the list row, so the detail screen renders instantly.
    static func person(_ person: Person) -> QueryOptions<Person> {
        QueryOptions(key: ["person", .string(person.url)], initialData: person) { _ in
            try await SWAPI.get(person.url)
        }
    }

    /// `skipToken` keeps the query disabled until the URL is known (a dependent query).
    static func planet(_ url: String?) -> QueryOptions<Planet> {
        QueryOptions(key: ["planet", url.map { .string($0) } ?? nil], staleTime: .infinity, skipToken: url == nil) { _ in
            try await SWAPI.get(url!)
        }
    }

    static var planets: InfiniteQueryOptions<Page<Planet>, Int> {
        InfiniteQueryOptions(
            key: ["planets"],
            initialPageParam: 1,
            getNextPageParam: { page, _, param, _ in page.next == nil ? nil : param + 1 },
            staleTime: .seconds(60)
        ) { context in
            try await SWAPI.get("\(SWAPI.base)/planets/?page=\(context.pageParam)")
        }
    }

    /// Films never change: `.infinity` means each film is fetched once, then shared by every person.
    static func film(_ url: String) -> QueryOptions<Film> {
        QueryOptions(key: ["film", .string(url)], staleTime: .infinity) { _ in try await SWAPI.get(url) }
    }

    static var favorites: QueryOptions<Set<String>> {
        QueryOptions(key: ["favorites"]) { _ in try await FavoritesServer.shared.fetch() }
    }

    static var flaky: QueryOptions<String> {
        QueryOptions(key: ["flaky"], staleTime: .infinity, retry: 3, retryDelay: .fixed(.seconds(1))) { _ in
            try await FlakyServer.shared.fetch()
        }
    }

    static func serverTime(polling: Bool) -> QueryOptions<Date> {
        QueryOptions(key: ["serverTime"], refetchInterval: polling ? .every(.seconds(2)) : nil) { _ in
            try await Task.sleep(for: .milliseconds(200))
            return Date()
        }
    }

    /// A streamed query: each line of the crawl is written to the cache as it arrives.
    static var openingCrawl: QueryOptions<String> {
        QueryOptions(
            key: ["crawl"], staleTime: .infinity,
            queryFn: streamedQuery(initialValue: "", reducer: { $0 + $1 }) { _ in
                let film: Film = try await SWAPI.get("\(SWAPI.base)/films/1/")
                let lines = film.openingCrawl.components(separatedBy: .newlines).filter { !$0.isEmpty }
                return AsyncThrowingStream<String, any Error> { continuation in
                    let task = Task {
                        for line in lines {
                            try? await Task.sleep(for: .milliseconds(250))
                            continuation.yield(line + "\n")
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }
}

@MainActor
enum Mutations {
    static let favoriteKey: QueryKey = ["favorite"]

    /// The mutation function lives in `setMutationDefaults` (see the app), so paused mutations can resume
    /// after a relaunch. This adds an optimistic update with rollback.
    static var toggleFavorite: MutationOptions<String, Set<String>, Set<String>> {
        MutationOptions(
            mutationKey: favoriteKey,
            onMutate: { name in
                await client.cancelQueries(QueryFilters(queryKey: ["favorites"]))
                let previous = client.getQueryData(["favorites"], as: Set<String>.self) ?? []
                client.setQueryData(["favorites"], previous.symmetricDifference([name]))
                return previous
            },
            onError: { _, _, previous in
                if let previous { client.setQueryData(["favorites"], previous) }
            },
            onSettled: { _, _, _, _ in
                await client.invalidateQueries(QueryFilters(queryKey: ["favorites"]))
            }
        )
    }
}
