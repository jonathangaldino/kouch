import Foundation

public struct MutationObserverResult<Variables: Sendable, Data: Sendable, Context: Sendable>: Sendable {
    public var state: MutationState<Variables, Data, Context>

    public var status: MutationStatus { state.status }
    public var data: Data? { state.data }
    public var error: (any Error)? { state.error }
    public var variables: Variables? { state.variables }
    public var context: Context? { state.context }
    public var failureCount: Int { state.failureCount }
    public var failureReason: (any Error)? { state.failureReason }
    public var isPaused: Bool { state.isPaused }
    public var submittedAt: Date? { state.submittedAt }
    public var isIdle: Bool { status == .idle }
    public var isPending: Bool { status == .pending }
    public var isSuccess: Bool { status == .success }
    public var isError: Bool { status == .error }
}

/// Per-call callbacks for ``MutationObserver/mutate(_:onSuccess:onError:onSettled:)``. They run after
/// the mutation's own callbacks, and only while the observer has listeners.
public struct MutateCallbacks<Variables, Data, Context> {
    var onSuccess: ((Data, Variables, Context?) -> Void)?
    var onError: ((any Error, Variables, Context?) -> Void)?
    var onSettled: ((Data?, (any Error)?, Variables, Context?) -> Void)?
}

/// Runs mutations and exposes the latest one's state.
@MainActor
public final class MutationObserver<Variables: Sendable, Data: Sendable, Context: Sendable> {
    public let client: QueryClient
    public private(set) var options: MutationOptions<Variables, Data, Context>
    private var currentMutation: Mutation<Variables, Data, Context>?
    private var callbacks: MutateCallbacks<Variables, Data, Context>?
    private let listeners = Listeners<MutationObserverResult<Variables, Data, Context>>()
    public private(set) var currentResult = MutationObserverResult<Variables, Data, Context>(state: .init())

    public init(client: QueryClient, options: MutationOptions<Variables, Data, Context>) {
        self.client = client
        self.options = options
        self.options.config = options.config.merged(over: client.defaultMutationConfiguration(for: options.mutationKey))
    }

    public var hasListeners: Bool { !listeners.isEmpty }

    public func setOptions(_ options: MutationOptions<Variables, Data, Context>) {
        let prevKey = self.options.mutationKey
        self.options = options
        self.options.config = options.config.merged(over: client.defaultMutationConfiguration(for: options.mutationKey))
        if let prevKey, let key = options.mutationKey, prevKey != key {
            reset()
        } else if let currentMutation, currentMutation.status == .pending {
            currentMutation.setOptions(self.options)
        }
    }

    public func subscribe(_ listener: @escaping @MainActor (MutationObserverResult<Variables, Data, Context>) -> Void) -> Subscription {
        let subscription = listeners.add(listener) { [weak self] in
            guard let self, listeners.isEmpty else { return }
            currentMutation?.removeObserver(self)
        }
        if listeners.count == 1, let currentMutation {
            currentMutation.addObserver(self)
            updateResult()
        }
        return subscription
    }

    public var results: AsyncStream<MutationObserverResult<Variables, Data, Context>> {
        let (stream, continuation) = AsyncStream.makeStream(of: MutationObserverResult<Variables, Data, Context>.self)
        var emitted = false
        let subscription = subscribe {
            emitted = true
            continuation.yield($0)
        }
        // Mounting may already have emitted (e.g. a fetch started); otherwise start from the current result.
        if !emitted { continuation.yield(currentResult) }
        continuation.onTermination = { _ in Task { @MainActor in subscription.cancel() } }
        return stream
    }

    /// Creates a new mutation and runs it.
    @discardableResult
    public func mutate(
        _ variables: Variables,
        onSuccess: ((Data, Variables, Context?) -> Void)? = nil,
        onError: ((any Error, Variables, Context?) -> Void)? = nil,
        onSettled: ((Data?, (any Error)?, Variables, Context?) -> Void)? = nil
    ) async throws -> Data {
        callbacks = MutateCallbacks(onSuccess: onSuccess, onError: onError, onSettled: onSettled)
        currentMutation?.removeObserver(self)
        let mutation = client.mutationCache.build(options)
        currentMutation = mutation
        mutation.addObserver(self)
        return try await mutation.execute(variables)
    }

    /// Detaches from the current mutation; the result returns to idle.
    public func reset() {
        currentMutation?.removeObserver(self)
        currentMutation = nil
        updateResult()
        notify(.other)
    }

    private func updateResult() {
        currentResult = MutationObserverResult(state: currentMutation?.state ?? .init())
    }

    private func notify(_ event: MutationEvent) {
        if let callbacks, hasListeners, let variables = currentResult.variables {
            let context = currentResult.context
            switch event {
            case .success:
                if let data = currentResult.data {
                    callbacks.onSuccess?(data, variables, context)
                    callbacks.onSettled?(data, nil, variables, context)
                }
            case .error:
                if let error = currentResult.error {
                    callbacks.onError?(error, variables, context)
                    callbacks.onSettled?(nil, error, variables, context)
                }
            case .other:
                break
            }
        }
        listeners.send(currentResult)
    }
}

extension MutationObserver: MutationObserving {
    func onMutationUpdate(_ event: MutationEvent) {
        updateResult()
        notify(event)
    }
}
