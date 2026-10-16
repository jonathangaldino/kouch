import Kouch
import KouchSwiftUI
import SwiftUI

/// Retries, polling, streaming and mutation state.
struct LabView: View {
    @State private var polling = true

    var body: some View {
        NavigationStack {
            Form {
                RetrySection()
                Section("Polling (refetchInterval)") {
                    Toggle("Poll every 2s", isOn: $polling)
                    ServerTimeRow(polling: polling)
                }
                StreamSection()
                MutationsSection()
            }
            .navigationTitle("Lab")
            .toolbar { FetchingIndicator() }
        }
    }
}

struct RetrySection: View {
    @ObservedQuery(Queries.flaky) var flaky

    var body: some View {
        Section {
            Text(flaky.data ?? "–")
            if let reason = flaky.failureReason { Text(reason.localizedDescription).foregroundStyle(.red).font(.caption) }
            StatusLine(result: flaky)
            Button("Reset & fetch again") { Task { await client.resetQueries(QueryFilters(queryKey: ["flaky"])) } }
        } header: {
            Text("Retries (3 retries, 1s apart)")
        } footer: {
            Text("The fake server fails twice, then succeeds.")
        }
    }
}

struct ServerTimeRow: View {
    @ObservedQuery var time: QueryObserverResult<Date>

    init(polling: Bool) { _time = ObservedQuery(Queries.serverTime(polling: polling)) }

    var body: some View {
        LabeledContent("Server time", value: time.data?.formatted(date: .omitted, time: .standard) ?? "–")
        StatusLine(result: time)
    }
}

struct StreamSection: View {
    @ObservedQuery(Queries.openingCrawl) var crawl

    var body: some View {
        Section("Streamed query") {
            Text(crawl.data ?? "").font(.caption.monospaced())
            StatusLine(result: crawl)
            HStack {
                Button("Replay") { Task { await $crawl.refetch() } }
                Spacer()
                Button("Cancel") { Task { await client.cancelQueries(QueryFilters(queryKey: ["crawl"])) } }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct MutationsSection: View {
    @ObservedQuery(Queries.favorites) var favorites
    @ObservedIsMutating var mutating
    @ObservedMutationState(MutationFilters(mutationKey: Mutations.favoriteKey), select: Self.describe) var history: [String]
    @State private var flaky = false

    static func describe(_ mutation: AnyMutation) -> String {
        "#\(mutation.mutationId) \(mutation.stateSnapshot.variables.map { "\($0)" } ?? "?") → \(mutation.status)"
    }

    var body: some View {
        Section {
            Toggle("Flaky server (70% failures)", isOn: $flaky)
                .onChange(of: flaky) { _, flaky in Task { await FavoritesServer.shared.setFailRate(flaky ? 0.7 : 0) } }
            LabeledContent("Favorites", value: favorites.data?.sorted().joined(separator: ", ") ?? "–")
            LabeledContent("Mutations in flight", value: "\(mutating)")
            ForEach(history.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
        } header: {
            Text("Mutations")
        } footer: {
            Text("Favorite people from their detail screen. Failed mutations retry once, then roll back.")
        }
    }
}
