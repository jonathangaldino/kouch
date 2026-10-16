import Kouch
import SwiftUI

extension EnvironmentValues {
    /// The client used by `@ObservedQuery` and friends. Set it with ``SwiftUICore/View/queryClient(_:)``.
    @Entry public var queryClient: QueryClient? = nil
    /// `true` while ``SwiftUICore/View/queryClient(_:persister:options:onRestored:)`` restores the
    /// persisted cache. Queries render without fetching until it is done.
    @Entry public var isRestoringQueries: Bool = false
}

extension View {
    /// Provides `client` to this view hierarchy, mounts it while the view is on screen (focus and
    /// reconnect refetching) and feeds scene activity into its ``FocusManager``.
    public func queryClient(_ client: QueryClient) -> some View {
        modifier(QueryClientModifier(client: client))
    }
}

extension View {
    /// Like ``SwiftUICore/View/queryClient(_:)``, and restores the persisted cache before queries mount,
    /// then saves on every change (TanStack `PersistQueryClientProvider`). `onRestored` runs after a
    /// successful restore; resuming paused mutations there is common:
    /// `.queryClient(client, persister: persister) { await client.resumePausedMutations() }`.
    public func queryClient(
        _ client: QueryClient, persister: QueryPersister, options: PersistOptions = .init(),
        onRestored: (@MainActor () async -> Void)? = nil
    ) -> some View {
        modifier(PersistQueryClientModifier(client: client, persister: persister, options: options, onRestored: onRestored))
            .queryClient(client)
    }
}

private struct PersistQueryClientModifier: ViewModifier {
    let client: QueryClient
    let persister: QueryPersister
    let options: PersistOptions
    let onRestored: (@MainActor () async -> Void)?
    @State private var isRestoring = true
    @State private var subscription: Subscription?

    func body(content: Content) -> some View {
        content
            .environment(\.isRestoringQueries, isRestoring)
            .task {
                guard isRestoring else { return }
                // A failed restore already discarded the stored cache; start fresh.
                if (try? await client.restore(from: persister, options: options)) != nil { await onRestored?() }
                subscription = client.subscribePersistence(persister, options: options)
                isRestoring = false
            }
            .onDisappear {
                subscription?.cancel()
                subscription = nil
            }
    }
}

private struct QueryClientModifier: ViewModifier {
    let client: QueryClient
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.queryClient, client)
            .onAppear {
                client.mount()
                client.focusManager.setFocused(scenePhase == .active)
            }
            .onDisappear { client.unmount() }
            .onChange(of: scenePhase) { _, phase in client.focusManager.setFocused(phase == .active) }
    }
}

@MainActor
func requireClient(_ client: QueryClient?) -> QueryClient {
    guard let client else { preconditionFailure("No QueryClient in the environment. Add .queryClient(client) to a parent view.") }
    return client
}
