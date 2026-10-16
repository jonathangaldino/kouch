import Kouch
import KouchSwiftUI
import SwiftUI

@MainActor let client = makeClient()

@MainActor private func makeClient() -> QueryClient {
    let client = QueryClient(defaultOptions: QueryConfiguration(staleTime: .seconds(30), gcTime: .seconds(300)))
    client.setMutationDefaults(Mutations.favoriteKey, MutationOptions<String, Set<String>, Set<String>>(retry: 1) { name in
        try await FavoritesServer.shared.toggle(name)
    })
    return client
}

@main
struct KouchDemoApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                PeopleView().tabItem { Label("People", systemImage: "person.3") }
                PlanetsView().tabItem { Label("Planets", systemImage: "globe") }
                LabView().tabItem { Label("Lab", systemImage: "flask") }
                CacheView().tabItem { Label("Cache", systemImage: "tray.full") }
            }
            // Restores the cache saved on the last run before any query mounts, then saves on every change.
            .queryClient(client, persister: StoragePersister()) { await client.resumePausedMutations() }
        }
    }
}

/// The raw state machine of a query, shown everywhere so you can watch it move.
struct StatusLine<Value: Sendable>: View {
    let result: QueryObserverResult<Value>

    var body: some View {
        HStack {
            Text("\(result.status)").foregroundStyle(result.isError ? .red : result.isSuccess ? .green : .orange)
            Text("· \(result.fetchStatus)").foregroundStyle(result.isFetching ? .blue : .secondary)
            if result.isStale { Text("· stale").foregroundStyle(.secondary) }
            if result.isPlaceholderData { Text("· placeholder").foregroundStyle(.purple) }
            if result.failureCount > 0 { Text("· failures \(result.failureCount)").foregroundStyle(.red) }
        }
        .font(.caption.monospaced())
    }
}

/// Global spinner: counts every fetching query in the client.
struct FetchingIndicator: View {
    @ObservedIsFetching var fetching

    var body: some View {
        if fetching > 0 { Label("\(fetching)", systemImage: "arrow.triangle.2.circlepath").font(.caption) }
    }
}
