import Foundation

public enum MutationStatus: String, Sendable, Equatable, Codable {
    case idle
    case pending
    case success
    case error
}

/// Mutation tunables shared by options and client defaults. `nil` means "inherit".
public struct MutationConfiguration: Sendable {
    public var gcTime: GCTime?
    public var retry: RetryPolicy?
    public var retryDelay: RetryDelay?
    public var networkMode: NetworkMode?
    /// Mutations sharing a scope id run one at a time, in order.
    public var scope: String?
    public var meta: QueryMeta?

    public init(
        gcTime: GCTime? = nil, retry: RetryPolicy? = nil, retryDelay: RetryDelay? = nil,
        networkMode: NetworkMode? = nil, scope: String? = nil, meta: QueryMeta? = nil
    ) {
        self.gcTime = gcTime
        self.retry = retry
        self.retryDelay = retryDelay
        self.networkMode = networkMode
        self.scope = scope
        self.meta = meta
    }

    func merged(over base: MutationConfiguration) -> MutationConfiguration {
        MutationConfiguration(
            gcTime: gcTime ?? base.gcTime, retry: retry ?? base.retry, retryDelay: retryDelay ?? base.retryDelay,
            networkMode: networkMode ?? base.networkMode, scope: scope ?? base.scope, meta: meta ?? base.meta
        )
    }
}

/// Passed to mutation functions.
public struct MutationFunctionContext: Sendable {
    public let client: QueryClient
    public let meta: QueryMeta?
    public let mutationKey: QueryKey?
}

public typealias MutationFunction<Variables, Data> = @Sendable (Variables, MutationFunctionContext) async throws -> Data

public struct MissingMutationFunctionError: Error, Sendable {
    public let mutationKey: QueryKey?
}

public struct MutationOptions<Variables: Sendable, Data: Sendable, Context: Sendable> {
    public var mutationKey: QueryKey?
    /// Optional when `setMutationDefaults` registered one for `mutationKey`.
    public var mutationFn: MutationFunction<Variables, Data>?
    /// Runs before `mutationFn`; its return value is passed to the other callbacks as `context`.
    public var onMutate: (@MainActor (Variables) async throws -> Context?)?
    public var onSuccess: (@MainActor (Data, Variables, Context?) async -> Void)?
    public var onError: (@MainActor (any Error, Variables, Context?) async -> Void)?
    public var onSettled: (@MainActor (Data?, (any Error)?, Variables, Context?) async -> Void)?
    public var config: MutationConfiguration

    public init(
        mutationKey: QueryKey? = nil,
        gcTime: GCTime? = nil,
        retry: RetryPolicy? = nil,
        retryDelay: RetryDelay? = nil,
        networkMode: NetworkMode? = nil,
        scope: String? = nil,
        meta: QueryMeta? = nil,
        onMutate: (@MainActor (Variables) async throws -> Context?)? = nil,
        onSuccess: (@MainActor (Data, Variables, Context?) async -> Void)? = nil,
        onError: (@MainActor (any Error, Variables, Context?) async -> Void)? = nil,
        onSettled: (@MainActor (Data?, (any Error)?, Variables, Context?) async -> Void)? = nil,
        mutationFn: MutationFunction<Variables, Data>? = nil
    ) {
        self.mutationKey = mutationKey
        self.mutationFn = mutationFn
        self.onMutate = onMutate
        self.onSuccess = onSuccess
        self.onError = onError
        self.onSettled = onSettled
        self.config = MutationConfiguration(gcTime: gcTime, retry: retry, retryDelay: retryDelay, networkMode: networkMode, scope: scope, meta: meta)
    }

    /// For mutation functions that don't need the context.
    public init(
        mutationKey: QueryKey? = nil,
        gcTime: GCTime? = nil,
        retry: RetryPolicy? = nil,
        retryDelay: RetryDelay? = nil,
        networkMode: NetworkMode? = nil,
        scope: String? = nil,
        meta: QueryMeta? = nil,
        onMutate: (@MainActor (Variables) async throws -> Context?)? = nil,
        onSuccess: (@MainActor (Data, Variables, Context?) async -> Void)? = nil,
        onError: (@MainActor (any Error, Variables, Context?) async -> Void)? = nil,
        onSettled: (@MainActor (Data?, (any Error)?, Variables, Context?) async -> Void)? = nil,
        mutationFn: @escaping @Sendable (Variables) async throws -> Data
    ) {
        self.init(
            mutationKey: mutationKey, gcTime: gcTime, retry: retry, retryDelay: retryDelay, networkMode: networkMode,
            scope: scope, meta: meta, onMutate: onMutate, onSuccess: onSuccess, onError: onError, onSettled: onSettled,
            mutationFn: { variables, _ in try await mutationFn(variables) }
        )
    }

    /// Fills unset functions from `defaults` (TanStack: `{...mutationDefaults, ...options}`).
    func filled(from defaults: MutationOptions) -> MutationOptions {
        var merged = self
        merged.mutationFn = mutationFn ?? defaults.mutationFn
        merged.onMutate = onMutate ?? defaults.onMutate
        merged.onSuccess = onSuccess ?? defaults.onSuccess
        merged.onError = onError ?? defaults.onError
        merged.onSettled = onSettled ?? defaults.onSettled
        merged.config = config.merged(over: defaults.config)
        return merged
    }
}

public struct MutationState<Variables: Sendable, Data: Sendable, Context: Sendable>: Sendable {
    public var context: Context?
    public var data: Data?
    public var error: (any Error)?
    public var failureCount = 0
    public var failureReason: (any Error)?
    public var isPaused = false
    public var status: MutationStatus = .idle
    public var variables: Variables?
    public var submittedAt: Date?

    public init() {}
}

/// Type-erased mutation, for the mutation cache and filters.
@MainActor
public class AnyMutation: Removable {
    public let mutationId: Int
    weak var cache: MutationCache?
    var observerCount: Int { fatalError("abstract") }

    init(mutationId: Int, cache: MutationCache, environment: QueryEnvironment) {
        self.mutationId = mutationId
        self.cache = cache
        super.init(environment: environment)
    }

    public var mutationKey: QueryKey? { fatalError("abstract") }
    public var status: MutationStatus { fatalError("abstract") }
    public var isPaused: Bool { fatalError("abstract") }
    var scope: String? { fatalError("abstract") }
    func dehydrated() -> DehydratedMutation { fatalError("abstract") }
    /// The state with types erased (for `MutationCache` listings such as TanStack `useMutationState`).
    public var stateSnapshot: DehydratedMutationState { dehydrated().state }
    /// Resumes a paused mutation (or re-runs a restored pending one).
    func `continue`() async { fatalError("abstract") }

    override func optionalRemove() {
        guard observerCount == 0 else { return }
        if status == .pending { scheduleGc() } else { cache?.remove(self) }
    }
}

@MainActor
protocol MutationObserving: AnyObject {
    func onMutationUpdate(_ event: MutationEvent)
}

enum MutationEvent {
    case success
    case error
    case other
}

/// One execution of a mutation function and its state.
@MainActor
public final class Mutation<Variables: Sendable, Data: Sendable, Context: Sendable>: AnyMutation {
    public private(set) var options: MutationOptions<Variables, Data, Context>
    public private(set) var state = MutationState<Variables, Data, Context>()
    private var observers: [any MutationObserving] = []
    private var retryer: Retryer<Data>?

    init(
        options: MutationOptions<Variables, Data, Context>, mutationId: Int, cache: MutationCache,
        environment: QueryEnvironment, state: MutationState<Variables, Data, Context>? = nil
    ) {
        self.options = options
        if let state { self.state = state }
        super.init(mutationId: mutationId, cache: cache, environment: environment)
        updateGcTime(options.config.gcTime)
        scheduleGc()
    }

    override var observerCount: Int { observers.count }
    public override var mutationKey: QueryKey? { options.mutationKey }
    public override var status: MutationStatus { state.status }
    public override var isPaused: Bool { state.isPaused }
    override var scope: String? { options.config.scope }

    override func dehydrated() -> DehydratedMutation {
        DehydratedMutation(mutationKey: options.mutationKey, scope: options.config.scope, state: DehydratedMutationState(
            context: state.context, data: state.data, error: state.error, failureCount: state.failureCount,
            failureReason: state.failureReason, isPaused: state.isPaused, status: state.status,
            variables: state.variables, submittedAt: state.submittedAt
        ))
    }

    func setOptions(_ options: MutationOptions<Variables, Data, Context>) {
        self.options = options
        updateGcTime(options.config.gcTime)
    }

    func addObserver(_ observer: any MutationObserving) {
        guard !observers.contains(where: { $0 === observer }) else { return }
        observers.append(observer)
        clearGcTimer()
    }

    func removeObserver(_ observer: any MutationObserving) {
        observers.removeAll { $0 === observer }
        scheduleGc()
    }

    override func `continue`() async {
        if let retryer {
            _ = try? await retryer.continue().value
        } else if state.status == .pending, let variables = state.variables {
            _ = try? await execute(variables)
        }
    }

    /// The mutation's `meta` option.
    public var meta: QueryMeta? { options.config.meta }

    func execute(_ variables: Variables) async throws -> Data {
        let mutationFn = options.mutationFn
        guard let client = cache?.client else { preconditionFailure("Mutation is not in a client's cache") }
        let context = MutationFunctionContext(client: client, meta: options.config.meta, mutationKey: options.mutationKey)
        let mutationKey = options.mutationKey
        let retryer = Retryer<Data>(.init(
            run: {
                Task {
                    guard let mutationFn else { throw MissingMutationFunctionError(mutationKey: mutationKey) }
                    return try await mutationFn(variables, context)
                }
            },
            onFail: { [weak self] count, error in self?.dispatch(.failed(count, error)) },
            onPause: { [weak self] in self?.dispatch(.pause) },
            onContinue: { [weak self] in self?.dispatch(.continue) },
            retry: options.config.retry ?? .never,
            retryDelay: options.config.retryDelay ?? .exponential,
            networkMode: options.config.networkMode ?? .online,
            canRun: { [weak self] in self.map { $0.cache?.canRun($0) ?? true } ?? true },
            environment: environment
        ))
        self.retryer = retryer
        let restored = state.status == .pending
        let isPaused = !retryer.canStart()
        defer {
            if self.retryer === retryer { self.retryer = nil }
            cache?.runNext(self)
        }
        let cacheConfig = cache?.config ?? .init()

        do {
            if restored {
                dispatch(.continue)
            } else {
                dispatch(.pending(variables: variables, context: nil, isPaused: isPaused))
                await cacheConfig.onMutate?(variables, self)
                if let onMutate = options.onMutate {
                    let context = try await onMutate(variables)
                    dispatch(.pending(variables: variables, context: context, isPaused: isPaused))
                }
            }
            let data = try await retryer.start().value
            let context = state.context
            await cacheConfig.onSuccess?(data, variables, context, self)
            await options.onSuccess?(data, variables, context)
            await cacheConfig.onSettled?(data, nil, variables, context, self)
            await options.onSettled?(data, nil, variables, context)
            dispatch(.success(data))
            return data
        } catch {
            let context = state.context
            await cacheConfig.onError?(error, variables, context, self)
            await options.onError?(error, variables, context)
            await cacheConfig.onSettled?(nil, error, variables, context, self)
            await options.onSettled?(nil, error, variables, context)
            dispatch(.error(error))
            throw error
        }
    }

    private enum Action {
        case failed(Int, any Error)
        case pause
        case `continue`
        case pending(variables: Variables, context: Context?, isPaused: Bool)
        case success(Data)
        case error(any Error)
    }

    private func dispatch(_ action: Action) {
        var s = state
        var event = MutationEvent.other
        switch action {
        case .failed(let count, let error):
            s.failureCount = count
            s.failureReason = error
        case .pause:
            s.isPaused = true
        case .continue:
            s.isPaused = false
        case .pending(let variables, let context, let isPaused):
            s.context = context
            s.data = nil
            s.failureCount = 0
            s.failureReason = nil
            s.error = nil
            s.isPaused = isPaused
            s.status = .pending
            s.variables = variables
            s.submittedAt = environment.clock.now
        case .success(let data):
            s.data = data
            s.failureCount = 0
            s.failureReason = nil
            s.error = nil
            s.status = .success
            s.isPaused = false
            event = .success
        case .error(let error):
            s.data = nil
            s.error = error
            s.failureCount += 1
            s.failureReason = error
            s.isPaused = false
            s.status = .error
            event = .error
        }
        state = s
        for observer in observers { observer.onMutationUpdate(event) }
        cache?.notify(.updated(self))
    }
}
