// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import BazerCore
@testable import BazerBluetooth

private actor AudioFakeBackend: BluetoothAudioBackend {
    var discovery: BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> = .init(status: .success)
    var power: BluetoothAudioReadResult<BluetoothAudioPowerRecord> = .init(status: .success)
    var discoverCount = 0, powerCount = 0, starts = 0, stops = 0
    var event: (@Sendable () -> Void)?
    var discoveryGate: AudioGate<Void>?
    func set(_ d: BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>, _ p: BluetoothAudioReadResult<BluetoothAudioPowerRecord>) { discovery = d; power = p }
    func discover() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        discoverCount += 1; if let discoveryGate { await discoveryGate.read() }; return discovery
    }
    func readPower() -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> { powerCount += 1; return power }
    func startEvents(_ onChange: @escaping @Sendable () -> Void) { starts += 1; event = onChange }
    func stop() { stops += 1; event = nil }
    func gate(_ gate: AudioGate<Void>?) { discoveryGate = gate }
    func fire() { event?() }
}

private actor AudioGate<Value: Sendable> {
    var calls = 0
    private var waiters: [CheckedContinuation<Value, Never>] = []
    func read() async -> Value { calls += 1; return await withCheckedContinuation { waiters.append($0) } }
    func release(_ value: Value) { let current = waiters; waiters = []; current.forEach { $0.resume(returning: value) } }
}

@Suite("Bluetooth audio monitor — fake backend and clock") struct BluetoothAudioMonitorTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func discovery(_ names: [String] = ["ACEFAST"], connected: Bool = true) -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        .init(records: names.enumerated().map { .init(key: "d\($0.offset)", name: $0.element, isConnected: connected) }, status: .success)
    }
    func power(_ percent: Int = 30, name: String = "ACEFAST", preference: String? = nil) -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> {
        .init(records: [.init(key: "p0", name: name, verifiedPreferenceIdentity: preference, percent: percent, charging: .discharging, observedAt: date)], status: .success)
    }
    @Test func uniqueSameNameHasOneCardAndNeverGetsPersistentIdentity() async throws {
        let backend = AudioFakeBackend(); await backend.set(discovery(), power())
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date })
        let first = await monitor.refresh(), device = try #require(first.devices.first)
        #expect(first.devices.count == 1); #expect(device.currentPercent(at: date) == 30)
        #expect(device.preferenceIdentity == nil); #expect(device.identityQuality == .sessionOnly)
        #expect(device.notificationReadings(at: date).isEmpty)
        let second = await monitor.refresh(), updated = try #require(second.devices.first)
        #expect(updated.id == device.id); #expect(updated.session == device.session)
        #expect(updated.eventVersion == device.eventVersion)
        await monitor.stop()
    }
    @Test func failureAndPartialEnumerationNeverClearOrDisconnectKnownDevice() async throws {
        let backend = AudioFakeBackend(); await backend.set(discovery(), power())
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date })
        let first = try #require(await monitor.refresh().devices.first)
        for status in [BluetoothAudioReadStatus.partial, .failed, .unavailable] {
            await backend.set(.init(status: status), .init(status: status))
            let current = try #require(await monitor.refresh().devices.first)
            #expect(current.id == first.id); #expect(current.connection == .uncertain)
            #expect(current.currentPercent(at: date) == nil); #expect(current.lastReadings.first?.percent == 30)
        }
        await monitor.stop()
    }
    @Test func validAccessoryInPartialSnapshotStillDisplaysItsBattery() async throws {
        let backend = AudioFakeBackend(), complete = power()
        await backend.set(discovery(), .init(records: complete.records, status: .partial))
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date })
        let snapshot = await monitor.refresh(), device = try #require(snapshot.devices.first)
        #expect(snapshot.powerStatus == .partial); #expect(device.currentPercent(at: date) == 30)
        await monitor.stop()
    }
    @Test func explicitDisconnectDefeatsPresentPowerCacheAndDoesNotRecreateLiveCard() async throws {
        let backend = AudioFakeBackend(); await backend.set(discovery(), power())
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date })
        let first = try #require(await monitor.refresh().devices.first)
        await backend.set(discovery(connected: false), power())
        for _ in 0..<3 {
            let snapshot = await monitor.refresh()
            #expect(snapshot.devices.count == 1)
            #expect(snapshot.devices.first?.connection == .disconnected)
            #expect(snapshot.devices.first?.currentPercent(at: date) == nil)
        }
        await backend.set(discovery(), power(40))
        let reconnected = await monitor.refresh(), current = try #require(reconnected.devices.first { $0.connection == .connected })
        #expect(current.id != first.id); #expect(current.session != first.session)
        #expect(current.currentPercent(at: date) == 40)
        #expect(reconnected.devices.filter { $0.connection == .disconnected }.count == 1)
        await monitor.stop()
    }
    @Test func absentPowerAndNativeConnectedAreUncertain() async throws {
        let backend = AudioFakeBackend(); await backend.set(discovery(), power())
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }); _ = await monitor.refresh()
        await backend.set(discovery(), .init(records: [.init(key: "p0", name: "ACEFAST", percent: 30, isPresent: false, observedAt: date)], status: .success))
        let current = try #require(await monitor.refresh().devices.first)
        #expect(current.connection == .uncertain); #expect(current.currentPercent(at: date) == nil)
        await monitor.stop()
    }
    @Test func completeEmptyMovesToHistoryAndVerifiedOwnIdentityReusesOnlyItsHistory() async throws {
        let backend = AudioFakeBackend(); await backend.set(discovery(), power(preference: "verified-own-source"))
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date })
        let first = try #require(await monitor.refresh().devices.first)
        await backend.set(.init(status: .success), .init(status: .success)); _ = await monitor.refresh()
        await backend.set(discovery(), power(25, name: "Renamed", preference: "verified-own-source"))
        let reconnect = await monitor.refresh(), same = try #require(reconnect.devices.first { $0.preferenceIdentity != nil })
        #expect(same.id == first.id); #expect(same.session != first.session)
        #expect(same.currentPercent(at: date) == 25)
        await monitor.stop()
    }
    @Test func sameNameCollisionPreservesAccessoryAndNeverBorrowsAnIdentity() async throws {
        let backend = AudioFakeBackend(); await backend.set(discovery(["ACEFAST", "ACEFAST"]), power())
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date })
        let snapshot = await monitor.refresh(), device = try #require(snapshot.devices.first)
        #expect(snapshot.devices.count == 1); #expect(device.identityQuality == .ambiguous)
        #expect(device.currentPercent(at: date) == 30); #expect(device.preferenceIdentity == nil)
        #expect(device.notificationReadings(at: date).isEmpty)
        await monitor.stop()
    }
    @Test func twoDistinctSameNameAccessoriesRemainSeparateAndNoNativeDuplicateCards() async {
        let backend = AudioFakeBackend()
        await backend.set(discovery(["ACEFAST", "ACEFAST"]), .init(records: [
            .init(key: "p0", name: "ACEFAST", percent: 30, observedAt: date), .init(key: "p1", name: "ACEFAST", percent: 80, observedAt: date)], status: .success))
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }), snapshot = await monitor.refresh()
        #expect(snapshot.devices.count == 2)
        #expect(Set(snapshot.devices.compactMap { $0.currentPercent(at: date) }) == [30,80])
        #expect(snapshot.devices.allSatisfy { $0.preferenceIdentity == nil })
        await monitor.stop()
    }
    @Test func multiPartsNeedExplicitGroupAndCaseNeverLowersSummary() async throws {
        let backend = AudioFakeBackend()
        let records: [BluetoothAudioPowerRecord] = [
            .init(key: "left", name: "Air", groupKey: "g", component: .left, percent: 35, charging: .discharging, observedAt: date),
            .init(key: "right", name: "Air", groupKey: "g", component: .right, percent: 50, charging: .discharging, observedAt: date),
            .init(key: "case", name: "Air", groupKey: "g", component: .case, percent: 1, charging: .charging, observedAt: date)]
        await backend.set(.init(status: .success), .init(records: records, status: .success))
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }), first = await monitor.refresh()
        #expect(first.devices.count == 1); #expect(first.devices.first?.currentPercent(at: date) == 35)
        await backend.set(.init(status: .success), .init(records: [records[1]], status: .success))
        let missing = try #require(await monitor.refresh().devices.first)
        #expect(missing.batteryReadings.count == 1); #expect(missing.currentPercent(at: date) == 50)
        await monitor.stop()
    }
    @Test func duplicateComponentsAreConflictAndNotBattery() async {
        let backend = AudioFakeBackend()
        await backend.set(.init(status: .success), .init(records: [
            .init(key: "left0", name: "Air", groupKey: "g", component: .left, percent: 20, observedAt: date),
            .init(key: "left1", name: "Air", groupKey: "g", component: .left, percent: 60, observedAt: date)], status: .success))
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }), snapshot = await monitor.refresh()
        #expect(snapshot.devices.first?.readStatus == .partial); #expect(snapshot.devices.first?.currentPercent(at: date) == nil)
        await monitor.stop()
    }
    @Test func suspendDropsUncooperativeOldReturnAndResumeUsesNewEpoch() async throws {
        let dGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>>()
        let pGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioPowerRecord>>()
        let backend = SystemBluetoothAudioBackend(identityRegistry: nil, discoveryOperation: { await dGate.read() }, powerOperation: { await pGate.read() })
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }, timeout: 2)
        let pending = Task { await monitor.refresh() }
        while await pGate.calls == 0 { await Task.yield() }
        await monitor.suspend()
        let suspended = await monitor.snapshot()
        await dGate.release(discovery()); await pGate.release(power())
        _ = await pending.value
        #expect(await monitor.snapshot().epoch == suspended.epoch)
        #expect(await monitor.snapshot().devices.isEmpty)
        await monitor.stop()
    }
    @Test func timeoutIsBoundedAndSingleFlightPreventsUnderlyingReaderAccumulation() async {
        let dGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>>()
        let pGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioPowerRecord>>()
        let backend = SystemBluetoothAudioBackend(identityRegistry: nil, discoveryOperation: { await dGate.read() }, powerOperation: { await pGate.read() })
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }, timeout: 0.02)
        for _ in 0..<4 { let snapshot = await monitor.refresh(); #expect(snapshot.powerStatus == .failed) }
        #expect(await dGate.calls == 1); #expect(await pGate.calls == 1)
        await monitor.stop()
        await dGate.release(.init(status: .success)); await pGate.release(.init(status: .success))
    }
    @Test func constructionAndStopWithoutStartDoNotReadAnyProvider() async {
        let backend = AudioFakeBackend(), monitor = BluetoothAudioMonitor(backend: backend)
        await monitor.stop()
        #expect(await backend.discoverCount == 0); #expect(await backend.powerCount == 0)
        #expect(await backend.starts == 0)
    }
    @Test func underlyingReadFromEarlierEpochCannotBeStampedIntoNewConnection() async throws {
        let dGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>>()
        let pGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioPowerRecord>>()
        let backend = SystemBluetoothAudioBackend(identityRegistry: nil, discoveryOperation: { await dGate.read() }, powerOperation: { await pGate.read() })
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }, timeout: 2)
        let pending = Task { await monitor.refresh() }
        while await pGate.calls == 0 { await Task.yield() }
        while await dGate.calls == 0 { await Task.yield() }
        await dGate.release(.init(records: discovery().records, status: .success, startedAt: date.addingTimeInterval(-10)))
        await pGate.release(.init(records: power(10).records, status: .success, startedAt: date.addingTimeInterval(-10)))
        while await pGate.calls < 2 { await Task.yield() }
        while await dGate.calls < 2 { await Task.yield() }
        #expect(await monitor.snapshot().devices.isEmpty)
        await dGate.release(discovery()); await pGate.release(power(40))
        let current = try #require(await pending.value.devices.first)
        #expect(current.currentPercent(at: date) == 40)
        #expect(current.lastReadings.allSatisfy { $0.percent != 10 })
        await monitor.stop()
    }
    @Test func concurrentRefreshIntentsJoinAndCanOnlyAddOneSupplementalPass() async {
        let dGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>>()
        let pGate = AudioGate<BluetoothAudioReadResult<BluetoothAudioPowerRecord>>()
        let backend = SystemBluetoothAudioBackend(identityRegistry: nil, discoveryOperation: { await dGate.read() }, powerOperation: { await pGate.read() })
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }, timeout: 2)
        let initial = Task { await monitor.refresh() }
        while await dGate.calls == 0 { await Task.yield() }
        while await pGate.calls == 0 { await Task.yield() }
        let joined = (0..<8).map { _ in Task { await monitor.refresh() } }
        for _ in 0..<100 { await Task.yield() }
        await dGate.release(discovery()); await pGate.release(power())
        while await dGate.calls < 2 { await Task.yield() }
        while await pGate.calls < 2 { await Task.yield() }
        let duringSupplement = (0..<8).map { _ in Task { await monitor.refresh() } }
        for _ in 0..<100 { await Task.yield() }
        await dGate.release(discovery()); await pGate.release(power())
        _ = await initial.value
        for task in joined + duringSupplement { _ = await task.value }
        #expect(await dGate.calls == 2); #expect(await pGate.calls == 2)
        await monitor.stop()
    }
    @Test func startSuspendResumeAndStopOwnEventSubscriptionLifecycle() async {
        let backend = AudioFakeBackend(), monitor = BluetoothAudioMonitor(backend: backend, pollInterval: 3600)
        await monitor.start { _ in }
        #expect(await backend.starts == 1)
        await monitor.suspend(); #expect(await backend.stops == 1)
        await monitor.resume(); #expect(await backend.starts == 2)
        await monitor.stop(); #expect(await backend.stops == 2)
        #expect(await backend.event == nil)
    }
    @Test func eventImmediatelyRevokesCurrentReadingsAndStableContentKeepsItsEventVersion() async throws {
        let backend = AudioFakeBackend(); await backend.set(discovery(), power(preference: "verified"))
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }, pollInterval: 3600)
        await monitor.start { _ in }
        let initial = await monitor.snapshot(), version = try #require(initial.devices.first?.eventVersion)
        let gate = AudioGate<Void>(); await backend.gate(gate)
        let pending = Task { await monitor.refresh() }
        while await gate.calls == 0 { await Task.yield() }
        await backend.fire()
        while await monitor.snapshot().epoch == initial.epoch { await Task.yield() }
        let invalidated = await monitor.snapshot(), current = try #require(invalidated.devices.first)
        #expect(current.connection == .uncertain); #expect(current.currentReadings(at: date).isEmpty)
        #expect(current.notificationReadings(at: date).isEmpty); #expect(invalidated.powerStatus == .unavailable)
        await backend.gate(nil); await gate.release(())
        let fresh = try #require(await pending.value.devices.first)
        #expect(fresh.currentPercent(at: date) == 30); #expect(fresh.eventVersion == version)
        #expect(await backend.discoverCount == 3)
        await monitor.stop()
    }
    @Test func multipleUnknownPartsHaveDistinctPresentationIDsAndDoNotEraseKnownEarBattery() async throws {
        let backend = AudioFakeBackend()
        await backend.set(.init(status: .success), .init(records: [
            .init(key: "u1", name: "Air", groupKey: "g", verifiedPreferenceIdentity: "group", component: .unknown, percent: 1, charging: .discharging, observedAt: date),
            .init(key: "u2", name: "Air", groupKey: "g", verifiedPreferenceIdentity: "group", component: .unknown, percent: 2, charging: .discharging, observedAt: date),
            .init(key: "left", name: "Air", groupKey: "g", verifiedPreferenceIdentity: "group", component: .left, percent: 35, charging: .discharging, observedAt: date)], status: .success))
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date })
        let device = try #require(await monitor.refresh().devices.first), readings = device.currentReadings(at: date)
        #expect(device.readStatus == .success); #expect(readings.count == 3)
        #expect(Set(readings.map(\.componentID)).count == 3)
        #expect(device.currentPercent(at: date) == 35)
        #expect(device.notificationReadings(at: date).map(\.component) == [.left])
        await monitor.stop()
    }
    @Test func directSourceLinkRetainsDisconnectAuthorityAcrossNativeRename() async throws {
        let backend = AudioFakeBackend()
        let report = BluetoothAudioReadResult(records: [BluetoothAudioPowerRecord(key: "p0", name: "ACEFAST", directDiscoveryKey: "d0", percent: 30, observedAt: date)], status: BluetoothAudioReadStatus.success)
        await backend.set(discovery(), report)
        let monitor = BluetoothAudioMonitor(backend: backend, clock: { date }); _ = await monitor.refresh()
        await backend.set(discovery(["Renamed"]), report); _ = await monitor.refresh()
        await backend.set(discovery(["Renamed"], connected: false), report)
        let snapshot = await monitor.refresh()
        #expect(snapshot.devices.count == 1); #expect(snapshot.devices.first?.connection == .disconnected)
        #expect(snapshot.devices.first?.currentPercent(at: date) == nil)
        await monitor.stop()
    }
}
