// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import CoreFoundation
import Foundation

/// Backends are created, called, and destroyed on the one discovery thread.
/// The default backend is private; this value-only seam permits hardware-free tests.
public protocol HIDDiscoveryBackend: AnyObject {
    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) throws
    func snapshot() throws -> HIDDiscoverySnapshot
    func inspectInterface(registryEntryID: UInt64) throws -> HIDInspectionResult
    func stop()
}

public enum HIDDiscoveryError: Error, Sendable, Equatable, CustomStringConvertible {
    case stopped
    case missingInterface(UInt64)
    case unsafeEndpoint(String)

    public var description: String {
        switch self {
        case .stopped: "HID discovery has stopped."
        case .missingInterface(let id): "Interface \(id) is no longer present in this session."
        case .unsafeEndpoint(let reason): "Refused to open HID interface: \(reason)"
        }
    }
}

/// All HID objects and C callbacks stay on one long-lived Thread/CFRunLoop.
/// Only immutable Sendable values and AsyncStream continuations cross that boundary.
public final class HIDDiscovery: HIDDiscoveryService, HIDFeatureGroupTransport, Sendable {
    private let worker: HIDRunLoopWorker
    private let queryReservations = HIDQueryReservations()
    private let processLockFactory: @Sendable (PhysicalDeviceID) throws -> HIDProcessQueryLock?

    public convenience init() {
        self.init(backendFactory: { IOKitDiscoveryBackend() })
    }

    public convenience init(backendFactory: @escaping @Sendable () -> any HIDDiscoveryBackend) {
        self.init(backendFactory: backendFactory, processLockFactory: { try HIDProcessQueryLock(physicalDeviceID: $0) })
    }

    init(backendFactory: @escaping @Sendable () -> any HIDDiscoveryBackend, processLockFactory: @escaping @Sendable (PhysicalDeviceID) throws -> HIDProcessQueryLock?) {
        self.processLockFactory = processLockFactory
        worker = HIDRunLoopWorker(backendFactory: backendFactory)
    }

    deinit { worker.requestStop() }

    public func snapshot() async throws -> HIDDiscoverySnapshot {
        try await worker.perform { state in
            try state.startIfNeeded()
            return try state.backend!.snapshot()
        }
    }

    public func events() async throws -> AsyncStream<HIDDiscoveryEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HIDDiscoveryEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak worker] _ in worker?.removeObserver(id) }
        do {
            try await worker.perform { state in
                try state.startIfNeeded()
                state.observers[id] = continuation
                continuation.yield(HIDDiscoveryEvent(kind: .initial, snapshot: try state.backend!.snapshot()))
            }
        } catch {
            continuation.finish()
            throw error
        }
        return stream
    }

    /// Explicit session endpoint only. This never opens a manager or a generic device.
    public func inspectControlInterface(registryEntryID: UInt64) async throws -> HIDInspectionResult {
        try await worker.perform { state in
            try state.startIfNeeded()
            let snapshot = try state.backend!.snapshot()
            try Self.validateInspectionEndpoint(registryEntryID, in: snapshot)
            return try state.backend!.inspectInterface(registryEntryID: registryEntryID)
        }
    }

    public func stop() async { await worker.stop() }

    /// Explicit validation workflows bind to a currently present, exact endpoint.
    /// Minting this value sends no reports and does not open an HID device.
    public func bindFeatureSession(physicalDeviceID: PhysicalDeviceID, registryEntryID: UInt64, profile: HIDFeatureProfile) async throws -> HIDFeatureSessionBinding {
        try await worker.perform { state in
            try state.startIfNeeded()
            let snapshot = try state.backend!.snapshot()
            try Self.validateInspectionEndpoint(registryEntryID, in: snapshot)
            guard let device = snapshot.devices.first(where: { $0.id == physicalDeviceID && $0.interfaces.contains { $0.registryEntryID == registryEntryID } }) else {
                throw HIDDiscoveryError.unsafeEndpoint("cannot bind a feature session to a different physical device")
            }
            let binding = HIDFeatureSessionBinding(id: UUID(), physicalDeviceID: physicalDeviceID, registryEntryID: registryEntryID, profile: profile)
            state.featureSessions[binding.id] = (binding, device.interfaces)
            return binding
        }
    }

    /// Holds one physical reservation and process flock across adaptive
    /// read -> construct -> write -> readback work. The body must not suspend.
    public func withFeatureTransaction<T: Sendable>(session: HIDFeatureSessionBinding, body: @escaping @Sendable (HIDFeatureTransaction) throws -> T) async throws -> T {
        guard queryReservations.acquire(session.physicalDeviceID) else { throw TelemetryFailure(category: .busy, message: "A transaction is already queued or in flight for this physical device.", operation: "transactionReservation", endpointRegistryEntryID: session.registryEntryID) }
        defer { queryReservations.release(session.physicalDeviceID) }
        let cancellation = HIDQueryCancellation()
        return try await withTaskCancellationHandler {
            try await worker.perform { state in
                try state.startIfNeeded()
                guard !cancellation.isCancelled else { throw CancellationError() }
                let snapshot = try state.backend!.snapshot()
                try Self.validateInspectionEndpoint(session.registryEntryID, in: snapshot)
                guard let bound = state.featureSessions[session.id], bound.0 == session,
                      snapshot.devices.contains(where: { $0.id == session.physicalDeviceID && $0.interfaces == bound.1 }) else {
                    throw HIDDiscoveryError.unsafeEndpoint("feature transaction session expired")
                }
                guard let backend = state.backend as? any HIDSynchronousReportBackend else { throw TelemetryFailure(category: .unsupported, message: "This backend has no Feature transport.") }
                let processLock = try self.processLockFactory(session.physicalDeviceID)
                return try withExtendedLifetime(processLock) {
                    let transaction = HIDFeatureTransaction(session: session, backend: backend, cancellation: cancellation) { id in
                        guard state.consumedWriteIntents.insert(id).inserted else { throw HIDDiscoveryError.unsafeEndpoint("this write intent was already attempted") }
                    }
                    defer { transaction.finish() }
                    return try body(transaction)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    public func queryGroup(_ group: HIDFeatureQueryGroup, validate: @escaping @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation) async throws -> HIDFeatureGroupResult {
        try HIDFeatureQueryRunner.validateAllowlist(group)
        if case .userInitiatedWrite(let intent) = group.intent, case .setDPIStages = intent.operation {
            throw HIDDiscoveryError.unsafeEndpoint("stage edits require a scoped transaction with its own complete read image and confirmed hardware evidence")
        }
        if group.priorDPIResponse != nil || group.requests.contains(where: { if case .setDPI = $0.operation { true } else { false } }) {
            throw HIDDiscoveryError.unsafeEndpoint("DPI edits require a scoped transaction with its own complete source read")
        }
        guard queryReservations.acquire(group.physicalDeviceID) else {
            throw TelemetryFailure(category: .busy, message: "A complete query group is already queued or in flight for this physical device.", operation: "groupReservation", endpointRegistryEntryID: group.registryEntryID)
        }
        defer { queryReservations.release(group.physicalDeviceID) }
        let cancellation = HIDQueryCancellation()
        return try await withTaskCancellationHandler {
            try await worker.perform { state in
                try state.startIfNeeded()
                guard !cancellation.isCancelled else { throw CancellationError() }
                let snapshot = try state.backend!.snapshot()
                try Self.validateInspectionEndpoint(group.registryEntryID, in: snapshot)
                guard snapshot.devices.contains(where: { $0.id == group.physicalDeviceID && $0.interfaces.contains { $0.registryEntryID == group.registryEntryID } }) else {
                    throw HIDDiscoveryError.unsafeEndpoint("the requested endpoint no longer belongs to this physical session")
                }
                if let binding = group.session {
                    guard let bound = state.featureSessions[binding.id], bound.0 == binding,
                          snapshot.devices.contains(where: { $0.id == binding.physicalDeviceID && $0.interfaces == bound.1 }) else {
                        throw HIDDiscoveryError.unsafeEndpoint("feature session expired after a topology change or belongs to a different discovery instance")
                    }
                }
                guard let backend = state.backend as? any HIDSynchronousReportBackend else {
                    throw TelemetryFailure(category: .unsupported, message: "This discovery backend has no report transport.")
                }
                let processLock = try self.processLockFactory(group.physicalDeviceID)
                if case .userInitiatedWrite(let intent) = group.intent {
                    guard state.consumedWriteIntents.insert(intent.id).inserted else {
                        throw HIDDiscoveryError.unsafeEndpoint("this write intent was already attempted; read actual state before a new user action")
                    }
                }
                return try withExtendedLifetime(processLock) {
                    try HIDFeatureQueryRunner.run(group, backend: backend, clock: SystemHIDQueryClock(), cancellation: cancellation, validate: validate)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Defense at the actual access boundary, independent of the CLI/driver selector.
    private static func validateInspectionEndpoint(_ id: UInt64, in snapshot: HIDDiscoverySnapshot) throws {
        guard let group = snapshot.devices.first(where: { $0.interfaces.contains { $0.registryEntryID == id } }) else {
            throw HIDDiscoveryError.missingInterface(id)
        }
        guard group.isExternalUSB, group.interfaces.allSatisfy({ $0.vendorID == 0x1532 && $0.productID == 0x00C5 }), group.allUsages.contains(.mouse) else {
            throw HIDDiscoveryError.unsafeEndpoint("only the external USB 1532:00C5 physical mouse is authorized")
        }
        let candidates = group.interfaces.filter { descriptor in
            guard descriptor.allUsages.contains(.mouse), descriptor.maxFeatureReportSize == 90,
                  let summary = descriptor.descriptorSummary else { return false }
            return summary.explicitReportIDs.isEmpty && summary.hasReport(kind: .feature, reportID: 0, byteCount: 90)
        }
        guard candidates.count == 1, candidates[0].registryEntryID == id else {
            throw HIDDiscoveryError.unsafeEndpoint("requires exactly one mouse interface with a real 90-byte Feature report, Report ID 0, and no explicit report IDs")
        }
    }
}

/// The unchecked boundary covers the run-loop reference and queue, guarded by condition.
/// Backend/state access occurs exclusively inside blocks executed by the worker thread.
private final class HIDRunLoopWorker: @unchecked Sendable {
    private let condition = NSCondition()
    private var runLoop: CFRunLoop?
    private var stopping = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var thread: Thread?
    private let state: HIDWorkerState

    init(backendFactory: @escaping @Sendable () -> any HIDDiscoveryBackend) {
        state = HIDWorkerState(factory: backendFactory)
        let thread = Thread { [weak self] in
            guard let self else { return }
            autoreleasepool { self.run() }
        }
        thread.name = "Bazer HID discovery"
        self.thread = thread
        thread.start()
        condition.lock()
        while runLoop == nil { condition.wait() }
        condition.unlock()
    }

    private func run() {
        let loop = CFRunLoopGetCurrent()!
        var context = CFRunLoopSourceContext()
        let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
        CFRunLoopAddSource(loop, source, .defaultMode)
        condition.lock()
        runLoop = loop
        condition.broadcast()
        condition.unlock()
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, .defaultMode)
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (HIDWorkerState) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue({ state in
                do { continuation.resume(returning: try operation(state)) }
                catch { continuation.resume(throwing: error) }
            }, rejected: { continuation.resume(throwing: HIDDiscoveryError.stopped) })
        }
    }

    private func enqueue(_ block: @escaping @Sendable (HIDWorkerState) -> Void, rejected: @Sendable () -> Void = {}) {
        condition.lock()
        guard !stopping, let loop = runLoop else {
            condition.unlock()
            rejected()
            return
        }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in block(state) }
        CFRunLoopWakeUp(loop)
        condition.unlock()
    }

    func removeObserver(_ id: UUID) { enqueue { $0.observers.removeValue(forKey: id) } }

    func requestStop() { scheduleStop(completion: nil) }

    func stop() async {
        await withCheckedContinuation { continuation in scheduleStop(completion: continuation) }
    }

    private func scheduleStop(completion: CheckedContinuation<Void, Never>?) {
        condition.lock()
        guard !stopped, let loop = runLoop else {
            condition.unlock()
            completion?.resume()
            return
        }
        if let completion { stopWaiters.append(completion) }
        guard !stopping else { condition.unlock(); return }
        stopping = true
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            state.backend?.stop()
            state.backend = nil
            for observer in state.observers.values { observer.finish() }
            state.observers.removeAll()
            CFRunLoopStop(loop)
            condition.lock()
            stopped = true
            let waiters = stopWaiters
            stopWaiters.removeAll()
            condition.unlock()
            for waiter in waiters { waiter.resume() }
        }
        CFRunLoopWakeUp(loop)
        condition.unlock()
    }
}

private final class HIDWorkerState {
    let factory: @Sendable () -> any HIDDiscoveryBackend
    var backend: (any HIDDiscoveryBackend)?
    var observers: [UUID: AsyncStream<HIDDiscoveryEvent>.Continuation] = [:]
    var featureSessions: [UUID: (HIDFeatureSessionBinding, [HIDInterfaceDescriptor])] = [:]
    var consumedWriteIntents: Set<UUID> = []

    init(factory: @escaping @Sendable () -> any HIDDiscoveryBackend) { self.factory = factory }

    func startIfNeeded() throws {
        guard backend == nil else { return }
        let created = factory()
        do {
            try created.start { [weak self] event in
                guard let self else { return }
                // Even a remove/reinsert with the same numeric Registry ID must
                // not inherit a setting intent from the previous connection.
                self.featureSessions.removeAll()
                self.consumedWriteIntents.removeAll()
                for observer in self.observers.values { observer.yield(event) }
            }
            backend = created
        } catch {
            created.stop()
            throw error
        }
    }
}
