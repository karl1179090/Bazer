// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import Foundation

public protocol BatteryMonitorDiscovery: HIDDiscoveryService {
    func events() async throws -> AsyncStream<HIDDiscoveryEvent>
    func stop() async
}
extension HIDDiscovery: BatteryMonitorDiscovery {}

public enum DeviceIdentifier {
    public static func identify(_ device: PhysicalDeviceDescriptor) -> IdentifiedDevice? { DriverRegistry.identification.identify(device) }
}

/// Owns all mutable monitoring state. No HID objects or UI objects cross this actor.
public actor BatteryMonitor {
    private let discovery: any BatteryMonitorDiscovery
    private let reader: any DeviceTelemetryReading
    private let registry: DriverRegistry?
    private let clock: any MonitorClock
    private let persistence: any DevicePreferencesPersisting
    private let policy: RefreshPolicy
    private let automaticallyRefreshTelemetry: Bool
    private var store: DeviceStore
    private var logicalDiscoveryTasks: [PhysicalDeviceID: Task<Void, Never>] = [:]
    private var logicalEventTasks: [String: Task<Void, Never>] = [:]
    private var pendingLogicalRediscovery: Set<DeviceSessionID> = []
    private var logicalReadTasks: [LogicalDeviceID: Task<Void, Never>] = [:]
    private var logicalNextRefresh: [LogicalDeviceID: Date] = [:]
    private var logicalFailureCounts: [LogicalDeviceID: Int] = [:]
    private var logicalLifecycleTasks: [UUID: Task<Void, Never>] = [:]
    private var coordinator = RefreshCoordinator()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var eventTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var discoveryRefreshTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var pendingAdded: Set<DeviceSessionID> = []
    private var observers: [UUID: AsyncStream<DeviceStoreSnapshot>.Continuation] = [:]
    private var runID = UUID()
    private var epoch = UUID()
    private var timerID = UUID()
    private var batchID = UUID()
    private var wakeID = UUID()
    private var isMonitoring = false
    private var isSuspended = false
    private var stopped = false
    private var recovery = MonitorRecoveryScheduling()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTimerID = UUID()
    private var recoveryIsRunning = false
    private var activeRecoveryTask: Task<Void, Never>?
    private var eventSubscriptionID: UUID?
    private var eventStreamID = UUID()
    private var wakeRequested = false
    private var wakeAttemptID: UUID?
    private var wakeAttemptTask: Task<Void, Never>?
    private var discoveryFailure: String? { [recovery.failureDescription, fullDiscoveryFailure].compactMap { $0 }.joined(separator: "\n").nilIfEmpty }
    private var preferencesFailure: String?
    private var fullRefreshTask: Task<Void, Never>?
    private var fullRefreshID: UUID?
    private var fullRefreshEpoch: UUID?
    private var fullRefreshDrains: [UUID: Task<Void, Never>] = [:]
    private var fullRefreshPending = false
    private var fullRefreshNeedsAllTelemetry = false
    private var lastFullDiscoveryAt: Date?
    private var fullDiscoveryFailure: String?
    private var receivedInitialDiscovery = false
    private var initialDiscoveryWaiters: [CheckedContinuation<DeviceStoreSnapshot, Never>] = []

    public init(discovery: any BatteryMonitorDiscovery, reader: any DeviceTelemetryReading,
                clock: any MonitorClock = SystemMonitorClock(),
                preferences: any DevicePreferencesPersisting = FileDevicePreferences(),
                policy: RefreshPolicy = RefreshPolicy(), registry: DriverRegistry? = nil, automaticallyRefreshTelemetry: Bool = true) {
        self.discovery = discovery; self.reader = reader; self.clock = clock; self.registry = registry
        persistence = preferences; self.policy = policy; self.automaticallyRefreshTelemetry = automaticallyRefreshTelemetry
        do { store = DeviceStore(preferences: try preferences.load()) }
        catch { store = DeviceStore(); preferencesFailure = String(describing: error) }
    }
    public static func live() -> BatteryMonitor {
        let discovery = HIDDiscovery()
        let registry = DriverRegistry.live(transport: discovery)
        return BatteryMonitor(discovery: discovery, reader: registry, registry: registry)
    }

    public func snapshot() -> DeviceStoreSnapshot {
        DeviceStoreSnapshot(capturedAt: clock.now, devices: store.devices.values.sorted { $0.id < $1.id },
            primaryDeviceID: store.primaryDeviceID, isMonitoring: isMonitoring, isSuspended: isSuspended,
            discoveryFailure: discoveryFailure, preferencesFailure: preferencesFailure,
            logicalDevices: store.logicalDevices.values.sorted { $0.id < $1.id }, primaryLogicalDeviceID: store.primaryLogicalDeviceID,
            preferences: store.preferences, historicalDevices: store.historicalDevices, historicalLogicalDevices: store.historicalLogicalDevices)
    }
    public func snapshots() -> AsyncStream<DeviceStoreSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DeviceStoreSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !stopped else { continuation.yield(snapshot()); continuation.finish(); return stream }
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(snapshot()); return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() {
        let value = snapshot()
        for observer in observers.values { observer.yield(value) }
    }

    public func start() async {
        guard !isMonitoring, !stopped else { return }
        isMonitoring = true; runID = UUID(); epoch = UUID()
        let run = runID
        publish()
        for registration in registry?.registrations ?? [] {
            guard let driver = registration.logicalDriver else { continue }
            logicalEventTasks[registration.id] = Task { [weak self] in
                let events = await driver.discoveryEvents()
                for await session in events {
                    guard !Task.isCancelled else { break }
                    await self?.receiveLogicalDiscoveryEvent(session, run: run)
                }
            }
        }
        await subscribeToDiscovery(run: run)
    }
    private func subscribeToDiscovery(run: UUID) async {
        guard isMonitoring, !isSuspended, run == runID, eventTask == nil, eventSubscriptionID == nil else { return }
        let attempt = UUID(), expected = epoch
        eventSubscriptionID = attempt
        do {
            let stream = try await discovery.events()
            eventSubscriptionID = nil
            guard isMonitoring, !isSuspended, run == runID, expected == epoch else {
                if isMonitoring, !isSuspended { scheduleRecovery(.eventSubscription, message: "Discovery subscription was interrupted by a lifecycle change.") }
                return
            }
            recovery.succeed(.eventSubscription)
            eventStreamID = UUID(); let streamID = eventStreamID
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.receive(event.snapshot, run: run)
                }
                await self?.discoveryStreamEnded(run: run, streamID: streamID)
            }
            publish(); rescheduleRecovery()
        } catch {
            eventSubscriptionID = nil
            guard isMonitoring, run == runID else { return }
            guard expected == epoch else {
                // Wake may already have skipped subscription while this older
                // uncancellable attempt owned the slot. Requeue for the live epoch.
                if !isSuspended { scheduleRecovery(.eventSubscription, message: "Discovery subscription was interrupted by a lifecycle change.") }
                return
            }
            scheduleRecovery(.eventSubscription, message: String(describing: error)); publish(); finishInitialDiscoveryIfReady()
        }
    }
    private func discoveryStreamEnded(run: UUID, streamID: UUID) {
        guard isMonitoring, run == runID, streamID == eventStreamID else { return }
        eventTask = nil
        scheduleRecovery(.eventSubscription, message: "Discovery event stream ended; waiting to reconnect.")
        publish(); finishInitialDiscoveryIfReady()
    }

    private func receive(_ snapshot: HIDDiscoverySnapshot, run: UUID) {
        guard isMonitoring, run == runID else { return }
        receivedInitialDiscovery = true
        let identified = snapshot.devices.compactMap { registry?.identify($0) ?? (registry == nil ? DeviceIdentifier.identify($0) : nil) }
        let previousHosts = store.devices
        let changes = store.reconcile(identified, at: clock.now)
        for session in changes.invalidated {
            recovery.succeed(.logicalDiscovery(session)); pendingLogicalRediscovery.remove(session)
            logicalDiscoveryTasks[session.physicalDeviceID]?.cancel()
            for child in store.logicalDevices.values where child.sessionID.address.hostSessionID == session {
                logicalReadTasks[child.id]?.cancel(); logicalNextRefresh.removeValue(forKey: child.id)
                logicalFailureCounts.removeValue(forKey: child.id)
            }
            if let previous = previousHosts[session.physicalDeviceID] { invalidateLogicalHost(session, device: previous.descriptor) }
        }
        if !isSuspended {
            for device in identified where device.isReceiver {
                if let state = store.devices[device.descriptor.id] {
                    let children = store.logicalDevices.values.filter { $0.descriptor.address.hostSessionID == state.sessionID && $0.hostPresence == .present }
                    // A stable host snapshot is not a reason to rotate working logical sessions.
                    if changes.added.contains(state.sessionID) || children.isEmpty { requestLogicalDiscovery(state) }
                }
            }
        }
        for session in changes.invalidated {
            coordinator.invalidate(session); pendingAdded.remove(session)
            for request in coordinator.requests where request.session == session { tasks[request.id]?.cancel() }
        }
        if !isSuspended && automaticallyRefreshTelemetry {
            pendingAdded.formUnion(changes.added.filter { store.devices[$0.physicalDeviceID]?.canRefresh == true })
            scheduleAddedBatch()
        }
        publish(); rescheduleTimer(); rescheduleRecovery(); finishInitialDiscoveryIfReady()
    }

    private func scheduleAddedBatch() {
        guard !pendingAdded.isEmpty, discoveryRefreshTask == nil else { return }
        batchID = UUID(); let batch = batchID; let currentEpoch = epoch; let clock = clock
        let delay = policy.discoveryCoalescingDelay
        discoveryRefreshTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.flushAdded(batch: batch, epoch: currentEpoch)
        }
    }
    private func flushAdded(batch: UUID, epoch expected: UUID) {
        guard batch == batchID, expected == epoch, isMonitoring, !isSuspended else { return }
        discoveryRefreshTask = nil
        let sessions = pendingAdded; pendingAdded.removeAll()
        for session in sessions { _ = requestRefresh(session) }
        publish(); rescheduleTimer()
    }

    /// All calls join an already active request for that physical device.
    /// Cancellation is cooperative; a synchronous C report still has to return.
    public func refresh(deviceID: PhysicalDeviceID? = nil) async {
        guard isMonitoring, !isSuspended else { return }
        let sessions = store.devices.values.filter { $0.canRefresh && (deviceID == nil || $0.id == deviceID) }.map(\.sessionID)
        let work = sessions.compactMap { requestRefresh($0) }
        let logical = store.logicalDevices.values.filter { child in
            let hostID = child.descriptor.address.hostSessionID.physicalDeviceID
            return child.canRefreshTelemetry && (deviceID == nil || hostID == deviceID)
                && store.devices[hostID].flatMap({ registry?.logicalDriver(for: $0.descriptor) }) != nil
        }.compactMap { requestLogicalRefresh($0.sessionID) }
        publish(); rescheduleTimer()
        for task in work + logical { await task.value }
    }
    /// Full read-only reconciliation. One in-flight pass and at most one queued follow-up.
    /// Discovery-created automatic reads are joined by refresh(), never duplicated.
    public func refreshAllDeviceInformation(onlyDueTelemetry: Bool = false) async {
        guard isMonitoring, !isSuspended else { return }
        if let active = fullRefreshTask, fullRefreshEpoch == epoch {
            fullRefreshPending = true
            if !onlyDueTelemetry { fullRefreshNeedsAllTelemetry = true }
            await active.value
            return
        }
        let expected = epoch, run = runID, refreshID = UUID()
        fullRefreshID = refreshID; fullRefreshEpoch = expected
        let hadOlderRead = !onlyDueTelemetry && (!tasks.isEmpty || !logicalReadTasks.isEmpty || !logicalDiscoveryTasks.isEmpty)
        fullRefreshPending = hadOlderRead; fullRefreshNeedsAllTelemetry = !onlyDueTelemetry
        let work = Task<Void, Never> { [weak self] in
            await self?.performFullRefresh(run: run, epoch: expected, onlyDueTelemetry: onlyDueTelemetry)
            await self?.finishFullRefresh(refreshID)
        }
        fullRefreshTask = work; fullRefreshDrains[refreshID] = work
        await work.value
    }
    private func finishFullRefresh(_ id: UUID) {
        fullRefreshDrains.removeValue(forKey: id)
        if fullRefreshID == id { fullRefreshTask = nil; fullRefreshID = nil; fullRefreshEpoch = nil }
    }
    private func performFullRefresh(run: UUID, epoch expected: UUID, onlyDueTelemetry: Bool) async {
        for pass in 0...1 {
            guard isMonitoring, !isSuspended, run == runID, expected == epoch, !Task.isCancelled else { return }
            do {
                let found = try await discovery.snapshot()
                guard isMonitoring, !isSuspended, run == runID, expected == epoch else { return }
                fullDiscoveryFailure = nil; lastFullDiscoveryAt = clock.now
                receive(found, run: run)
                // Retry missing/incomplete children only. Healthy sessions and settings drafts survive.
                for host in store.devices.values where host.hostPresence == .present && host.managesLogicalTargets {
                    let children = store.logicalDevices.values.filter { $0.descriptor.address.hostSessionID == host.sessionID && $0.hostPresence == .present }
                    if children.isEmpty || children.contains(where: { $0.capabilities.operations.values.contains { $0.evidence == .unknown && $0.failureReason != nil } && $0.peerPresence != .unreachable }) { requestLogicalDiscovery(host) }
                }
                for task in Array(logicalDiscoveryTasks.values) { await task.value }
                guard isMonitoring, !isSuspended, expected == epoch else { return }
                // Consume the discovery batch now so its timer cannot issue a second read later.
                discoveryRefreshTask?.cancel(); discoveryRefreshTask = nil
                let added = pendingAdded; pendingAdded.removeAll()
                for session in added { _ = requestRefresh(session) }
                if onlyDueTelemetry && !fullRefreshNeedsAllTelemetry { await refreshDueTelemetry() } else { await refresh() }
            } catch {
                guard isMonitoring, !isSuspended, expected == epoch else { return }
                fullDiscoveryFailure = String(describing: error)
                // Failure leaves presence untouched, but existing telemetry can still refresh.
                if onlyDueTelemetry && !fullRefreshNeedsAllTelemetry { await refreshDueTelemetry() } else { await refresh() }
            }
            publish()
            guard pass == 0, fullRefreshPending else { break }
            fullRefreshPending = false
        }
        fullRefreshPending = false
    }

    private func refreshDueTelemetry() async {
        let now = clock.now
        let physical = store.devices.values.filter { $0.canRefreshTelemetry && ($0.nextRefreshAt.map { $0 <= now } ?? false) }.map(\.sessionID)
        let logical = store.logicalDevices.values.filter { logicalNextRefresh[$0.id].map { $0 <= now } ?? false }.map(\.sessionID)
        let work = physical.compactMap { requestRefresh($0) } + logical.compactMap { requestLogicalRefresh($0) }
        publish(); rescheduleTimer()
        for task in work { await task.value }
    }

    private func requestRefresh(_ session: DeviceSessionID) -> Task<Void, Never>? {
        guard isMonitoring, !isSuspended, store.isCurrent(session), let state = store.devices[session.physicalDeviceID], state.canRefresh else { return nil }
        pendingAdded.remove(session)
        let reservation = coordinator.request(session, epoch: epoch)
        guard reservation.isNew else { return tasks[reservation.request.id] }
        guard store.begin(session, at: clock.now) else { _ = coordinator.finish(reservation.request); return nil }
        let request = reservation.request, device = state.descriptor, reader = reader
        let task = Task { [weak self] in
            let result = await reader.read(device: device)
            await self?.complete(result, request: request)
        }
        tasks[request.id] = task; return task
    }
    private func complete(_ result: DeviceTelemetryResult, request: RefreshRequest) {
        let pending = coordinator.finish(request)
        tasks.removeValue(forKey: request.id)
        if isMonitoring, !isSuspended, request.epoch == epoch, store.isCurrent(request.session) {
            let state = store.devices[request.session.physicalDeviceID]
            let validTarget = result.physicalDeviceID == request.session.physicalDeviceID
                && result.endpointRegistryEntryID == state?.controlEndpointRegistryEntryID
            let update: DeviceTelemetryUpdate
            if validTarget {
                update = DeviceTelemetryUpdate(startedAt: result.startedAt, finishedAt: result.finishedAt,
                    battery: result.battery, batteryFailure: result.batteryFailure,
                    charging: result.charging, chargingFailure: result.chargingFailure)
            } else {
                let failure = TelemetryFailure(category: .transport, message: "Discarded telemetry for a different physical device or endpoint.")
                update = DeviceTelemetryUpdate(startedAt: state?.lastAttemptedAt ?? clock.now, finishedAt: clock.now,
                    battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure)
            }
            _ = store.apply(update, to: request.session, policy: policy)
        }
        if let pending { _ = requestRefresh(pending) }
        publish(); rescheduleTimer()
    }

    private func rescheduleTimer() {
        timerTask?.cancel(); timerTask = nil; timerID = UUID()
        guard isMonitoring, !isSuspended, automaticallyRefreshTelemetry else { return }
        let now = clock.now
        var dates: [Date] = [(lastFullDiscoveryAt ?? now).addingTimeInterval(policy.regularInterval)]
        for state in store.devices.values where state.hostPresence == .present {
            // Added endpoints are coalesced by the discovery batch instead.
            if let due = state.nextRefreshAt, !pendingAdded.contains(state.sessionID),
               !coordinator.hasActive(physicalDeviceID: state.id) { dates.append(due) }
            if let sample = state.battery {
                let expiry = sample.receivedAt.addingTimeInterval(policy.maximumSampleAge)
                if expiry > now { dates.append(expiry) }
            }
            if let sample = state.charging {
                let expiry = sample.receivedAt.addingTimeInterval(policy.maximumSampleAge)
                if expiry > now { dates.append(expiry) }
            }
        }
        for child in store.logicalDevices.values where child.hostPresence == .present {
            if let due = logicalNextRefresh[child.id], logicalReadTasks[child.id] == nil { dates.append(due) }
            if let battery = child.battery {
                let expiry = battery.receivedAt.addingTimeInterval(policy.maximumSampleAge)
                if expiry > now { dates.append(expiry) }
            }
        }
        guard let next = dates.min() else { return }
        let id = timerID, expected = epoch, clock = clock
        timerTask = Task { [weak self] in
            do { try await clock.sleep(for: max(0, next.timeIntervalSince(clock.now))) } catch { return }
            await self?.tick(id: id, epoch: expected)
        }
    }
    private func tick(id: UUID, epoch expected: UUID) {
        guard id == timerID, expected == epoch, isMonitoring, !isSuspended else { return }
        timerTask = nil
        let now = clock.now
        if lastFullDiscoveryAt.map({ now.timeIntervalSince($0) >= policy.regularInterval }) ?? true {
            lastFullDiscoveryAt = now
            Task { await self.refreshAllDeviceInformation(onlyDueTelemetry: true) }
            publish(); rescheduleTimer(); return
        }
        let due = store.devices.values.filter {
            $0.canRefresh && !$0.isRefreshing && !coordinator.hasActive(physicalDeviceID: $0.id)
                && ($0.nextRefreshAt.map { $0 <= now } ?? false)
        }.map(\.sessionID)
        for session in due { _ = requestRefresh(session) }
        let logicalDue = logicalNextRefresh.filter { $0.value <= now }.map(\.key)
        for id in logicalDue {
            if let child = store.logicalDevices[id] { _ = requestLogicalRefresh(child.sessionID) }
            else { logicalNextRefresh.removeValue(forKey: id) }
        }
        publish(); rescheduleTimer()
    }

    public func setAlias(_ alias: String?, for deviceID: PhysicalDeviceID) {
        store.setAlias(alias, for: deviceID); persistPreferences(); publish()
    }
    public func setPrimary(_ deviceID: PhysicalDeviceID?) {
        store.setPrimary(deviceID); persistPreferences(); publish()
    }
    public func setPrimaryIdentity(_ key: String?) {
        store.setPrimaryIdentity(key); persistPreferences(); publish()
    }
    public func setAliasIdentity(_ alias: String?, identityKey: String) {
        store.setAliasIdentity(alias, identityKey: identityKey); persistPreferences(); publish()
    }
    private func persistPreferences() {
        do { try persistence.save(store.preferences); preferencesFailure = nil }
        catch { preferencesFailure = String(describing: error) }
    }

    public func suspend() {
        guard isMonitoring else { return }
        isSuspended = true; epoch = UUID(); wakeID = UUID(); wakeRequested = false
        wakeTask?.cancel(); wakeTask = nil
        wakeAttemptTask?.cancel()
        cancelRecovery(); recovery.removeAll(); pendingLogicalRediscovery.removeAll()
        fullRefreshPending = false; fullRefreshTask?.cancel()
        cancelScheduling(); coordinator.clearPending(); store.pause()
        for task in tasks.values { task.cancel() }
        for task in logicalReadTasks.values { task.cancel() }
        for task in logicalDiscoveryTasks.values { task.cancel() }
        for state in store.devices.values where state.hostPresence == .present { invalidateLogicalHost(state.sessionID, device: state.descriptor) }
        logicalNextRefresh.removeAll()
        publish()
    }
    public func wake() {
        guard isMonitoring, isSuspended, !wakeRequested else { return }
        wakeRequested = true
        wakeID = UUID(); let id = wakeID, run = runID, expected = epoch, clock = clock
        let delay = policy.wakeDelay
        wakeTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.finishWake(id: id, run: run, epoch: expected)
        }
    }
    private func finishWake(id: UUID, run: UUID, epoch expected: UUID) async {
        guard id == wakeID, run == runID, expected == epoch, isMonitoring, isSuspended else { return }
        // A cancelled native enumeration still owns its slot until it returns.
        guard wakeAttemptID == nil else { wakeTask = nil; return }
        wakeAttemptTask = wakeTask; wakeTask = nil
        wakeAttemptID = UUID()
        do {
            let value = try await discovery.snapshot()
            wakeAttemptID = nil; wakeAttemptTask = nil
            guard id == wakeID, run == runID, expected == epoch, isMonitoring else { retryInterruptedWakeIfNeeded(); return }
            recovery.succeed(.wake)
            receive(value, run: run)
            isSuspended = false; wakeRequested = false
            let sessions = store.devices.values.filter(\.canRefresh).map(\.sessionID)
            if automaticallyRefreshTelemetry { for session in sessions { _ = requestRefresh(session) } }
            for state in store.devices.values {
                if registry?.logicalDriver(for: state.descriptor) != nil { requestLogicalDiscovery(state) }
            }
            if eventTask == nil { await subscribeToDiscovery(run: run) }
            publish(); rescheduleTimer(); rescheduleRecovery()
        } catch {
            wakeAttemptID = nil; wakeAttemptTask = nil
            guard id == wakeID, run == runID, expected == epoch, isMonitoring else { retryInterruptedWakeIfNeeded(); return }
            scheduleRecovery(.wake, message: String(describing: error))
            // Keep scheduling paused until a successful re-enumeration.
            publish()
        }
    }
    private func retryInterruptedWakeIfNeeded() {
        if isMonitoring, isSuspended, wakeRequested { scheduleRecovery(.wake, message: "Waiting for a fresh wake enumeration.") }
    }
    private func scheduleRecovery(_ key: MonitorRecoveryScheduling.Key, message: String) {
        recovery.fail(key, message: message, at: clock.now, policy: policy, retry: automaticallyRefreshTelemetry)
        rescheduleRecovery()
    }
    private func cancelRecovery() {
        recoveryTimerID = UUID(); recoveryTask?.cancel(); activeRecoveryTask?.cancel(); recoveryTask = nil
    }
    private func rescheduleRecovery() {
        guard !recoveryIsRunning else { return }
        cancelRecovery()
        guard isMonitoring, automaticallyRefreshTelemetry, let next = recovery.nextDate else { return }
        // A new sleep pauses every retry. Only an explicitly requested wake may
        // retry enumeration while telemetry remains suspended.
        guard !isSuspended || wakeRequested else { return }
        let id = recoveryTimerID, run = runID, expected = epoch, clock = clock
        recoveryTask = Task { [weak self] in
            do { try await clock.sleep(for: max(0, next.timeIntervalSince(clock.now))) } catch { return }
            await self?.retryRecovery(id: id, run: run, epoch: expected)
        }
    }
    private func retryRecovery(id: UUID, run: UUID, epoch expected: UUID) async {
        guard id == recoveryTimerID, run == runID, expected == epoch, isMonitoring else { return }
        recoveryIsRunning = true; activeRecoveryTask = recoveryTask
        defer { recoveryIsRunning = false; activeRecoveryTask = nil; recoveryTask = nil; rescheduleRecovery() }
        for key in recovery.takeDue(at: clock.now) {
            guard run == runID, expected == epoch, isMonitoring else { return }
            switch key {
            case .eventSubscription:
                if !isSuspended { await subscribeToDiscovery(run: run) }
            case .wake:
                if isSuspended, wakeRequested { await finishWake(id: wakeID, run: run, epoch: expected) }
            case .logicalDiscovery(let session):
                if !isSuspended, store.isCurrent(session), let host = store.devices[session.physicalDeviceID] { requestLogicalDiscovery(host) }
            }
        }
    }
    private func cancelScheduling() {
        timerID = UUID(); batchID = UUID()
        timerTask?.cancel(); timerTask = nil
        discoveryRefreshTask?.cancel(); discoveryRefreshTask = nil; pendingAdded.removeAll()
    }
    public func stop() async {
        if let stopTask { await stopTask.value; return }
        guard !stopped else { return }
        stopped = true; isMonitoring = false; epoch = UUID(); runID = UUID(); wakeID = UUID()
        let recoveryWork = recoveryTask, activeRecoveryWork = activeRecoveryTask, wakeWork = wakeTask, wakeAttemptWork = wakeAttemptTask
        cancelRecovery(); recovery.removeAll(); wakeRequested = false
        cancelScheduling(); wakeTask?.cancel(); wakeTask = nil
        eventTask?.cancel(); eventTask = nil; coordinator.clearPending(); store.pause()
        let work = Array(fullRefreshDrains.values) + Array(tasks.values) + Array(logicalReadTasks.values) + Array(logicalDiscoveryTasks.values) + Array(logicalLifecycleTasks.values) + Array(logicalEventTasks.values) + [recoveryWork, activeRecoveryWork, wakeWork, wakeAttemptWork].compactMap { $0 }
        for task in logicalEventTasks.values { task.cancel() }; logicalEventTasks.removeAll()
        for task in work { task.cancel() }
        publish()
        for observer in observers.values { observer.finish() }; observers.removeAll()
        finishInitialDiscoveryIfReady()
        // Save the shared drain before the first await. Every concurrent caller
        // waits for the same real cleanup, including uncancellable C requests.
        let discovery = discovery, registry = registry
        let drain = Task {
            // Close long-lived receiver callbacks as part of the shared stop drain.
            await registry?.stop()
            await discovery.stop()
            for task in work { await task.value }
        }
        stopTask = drain
        // Actual transport drain may exceed its logical two-second budget.
        await drain.value
    }

    public func refreshLogicalDiscovery(deviceID: PhysicalDeviceID? = nil) async {
        guard isMonitoring, !isSuspended else { return }
        let states = store.devices.values.filter { $0.hostPresence == .present && (deviceID == nil || $0.id == deviceID) }
        for state in states { requestLogicalDiscovery(state) }
        for task in Array(logicalDiscoveryTasks.values) { await task.value }
    }
    private func requestLogicalDiscovery(_ state: DeviceState) {
        guard isMonitoring, !isSuspended, store.isCurrent(state.sessionID), logicalDiscoveryTasks[state.id] == nil,
              let driver = registry?.logicalDriver(for: state.descriptor) else { return }
        recovery.unschedule(.logicalDiscovery(state.sessionID)); rescheduleRecovery()
        let host = state.descriptor, session = state.sessionID, expected = epoch
        logicalDiscoveryTasks[state.id] = Task { [weak self] in
            do {
                let targets = try await driver.discoverTargets(host: host, session: session)
                await self?.completeLogicalDiscovery(targets, session: session, epoch: expected, error: nil)
            } catch {
                await self?.completeLogicalDiscovery([], session: session, epoch: expected, error: String(describing: error))
            }
        }
    }
    private func completeLogicalDiscovery(_ targets: [LogicalDeviceDescriptor], session: DeviceSessionID, epoch expected: UUID, error: String?) {
        logicalDiscoveryTasks.removeValue(forKey: session.physicalDeviceID)
        let needsRediscovery = pendingLogicalRediscovery.remove(session) != nil
        guard isMonitoring, !isSuspended, expected == epoch, store.isCurrent(session) else {
            if isMonitoring, !isSuspended, let current = store.devices[session.physicalDeviceID], current.hostPresence == .present {
                requestLogicalDiscovery(current)
            }
            finishInitialDiscoveryIfReady()
            return
        }
        if let error {
            scheduleRecovery(.logicalDiscovery(session), message: error)
            publish(); finishInitialDiscoveryIfReady(); return
        }
        let incomplete = targets.isEmpty || targets.contains { target in
            target.capabilities.operations.values.contains { $0.evidence == .unknown && $0.failureReason != nil }
        }
        if incomplete {
            let reason = targets.flatMap { $0.capabilities.operations.values }.compactMap(\.failureReason).first ?? "No paired device completed read-only discovery."
            scheduleRecovery(.logicalDiscovery(session), message: reason)
        } else { recovery.succeed(.logicalDiscovery(session)); rescheduleRecovery() }
        let previousPreferences = store.preferences
        let changes = store.reconcileLogicalDevices(targets, for: session)
        if store.preferences != previousPreferences { persistPreferences() }
        for old in changes.invalidated {
            logicalReadTasks[old.deviceID]?.cancel(); logicalNextRefresh.removeValue(forKey: old.deviceID)
            logicalFailureCounts.removeValue(forKey: old.deviceID)
        }
        if needsRediscovery, !incomplete, let host = store.devices[session.physicalDeviceID] { requestLogicalDiscovery(host) }
        else if automaticallyRefreshTelemetry {
            for child in store.logicalDevices.values where child.descriptor.address.hostSessionID == session && child.canRefreshTelemetry {
                if logicalReadTasks[child.id] == nil { _ = requestLogicalRefresh(child.sessionID) }
            }
        }
        publish(); rescheduleTimer(); finishInitialDiscoveryIfReady()
    }
    public func refresh(logicalDeviceID: LogicalDeviceID) async {
        guard let child = store.logicalDevices[logicalDeviceID] else { return }
        if case .direct = child.descriptor.address.target,
           store.devices[child.descriptor.address.hostSessionID.physicalDeviceID].flatMap({ registry?.logicalDriver(for: $0.descriptor) }) == nil {
            await refresh(deviceID: child.descriptor.address.hostSessionID.physicalDeviceID); return
        }
        if let task = requestLogicalRefresh(child.sessionID) { await task.value }
    }
    private func requestLogicalRefresh(_ session: LogicalDeviceSessionID) -> Task<Void, Never>? {
        guard isMonitoring, !isSuspended, store.isCurrent(session), let child = store.logicalDevices[session.deviceID], child.canRefreshTelemetry,
              let host = store.devices[session.address.hostSessionID.physicalDeviceID],
              let driver = registry?.logicalDriver(for: host.descriptor) else {
            logicalNextRefresh.removeValue(forKey: session.deviceID); return nil
        }
        if let current = logicalReadTasks[session.deviceID] { return current }
        logicalNextRefresh.removeValue(forKey: session.deviceID)
        _ = store.beginTelemetry(session, at: clock.now)
        let expected = epoch, target = child.descriptor
        let task = Task { [weak self] in
            let result = await driver.readTelemetry(target: target, session: session)
            await self?.completeLogicalRefresh(result, requested: session, epoch: expected)
        }
        logicalReadTasks[session.deviceID] = task; return task
    }
    private func completeLogicalRefresh(_ result: LogicalDeviceTelemetryResult, requested: LogicalDeviceSessionID, epoch expected: UUID) {
        logicalReadTasks.removeValue(forKey: requested.deviceID)
        guard isMonitoring, !isSuspended, expected == epoch, store.isCurrent(requested) else {
            if let replacement = store.logicalDevices[requested.deviceID], store.isCurrent(replacement.sessionID), !isSuspended {
                _ = requestLogicalRefresh(replacement.sessionID)
            }
            return
        }
        let update: DeviceTelemetryUpdate
        if result.session == requested { update = result.update }
        else {
            let failure = TelemetryFailure(category: .transport, message: "Discarded telemetry for a different logical device or generation.")
            update = DeviceTelemetryUpdate(startedAt: clock.now, finishedAt: clock.now, battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure)
        }
        _ = store.apply(update, to: requested, policy: policy)
        let count = update.battery != nil || update.charging != nil ? 0 : (logicalFailureCounts[requested.deviceID] ?? 0) + 1
        logicalFailureCounts[requested.deviceID] = count
        logicalNextRefresh[requested.deviceID] = update.finishedAt.addingTimeInterval(policy.interval(afterConsecutiveFailures: count))
        if [update.batteryFailure, update.chargingFailure].contains(where: { $0?.category == .removed }),
           let host = store.devices[requested.address.hostSessionID.physicalDeviceID] { requestLogicalDiscovery(host) }
        publish(); rescheduleTimer()
    }
    public func setAlias(_ alias: String?, for logicalDeviceID: LogicalDeviceID) {
        guard let child = store.logicalDevices[logicalDeviceID] else { return }
        if case .direct = child.descriptor.address.target,
           store.devices[child.descriptor.address.hostSessionID.physicalDeviceID].flatMap({ registry?.logicalDriver(for: $0.descriptor) }) == nil {
            setAlias(alias, for: child.descriptor.address.hostSessionID.physicalDeviceID); return
        }
        store.setAlias(alias, for: logicalDeviceID); persistPreferences(); publish()
    }

    private func invalidateLogicalHost(_ session: DeviceSessionID, device: PhysicalDeviceDescriptor) {
        guard let registry, registry.logicalDriver(for: device) != nil else { return }
        let id = UUID()
        logicalLifecycleTasks[id] = Task { [weak self] in
            await registry.invalidateHost(session, device: device)
            await self?.finishLogicalLifecycle(id)
        }
    }
    private func finishLogicalLifecycle(_ id: UUID) { logicalLifecycleTasks.removeValue(forKey: id) }

    public func settingsAdapter(for logicalDeviceID: LogicalDeviceID) -> (any DeviceSettingsAdapter)? {
        guard let child = store.logicalDevices[logicalDeviceID], store.isCurrent(child.sessionID),
              let host = store.devices[child.sessionID.address.hostSessionID.physicalDeviceID] else { return nil }
        return registry?.settingsAdapter(for: host.descriptor)
    }
    @discardableResult public func beginSettingsRead(_ session: LogicalDeviceSessionID, at date: Date) -> Bool {
        guard isMonitoring, !isSuspended else { return false }
        let accepted = store.beginSettingsRead(session, at: date); if accepted { publish() }; return accepted
    }
    @discardableResult public func publishSettings(_ settings: DeviceSettingsSnapshot, capabilityUpdates: [DeviceOperation: OperationCapability] = [:]) -> Bool {
        guard isMonitoring, !isSuspended else { return false }
        let accepted = store.applySettings(settings, capabilityUpdates: capabilityUpdates); if accepted { publish() }; return accepted
    }
    public func publishSettingsFailure(_ failure: TelemetryFailure, session: LogicalDeviceSessionID, at date: Date, capabilityUpdates: [DeviceOperation: OperationCapability] = [:]) {
        guard isMonitoring, !isSuspended else { return }
        if store.failSettingsRead(failure, session: session, at: date, capabilityUpdates: capabilityUpdates) { publish() }
    }
    @discardableResult public func publishSettingChange(_ result: SettingChangeResult, capabilityUpdates: [DeviceOperation: OperationCapability] = [:]) -> Bool {
        guard isMonitoring, !isSuspended else { return false }
        let accepted = store.applySettingChange(result, capabilityUpdates: capabilityUpdates); if accepted { publish() }; return accepted
    }

    public func setPrimaryLogical(_ logicalDeviceID: LogicalDeviceID?) {
        store.setPrimaryLogical(logicalDeviceID); persistPreferences(); publish()
    }
    @discardableResult
    public func setDeviceFolded(_ folded: Bool, identityKey: String) -> Bool {
        store.setDeviceFolded(folded, identityKey: identityKey)
        persistPreferences()
        publish()
        return preferencesFailure == nil
    }
    @discardableResult
    public func setRememberFoldedDevices(_ remember: Bool, activeFoldedKeys: Set<String>) -> Bool {
        store.setRememberFoldedDevices(remember, activeFoldedKeys: activeFoldedKeys)
        persistPreferences()
        publish()
        return preferencesFailure == nil
    }
    @discardableResult
    public func setQuickPresets(_ presets: DeviceQuickPresets?, for identityKey: String) -> Bool {
        store.setQuickPresets(presets, for: identityKey)
        persistPreferences()
        publish()
        return preferencesFailure == nil
    }
    @discardableResult
    public func setShowMenuBarPercentage(_ show: Bool) -> Bool {
        store.setShowMenuBarPercentage(show)
        persistPreferences()
        publish()
        return preferencesFailure == nil
    }
    @discardableResult
    public func setAppearanceMode(_ mode: BazerAppearanceMode) -> Bool {
        store.setAppearanceMode(mode)
        persistPreferences()
        publish()
        return preferencesFailure == nil
    }
    /// Wait for the initial host snapshot and any initial receiver identity handshakes; no polling sleeps.
    public func initialDiscoveryReady() async -> DeviceStoreSnapshot {
        if hasFinishedInitialDiscovery { return snapshot() }
        return await withCheckedContinuation { initialDiscoveryWaiters.append($0) }
    }
    private var hasFinishedInitialDiscovery: Bool {
        // Before a host snapshot, a subscription failure must unblock callers.
        // Once hosts are known, stream diagnostics cannot finish still-running
        // receiver handshakes or expose a host-only snapshot as a completed pass.
        stopped || (receivedInitialDiscovery ? logicalDiscoveryTasks.isEmpty : discoveryFailure != nil)
    }
    private func finishInitialDiscoveryIfReady() {
        guard hasFinishedInitialDiscovery else { return }
        let value = snapshot(), waiters = initialDiscoveryWaiters; initialDiscoveryWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: value) }
    }

    private func receiveLogicalDiscoveryEvent(_ session: DeviceSessionID, run: UUID) {
        guard isMonitoring, !isSuspended, run == runID, store.isCurrent(session), let host = store.devices[session.physicalDeviceID] else { return }
        if logicalDiscoveryTasks[session.physicalDeviceID] != nil { pendingLogicalRediscovery.insert(session) }
        else { requestLogicalDiscovery(host) }
    }

}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
