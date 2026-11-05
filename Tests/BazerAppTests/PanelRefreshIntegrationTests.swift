// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import BazerBluetooth
import Foundation
import Testing
@testable import BazerApp

@Suite("Panel open full refresh integration — offline", .timeLimit(.minutes(1)))
@MainActor
struct PanelRefreshIntegrationTests {
    @Test func everyRealOpenHasOneIntentAndSlowAudioCannotDelayHIDDiscoveryOrTelemetry() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let discovery = PanelFakeDiscovery(date: date), reader = PanelFakeReader(date: date)
        let monitor = BatteryMonitor(discovery: discovery, reader: reader, clock: PanelClock(date: date), preferences: PanelMemoryPreferences(), automaticallyRefreshTelemetry: false)
        let audioBackend = PanelSlowAudioBackend()
        let audioMonitor = BluetoothAudioMonitor(backend: audioBackend, clock: { date }, pollInterval: 3600, timeout: 60)
        let model = AppModel(monitor: monitor, notifications: NotificationService(backend: PanelNotificationBackend(), persistence: PanelNotificationPreferences()), loginItem: LoginItemService(backend: PanelLoginBackend()), audioMonitor: audioMonitor)
        // A first open before start records intent and runs once monitoring is ready.
        let first = UUID(); model.handlePanelDidOpen(openSessionID: first)
        #expect(model.panelOpenRefreshIntentCount == 1)
        model.start()
        await waitUntil {
            let discoveries = await discovery.snapshotCalls, reads = await reader.reads
            return discoveries == 1 && reads == 1 && model.snapshot.devices.first?.battery?.percent == 40
        }
        #expect(model.snapshot.devices.first?.battery?.percent == 40)
        #expect(await audioBackend.isWaiting)
        model.handlePanelDidOpen(openSessionID: first)
        #expect(model.panelOpenRefreshIntentCount == 1)
        model.navigateToSettings(); model.navigateToHome()
        model.isFoldedSectionExpanded.toggle(); model.applicationDidBecomeActive()
        #expect(model.panelOpenRefreshIntentCount == 1)
        // Closing and opening again remains responsive even though the audio read
        // from the first open still owns its independent bounded worker.
        model.handlePanelDidClose(); model.handlePanelDidOpen(openSessionID: UUID())
        await waitUntil {
            let discoveries = await discovery.snapshotCalls, reads = await reader.reads
            return discoveries == 2 && reads == 2
        }
        #expect(model.panelOpenRefreshIntentCount == 2)
        model.handlePanelDidOpen(openSessionID: first) // A, B, A is still exactly two intents.
        #expect(model.panelOpenRefreshIntentCount == 2)
        #expect(await audioBackend.isWaiting)
        await model.stop()
        #expect(await audioBackend.stopCalls >= 1)
    }

    @Test func emptyHIDAndAudioOnlySnapshotsStillAllowManualAndPanelRefresh() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let discovery = PanelFakeDiscovery(date: date, empty: true), reader = PanelFakeReader(date: date)
        let monitor = BatteryMonitor(discovery: discovery, reader: reader, clock: PanelClock(date: date), preferences: PanelMemoryPreferences(), automaticallyRefreshTelemetry: false)
        let audioMonitor = BluetoothAudioMonitor(backend: PanelEmptyAudioBackend(), clock: { date }, pollInterval: 3600)
        let model = AppModel(monitor: monitor, notifications: NotificationService(backend: PanelNotificationBackend(), persistence: PanelNotificationPreferences()), loginItem: LoginItemService(backend: PanelLoginBackend()), audioMonitor: audioMonitor)
        model.start(); await waitUntil { model.canRefresh }
        #expect(model.connectedHomeDevices.isEmpty)
        model.refreshAllDeviceInformation(reason: .manual); await model.waitForAllDeviceInformationRefresh()
        #expect(await discovery.snapshotCalls == 1); #expect(await reader.reads == 0)
        model.handlePanelDidOpen(openSessionID: UUID()); await model.waitForAllDeviceInformationRefresh()
        #expect(await discovery.snapshotCalls == 2); #expect(model.canRefresh)
        await model.stop()
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<20_000 { if await condition() { return }; await Task.yield() }
        Issue.record("Controlled panel integration condition did not settle")
    }
}

private actor PanelFakeDiscovery: BatteryMonitorDiscovery {
    let date: Date
    let empty: Bool
    private var stream: AsyncStream<HIDDiscoveryEvent>.Continuation?
    private(set) var snapshotCalls = 0
    init(date: Date, empty: Bool = false) { self.date = date; self.empty = empty }
    private func value() -> HIDDiscoverySnapshot {
        let endpoint = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 1, vendorID: 0x1532, productID: 0x00C5, product: "Synthetic", transport: "USB", locationID: 100, primaryUsage: .mouse, maxFeatureReportSize: 90, reportDescriptor: [0x05, 1, 0x09, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0])
        return HIDDiscoverySnapshot(capturedAt: date, interfaces: empty ? [] : [endpoint])
    }
    func snapshot() -> HIDDiscoverySnapshot { snapshotCalls += 1; return value() }
    func events() -> AsyncStream<HIDDiscoveryEvent> {
        let (events, continuation) = AsyncStream<HIDDiscoveryEvent>.makeStream()
        stream = continuation; continuation.yield(.init(kind: .initial, snapshot: value())); return events
    }
    func stop() { stream?.finish(); stream = nil }
}
private actor PanelFakeReader: DeviceTelemetryReading {
    let date: Date
    private(set) var reads = 0
    init(date: Date) { self.date = date }
    func read(device: PhysicalDeviceDescriptor) -> DeviceTelemetryResult {
        reads += 1
        return DeviceTelemetryResult(physicalDeviceID: device.id, endpointRegistryEntryID: 101, startedAt: date, finishedAt: date,
            battery: BatterySample(value: .percentage(40), receivedAt: date, source: "synthetic"), batteryFailure: nil,
            charging: ChargingSample(state: .notCharging, rawValue: nil, receivedAt: date, source: "synthetic"), chargingFailure: nil)
    }
}
private actor PanelSlowAudioBackend: BluetoothAudioBackend {
    private var waiter: CheckedContinuation<BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>, Never>?
    private(set) var stopCalls = 0
    var isWaiting: Bool { waiter != nil }
    func discover() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> { await withCheckedContinuation { waiter = $0 } }
    func readPower() -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> { .init(status: .success) }
    func stop() { stopCalls += 1; waiter?.resume(returning: .init(status: .unavailable)); waiter = nil }
}
private struct PanelEmptyAudioBackend: BluetoothAudioBackend {
    func discover() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> { .init(status: .success) }
    func readPower() async -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> { .init(status: .success) }
}
private struct PanelClock: MonitorClock {
    let date: Date
    var now: Date { date }
    func sleep(for interval: TimeInterval) async throws { try await Task.sleep(for: .seconds(interval)) }
}
private struct PanelMemoryPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}
private struct PanelNotificationPreferences: NotificationPreferencesPersisting {
    func load() -> NotificationPreferences { NotificationPreferences() }
    func save(_ preferences: NotificationPreferences) {}
}
@MainActor private final class PanelNotificationBackend: NotificationBackend {
    func authorization() async throws -> NotificationAuthorization { .authorized }
    func requestAuthorization() async throws { Issue.record("No notification request is authorized by panel tests") }
    func send(identifier: String, title: String, body: String) async throws { Issue.record("No notification send is authorized by panel tests") }
}
@MainActor private final class PanelLoginBackend: LoginItemBackend {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { Issue.record("No login-item registration is authorized by panel tests") }
    func unregister() throws { Issue.record("No login-item removal is authorized by panel tests") }
    func openSettings() { Issue.record("No system settings launch is authorized by panel tests") }
}
