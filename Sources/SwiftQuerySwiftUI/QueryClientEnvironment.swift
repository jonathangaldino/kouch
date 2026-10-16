import SwiftQuery
import SwiftUI

extension EnvironmentValues {
    /// The client used by `@ObservedQuery` and friends. Set it with ``SwiftUICore/View/queryClient(_:)``.
    @Entry public var queryClient: QueryClient? = nil
}

extension View {
    /// Provides `client` to this view hierarchy, mounts it while the view is on screen (focus and
    /// reconnect refetching) and feeds scene activity into its ``FocusManager``.
    public func queryClient(_ client: QueryClient) -> some View {
        modifier(QueryClientModifier(client: client))
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
