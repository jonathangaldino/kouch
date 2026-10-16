import Kouch
import KouchSwiftUI
import SwiftUI

/// Infinite query: the next page loads when the last row scrolls into view.
struct PlanetsView: View {
    @ObservedInfiniteQuery(Queries.planets) var planets

    var body: some View {
        NavigationStack {
            List {
                Section { StatusLine(result: planets.base) }
                let all = planets.data?.pages.flatMap(\.results) ?? []
                ForEach(all) { planet in
                    VStack(alignment: .leading) {
                        Text(planet.name).font(.headline)
                        Text("\(planet.climate) · \(planet.terrain) · pop. \(planet.population)").font(.caption)
                    }
                    .task {
                        // Reached the end of the list: ask for the next page (no-op while one is in flight).
                        if planet.id == all.last?.id, planets.hasNextPage, !planets.isFetchingNextPage {
                            await $planets.fetchNextPage()
                        }
                    }
                }
                if planets.isFetchingNextPage {
                    ProgressView().frame(maxWidth: .infinity)
                } else if planets.data != nil, !planets.hasNextPage {
                    Text("All \(all.count) planets loaded").font(.caption).frame(maxWidth: .infinity)
                }
                if planets.isFetchNextPageError {
                    Button("Couldn't load more. Retry") { Task { await $planets.fetchNextPage() } }
                }
            }
            .overlay { if planets.isLoading { ProgressView("Loading planets…") } }
            .refreshable { await $planets.base.refetch() }
            .navigationTitle("Planets (\(planets.data?.pages.count ?? 0) pages)")
            .toolbar { FetchingIndicator() }
        }
    }
}
