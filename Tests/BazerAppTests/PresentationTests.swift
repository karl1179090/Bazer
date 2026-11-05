// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import Foundation
import Testing
@testable import BazerApp

@Suite("App snapshot presentation — offline")
struct PresentationTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func identityOnlyAndAliasNeverCreateBatteryCapability() throws {
        let item = identified(parent: 1, kind: .keyboard, support: .unsupported)
        var store = DeviceStore()
        store.reconcile([item], at: date)
        store.setAlias("Razer DeathAdder 100%", for: item.descriptor.id)
        let state = try #require(store.devices[item.descriptor.id])
        let presentation = DevicePresentation(state, at: date)
        #expect(presentation.batteryText == "--")
        #expect(presentation.statusText == "已识别 · 电量未知")
        #expect(presentation.connectionText == "USB 已识别")
        #expect(state.canRefresh == false)
        #expect(state.peerPresence == .unknown)
    }

    @Test func zeroIsValidAndExpiresAt180SecondsWithoutChangingHistory() throws {
        let state = try sampled(raw: 0, charging: .notCharging)
        #expect(DevicePresentation(state, at: date.addingTimeInterval(179)).batteryText == "0%")
        let expired = DevicePresentation(state, at: date.addingTimeInterval(180))
        #expect(expired.batteryText == "--")
        #expect(expired.statusText == "电量已过期")
        #expect(expired.chargingText == "充电状态未知")
        #expect(state.battery?.rawValue == 0)
        #expect(state.battery?.receivedAt == date)
    }

    @Test func deviceStatusFailureIsVisibleImmediatelyAndKeepsRealHistory() throws {
        let item = identified(parent: 1)
        var store = DeviceStore()
        store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(raw: 128, charging: .charging), to: session)
        let failure = TelemetryFailure(category: .deviceStatus, message: "synthetic status04 for offline test", protocolStatus: 4)
        store.apply(DeviceTelemetryUpdate(startedAt: date.addingTimeInterval(10), finishedAt: date.addingTimeInterval(11), battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure), to: session)
        let state = try #require(store.devices[item.descriptor.id])
        let presentation = DevicePresentation(state, at: date.addingTimeInterval(11))
        #expect(presentation.batteryText == "--")
        #expect(state.battery?.percent == 50) // Retained only as explicit history.
        #expect(presentation.statusText == "电量读取失败 · 设备状态 0x04")
        #expect(presentation.hasFailure)
        #expect(presentation.chargingText == "充电状态未知")
        #expect(state.peerPresence == .unknown)
        #expect(state.battery?.receivedAt == date)
    }

    @Test func chargingFailureDoesNotReuseChargingBoltOrDropValidBattery() throws {
        let item = identified(parent: 1)
        var store = DeviceStore()
        store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(raw: 255, charging: .charging), to: session)
        store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: BatterySample(rawValue: 255, receivedAt: date, source: "synthetic test"), batteryFailure: nil, charging: nil, chargingFailure: TelemetryFailure(category: .timeout, message: "synthetic timeout")), to: session)
        let state = try #require(store.devices[item.descriptor.id])
        let presentation = DevicePresentation(state, at: date)
        #expect(presentation.batteryText == "100%")
        #expect(presentation.chargingText == "充电状态未知")
        #expect(!presentation.batterySymbol.contains("bolt"))
        #expect(presentation.statusText == "充电读取失败 · 查询超时")
        #expect(state.charging?.state == .charging)
    }

    @MainActor @Test func reconnectShowsOneCurrentCardAndKeepsRemovalSeparate() throws {
        let old = identified(parent: 1), new = identified(parent: 2)
        var store = DeviceStore()
        store.reconcile([old], at: date)
        let session = try #require(store.devices[old.descriptor.id]?.sessionID)
        store.apply(update(raw: 128, charging: .notCharging), to: session)
        store.reconcile([], at: date.addingTimeInterval(1))
        store.reconcile([new], at: date.addingTimeInterval(2))
        let model = offlineModel()
        model.consume(snapshot(store, at: date.addingTimeInterval(2)))
        #expect(model.presentDevices.map(\.id) == [new.descriptor.id])
        #expect(model.removedDevices.map(\.id) == [old.descriptor.id])
        #expect(model.snapshot.primaryDeviceID == new.descriptor.id)
        #expect(model.menuBarTitle == "--")
        let removed = try #require(model.removedDevices.first)
        #expect(DevicePresentation(removed, at: date).connectionText == "USB 已移除")
        #expect(DevicePresentation(removed, at: date).batteryText == "--")
    }

    @MainActor @Test func menuBarUsesSelectedPrimaryAndExposesFailure() throws {
        let mouse = identified(parent: 1), keyboard = identified(parent: 2, kind: .keyboard, support: .unsupported)
        var store = DeviceStore()
        store.reconcile([mouse, keyboard], at: date)
        let session = try #require(store.devices[mouse.descriptor.id]?.sessionID)
        store.apply(update(raw: 128, charging: .notCharging), to: session)
        let model = offlineModel()
        model.consume(snapshot(store, at: date))
        #expect(model.menuBarTitle == "50%")
        model.setPrimaryTarget(.physical(keyboard.descriptor.id))
        store.setPrimary(keyboard.descriptor.id)
        model.consume(snapshot(store, at: date))
        #expect(model.menuBarTitle == "--")
        #expect(model.menuBarAccessibilityLabel.contains("电量未知"))
        model.setPrimaryTarget(.physical(mouse.descriptor.id))
        store.setPrimary(mouse.descriptor.id)
        let failure = TelemetryFailure(category: .denied, message: "synthetic denied")
        store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure), to: session)
        model.consume(snapshot(store, at: date))
        #expect(model.menuBarTitle == "50%")
        #expect(model.menuBarSymbol == "battery.50percent")
        #expect(model.menuBarAccessibilityLabel.contains("状态待确认"))
        #expect(model.menuBarAccessibilityLabel.contains("上次电量 50%"))
    }

    @MainActor @Test func suspendedAndStoppingKeepMenuCacheDisableRefreshAndDrainOfflineMonitor() async throws {
        let state = try sampled(raw: 128, charging: .notCharging)
        let model = offlineModel()
        model.consume(DeviceStoreSnapshot(capturedAt: date, devices: [state], primaryDeviceID: state.id,
            isMonitoring: true, isSuspended: true, discoveryFailure: nil, preferencesFailure: nil))
        #expect(model.menuBarTitle == "50%")
        #expect(!model.canRefresh)
        await model.stop()
        #expect(model.isTerminating)
        #expect(!model.canRefresh)
    }

    @MainActor @Test(arguments: [false, true]) func selectedReceiverChildSuppliesMenuBatteryWithoutDuplicatingDirectRows(estimated: Bool) throws {
        let hostItem = identified(parent: 1)
        var store = DeviceStore()
        store.reconcile([IdentifiedDevice(descriptor: hostItem.descriptor, kind: .other, capabilities: .identificationOnly,
            controlEndpointRegistryEntryID: hostItem.controlEndpointRegistryEntryID, isReceiver: true)], at: date)
        let host = try #require(store.devices[hostItem.descriptor.id]?.sessionID)
        let child = LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: host,
            target: .receiver(index: 1, identity: LogicalPeripheralIdentity(vendorID: 0x046D, unitID: "synthetic-child")), pairingGeneration: UUID()),
            product: "Synthetic receiver child", kind: .mouse, capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: 101)
        store.reconcileLogicalDevices([child], for: host)
        let session = try #require(store.logicalDevices[child.id]?.sessionID)
        if estimated {
            let estimate = try #require(BatteryPercentageEstimate(value: 55, source: "synthetic Solaar curve", resolution: "5% display steps; uncalibrated"))
            store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
                battery: BatterySample(value: .voltageOnly(millivolts: 3845), rawBytes: [15,5,0], receivedAt: date, source: "HID++ 1001 runtime feature", percentageEstimate: estimate),
                batteryFailure: nil, charging: ChargingSample(state: .discharging, rawValue: 0, receivedAt: date, source: "test"), chargingFailure: nil), to: session)
        } else { store.apply(update(raw: 128, charging: .notCharging), to: session) }
        store.setPrimaryLogical(child.id)
        let model = offlineModel()
        model.consume(DeviceStoreSnapshot(capturedAt: date, devices: Array(store.devices.values), primaryDeviceID: store.primaryDeviceID,
            isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil,
            logicalDevices: Array(store.logicalDevices.values), primaryLogicalDeviceID: store.primaryLogicalDeviceID))
        #expect(model.menuBarTitle == (estimated ? "约 55%" : "50%"))
        #expect(model.menuBarAccessibilityLabel.contains("Synthetic receiver child"))
        if estimated { #expect(model.menuBarAccessibilityLabel.contains("约 55%")) }
        #expect(model.receiverChildren.map(\.id) == [child.id])
    }
    @MainActor @Test func managedDirectMouseKeyboardAndHeadsetUseTheirLogicalCardAndActualBattery() throws {
        for kind in [DeviceKind.mouse, .keyboard, .other] {
            let hostItem = identified(parent: 1)
            var store = DeviceStore()
            store.reconcile([IdentifiedDevice(descriptor: hostItem.descriptor, kind: .other, capabilities: .identificationOnly,
                controlEndpointRegistryEntryID: 101, isReceiver: true)], at: date)
            let host = try #require(store.devices[hostItem.descriptor.id]?.sessionID)
            let identity = LogicalPeripheralIdentity(vendorID: 0x046D, unitID: "synthetic-direct-\(kind.rawValue)", protocolVersion: "2.0", firmware: "1.2")
            let child = LogicalDeviceDescriptor(address: .direct(host), product: "Synthetic direct \(kind.rawValue)", kind: kind,
                capabilities: DeviceCapabilities(battery: .candidate, powerSource: .replaceableBattery), controlEndpointRegistryEntryID: 101,
                preferenceIdentity: .confirmedLogicalUnit(identity), peripheralIdentity: identity)
            store.reconcileLogicalDevices([child], for: host)
            let session = try #require(store.logicalDevices[child.id]?.sessionID)
            store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
                battery: BatterySample(value: .percentage(20), receivedAt: date, source: "synthetic managed direct"), batteryFailure: nil,
                charging: nil, chargingFailure: nil), to: session)
            let model = offlineModel()
            model.consume(DeviceStoreSnapshot(capturedAt: date, devices: Array(store.devices.values), primaryDeviceID: store.primaryDeviceID,
                isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil,
                logicalDevices: Array(store.logicalDevices.values), primaryLogicalDeviceID: store.primaryLogicalDeviceID))
            #expect(model.presentDevices.isEmpty, "A managed direct host must not show a second identity-only card")
            #expect(model.managedLogicalDevices.map(\.id) == [child.id]); #expect(model.receiverChildren.isEmpty)
            #expect(model.managedDirectLogicalDevice(for: hostItem.descriptor.id)?.id == child.id)
            #expect(model.menuBarTitle == "20%"); #expect(model.canRefresh)
            let shown = try #require(model.managedLogicalDevices.first)
            #expect(LogicalDevicePresentation(shown, at: date).batteryText == "20%")
            #expect(shown.canRefreshTelemetry); #expect(shown.descriptor.preferenceIdentity?.kind == .confirmedLogicalUnit)
        }
    }
    @MainActor @Test func legacyDirectRazerAndIdentityOnlyKeyboardKeepPhysicalCards() throws {
        for kind in [DeviceKind.mouse, .keyboard] {
            let item = identified(parent: 1, kind: kind, support: kind == .mouse ? .candidate : .unsupported)
            var store = DeviceStore(); store.reconcile([item], at: date)
            let model = offlineModel()
            model.consume(DeviceStoreSnapshot(capturedAt: date, devices: Array(store.devices.values), primaryDeviceID: store.primaryDeviceID,
                isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil,
                logicalDevices: Array(store.logicalDevices.values), primaryLogicalDeviceID: store.primaryLogicalDeviceID))
            #expect(model.presentDevices.map(\.id) == [item.descriptor.id]); #expect(model.managedLogicalDevices.isEmpty)
            #expect(model.managedDirectLogicalDevice(for: item.descriptor.id) == nil)
        }
    }

    private func identified(parent: UInt64, kind: DeviceKind = .mouse, support: BatterySupport = .candidate) -> IdentifiedDevice {
        let interface = HIDInterfaceDescriptor(registryEntryID: parent + 100, usbParentRegistryEntryID: parent,
            vendorID: 0x1234, productID: 0x5678, product: "Synthetic offline device", transport: "USB",
            primaryUsage: kind == .mouse ? .mouse : .keyboard)
        return IdentifiedDevice(descriptor: PhysicalDeviceDescriptor(id: PhysicalDeviceID(rawValue: "usb-parent:\(parent)"), interfaces: [interface]), kind: kind,
            capabilities: DeviceCapabilities(battery: support, chargingQuery: support != .unsupported),
            controlEndpointRegistryEntryID: support == .unsupported ? nil : interface.registryEntryID)
    }
    private func update(raw: UInt8, charging: ChargingState) -> DeviceTelemetryUpdate {
        DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
            battery: BatterySample(rawValue: raw, receivedAt: date, source: "synthetic offline test"), batteryFailure: nil,
            charging: ChargingSample(state: charging, rawValue: charging == .charging ? 1 : 0, receivedAt: date, source: "synthetic offline test"), chargingFailure: nil)
    }
    private func sampled(raw: UInt8, charging: ChargingState) throws -> DeviceState {
        let item = identified(parent: 1)
        var store = DeviceStore()
        store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(raw: raw, charging: charging), to: session)
        return try #require(store.devices[item.descriptor.id])
    }
    private func snapshot(_ store: DeviceStore, at date: Date) -> DeviceStoreSnapshot {
        DeviceStoreSnapshot(capturedAt: date, devices: store.devices.values.sorted { $0.id < $1.id }, primaryDeviceID: store.primaryDeviceID,
            isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil)
    }
    private func offlineMonitor() -> BatteryMonitor {
        BatteryMonitor(discovery: EmptyDiscovery(), reader: NeverRead(), preferences: MemoryPreferences())
    }
    @MainActor private func offlineModel() -> AppModel {
        AppModel(monitor: offlineMonitor(),
                 notifications: NotificationService(backend: PresentationNotificationBackend(), persistence: PresentationNotificationPreferences()),
                 loginItem: LoginItemService(backend: PresentationLoginBackend()))
    }
}

private struct PresentationNotificationPreferences: NotificationPreferencesPersisting {
    func load() throws -> NotificationPreferences { NotificationPreferences() }
    func save(_ preferences: NotificationPreferences) throws {}
}
@MainActor private final class PresentationNotificationBackend: NotificationBackend {
    func authorization() async throws -> NotificationAuthorization { .denied }
    func requestAuthorization() async throws { fatalError("Presentation tests must never request notification authorization") }
    func send(identifier: String, title: String, body: String) async throws { fatalError("Presentation tests must never send notifications") }
}
@MainActor private final class PresentationLoginBackend: LoginItemBackend {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { fatalError("Presentation tests must never register login items") }
    func unregister() throws { fatalError("Presentation tests must never unregister login items") }
    func openSettings() { fatalError("Presentation tests must never open system settings") }
}

private struct EmptyDiscovery: BatteryMonitorDiscovery {
    func snapshot() async throws -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: []) }
    func events() async throws -> AsyncStream<HIDDiscoveryEvent> { AsyncStream { $0.finish() } }
    func stop() async {}
}
private struct NeverRead: DeviceTelemetryReading {
    func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult { fatalError("App projection tests must never read hardware") }
}
private struct MemoryPreferences: DevicePreferencesPersisting {
    func load() throws -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) throws {}
}

extension PresentationTests {
    @Test func explicitBatteryKindsDisplayTheirUnitsWithoutFabricatedPercent() throws {
        let item = identified(parent: 1)
        var store = DeviceStore(); store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        for (value, text) in [(BatteryValue.percentage(50), "50%"), (.voltageOnly(millivolts: 4123), "4123 mV"),
                              (.approximateLevel(.low), "低"), (.unknown, "--"), (.notApplicable, "不适用")] {
            store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
                battery: BatterySample(value: value, receivedAt: date, source: "synthetic"), batteryFailure: nil,
                charging: ChargingSample(state: .notApplicable, rawValue: nil, receivedAt: date, source: "synthetic"), chargingFailure: nil), to: session)
            let projection = DevicePresentation(try #require(store.devices[item.descriptor.id]), at: date)
            #expect(projection.batteryText == text); #expect(!projection.batteryText.contains("Optional"))
            #expect(!projection.batterySymbol.contains("bolt")); #expect(projection.chargingText == "不适用")
        }
    }
}
