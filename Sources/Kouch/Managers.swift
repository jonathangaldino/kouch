import Network

/// A main-actor event source with tokens for unsubscribing.
@MainActor
public final class Subscription {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

    /// Stops delivery. Safe to call more than once.
    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

@MainActor
final class Listeners<Value> {
    private var listeners: [(id: Int, fn: (Value) -> Void)] = []
    private var nextID = 0

    var isEmpty: Bool { listeners.isEmpty }
    var count: Int { listeners.count }

    func add(_ fn: @escaping (Value) -> Void, onRemove: @escaping () -> Void = {}) -> Subscription {
        nextID += 1
        let id = nextID
        listeners.append((id, fn))
        return Subscription { [weak self] in
            guard let self, let index = listeners.firstIndex(where: { $0.id == id }) else { return }
            listeners.remove(at: index)
            onRemove()
        }
    }

    func send(_ value: Value) { listeners.forEach { $0.fn(value) } }
    func removeAll() { listeners = [] }
}

/// Tracks network reachability. Queries with `networkMode: .online` pause while offline.
@MainActor
public final class OnlineManager {
    /// Process-wide manager backed by `NWPathMonitor`.
    public static let shared: OnlineManager = {
        let manager = OnlineManager()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in manager.setOnline(online) }
        }
        monitor.start(queue: .main)
        manager.monitor = monitor
        return manager
    }()

    private var monitor: NWPathMonitor?
    private let listeners = Listeners<Bool>()
    public private(set) var isOnline: Bool

    public init(isOnline: Bool = true) { self.isOnline = isOnline }

    public func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        listeners.send(online)
    }

    public func subscribe(_ listener: @escaping @MainActor (Bool) -> Void) -> Subscription {
        listeners.add(listener)
    }
}

/// Tracks whether the app is in the foreground. Retries pause and interval refetches stop while
/// unfocused; regaining focus refetches stale active queries on mounted clients.
///
/// Kouch core has no UI dependency, so focus is fed by the host (e.g. a SwiftUI scene phase).
@MainActor
public final class FocusManager {
    public static let shared = FocusManager()

    private let listeners = Listeners<Bool>()
    private var focused: Bool?

    public init() {}

    /// `nil` falls back to "focused".
    public var isFocused: Bool { focused ?? true }

    public func setFocused(_ focused: Bool?) {
        guard focused != self.focused else { return }
        self.focused = focused
        listeners.send(isFocused)
    }

    public func subscribe(_ listener: @escaping @MainActor (Bool) -> Void) -> Subscription {
        listeners.add(listener)
    }
}
