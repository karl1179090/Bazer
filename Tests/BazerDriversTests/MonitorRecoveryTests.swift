// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import Foundation
import Testing
@testable import BazerDrivers

private final class RecoveryClock: MonitorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    private var deadlineWaiters: [UUID: (Date, CheckedContinuation<Bool, Never>)] = [:]
    var now: Date { lock.withLock { date } }
    var sleepCount: Int { lock.withLock { sleepers.count } }
    func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if interval <= 0 { continuation.resume() }
                    else {
                        let deadline = date.addingTimeInterval(interval)
                        sleepers[id] = (deadline, continuation)
                        let ready = deadlineWaiters.filter { $0.value.0 == deadline }
                        for key in ready.keys { deadlineWaiters.removeValue(forKey: key) }
                        for waiter in ready.values { waiter.1.resume(returning: true) }
                    }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    /// The monitor has an independent 60-second discovery poll as well as its
    /// recovery timer. Readiness means this exact fake deadline is registered,
    /// rather than a transient count of all outstanding sleeps.
    func waitForSleep(in interval: TimeInterval, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = now.addingTimeInterval(interval), id = UUID()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        self.lock.withLock {
                            if Task.isCancelled { continuation.resume(returning: false) }
                            else if self.sleepers.values.contains(where: { $0.0 == deadline }) { continuation.resume(returning: true) }
                            else { self.deadlineWaiters[id] = (deadline, continuation) }
                        }
                    }
                } onCancel: {
                    self.lock.withLock { self.deadlineWaiters.removeValue(forKey: id)?.1.resume(returning: false) }
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return false }
                return false
            }
            let ready = await group.next() ?? false
            group.cancelAll()
            return ready
        }
    }
    func advance(_ interval: TimeInterval) {
        let ready = lock.withLock {
            date = date.addingTimeInterval(interval)
            let ready = sleepers.filter { $0.value.0 <= date }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        ready.forEach { $0.1.resume() }
    }
}
private struct RecoveryPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}
private func recoveryInterface(_ id: UInt64 = 101) -> HIDInterfaceDescriptor {
    HIDInterfaceDescriptor(registryEntryID: id, usbParentRegistryEntryID: id + 1000,
        vendorID: 0x046D, productID: 0xDEAD, product: "Offline recovery receiver", transport: "USB",
        maxInputReportSize: 20, maxOutputReportSize: 20,
        reportDescriptor: [0x06,0,0xFF,9,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0])
}
private actor RecoveryDiscovery: BatteryMonitorDiscovery {
    let clock: RecoveryClock
    var interfaces: [HIDInterfaceDescriptor]
    var eventFailures = 0, snapshotFailures = 0
    var eventCalls = 0, snapshotCalls = 0
    var continuation: AsyncStream<HIDDiscoveryEvent>.Continuation?
    private var heldSnapshot: CheckedContinuation<HIDDiscoverySnapshot, Never>?
    private var holdNext = false
    private var holdNextEvents = false
    private var heldEvents: CheckedContinuation<AsyncStream<HIDDiscoveryEvent>, any Error>?
    init(clock: RecoveryClock, interfaces: [HIDInterfaceDescriptor]) { self.clock = clock; self.interfaces = interfaces }
    func failEvents(_ count: Int) { eventFailures = count }
    func failSnapshots(_ count: Int) { snapshotFailures = count }
    func holdSnapshot() { holdNext = true }
    func holdEvents() { holdNextEvents = true }
    func failHeldEvents() {
        heldEvents?.resume(throwing: TelemetryFailure(category: .transport, message: "offline delayed subscription failure")); heldEvents = nil
    }
    func snapshot() async throws -> HIDDiscoverySnapshot {
        snapshotCalls += 1
        if holdNext { holdNext = false; return await withCheckedContinuation { heldSnapshot = $0 } }
        if snapshotFailures > 0 { snapshotFailures -= 1; throw TelemetryFailure(category: .transport, message: "offline wake failure") }
        return value()
    }
    func releaseSnapshot() { heldSnapshot?.resume(returning: value()); heldSnapshot = nil }
    func events() async throws -> AsyncStream<HIDDiscoveryEvent> {
        eventCalls += 1
        if holdNextEvents { holdNextEvents = false; return try await withCheckedThrowingContinuation { heldEvents = $0 } }
        if eventFailures > 0 { eventFailures -= 1; throw TelemetryFailure(category: .transport, message: "offline subscription failure") }
        let pair = AsyncStream<HIDDiscoveryEvent>.makeStream(); continuation = pair.continuation
        pair.continuation.yield(HIDDiscoveryEvent(kind: .initial, snapshot: value()))
        return pair.stream
    }
    func change(_ interfaces: [HIDInterfaceDescriptor]) {
        self.interfaces = interfaces; continuation?.yield(HIDDiscoveryEvent(kind: .changed, snapshot: value()))
    }
    func endEvents() { continuation?.finish() }
    private func value() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: clock.now, interfaces: interfaces) }
    func stop() { continuation?.finish() }
}
private actor RecoveryLogicalDriver: DeviceLogicalDriver {
    enum Outcome { case healthy, placeholder, failure }
    let clock: RecoveryClock
    var outcomes: [PhysicalDeviceID: Outcome] = [:]
    var discoveries: [DeviceSessionID] = []
    var reads: [LogicalDeviceSessionID] = []
    var invalidated: [DeviceSessionID] = []
    private var holdNext = false
    private var held: (DeviceSessionID, CheckedContinuation<[LogicalDeviceDescriptor], Never>)?
    init(clock: RecoveryClock) { self.clock = clock }
    func set(_ outcome: Outcome, host: PhysicalDeviceID) { outcomes[host] = outcome }
    func holdDiscovery() { holdNext = true }
    func releaseDiscovery() {
        if let (session, waiter) = held { held = nil; waiter.resume(returning: targets(session, outcome: .healthy)) }
    }
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) async throws -> [LogicalDeviceDescriptor] {
        discoveries.append(session)
        if holdNext { holdNext = false; return await withCheckedContinuation { held = (session, $0) } }
        let outcome = outcomes[host.id] ?? .healthy
        if case .failure = outcome { throw TelemetryFailure(category: .timeout, message: "offline host \(host.id.rawValue) unavailable") }
        return targets(session, outcome: outcome)
    }
    private func targets(_ session: DeviceSessionID, outcome: Outcome) -> [LogicalDeviceDescriptor] {
        let placeholder: Bool; if case .placeholder = outcome { placeholder = true } else { placeholder = false }
        let caps = placeholder ? DeviceCapabilities(operations: [.batteryRead: OperationCapability(evidence: .unknown,
            source: "offline handshake", failureReason: "offline handshake incomplete")]) : DeviceCapabilities(battery: .candidate)
        return [LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: session,
            target: .receiver(index: 1, identity: LogicalPeripheralIdentity(vendorID: 0x046D, unitID: "offline-unit")),
            pairingGeneration: UUID()), product: "Offline child", kind: .mouse, capabilities: caps,
            controlEndpointRegistryEntryID: 101)]
    }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> LogicalDeviceTelemetryResult {
        reads.append(session)
        return LogicalDeviceTelemetryResult(session: session, update: DeviceTelemetryUpdate(startedAt: clock.now, finishedAt: clock.now,
            battery: BatterySample(value: .percentage(50), receivedAt: clock.now, source: "offline"), batteryFailure: nil,
            charging: nil, chargingFailure: nil))
    }
    func invalidateHost(_ session: DeviceSessionID) { invalidated.append(session) }
}
private func recoveryMonitor(clock: RecoveryClock, discovery: RecoveryDiscovery, driver: RecoveryLogicalDriver,
                             automatic: Bool = true) -> BatteryMonitor {
    let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.recovery", identify: { host in
        IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly,
            controlEndpointRegistryEntryID: host.interfaces.first?.registryEntryID, isReceiver: true)
    }, logicalDriver: driver)])
    return BatteryMonitor(discovery: discovery, reader: registry, clock: clock, preferences: RecoveryPreferences(),
        registry: registry, automaticallyRefreshTelemetry: automatic)
}
private func recoveryEventually(_ predicate: () async -> Bool) async -> Bool {
    for _ in 0..<4000 { if await predicate() { return true }; await Task.yield() }
    return false
}
private func recoveryDrain() async { for _ in 0..<100 { await Task.yield() } }
private actor RecoveryReadyResult {
    private(set) var snapshot: DeviceStoreSnapshot?
    func complete(_ value: DeviceStoreSnapshot) { snapshot = value }
}

@Suite("Monitor read-only recovery — offline", .timeLimit(.minutes(1)))
struct MonitorRecoveryTests {
    @Test(arguments: [false, true]) func streamFailureCannotFinishInitialDiscoveryWhileHandshakeIsInFlight(sleepBeforeCompletion: Bool) async {
        let clock = RecoveryClock(), discovery = RecoveryDiscovery(clock: clock, interfaces: [recoveryInterface()])
        let driver = RecoveryLogicalDriver(clock: clock), monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver, automatic: false)
        await driver.holdDiscovery(); await monitor.start()
        #expect(await recoveryEventually { await driver.discoveries.count == 1 })
        await discovery.endEvents()
        #expect(await recoveryEventually { await monitor.snapshot().discoveryFailure != nil })
        let result = RecoveryReadyResult()
        let waiting = Task { await result.complete(await monitor.initialDiscoveryReady()) }
        await recoveryDrain()
        #expect(await result.snapshot == nil, "A stream diagnostic cannot complete an in-flight initial receiver handshake")
        if sleepBeforeCompletion { await monitor.suspend() }
        await driver.releaseDiscovery(); await waiting.value
        let initial = await result.snapshot
        if sleepBeforeCompletion {
            #expect(initial?.isSuspended == true)
            #expect(initial?.logicalDevices.isEmpty == true, "The invalidated handshake must finish the waiter without publishing an old child")
        } else {
            #expect(initial?.logicalDevices.count == 1)
            #expect(initial?.discoveryFailure != nil, "Completing the handshake must preserve the separate stream failure")
        }
        await monitor.stop()
    }
    @Test func subscriptionFailureRetriesWithoutRestartingMonitor() async {
        let clock = RecoveryClock(), discovery = RecoveryDiscovery(clock: clock, interfaces: [])
        let driver = RecoveryLogicalDriver(clock: clock), monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await discovery.failEvents(1); await monitor.start()
        #expect(await monitor.snapshot().discoveryFailure != nil)
        #expect(await monitor.initialDiscoveryReady().devices.isEmpty, "A subscription failure before the first host snapshot must still finish initial discovery")
        #expect(await clock.waitForSleep(in: 2))
        clock.advance(2)
        #expect(await recoveryEventually { await discovery.eventCalls == 2 })
        #expect(await recoveryEventually { await monitor.snapshot().discoveryFailure == nil })
        await monitor.stop()
    }
    @Test(arguments: [false, true]) func subscriptionRetryIsCancelledByStopOrNewSleep(stop: Bool) async {
        let clock = RecoveryClock(), discovery = RecoveryDiscovery(clock: clock, interfaces: [])
        let driver = RecoveryLogicalDriver(clock: clock), monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await discovery.failEvents(100); await monitor.start()
        #expect(await clock.waitForSleep(in: 2))
        if stop { await monitor.stop() } else { await monitor.suspend() }
        clock.advance(1000); await recoveryDrain()
        #expect(await discovery.eventCalls == 1)
        #expect(await recoveryEventually { clock.sleepCount == 0 })
        await monitor.stop()
    }
    @Test func lateSubscriptionFailureAfterSleepWakeReschedulesOnlyCurrentLifecycle() async {
        let clock = RecoveryClock(), discovery = RecoveryDiscovery(clock: clock, interfaces: [])
        let driver = RecoveryLogicalDriver(clock: clock), monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await discovery.holdEvents()
        let starting = Task { await monitor.start() }
        #expect(await recoveryEventually { await discovery.eventCalls == 1 })
        await monitor.suspend(); await monitor.wake()
        #expect(await clock.waitForSleep(in: 2)); clock.advance(2)
        #expect(await recoveryEventually { await monitor.snapshot().isSuspended == false })
        #expect(await discovery.eventCalls == 1)
        await discovery.failHeldEvents(); await starting.value
        #expect(await clock.waitForSleep(in: 2)); clock.advance(2)
        #expect(await recoveryEventually { await discovery.eventCalls == 2 })
        #expect(await recoveryEventually { await monitor.snapshot().discoveryFailure == nil })
        await monitor.stop()
    }
    @Test(arguments: [false, true]) func failedOrPlaceholderDiscoveryRecoversWithoutNewHardwareEvent(placeholder: Bool) async throws {
        let clock = RecoveryClock(), interface = recoveryInterface()
        let discovery = RecoveryDiscovery(clock: clock, interfaces: [interface]), driver = RecoveryLogicalDriver(clock: clock)
        let host = try #require(PhysicalDeviceGrouper.group([interface]).first)
        await driver.set(placeholder ? .placeholder : .failure, host: host.id)
        let monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        #expect(await clock.waitForSleep(in: 2))
        #expect(await driver.discoveries.count == 1)
        await driver.set(.healthy, host: host.id); clock.advance(2)
        #expect(await recoveryEventually { await driver.discoveries.count == 2 })
        #expect(await recoveryEventually { await monitor.snapshot().logicalDevices.first?.battery?.percent == 50 })
        #expect(await monitor.snapshot().discoveryFailure == nil)
        await monitor.stop()
    }
    @Test func successfulHostRecoveryDoesNotEraseOtherHostErrorAndRemovalClearsOnlyThatError() async throws {
        let clock = RecoveryClock(), first = recoveryInterface(), second = recoveryInterface(202)
        let discovery = RecoveryDiscovery(clock: clock, interfaces: [first, second]), driver = RecoveryLogicalDriver(clock: clock)
        let hosts = PhysicalDeviceGrouper.group([first, second])
        for host in hosts { await driver.set(.failure, host: host.id) }
        let monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        let recovered = try #require(hosts.first), failed = try #require(hosts.last)
        await driver.set(.healthy, host: recovered.id)
        await monitor.refreshLogicalDiscovery(deviceID: recovered.id)
        #expect(await monitor.snapshot().discoveryFailure?.contains(failed.id.rawValue) == true)
        await driver.set(.healthy, host: failed.id)
        await monitor.refreshLogicalDiscovery(deviceID: failed.id)
        #expect(await monitor.snapshot().discoveryFailure == nil)
        await driver.set(.failure, host: failed.id)
        await monitor.refreshLogicalDiscovery(deviceID: failed.id)
        await discovery.change(recovered.interfaces)
        #expect(await recoveryEventually { await monitor.snapshot().discoveryFailure == nil })
        await monitor.stop()
    }
    @Test func failedWakeRetriesButSecondSleepRejectsLateWakeResult() async {
        let clock = RecoveryClock(), discovery = RecoveryDiscovery(clock: clock, interfaces: [])
        let driver = RecoveryLogicalDriver(clock: clock), monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        await monitor.suspend(); await discovery.failSnapshots(1); await monitor.wake()
        #expect(await clock.waitForSleep(in: 2)); clock.advance(2)
        #expect(await recoveryEventually { await discovery.snapshotCalls == 1 })
        #expect(await clock.waitForSleep(in: 2)); clock.advance(2)
        #expect(await recoveryEventually { await monitor.snapshot().isSuspended == false })
        #expect(await monitor.snapshot().discoveryFailure == nil)
        await monitor.suspend(); await discovery.holdSnapshot(); await monitor.wake()
        #expect(await clock.waitForSleep(in: 2)); clock.advance(2)
        #expect(await recoveryEventually { await discovery.snapshotCalls == 3 })
        await monitor.suspend(); await discovery.releaseSnapshot(); await recoveryDrain()
        #expect(await monitor.snapshot().isSuspended)
        #expect(clock.sleepCount == 0)
        await monitor.stop()
    }
    @Test func removingHostCancelsRetryAndLateDiscoveryCannotPublishOldChild() async {
        let clock = RecoveryClock(), interface = recoveryInterface()
        let discovery = RecoveryDiscovery(clock: clock, interfaces: [interface]), driver = RecoveryLogicalDriver(clock: clock)
        await driver.holdDiscovery()
        let monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await monitor.start(); #expect(await recoveryEventually { await driver.discoveries.count == 1 })
        await discovery.change([])
        #expect(await recoveryEventually { await monitor.snapshot().devices.first?.hostPresence == .removed })
        await driver.releaseDiscovery(); await recoveryDrain(); clock.advance(1000); await recoveryDrain()
        #expect(await monitor.snapshot().logicalDevices.isEmpty)
        #expect(await driver.discoveries.count == 1)
        await monitor.stop(); #expect(await recoveryEventually { clock.sleepCount == 0 })
    }
    @Test func discoveryOnlyProbeDoesNotCreateRecoveryPolling() async throws {
        let clock = RecoveryClock(), interface = recoveryInterface()
        let discovery = RecoveryDiscovery(clock: clock, interfaces: [interface]), driver = RecoveryLogicalDriver(clock: clock)
        let host = try #require(PhysicalDeviceGrouper.group([interface]).first)
        await driver.set(.failure, host: host.id)
        let monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver, automatic: false)
        await monitor.start(); _ = await monitor.initialDiscoveryReady(); clock.advance(1000); await recoveryDrain()
        #expect(await driver.discoveries.count == 1); #expect(clock.sleepCount == 0)
        await monitor.stop()
    }
    @Test func hostRetryHasOneInFlightAttemptAndStopCancelsItsNextDeadline() async throws {
        let clock = RecoveryClock(), interface = recoveryInterface()
        let discovery = RecoveryDiscovery(clock: clock, interfaces: [interface]), driver = RecoveryLogicalDriver(clock: clock)
        let host = try #require(PhysicalDeviceGrouper.group([interface]).first)
        await driver.set(.failure, host: host.id)
        let monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        #expect(await clock.waitForSleep(in: 2))
        await driver.holdDiscovery(); clock.advance(2)
        #expect(await recoveryEventually { await driver.discoveries.count == 2 })
        let joining = Task { await monitor.refreshLogicalDiscovery(deviceID: host.id) }
        clock.advance(1000); await recoveryDrain()
        #expect(await driver.discoveries.count == 2)
        await driver.releaseDiscovery(); await joining.value
        await driver.set(.failure, host: host.id)
        await monitor.refreshLogicalDiscovery(deviceID: host.id)
        let beforeStop = await driver.discoveries.count
        await monitor.stop(); clock.advance(1000); await recoveryDrain()
        #expect(await driver.discoveries.count == beforeStop)
        #expect(await recoveryEventually { clock.sleepCount == 0 })
    }
    @Test func stopWaitsForUncancellableWakeAndRejectsItsResult() async {
        let clock = RecoveryClock(), discovery = RecoveryDiscovery(clock: clock, interfaces: [])
        let driver = RecoveryLogicalDriver(clock: clock), monitor = recoveryMonitor(clock: clock, discovery: discovery, driver: driver)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        await discovery.holdSnapshot(); await monitor.suspend(); await monitor.wake()
        #expect(await clock.waitForSleep(in: 2)); clock.advance(2)
        #expect(await recoveryEventually { await discovery.snapshotCalls == 1 })
        let stopping = Task { await monitor.stop() }
        #expect(await recoveryEventually { await monitor.snapshot().isMonitoring == false })
        await discovery.releaseSnapshot(); await stopping.value
        #expect(await monitor.snapshot().isSuspended)
        #expect(clock.sleepCount == 0)
    }
    @Test func recoveryDelayHasPositiveFloorAndFiveMinuteCeilingWithIndependentHostErrors() throws {
        var scheduling = MonitorRecoveryScheduling()
        let host = DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "offline-host"))
        let now = Date(timeIntervalSince1970: 1000), policy = RefreshPolicy(regularInterval: 0.01)
        var previous: TimeInterval = 0
        for _ in 0..<100 {
            scheduling.fail(.logicalDiscovery(host), message: "host failure", at: now, policy: policy, retry: true)
            let delay = try #require(scheduling.nextDate).timeIntervalSince(now)
            #expect(delay >= 1 && delay <= 300 && delay >= previous)
            previous = delay
        }
        #expect(previous == 300)
        scheduling.fail(.wake, message: "wake failure", at: now, policy: policy, retry: true)
        scheduling.succeed(.logicalDiscovery(host))
        #expect(scheduling.failureDescription == "wake failure")
        scheduling.removeAll(); #expect(scheduling.nextDate == nil)
    }
}


extension MonitorRecoveryTests {
    @Test func recoveryDeadlineReadinessDoesNotMistakeTheRegularDiscoveryPollForRecovery() async {
        let clock = RecoveryClock()
        let poll = Task { try? await clock.sleep(for: 60) }
        #expect(await clock.waitForSleep(in: 60))
        #expect(!(await clock.waitForSleep(in: 2, timeout: .milliseconds(20))), "A regular 60-second poll cannot satisfy the 2-second recovery handshake")
        let recovery = Task { try? await clock.sleep(for: 2) }
        #expect(await clock.waitForSleep(in: 2))
        #expect(clock.sleepCount == 2)
        clock.advance(2); await recovery.value
        #expect(clock.sleepCount == 1)
        poll.cancel(); await poll.value
        #expect(clock.sleepCount == 0)
    }
}
