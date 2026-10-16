import Kouch
import KouchSwiftUI
import SwiftUI

/// A tiny devtools: every query in the cache, plus the bulk client operations.
struct CacheView: View {
    @State private var queries: [AnyQuery] = []
    @State private var subscription: Subscription?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Invalidate all (refetch active)") { Task { await client.invalidateQueries() } }
                    Button("Refetch all") { Task { await client.refetchQueries() } }
                    Button("Cancel all fetches") { Task { await client.cancelQueries() } }
                    Button("Clear cache", role: .destructive) { client.clear() }
                }
                Section("\(queries.count) queries") {
                    ForEach(queries, id: \.queryKey) { query in
                        let state = query.stateSummary
                        VStack(alignment: .leading) {
                            Text(query.queryKey.description).font(.caption.monospaced()).lineLimit(1)
                            Text("\(state.status) · \(state.fetchStatus) · \(query.isStale() ? "stale" : "fresh") · \(query.observersCount) observers")
                                .font(.caption2)
                                .foregroundStyle(query.isActive() ? .primary : .secondary)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { client.queryCache.remove(query) } }
                    }
                }
            }
            .navigationTitle("Cache")
            .toolbar { FetchingIndicator() }
            .onAppear {
                queries = client.queryCache.getAll()
                subscription = client.queryCache.subscribe { _ in queries = client.queryCache.getAll() }
            }
            .onDisappear { subscription?.cancel() }
        }
    }
}
