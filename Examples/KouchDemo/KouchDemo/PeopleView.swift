import Kouch
import KouchSwiftUI
import SwiftUI

/// Infinite query: pages load as you scroll; pull to refresh refetches every loaded page.
struct PeopleView: View {
    @ObservedInfiniteQuery(Queries.people) var people

    var body: some View {
        NavigationStack {
            List {
                Section { StatusLine(result: people.base) }
                ForEach(people.data?.pages.flatMap(\.results) ?? []) { person in
                    NavigationLink(person.name, value: person)
                }
                if people.hasNextPage {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .task { await $people.fetchNextPage() }
                }
                if let error = people.error { Text(error.localizedDescription).foregroundStyle(.red) }
            }
            .overlay { if people.isLoading { ProgressView("Loading people…") } }
            .refreshable { await $people.base.refetch() }
            .navigationTitle("People (\(people.data?.pages.count ?? 0) pages)")
            .navigationDestination(for: Person.self) { PersonView(person: $0) }
            .toolbar { FetchingIndicator() }
        }
    }
}

/// A plain query seeded with `initialData`, parallel film queries, a dependent query and a mutation.
struct PersonView: View {
    @ObservedQuery var person: QueryObserverResult<Person>
    @ObservedQueries var films: [QueryObserverResult<Film>]
    @ObservedQuery var favorites: QueryObserverResult<Set<String>>
    @ObservedMutation var toggle: MutationObserverResult<String, Set<String>, Set<String>>

    init(person: Person) {
        _person = ObservedQuery(Queries.person(person))
        _films = ObservedQueries(person.films.map(Queries.film))
        _favorites = ObservedQuery(Queries.favorites)
        _toggle = ObservedMutation(Mutations.toggleFavorite)
    }

    var body: some View {
        Form {
            if let person = person.data {
                Section {
                    LabeledContent("Height", value: person.height)
                    LabeledContent("Mass", value: person.mass)
                    LabeledContent("Born", value: person.birthYear)
                } header: {
                    Text("initialData from the list")
                } footer: {
                    StatusLine(result: self.person)
                }

                Section("Dependent query + select") { HomeworldView(url: person.homeworld) }

                Section("Parallel queries (shared cache)") {
                    ForEach(Array(films.enumerated()), id: \.offset) { _, film in
                        if let film = film.data { Text("Ep. \(film.episodeId) – \(film.title)") } else { StatusLine(result: film) }
                    }
                }

                Section {
                    let isFavorite = favorites.data?.contains(person.name) ?? false
                    Button(isFavorite ? "★ Unfavorite" : "☆ Favorite") {
                        Task { try? await $toggle.mutate(person.name) }
                    }
                    .disabled(toggle.isPending)
                    if toggle.isPending { Text("Saving… (optimistic, already applied)").font(.caption) }
                    if let error = toggle.error { Text("Rolled back: \(error.localizedDescription)").foregroundStyle(.red) }
                } header: {
                    Text("Optimistic mutation")
                } footer: {
                    Text("Make the server flaky in the Lab tab to see rollbacks.")
                }
            }
        }
        .navigationTitle(person.data?.name ?? "")
        .refreshable { await $person.refetch() }
    }
}

/// Only fetches once the parent knows the homeworld URL, and `select`s just the name out of the planet.
struct HomeworldView: View {
    @ObservedSelectQuery<Planet, String> var name: QueryObserverResult<String>

    init(url: String?) { _name = ObservedSelectQuery(Queries.planet(url)) { $0.name } }

    var body: some View {
        LabeledContent("Homeworld", value: name.data ?? "…")
        StatusLine(result: name)
    }
}
