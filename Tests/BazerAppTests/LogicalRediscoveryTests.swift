// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import Foundation
@testable import BazerApp
import Testing

@Suite("Manual logical discovery UI — offline", .timeLimit(.minutes(1)))
struct LogicalRediscoveryTests {
    @MainActor @Test func receiverOnlyPlaceholderCanDiscoverAndRepeatedClicksJoinTheActualRead() async throws {
        let (model, monitor, driver) = try await makeModel()
        let host = try #require(model.logicalDiscoveryHosts.first)
        let placeholder = try #require(model.managedLogicalDevices.first)
        #expect(!host.canRefreshTelemetry); #expect(!placeholder.canRefreshTelemetry)
        #expect(model.canRefresh, "Full information refresh remains available for receiver placeholders")
        #expect(model.canRediscoverLogicalDevices(host.id))
        await driver.planNext(blocked: true)
        var entered = driver.entered.stream.makeAsyncIterator()
        model.rediscoverLogicalDevices(host.id)
        #expect(model.logicalDiscoveryBusy.contains(host.id)); #expect(model.isRefreshing)
        _ = await entered.next()
        model.rediscoverLogicalDevices(host.id)
        #expect(await driver.discoveryCalls == 2, "One initial discovery and one user action, even after a repeated click")
        #expect(!model.canRediscoverLogicalDevices(host.id))
        #expect(model.logicalDiscoveryMessages[host.id] == nil)
        await driver.release()
        await model.waitForLogicalDiscovery(host.id)
        #expect(!model.logicalDiscoveryBusy.contains(host.id)); #expect(!model.isRefreshing)
        #expect(model.canRediscoverLogicalDevices(host.id))
        #expect(model.managedLogicalDevices.first?.descriptor.product == "Synthetic confirmed mouse")
        #expect(model.managedLogicalDevices.first?.canRefreshTelemetry == true)
        #expect(model.logicalDiscoveryMessages[host.id]?.contains("已结束") == true)
        #expect(model.logicalDiscoveryErrors[host.id] == nil)
        #expect(await driver.settingsWrites == 0); #expect(await driver.settingsReads == 0)
        #expect(await driver.telemetryReads == 0)
        #expect((await monitor.snapshot()).logicalDevices.first?.descriptor.product == "Synthetic confirmed mouse")
        await model.stop()
    }

    @MainActor @Test func rediscoveryReplacesSessionAndRejectsAnOldDraftWithoutReplayingAnySettingWrite() async throws {
        let (model, monitor, driver) = try await makeModel()
        let host = try #require(model.logicalDiscoveryHosts.first)
        model.rediscoverLogicalDevices(host.id); await model.waitForLogicalDiscovery(host.id)
        let child = try #require(model.managedLogicalDevices.first)
        model.readSettings(child.id); await model.waitForSettingsAction(child.id)
        model.consume(await monitor.snapshot())
        let original = try #require(model.managedLogicalDevices.first?.settings)
        var draft = DeviceSettingsDraft(original, scope: .runtime)
        draft.dpiX = "1600"; draft.dpiY = "1600"
        let staleRequest = try #require(draft.request(capabilities: child.capabilities))
        model.rediscoverLogicalDevices(host.id); await model.waitForLogicalDiscovery(host.id)
        let current = try #require(model.managedLogicalDevices.first)
        #expect(current.sessionID != original.session)
        #expect(current.settings == nil, "A replacement pairing session must not inherit previous settings or draft state")
        #expect(draft.snapshot.session != current.sessionID)
        #expect(await driver.settingsWrites == 0)
        model.applySettings(staleRequest); await model.waitForSettingsAction(child.id)
        #expect(await driver.settingsWrites == 0, "Even explicit submission of the old draft must be rejected before adapter writes")
        #expect(await driver.settingsReads == 1)
        await model.stop()
    }

    @MainActor @Test func realDiscoveryFailureRemainsVisibleAndNoCompletionIsReportedWhileBlocked() async throws {
        let (model, _, driver) = try await makeModel()
        let host = try #require(model.logicalDiscoveryHosts.first)
        await driver.planNext(blocked: true, failure: true)
        var entered = driver.entered.stream.makeAsyncIterator()
        model.rediscoverLogicalDevices(host.id); _ = await entered.next()
        #expect(model.logicalDiscoveryBusy.contains(host.id))
        #expect(model.logicalDiscoveryErrors[host.id] == nil); #expect(model.logicalDiscoveryMessages[host.id] == nil)
        await driver.release(); await model.waitForLogicalDiscovery(host.id)
        #expect(!model.logicalDiscoveryBusy.contains(host.id))
        #expect(model.logicalDiscoveryErrors[host.id]?.contains("synthetic discovery unavailable") == true)
        #expect(model.logicalDiscoveryMessages[host.id]?.contains("仍有诊断信息") == true)
        #expect(model.canRediscoverLogicalDevices(host.id))
        // A successful retry updates actual targets and clears this host's error.
        model.rediscoverLogicalDevices(host.id); await model.waitForLogicalDiscovery(host.id)
        #expect(model.managedLogicalDevices.first?.descriptor.product == "Synthetic confirmed mouse")
        #expect(model.logicalDiscoveryMessages[host.id]?.contains("已结束") == true)
        #expect(model.logicalDiscoveryErrors[host.id] == nil)
        #expect(model.snapshot.discoveryFailure == nil)
        #expect(await driver.settingsWrites == 0)
        await model.stop()
    }

    @MainActor @Test func pausedStoppedRemovedAndLegacyHostsCannotStartLogicalDiscovery() async throws {
        let (model, monitor, driver) = try await makeModel()
        let initial = await monitor.snapshot(), host = try #require(initial.devices.first)
        for (monitoring, suspended) in [(false, false), (true, true)] {
            model.consume(DeviceStoreSnapshot(capturedAt: initial.capturedAt, devices: initial.devices,
                primaryDeviceID: initial.primaryDeviceID, isMonitoring: monitoring, isSuspended: suspended,
                discoveryFailure: nil, preferencesFailure: nil, logicalDevices: initial.logicalDevices))
            #expect(!model.canRediscoverLogicalDevices(host.id)); model.rediscoverLogicalDevices(host.id)
        }
        model.consume(initial)
        #expect(!model.canRediscoverLogicalDevices(PhysicalDeviceID(rawValue: "removed-or-unknown")))
        for (vendor, product, kind) in [(UInt16(0x1532), UInt16(0x00C5), DeviceKind.mouse), (0x342D, 0xE51A, .keyboard)] {
            let descriptor = HIDInterfaceDescriptor(registryEntryID: 9, usbParentRegistryEntryID: 8,
                vendorID: vendor, productID: product, product: "Synthetic legacy", transport: "USB", primaryUsage: kind == .mouse ? .mouse : .keyboard)
            let physical = PhysicalDeviceDescriptor(id: PhysicalDeviceID(rawValue: "legacy-\(vendor)"), interfaces: [descriptor])
            var store = DeviceStore(); store.reconcile([IdentifiedDevice(descriptor: physical, kind: kind, capabilities: .identificationOnly)], at: Date())
            model.consume(DeviceStoreSnapshot(capturedAt: Date(), devices: Array(store.devices.values), primaryDeviceID: physical.id,
                isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil))
            #expect(model.logicalDiscoveryHosts.isEmpty); #expect(!model.canRediscoverLogicalDevices(physical.id))
            model.rediscoverLogicalDevices(physical.id)
        }
        #expect(await driver.discoveryCalls == 1)
        model.consume(initial); await model.stop()
        #expect(!model.canRediscoverLogicalDevices(host.id)); model.rediscoverLogicalDevices(host.id)
        #expect(await driver.discoveryCalls == 1); #expect(await driver.settingsWrites == 0)
    }

    @MainActor private func makeModel() async throws -> (AppModel, BatteryMonitor, RediscoveryDriver) {
        let descriptor = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10,
            vendorID: 0x046D, productID: 0xC539, product: "Synthetic receiver only", transport: "USB", primaryUsage: .mouse)
        let driver = RediscoveryDriver()
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "synthetic-rediscovery", identify: { host in
            IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly, controlEndpointRegistryEntryID: 101, isReceiver: true)
        }, logicalDriver: driver, settingsAdapter: driver)])
        let monitor = BatteryMonitor(discovery: RediscoveryHost(descriptor: descriptor), reader: registry,
            preferences: RediscoveryPreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start(); let initial = await monitor.initialDiscoveryReady()
        let model = AppModel(monitor: monitor,
            notifications: NotificationService(backend: RediscoveryNotifications(), persistence: RediscoveryNotificationPreferences()),
            loginItem: LoginItemService(backend: RediscoveryLogin()))
        model.consume(initial)
        return (model, monitor, driver)
    }
}

private actor RediscoveryDriver: DeviceLogicalDriver, DeviceSettingsAdapter {
    nonisolated let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = false, failure = false
    private(set) var discoveryCalls = 0, settingsWrites = 0, settingsReads = 0, telemetryReads = 0
    func planNext(blocked: Bool, failure: Bool = false) { self.blocked = blocked; self.failure = failure }
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) async throws -> [LogicalDeviceDescriptor] {
        discoveryCalls += 1
        let shouldBlock = blocked, shouldFail = failure
        blocked = false; failure = false
        if shouldBlock { await withCheckedContinuation { continuation = $0; entered.continuation.yield(()) } }
        if shouldFail { throw RediscoveryError.unavailable }
        let isKnown = discoveryCalls > 1
        let identity = LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: isKnown ? 0x4079 : nil,
            unitID: isKnown ? "synthetic-recovered-unit" : nil, protocolVersion: isKnown ? "2.0" : nil)
        let constraints = CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, persistenceScopes: [.runtime])
        let caps = isKnown ? DeviceCapabilities(battery: .candidate, operations: [
            .dpiRead: OperationCapability(evidence: .readVerified), .dpiWrite: OperationCapability(evidence: .writeVerified, constraints: constraints)
        ]) : .identificationOnly
        return [LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: session, target: .receiver(index: 1, identity: identity), pairingGeneration: UUID()),
            product: isKnown ? "Synthetic confirmed mouse" : "Synthetic unconfirmed slot", kind: .mouse,
            capabilities: caps, controlEndpointRegistryEntryID: isKnown ? 101 : nil)]
    }
    func release() { continuation?.resume(); continuation = nil }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async -> LogicalDeviceTelemetryResult {
        telemetryReads += 1; fatalError("Manual discovery tests must never request telemetry")
    }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async throws -> DeviceSettings {
        settingsReads += 1; return DeviceSettings(currentDPI: DPISetting(800))
    }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) async throws -> SettingAdapterTransaction {
        settingsWrites += 1; throw RediscoveryError.unexpectedWrite
    }
}
private enum RediscoveryError: String, Error, CustomStringConvertible {
    case unavailable = "synthetic discovery unavailable", unexpectedWrite
    var description: String { rawValue }
}
private actor RediscoveryHost: BatteryMonitorDiscovery {
    let descriptor: HIDInterfaceDescriptor
    private var continuation: AsyncStream<HIDDiscoveryEvent>.Continuation?
    init(descriptor: HIDInterfaceDescriptor) { self.descriptor = descriptor }
    func snapshot() async throws -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [descriptor]) }
    func events() async throws -> AsyncStream<HIDDiscoveryEvent> {
        let pair = AsyncStream<HIDDiscoveryEvent>.makeStream()
        continuation = pair.continuation
        pair.continuation.yield(HIDDiscoveryEvent(kind: .initial, snapshot: HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [descriptor])))
        return pair.stream
    }
    func stop() async { continuation?.finish(); continuation = nil }
}
private struct RediscoveryPreferences: DevicePreferencesPersisting { func load() throws -> DevicePreferences { DevicePreferences() }; func save(_ preferences: DevicePreferences) throws {} }
private struct RediscoveryNotificationPreferences: NotificationPreferencesPersisting { func load() throws -> NotificationPreferences { NotificationPreferences() }; func save(_ preferences: NotificationPreferences) throws {} }
@MainActor private final class RediscoveryNotifications: NotificationBackend {
    func authorization() async throws -> NotificationAuthorization { .denied }
    func requestAuthorization() async throws { fatalError("Offline test cannot request OS authorization") }
    func send(identifier: String, title: String, body: String) async throws { fatalError("Offline test cannot send notifications") }
}
@MainActor private final class RediscoveryLogin: LoginItemBackend {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { fatalError("Offline test cannot register login items") }
    func unregister() throws { fatalError("Offline test cannot unregister login items") }
    func openSettings() { fatalError("Offline test cannot open system settings") }
}
