// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import Foundation
import Testing
@testable import BazerDrivers

/// A fully controlled clock: neither this clock nor these tests sleep in real time.
private final class ManualMonitorClock: MonitorClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    private var cancelled: Set<UUID> = []
    private var zeroSleeps = 0
    var now: Date { lock.withLock { date } }
    var sleepCount: Int { lock.withLock { sleepers.count } }
    var zeroSleepCount: Int { lock.withLock { zeroSleeps } }
    func sleep(for interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if interval <= 0 { zeroSleeps += 1; continuation.resume() }
                    else { sleepers[id] = (date.addingTimeInterval(interval), continuation) }
                }
            }
        } onCancel: {
            self.lock.withLock {
                if let value = self.sleepers.removeValue(forKey: id) { value.1.resume(throwing: CancellationError()) }
                else { self.cancelled.insert(id) }
            }
        }
    }
    func advance(_ seconds: TimeInterval) {
        let ready = lock.withLock {
            date = date.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.0 <= date }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for value in ready { value.1.resume() }
    }
}

private struct VolatilePreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}

private func monitorInterface(_ id: UInt64 = 101, parent: UInt64 = 10, usage: HIDUsage = .mouse, control: Bool = true, vendor: UInt16 = 0x1532, product: UInt16 = 0x00C5) -> HIDInterfaceDescriptor {
    HIDInterfaceDescriptor(registryEntryID: id, usbParentRegistryEntryID: parent, vendorID: vendor, productID: product,
        product: "Synthetic renamed device", transport: "USB", locationID: UInt32(parent * 100), primaryUsage: usage, usages: [usage],
        maxFeatureReportSize: control ? 90 : 0,
        reportDescriptor: control ? [0x05, 1, 0x09, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0] : [0x05, 1, 0x09, UInt8(usage.usage), 0xA1, 1, 0xC0])
}

private actor MonitorDiscovery: BatteryMonitorDiscovery {
    private var interfaces: [HIDInterfaceDescriptor]
    private var continuation: AsyncStream<HIDDiscoveryEvent>.Continuation?
    private(set) var snapshotCalls = 0
    private var failSnapshots = false
    func setSnapshotFailure(_ value: Bool) { failSnapshots = value }
    private(set) var stopped = false
    private(set) var stopCalls = 0
    private let clock: ManualMonitorClock
    init(_ interfaces: [HIDInterfaceDescriptor], clock: ManualMonitorClock) { self.interfaces = interfaces; self.clock = clock }
    func snapshot() throws -> HIDDiscoverySnapshot {
        snapshotCalls += 1
        if failSnapshots { throw NSError(domain: "SyntheticDiscoveryFailure", code: 1) }
        return HIDDiscoverySnapshot(capturedAt: clock.now, interfaces: interfaces)
    }
    func events() -> AsyncStream<HIDDiscoveryEvent> {
        let (stream, continuation) = AsyncStream<HIDDiscoveryEvent>.makeStream()
        self.continuation = continuation
        continuation.yield(HIDDiscoveryEvent(kind: .initial, snapshot: HIDDiscoverySnapshot(capturedAt: clock.now, interfaces: interfaces)))
        return stream
    }
    func change(_ interfaces: [HIDInterfaceDescriptor]) {
        self.interfaces = interfaces
        continuation?.yield(HIDDiscoveryEvent(kind: .changed, snapshot: HIDDiscoverySnapshot(capturedAt: clock.now, interfaces: interfaces)))
    }
    func stop() { stopCalls += 1; stopped = true; continuation?.finish(); continuation = nil }
}

private actor StopCompletions {
    private(set) var started: Set<Int> = []
    private(set) var finished: Set<Int> = []
    func start(_ id: Int) { started.insert(id) }
    func finish(_ id: Int) { finished.insert(id) }
}

private actor MonitorReader: DeviceTelemetryReading {
    struct Call: Sendable { let device: PhysicalDeviceDescriptor; let startedAt: Date }
    private(set) var calls: [Call] = []
    private var waiting: [Int: CheckedContinuation<DeviceTelemetryResult, Never>] = [:]
    private let clock: ManualMonitorClock
    init(clock: ManualMonitorClock) { self.clock = clock }
    func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult {
        let index = calls.count
        calls.append(Call(device: device, startedAt: clock.now))
        // Intentionally ignores Task cancellation to model a synchronous C call.
        return await withCheckedContinuation { waiting[index] = $0 }
    }
    func release(_ index: Int, raw: UInt8? = 128, charging: ChargingState? = .notCharging, failure: TelemetryFailure? = nil, physicalID: PhysicalDeviceID? = nil) {
        guard let continuation = waiting.removeValue(forKey: index) else { Issue.record("No waiting synthetic read \(index)"); return }
        let call = calls[index]
        continuation.resume(returning: DeviceTelemetryResult(physicalDeviceID: physicalID ?? call.device.id,
            endpointRegistryEntryID: InterfaceSelector.razerControlInterface(in: call.device).selected?.registryEntryID,
            startedAt: call.startedAt, finishedAt: clock.now,
            battery: raw.map { BatterySample(rawValue: $0, receivedAt: clock.now, source: "synthetic") },
            batteryFailure: raw == nil ? failure : nil,
            charging: charging.map { ChargingSample(state: $0, rawValue: $0 == .charging ? 1 : 0, receivedAt: clock.now, source: "synthetic") },
            chargingFailure: charging == nil ? failure : nil))
    }
}

@discardableResult
private func eventually(_ condition: @escaping () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    for _ in 0..<20_000 {
        if await condition() { return true }
        await Task.yield()
    }
    Issue.record("Synthetic condition did not settle", sourceLocation: sourceLocation)
    return false
}

private func testMonitor(_ interfaces: [HIDInterfaceDescriptor] = [monitorInterface()]) -> (BatteryMonitor, MonitorDiscovery, MonitorReader, ManualMonitorClock) {
    let clock = ManualMonitorClock(), preferences = VolatilePreferences()
    let discovery = MonitorDiscovery(interfaces, clock: clock), reader = MonitorReader(clock: clock)
    return (BatteryMonitor(discovery: discovery, reader: reader, clock: clock, preferences: preferences), discovery, reader, clock)
}

@Suite(.timeLimit(.minutes(1)))
struct BatteryMonitorTests {
    @Test func repeatedManualRefreshJoinsOneRequestAndDiscoveryBatch() async throws {
        let (monitor, discovery, reader, clock) = testMonitor()
        await monitor.start()
        await eventually { await monitor.snapshot().devices.count == 1 }
        await eventually { clock.sleepCount > 0 }
        #expect(await reader.calls.isEmpty)
        // Repeated discovery snapshots must not enqueue duplicate reads.
        for _ in 0..<20 { await discovery.change([monitorInterface(), monitorInterface(102, usage: .keyboard, control: false)]) }
        let manual = (0..<20).map { _ in Task { await monitor.refresh() } }
        await eventually { await reader.calls.count == 1 }
        clock.advance(0.1)
        for _ in 0..<100 { await Task.yield() }
        #expect(await reader.calls.count == 1)
        await reader.release(0)
        for task in manual { await task.value }
        #expect(await monitor.snapshot().devices.first?.battery?.rawValue == 128)
        #expect(await monitor.snapshot().devices.first?.isRefreshing == false)
        await monitor.stop()
    }

    @Test func newDeviceBatchRefreshesOnlyAddedDeviceAndTwoSameModelsStaySeparate() async throws {
        let (monitor, discovery, reader, clock) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let first = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        await reader.release(0, raw: 10); await first.value
        await discovery.change([monitorInterface(), monitorInterface(201, parent: 20)])
        await eventually { await monitor.snapshot().devices.count == 2 }
        await eventually { clock.sleepCount >= 2 }
        clock.advance(0.1)
        await eventually { await reader.calls.count == 2 }
        #expect(await reader.calls[1].device.id != reader.calls[0].device.id)
        await reader.release(1, raw: 240, charging: .charging)
        await eventually { await monitor.snapshot().devices.filter { $0.battery != nil }.count == 2 }
        let states = await monitor.snapshot().devices
        #expect(states[0].battery?.rawValue == 10); #expect(states[1].battery?.rawValue == 240)
        #expect(states[0].currentCharging(at: clock.now) == .notCharging)
        #expect(states[1].currentCharging(at: clock.now) == .charging)
        await monitor.stop()
    }

    @Test func scheduledFailuresBackOffAndSuccessRestoresSixtySeconds() async throws {
        let (monitor, _, reader, clock) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let failure = TelemetryFailure(category: .denied, message: "synthetic denied", ioReturn: -1)
        let initial = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        await reader.release(0, raw: nil, charging: nil, failure: failure); await initial.value
        for (index, delay) in [(1, 60.0), (2, 120.0), (3, 300.0)] {
            await eventually { clock.sleepCount > 0 }
            clock.advance(delay - 1)
            for _ in 0..<100 { await Task.yield() }
            #expect(await reader.calls.count == index)
            clock.advance(1)
            await eventually { await reader.calls.count == index + 1 }
            if index == 3 { await reader.release(index, raw: 227) }
            else { await reader.release(index, raw: nil, charging: nil, failure: failure) }
            await eventually { await monitor.snapshot().devices.first?.isRefreshing == false }
        }
        let state = try #require(await monitor.snapshot().devices.first)
        #expect(state.consecutiveFailures == 0); #expect(state.nextRefreshAt == clock.now.addingTimeInterval(60))
        #expect(state.peerPresence == .unknown); #expect(state.access == .ready)
        await monitor.stop()
    }

    @Test func removeAndReconnectWhileOldReadIsPendingCannotRestoreOldSample() async throws {
        let (monitor, discovery, reader, clock) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let oldRead = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        let oldSession = try #require(await monitor.snapshot().devices.first?.sessionID)
        await discovery.change([])
        await eventually { await monitor.snapshot().devices.first?.hostPresence == .removed }
        await discovery.change([monitorInterface()])
        await eventually { await monitor.snapshot().devices.first?.sessionID != oldSession }
        await eventually { clock.sleepCount > 0 }; clock.advance(0.1)
        for _ in 0..<100 { await Task.yield() }
        // Same physical slot remains occupied until the old uncancellable call returns.
        #expect(await reader.calls.count == 1)
        await reader.release(0, raw: 255); await oldRead.value
        await eventually { await reader.calls.count == 2 }
        #expect(await monitor.snapshot().devices.first?.battery == nil)
        await reader.release(1, raw: 0)
        await eventually { await monitor.snapshot().devices.first?.battery?.rawValue == 0 }
        await monitor.stop()
    }

    @Test func removedDeviceLateResultStaysRemovedAndCannotBecomePrimary() async throws {
        let (monitor, discovery, reader, _) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let read = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        await discovery.change([]); await eventually { await monitor.snapshot().devices.first?.hostPresence == .removed }
        await reader.release(0, raw: 255); await read.value
        #expect(await monitor.snapshot().devices.first?.battery == nil)
        #expect(await monitor.snapshot().primaryDeviceID == nil)
        await monitor.stop()
    }

    @Test func endpointReplacementWaitsForOldSlotWithoutZeroDelayTimerLoop() async throws {
        let (monitor, discovery, reader, clock) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let oldRead = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        let oldSession = try #require(await monitor.snapshot().devices.first?.sessionID)
        await discovery.change([monitorInterface(109)])
        await eventually { await monitor.snapshot().devices.first?.sessionID != oldSession }
        await eventually { clock.sleepCount > 0 }; clock.advance(0.1)
        for _ in 0..<1000 { await Task.yield() }
        #expect(await reader.calls.count == 1); #expect(clock.zeroSleepCount == 0)
        await reader.release(0, raw: 255); await oldRead.value
        await eventually { await reader.calls.count == 2 }
        #expect(await reader.calls[1].device.interfaces.first?.registryEntryID == 109)
        #expect(await monitor.snapshot().devices.first?.battery == nil)
        await reader.release(1, raw: 64)
        await eventually { await monitor.snapshot().devices.first?.battery?.rawValue == 64 }
        await monitor.stop()
    }

    @Test func chargingFailurePreservesBatteryAndRawChargingHistoryButShowsUnknown() async throws {
        let (monitor, _, reader, clock) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let first = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        await reader.release(0, raw: 128, charging: .charging); await first.value
        let original = clock.now; clock.advance(10)
        let second = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 2 }
        let failure = TelemetryFailure(category: .timeout, message: "synthetic timeout")
        await reader.release(1, raw: 129, charging: nil, failure: failure); await second.value
        let state = try #require(await monitor.snapshot().devices.first)
        #expect(state.battery?.rawValue == 129); #expect(state.charging?.receivedAt == original)
        #expect(state.currentCharging(at: clock.now) == .unknown); #expect(state.consecutiveFailures == 0)
        await monitor.stop()
    }

    @Test func sleepPausesAndWakeWaitsTwoSecondsThenReenumerates() async throws {
        let (monitor, discovery, reader, clock) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let first = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        await reader.release(0); await first.value
        await monitor.suspend(); clock.advance(600)
        await monitor.refresh(); #expect(await reader.calls.count == 1)
        await monitor.wake(); await monitor.wake()
        await eventually { clock.sleepCount > 0 }; clock.advance(1.9)
        for _ in 0..<100 { await Task.yield() }
        #expect(await reader.calls.count == 1); #expect(await discovery.snapshotCalls == 0)
        clock.advance(0.1)
        await eventually { await reader.calls.count == 2 }
        #expect(await discovery.snapshotCalls == 1); #expect(await monitor.snapshot().isSuspended == false)
        await reader.release(1); await eventually { await monitor.snapshot().devices.first?.isRefreshing == false }
        await monitor.stop()
    }

    @Test func sleepInvalidatesInFlightResultAndDefersWakeRefreshUntilRealReturn() async throws {
        let (monitor, _, reader, clock) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let first = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        await monitor.suspend(); await monitor.wake()
        await eventually { clock.sleepCount > 0 }; clock.advance(2)
        await eventually { await monitor.snapshot().isSuspended == false }
        #expect(await reader.calls.count == 1)
        await reader.release(0, raw: 255); await first.value
        await eventually { await reader.calls.count == 2 }
        #expect(await monitor.snapshot().devices.first?.battery == nil)
        await reader.release(1, raw: 128); await eventually { await monitor.snapshot().devices.first?.battery?.rawValue == 128 }
        await monitor.stop()
    }

    @Test func secondSleepCancelsOldWakeAndStopFinishesSnapshots() async throws {
        let (monitor, discovery, reader, clock) = testMonitor([])
        let stream = await monitor.snapshots(); var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.isMonitoring == false)
        await monitor.start(); await monitor.suspend(); await monitor.wake()
        await eventually { clock.sleepCount > 0 }; clock.advance(1)
        await monitor.suspend(); clock.advance(20)
        for _ in 0..<100 { await Task.yield() }
        #expect(await discovery.snapshotCalls == 0); #expect(await reader.calls.isEmpty)
        await monitor.stop()
        var final: DeviceStoreSnapshot?
        while let value = await iterator.next() { final = value }
        #expect(final?.isMonitoring == false); #expect(await discovery.stopped)
    }

    @Test func capabilityAndIncompleteCompositeOwnershipNeverDependOnName() async throws {
        let auxiliary = monitorInterface(102, usage: .keyboard, control: false)
        let nutMouse = monitorInterface(301, parent: 30, usage: .mouse, control: false, vendor: 0x342D, product: 0xE51A)
        let (monitor, _, reader, _) = testMonitor([auxiliary, nutMouse])
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 2 }
        let states = await monitor.snapshot().devices
        #expect(states[0].kind == .mouse); #expect(!states[0].canRefresh)
        #expect(states[1].kind == .keyboard); #expect(states[1].capabilities == .identificationOnly)
        await monitor.setAlias("Battery mouse 100%", for: states[1].id)
        await monitor.refresh(); #expect(await reader.calls.isEmpty)
        #expect(await monitor.snapshot().devices[1].battery == nil)
        await monitor.stop()
    }

    @Test func wrongPhysicalResultIsRejectedAndRequestUUIDProtectsActiveSlot() async throws {
        let (monitor, _, reader, _) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let read = Task { await monitor.refresh() }; await eventually { await reader.calls.count == 1 }
        await reader.release(0, raw: 255, physicalID: PhysicalDeviceID(rawValue: "another-device")); await read.value
        #expect(await monitor.snapshot().devices.first?.battery == nil)
        #expect(await monitor.snapshot().devices.first?.batteryFailure?.category == .transport)
        var coordinator = RefreshCoordinator()
        let session = DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "test")), epoch = UUID()
        let request = coordinator.request(session, epoch: epoch).request
        let impostor = RefreshRequest(id: UUID(), session: session, epoch: epoch)
        let ignored = coordinator.finish(impostor)
        #expect(ignored == nil)
        #expect(coordinator.requests == [request])
        _ = coordinator.finish(request); #expect(coordinator.requests.isEmpty)
        await monitor.stop()
    }

    @Test func concurrentStopCallersAllWaitForOneRealDrain() async throws {
        let (monitor, discovery, reader, _) = testMonitor()
        await monitor.start(); await eventually { await monitor.snapshot().devices.count == 1 }
        let read = Task { await monitor.refresh() }
        await eventually { await reader.calls.count == 1 }
        let completions = StopCompletions()
        let first = Task {
            await completions.start(1)
            await monitor.stop()
            await completions.finish(1)
        }
        // Discovery is closed, but the cancelled synthetic C request is still held.
        await eventually { await discovery.stopped }
        let second = Task {
            await completions.start(2)
            await monitor.stop()
            await completions.finish(2)
        }
        await eventually { await completions.started.count == 2 }
        // Cancelling a caller cannot make stop report an unfinished drain as done.
        second.cancel()
        for _ in 0..<1000 { await Task.yield() }
        #expect(await completions.finished.isEmpty)
        #expect(await discovery.stopCalls == 1)
        await reader.release(0)
        await read.value; await first.value; await second.value
        #expect(await completions.finished == [1, 2])
        #expect(await discovery.stopCalls == 1)
        // A later caller also observes the completed shared drain.
        await monitor.stop(); #expect(await discovery.stopCalls == 1)
        #expect(await monitor.snapshot().devices.first?.battery == nil)
    }
}

private actor LogicalMonitorDriver: DeviceLogicalDriver {
    struct Call: Sendable { let session: LogicalDeviceSessionID; let startedAt: Date }
    private let clock: ManualMonitorClock
    private var pairing = UUID()
    private var discoveryContinuation: AsyncStream<DeviceSessionID>.Continuation?
    private(set) var calls: [Call] = []
    private(set) var invalidated: [DeviceSessionID] = []
    private(set) var stopCalls = 0
    private var waiting: [Int: CheckedContinuation<LogicalDeviceTelemetryResult, Never>] = [:]
    private var stopWaiter: CheckedContinuation<Void, Never>?
    init(clock: ManualMonitorClock) { self.clock = clock }
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) -> [LogicalDeviceDescriptor] {
        [UInt8(1), 2].map { index in
            LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: session,
                target: .receiver(index: index, identity: LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: "unit-\(index)")),
                pairingGeneration: pairing), product: "Offline child \(index)", kind: .mouse,
                capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: host.interfaces.first?.registryEntryID)
        }
    }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async -> LogicalDeviceTelemetryResult {
        let index = calls.count; calls.append(Call(session: session, startedAt: clock.now))
        return await withCheckedContinuation { waiting[index] = $0 }
    }
    func release(_ index: Int, percent: Int) {
        guard let waiter = waiting.removeValue(forKey: index) else { Issue.record("Missing logical read \(index)"); return }
        waiter.resume(returning: LogicalDeviceTelemetryResult(session: calls[index].session,
            update: DeviceTelemetryUpdate(startedAt: calls[index].startedAt, finishedAt: clock.now,
                battery: BatterySample(value: .percentage(percent), rawBytes: [UInt8(percent)], receivedAt: clock.now, source: "offline receiver"),
                batteryFailure: nil, charging: ChargingSample(state: .discharging, rawValue: nil, receivedAt: clock.now, source: "offline receiver"), chargingFailure: nil)))
    }
    func invalidateHost(_ session: DeviceSessionID) { invalidated.append(session) }
    func discoveryEvents() -> AsyncStream<DeviceSessionID> {
        let (stream, continuation) = AsyncStream<DeviceSessionID>.makeStream(); discoveryContinuation = continuation; return stream
    }
    func changePairing(_ host: DeviceSessionID) { pairing = UUID(); discoveryContinuation?.yield(host) }
    func stop() async { stopCalls += 1; discoveryContinuation?.finish(); await withCheckedContinuation { stopWaiter = $0 } }
    func releaseStop() { stopWaiter?.resume(); stopWaiter = nil }
}

@Suite("M7 registry and receiver monitor wiring — offline", .timeLimit(.minutes(1)))
struct LogicalMonitorTests {
    @Test func registryRoutesReceiverChildrenSeparatelyAndStopWaitsForAdapterClose() async throws {
        let clock = ManualMonitorClock(), driver = LogicalMonitorDriver(clock: clock)
        let discovery = MonitorDiscovery([monitorInterface(vendor: 0x046D, product: 0xC539)], clock: clock)
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.receiver", identify: { host in
            guard host.vendorID == 0x046D, host.productID == 0xC539 else { return nil }
            return IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly,
                controlEndpointRegistryEntryID: host.interfaces.first?.registryEntryID, isReceiver: true)
        }, logicalDriver: driver)])
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, clock: clock, preferences: VolatilePreferences(), registry: registry)
        await monitor.start()
        await eventually { await driver.calls.count == 2 }
        #expect(await monitor.snapshot().logicalDevices.count == 2)
        let calls = await driver.calls
        for (index, call) in calls.enumerated() {
            if case let .receiver(slot, _) = call.session.address.target { await driver.release(index, percent: slot == 1 ? 50 : 80) }
        }
        await eventually { await monitor.snapshot().logicalDevices.allSatisfy { $0.battery != nil } }
        let snapshot = await monitor.snapshot()
        #expect(snapshot.logicalDevices.map { $0.battery?.percent } == [50, 80])
        #expect(snapshot.devices.first?.battery == nil)
        await monitor.setAlias("Left mouse", for: snapshot.logicalDevices[0].id)
        #expect(await monitor.snapshot().logicalDevices[1].alias == nil)
        let stopping = Task { await monitor.stop() }
        await eventually { await driver.stopCalls == 1 }
        #expect(await discovery.stopped == false)
        await driver.releaseStop(); await stopping.value
        #expect(await discovery.stopped); #expect(await driver.stopCalls == 1)
        await monitor.stop(); #expect(await driver.stopCalls == 1)
    }

    @Test func ambiguousDriverRegistrationsDoNotSelectOrRead() async {
        let physical = PhysicalDeviceGrouper.group([monitorInterface()])[0]
        let entry = DeviceDriverRegistration(id: "collision", identify: { host in
            IdentifiedDevice(descriptor: host, kind: .mouse, capabilities: DeviceCapabilities(battery: .candidate), controlEndpointRegistryEntryID: 101)
        })
        let registry = DriverRegistry(registrations: [entry, entry])
        #expect(registry.identify(physical) == nil)
        let result = await registry.read(device: physical)
        #expect(result.battery == nil); #expect(result.batteryFailure?.category == .unsupported)
    }
    @Test func specificReceiverWinsOverGenericKeyboardFallback() throws {
        let physical = PhysicalDeviceGrouper.group([monitorInterface(usage: .keyboard, control: false, vendor: 0x046D, product: 0xC539)])[0]
        let receiver = DeviceDriverRegistration(id: "synthetic.receiver", identify: { host in
            guard host.vendorID == 0x046D, host.productID == 0xC539 else { return nil }
            return IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly, isReceiver: true)
        })
        let registry = DriverRegistry(registrations: DriverRegistry.standardRegistrations() + [receiver])
        let identified = try #require(registry.identify(physical))
        #expect(identified.isReceiver); #expect(identified.kind == .other)
    }

}

extension LogicalMonitorTests {
    @Test func knownCatalogueProductHasPassiveCanonicalPowerButNoTransportAuthorization() throws {
        let physical = PhysicalDeviceGrouper.group([monitorInterface(product: 0x0091)])[0]
        let identified = try #require(DeviceIdentifier.identify(physical))
        #expect(identified.catalogMatch?.entry.canonicalName == "Viper 8K")
        #expect(identified.capabilities.powerSource == .wired)
        #expect(identified.controlEndpointRegistryEntryID == nil)
        var store = DeviceStore(); store.reconcile([identified], at: Date())
        let state = try #require(store.devices[physical.id])
        #expect(state.displayName == "Viper 8K")
        #expect(!state.canRefreshTelemetry); #expect(!state.canRefreshSettings)
        #expect(state.battery == nil)
        let receiver = PhysicalDeviceGrouper.group([monitorInterface(product: 0x00B3)])[0]
        let dongle = try #require(DeviceIdentifier.identify(receiver))
        #expect(dongle.isReceiver); #expect(dongle.kind == .other)
        store.reconcile([dongle], at: Date())
        #expect(!store.logicalDevices.values.contains { $0.hostPresence == .present })
    }
    @Test func receiverPairingEventRediscoversWithoutPhysicalUnplugOrFeaturePolling() async throws {
        let clock = ManualMonitorClock(), driver = LogicalMonitorDriver(clock: clock)
        let discovery = MonitorDiscovery([monitorInterface(vendor: 0x046D, product: 0xC539)], clock: clock)
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.receiver-events", identify: { host in
            IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly, controlEndpointRegistryEntryID: 101, isReceiver: true)
        }, logicalDriver: driver)])
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, clock: clock, preferences: VolatilePreferences(), registry: registry)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        await eventually { await driver.calls.count == 2 }
        let old = await monitor.snapshot().logicalDevices.map(\.sessionID)
        await driver.release(0, percent: 50); await driver.release(1, percent: 80)
        await eventually { await monitor.snapshot().logicalDevices.allSatisfy { $0.battery != nil } }
        let host = try #require(await monitor.snapshot().devices.first?.sessionID)
        await driver.changePairing(host)
        await eventually { await driver.calls.count == 4 }
        let changed = await monitor.snapshot().logicalDevices
        #expect(changed.allSatisfy { $0.battery == nil })
        #expect(changed.map(\.sessionID) != old)
        #expect(await discovery.snapshotCalls == 0)
        await driver.release(2, percent: 55); await driver.release(3, percent: 85)
        let stopping = Task { await monitor.stop() }
        await eventually { await driver.stopCalls == 1 }; await driver.releaseStop(); await stopping.value
    }

    @Test func discoveryOnlyProbeNeverStartsAutomaticTelemetryOrTimers() async throws {
        let clock = ManualMonitorClock(), preferences = VolatilePreferences()
        let discovery = MonitorDiscovery([monitorInterface()], clock: clock), reader = MonitorReader(clock: clock)
        let monitor = BatteryMonitor(discovery: discovery, reader: reader, clock: clock, preferences: preferences,
            automaticallyRefreshTelemetry: false)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        clock.advance(600)
        for _ in 0..<100 { await Task.yield() }
        #expect(await reader.calls.isEmpty); #expect(clock.sleepCount == 0)
        let manual = Task { await monitor.refresh() }
        await eventually { await reader.calls.count == 1 }; await reader.release(0); await manual.value
        clock.advance(600)
        for _ in 0..<100 { await Task.yield() }
        #expect(await reader.calls.count == 1); #expect(clock.sleepCount == 0)
        await monitor.stop()
    }

}

private struct DirectLogicalMonitorDriver: DeviceLogicalDriver {
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) async throws -> [LogicalDeviceDescriptor] {
        let identity = LogicalPeripheralIdentity(vendorID: 0x046D, unitID: "offline-direct-unit")
        return [LogicalDeviceDescriptor(address: .direct(session), product: "Offline direct HID++ target", kind: .mouse,
            capabilities: DeviceCapabilities(battery: .candidate), controlEndpointRegistryEntryID: 101,
            preferenceIdentity: DevicePreferenceIdentity.confirmedLogicalUnit(identity))]
    }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async -> LogicalDeviceTelemetryResult {
        let now = Date(timeIntervalSince1970: 1000)
        return LogicalDeviceTelemetryResult(session: session, update: DeviceTelemetryUpdate(startedAt: now, finishedAt: now,
            battery: BatterySample(value: .percentage(20), receivedAt: now, source: "offline direct HID++"), batteryFailure: nil, charging: nil, chargingFailure: nil))
    }
}
extension LogicalMonitorTests {
    @Test func directLogicalAdapterUsesOwnRefreshAndUnitAliasInsteadOfLegacyPhysicalReader() async throws {
        let clock = ManualMonitorClock(), discovery = MonitorDiscovery([monitorInterface(vendor: 0x046D, product: 0xC332)], clock: ManualMonitorClock())
        let driver = DirectLogicalMonitorDriver()
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.direct-logical", identify: { host in
            IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly, controlEndpointRegistryEntryID: 101, isReceiver: true)
        }, logicalDriver: driver)])
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, clock: clock, preferences: VolatilePreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start(); let initial = await monitor.initialDiscoveryReady()
        let target = try #require(initial.logicalDevices.first)
        #expect(target.battery == nil)
        await monitor.refresh(logicalDeviceID: target.id)
        #expect(await monitor.snapshot().logicalDevices.first?.battery?.percent == 20)
        #expect(await monitor.snapshot().devices.first?.battery == nil)
        await monitor.setAlias("Unit alias", for: target.id)
        #expect(await monitor.snapshot().logicalDevices.first?.alias == "Unit alias")
        #expect(await monitor.snapshot().devices.first?.alias == nil)
        await monitor.stop()
    }
}

extension BatteryMonitorTests {
    @Test func fullRefreshDiscoversAnEmptyListAndDoesNotNeedTelemetryCapability() async {
        let clock = ManualMonitorClock(), discovery = MonitorDiscovery([], clock: clock), reader = MonitorReader(clock: clock)
        let monitor = BatteryMonitor(discovery: discovery, reader: reader, clock: clock, preferences: VolatilePreferences(), automaticallyRefreshTelemetry: false)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        await monitor.refreshAllDeviceInformation()
        #expect(await discovery.snapshotCalls == 1); #expect(await reader.calls.isEmpty)
        await monitor.stop()
    }

    @Test func fullRefreshCoalescesAnOpenBurstToOneFollowupAndJoinsDiscoveryReads() async {
        let clock = ManualMonitorClock(), discovery = MonitorDiscovery([monitorInterface()], clock: clock), reader = MonitorReader(clock: clock)
        let monitor = BatteryMonitor(discovery: discovery, reader: reader, clock: clock, preferences: VolatilePreferences(), automaticallyRefreshTelemetry: false)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        let initial = Task { await monitor.refreshAllDeviceInformation() }
        await eventually { await reader.calls.count == 1 }
        let repeated = (0..<6).map { _ in Task { await monitor.refreshAllDeviceInformation() } }
        for _ in 0..<100 { await Task.yield() }
        #expect(await discovery.snapshotCalls == 1); #expect(await reader.calls.count == 1)
        await reader.release(0)
        await eventually { await reader.calls.count == 2 }
        #expect(await discovery.snapshotCalls == 2)
        await reader.release(1)
        await initial.value; for task in repeated { await task.value }
        #expect(await reader.calls.count == 2); #expect(await discovery.snapshotCalls == 2)
        await monitor.stop()
    }

    @Test func fullRefreshOldInFlightTelemetryGetsOneFreshPassAndSleepRejectsLateResult() async {
        let clock = ManualMonitorClock(), discovery = MonitorDiscovery([monitorInterface()], clock: clock), reader = MonitorReader(clock: clock)
        let monitor = BatteryMonitor(discovery: discovery, reader: reader, clock: clock, preferences: VolatilePreferences(), automaticallyRefreshTelemetry: false)
        await monitor.start(); _ = await monitor.initialDiscoveryReady()
        let old = Task { await monitor.refresh() }
        await eventually { await reader.calls.count == 1 }
        let full = Task { await monitor.refreshAllDeviceInformation() }
        await eventually { await discovery.snapshotCalls == 1 }
        await reader.release(0)
        await eventually { await reader.calls.count == 2 }
        await monitor.suspend(); await reader.release(1, raw: 0)
        await full.value; await old.value
        let snapshot = await monitor.snapshot()
        #expect(snapshot.isSuspended); #expect(snapshot.devices.first?.battery?.percent != 0)
        #expect(await discovery.snapshotCalls == 2); #expect(await reader.calls.count == 2)
        await monitor.stop()
    }
}


private actor FullRefreshStableDriver: DeviceLogicalDriver {
    private(set) var discoveries = 0
    private(set) var reads = 0
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) -> [LogicalDeviceDescriptor] {
        discoveries += 1
        let identity = LogicalPeripheralIdentity(vendorID: 0x046D, unitID: "synthetic-stable")
        return [LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: session, target: .receiver(index: 1, identity: identity), pairingGeneration: UUID()), product: "Synthetic stable mouse", kind: .mouse, capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: 101, peerPresence: .reachable)]
    }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> LogicalDeviceTelemetryResult {
        reads += 1
        let date = Date(timeIntervalSince1970: 1000)
        return LogicalDeviceTelemetryResult(session: session, update: DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
            battery: BatterySample(value: .percentage(60), receivedAt: date, source: "synthetic"), batteryFailure: nil,
            charging: ChargingSample(state: .discharging, rawValue: nil, receivedAt: date, source: "synthetic"), chargingFailure: nil))
    }
}

extension BatteryMonitorTests {
    @Test func fullRefreshPreservesHealthyLogicalSessionAndReadbackRevisionWithoutRehandshake() async throws {
        let clock = ManualMonitorClock(), discovery = MonitorDiscovery([monitorInterface(vendor: 0x046D, product: 0xC539)], clock: ManualMonitorClock())
        let driver = FullRefreshStableDriver()
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "synthetic.full-refresh", identify: { host in
            IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly, controlEndpointRegistryEntryID: 101, isReceiver: true)
        }, logicalDriver: driver)])
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, clock: clock, preferences: VolatilePreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start(); let initial = await monitor.initialDiscoveryReady()
        let child = try #require(initial.logicalDevices.first)
        let settings = DeviceSettingsSnapshot(session: child.sessionID, revision: 1, capturedAt: clock.now, settings: DeviceSettings(currentDPI: DPISetting(800)))
        #expect(await monitor.publishSettings(settings))
        await monitor.refreshAllDeviceInformation(); await monitor.refreshAllDeviceInformation()
        let current = try #require(await monitor.snapshot().logicalDevices.first)
        #expect(current.sessionID == child.sessionID); #expect(current.settings == settings)
        #expect(await driver.discoveries == 1); #expect(await driver.reads == 2)
        #expect(await discovery.snapshotCalls == 2)
        await monitor.stop()
    }
    @Test func fullDiscoveryFailureDoesNotInventADisconnectAndExistingHIDStillRefreshes() async throws {
        let clock = ManualMonitorClock(), discovery = MonitorDiscovery([monitorInterface()], clock: clock), reader = MonitorReader(clock: clock)
        let monitor = BatteryMonitor(discovery: discovery, reader: reader, clock: clock, preferences: VolatilePreferences(), automaticallyRefreshTelemetry: false)
        await monitor.start(); let initial = await monitor.initialDiscoveryReady()
        let original = try #require(initial.devices.first?.sessionID)
        await discovery.setSnapshotFailure(true)
        let refresh = Task { await monitor.refreshAllDeviceInformation() }
        await eventually { await reader.calls.count == 1 }
        await reader.release(0); await refresh.value
        let current = await monitor.snapshot()
        #expect(current.devices.first?.hostPresence == .present); #expect(current.devices.first?.sessionID == original)
        #expect(current.devices.first?.battery != nil); #expect(current.discoveryFailure?.contains("SyntheticDiscoveryFailure") == true)
        await monitor.stop()
    }
}
