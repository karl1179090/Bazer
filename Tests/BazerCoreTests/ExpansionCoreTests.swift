// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BazerCore

@Suite("M7 explicit telemetry, logical identity and settings — offline")
struct ExpansionCoreTests {
    private let date = Date(timeIntervalSince1970: 1000)
    private func host(_ capabilities: DeviceCapabilities = .identificationOnly, receiver: Bool = true) -> IdentifiedDevice {
        let endpoint = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10, vendorID: 0x046D, productID: 0xC539,
            product: "Synthetic host", transport: "USB", locationID: 1000, primaryUsage: .mouse, usages: [.mouse])
        return IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([endpoint])[0], kind: .mouse, capabilities: capabilities,
            controlEndpointRegistryEntryID: 101, isReceiver: receiver)
    }
    private func child(_ session: DeviceSessionID, index: UInt8, unit: String?, epoch: UUID,
                       capabilities: DeviceCapabilities = DeviceCapabilities(battery: .candidate, chargingQuery: true)) -> LogicalDeviceDescriptor {
        LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: session, target: .receiver(index: index,
            identity: LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: unit)), pairingGeneration: epoch),
            product: "Synthetic child", kind: .mouse, capabilities: capabilities, controlEndpointRegistryEntryID: 101)
    }
    private func update(_ value: BatteryValue) -> DeviceTelemetryUpdate {
        DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: BatterySample(value: value, receivedAt: date, source: "synthetic"),
            batteryFailure: nil, charging: nil, chargingFailure: nil)
    }

    @Test func batteryKindsNeverInventPercentAndRazerRoundingRemainsStable() throws {
        #expect(BatterySample(value: .percentage(50), rawBytes: [50], receivedAt: date, source: "native").percent == 50)
        for (raw, percent) in [(UInt8(0), 0), (227, 89), (230, 90), (255, 100)] {
            #expect(BatterySample(rawValue: raw, receivedAt: date, source: "Razer").percent == percent)
        }
        for value in [BatteryValue.voltageOnly(millivolts: 4123), .approximateLevel(.low), .unknown, .notApplicable] {
            let sample = BatterySample(value: value, rawBytes: [0x10, 0x1B], receivedAt: date, source: "fixture")
            #expect(sample.percent == nil); #expect(sample.rawValue == nil)
            #expect(try JSONDecoder().decode(BatterySample.self, from: JSONEncoder().encode(sample)) == sample)
        }
        #expect(BatterySample(value: .percentage(101), receivedAt: date, source: "malformed").value == .unknown)
        #expect(BatterySample(value: .voltageOnly(millivolts: -1), receivedAt: date, source: "malformed").percent == nil)
    }

    @Test func settingsReadDoesNotDependOnBatteryAndHasIndependentFailure() throws {
        let caps = DeviceCapabilities(powerSource: .wired, operations: [.dpiRead: OperationCapability(evidence: .readVerified)])
        var store = DeviceStore(); let item = host(caps, receiver: false)
        store.reconcile([item], at: date)
        let physical = try #require(store.devices[item.descriptor.id])
        let logical = try #require(store.logicalDevices[.direct(item.descriptor.id)])
        #expect(!physical.canRefreshTelemetry); #expect(physical.canRefreshSettings)
        #expect(!logical.canRefreshTelemetry); #expect(logical.canRefreshSettings)
        let mutation1 = (store.beginSettingsRead(logical.sessionID, at: date)); #expect(mutation1)
        let snapshot = DeviceSettingsSnapshot(session: logical.sessionID, revision: 1, capturedAt: date, settings: DeviceSettings(currentDPI: DPISetting(800)))
        let mutation2 = (store.applySettings(snapshot)); #expect(mutation2)
        let error = TelemetryFailure(category: .timeout, message: "offline settings timeout")
        let mutation3 = (store.failSettingsRead(error, session: logical.sessionID, at: date.addingTimeInterval(1))); #expect(mutation3)
        #expect(store.logicalDevices[logical.id]?.settings == snapshot)
        #expect(store.logicalDevices[logical.id]?.batteryFailure == nil)
        #expect(store.logicalDevices[logical.id]?.lastSettingsFinishedAt == date.addingTimeInterval(1))
        let mutation4 = (!store.applySettings(snapshot)); #expect(mutation4)
    }

    @Test func childrenDoNotShareSamplesAndSlotReuseInvalidatesOldSession() throws {
        var store = DeviceStore(); let item = host(); store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID), pairing = UUID()
        let a = child(session, index: 1, unit: "A", epoch: pairing), b = child(session, index: 2, unit: "B", epoch: pairing)
        store.reconcileLogicalDevices([a, b], for: session)
        let oldA = try #require(store.logicalDevices[a.id]?.sessionID), oldB = try #require(store.logicalDevices[b.id]?.sessionID)
        let mutation5 = (store.apply(update(.percentage(20)), to: oldA)); #expect(mutation5)
        #expect(store.logicalDevices[b.id]?.battery == nil)
        let replacement = child(session, index: 1, unit: "C", epoch: pairing)
        let changes = store.reconcileLogicalDevices([replacement, b], for: session)
        #expect(changes.invalidated == [oldA]); #expect(store.logicalDevices[a.id]?.battery == nil)
        let mutation6 = (!store.apply(update(.percentage(99)), to: oldA)); #expect(mutation6); #expect(store.isCurrent(oldB))
        #expect(store.logicalDevices[b.id]?.sessionID == oldB)
    }

    @Test func anonymousSlotEpochHostReconnectAndDuplicateSlotFailClosed() throws {
        var store = DeviceStore(); let item = host(); store.reconcile([item], at: date)
        let hostSession = try #require(store.devices[item.descriptor.id]?.sessionID)
        let a = child(hostSession, index: 1, unit: nil, epoch: UUID())
        store.reconcileLogicalDevices([a], for: hostSession)
        let old = try #require(store.logicalDevices[a.id]?.sessionID)
        let replacement = child(hostSession, index: 1, unit: nil, epoch: UUID())
        store.reconcileLogicalDevices([replacement], for: hostSession)
        #expect(!store.isCurrent(old))
        let duplicate = try #require(store.logicalDevices[a.id]?.sessionID)
        store.reconcileLogicalDevices([replacement, replacement], for: hostSession)
        #expect(!store.isCurrent(duplicate))
        store.reconcile([], at: date); store.reconcile([item], at: date)
        #expect(!store.isCurrent(hostSession))
        let mutation7 = store.reconcileLogicalDevices([a], for: hostSession).added.isEmpty; #expect(mutation7)
        let mutation8 = (!store.apply(update(.percentage(10)), to: old)); #expect(mutation8)
    }

    @Test func receiverPreferenceCannotUseHostAliasOrModelOnlyIdentity() throws {
        var store = DeviceStore(); let item = host(), pairing = UUID()
        let hostIdentity = try #require(DevicePreferenceIdentity.derive(from: item.descriptor))
        store = DeviceStore(preferences: DevicePreferences(aliases: [hostIdentity.rawValue: "Legacy receiver alias"]))
        store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        let a = child(session, index: 1, unit: "A", epoch: pairing), b = child(session, index: 2, unit: nil, epoch: pairing)
        let poisoned = LogicalDeviceDescriptor(address: b.address, product: b.product, kind: b.kind, capabilities: b.capabilities,
            controlEndpointRegistryEntryID: 101, preferenceIdentity: hostIdentity)
        store.reconcileLogicalDevices([a, poisoned], for: session)
        #expect(store.logicalDevices[a.id]?.alias == nil); #expect(store.logicalDevices[b.id]?.alias == nil)
        #expect(store.logicalDevices[b.id]?.descriptor.preferenceIdentity == nil)
        store.setAlias("Child A", for: a.id)
        #expect(store.logicalDevices[b.id]?.alias == nil)
        #expect(store.preferences.aliases[hostIdentity.rawValue] == "Legacy receiver alias")
    }

    @Test func preferenceAndNotificationMigrationBackupExactBytesAndDoNotFanOut() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = Data("{\"aliases\":{\"legacy-host\":\"Desk\"},\"primaryIdentity\":\"legacy-host\"}".utf8)
        let file = FileDevicePreferences(url: folder.appendingPathComponent("preferences.json"))
        try old.write(to: file.url)
        var loaded = try file.load()
        #expect(loaded.schemaVersion == 2)
        #expect(try Data(contentsOf: file.url.appendingPathExtension("schema-v1.backup")) == old)
        let h = DevicePreferenceIdentity(kind: .portTopology, rawValue: "legacy-host")
        let a = DevicePreferenceIdentity(kind: .confirmedLogicalUnit, rawValue: "A"), b = DevicePreferenceIdentity(kind: .confirmedLogicalUnit, rawValue: "B")
        let mutation9 = (!loaded.migrateLegacyHost(h, to: [a, b], isDirectPeripheral: false)); #expect(mutation9)
        #expect(loaded.aliases[a.rawValue] == nil); #expect(loaded.primaryIdentity == h.rawValue)
        let mutation10 = (loaded.migrateLegacyHost(h, to: [a], isDirectPeripheral: true)); #expect(mutation10)
        #expect(loaded.aliases[a.rawValue] == "Desk"); #expect(loaded.primaryIdentity == a.rawValue)
        let notificationFile = FileNotificationPreferences(url: folder.appendingPathComponent("notifications.json"))
        let oldNotifications = Data("{\"isEnabled\":true,\"records\":{\"legacy-host\":{\"isArmed\":false}}}".utf8)
        try oldNotifications.write(to: notificationFile.url)
        var notifications = try notificationFile.load()
        #expect(try Data(contentsOf: notificationFile.url.appendingPathExtension("schema-v1.backup")) == oldNotifications)
        let mutation11 = (!notifications.migrateLegacyHost(h, to: [a, b], isDirectPeripheral: false)); #expect(mutation11)
        #expect(notifications.records[a.rawValue] == nil); #expect(notifications.records[b.rawValue] == nil)
        let mutation12 = (notifications.migrateLegacyHost(h, to: [a], isDirectPeripheral: true)); #expect(mutation12)
        #expect(notifications.records[a.rawValue]?.isArmed == false)
    }

    @Test func nativePercentageReplaceableBatteryCanNotifyWithoutChargingQuery() throws {
        let capabilities = DeviceCapabilities(battery: .verified, powerSource: .replaceableBattery)
        var store = DeviceStore(); let item = host(capabilities, receiver: false)
        store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(.percentage(20)), to: session)
        let state = try #require(store.devices[item.descriptor.id])
        #expect(LowBatteryPolicy().evaluate(state, at: date, record: LowBatteryRecord()) == .notify(percent: 20))
        for value in [BatteryValue.voltageOnly(millivolts: 1000), .approximateLevel(.critical), .unknown, .notApplicable] {
            store.apply(update(value), to: session)
            #expect(LowBatteryPolicy().evaluate(try #require(store.devices[item.descriptor.id]), at: date, record: LowBatteryRecord()) == .none)
        }
    }

    @Test func settingsRequirePerOperationEvidenceValidRangeXYAndPersistence() {
        var caps = DeviceCapabilities(battery: .verified, operations: [
            .dpiWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, persistenceScopes: [.runtime])),
            .independentXY: OperationCapability(evidence: .readVerified),
            .pollingRateWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [125, 500, 1000], persistenceScopes: [.runtime]))])
        #expect(DeviceSettingsChange(currentDPI: DPISetting(800)).validate(capabilities: caps).isEmpty)
        #expect(!DeviceSettingsChange(currentDPI: DPISetting(x: 800, y: 1600)).validate(capabilities: caps).isEmpty)
        caps.record(OperationCapability(evidence: .writeVerified), for: .independentXY)
        #expect(DeviceSettingsChange(currentDPI: DPISetting(x: 800, y: 1600)).validate(capabilities: caps).isEmpty)
        #expect(!DeviceSettingsChange(pollingRateHz: 8000).validate(capabilities: caps).isEmpty)
        #expect(!DeviceSettingsChange(currentDPI: DPISetting(825)).validate(capabilities: caps).isEmpty)
        #expect(!DeviceSettingsChange(currentDPI: DPISetting(800), persistence: .onboard).validate(capabilities: caps).isEmpty)
        #expect(!DeviceSettingsChange(activeProfileID: -1).validate(capabilities: caps).isEmpty)
        #expect(!DeviceSettingsChange().validate(capabilities: caps).isEmpty)
        #expect(!caps.permits(.stagesWrite)); #expect(!caps.permits(.onboardPersist))
    }

    @Test func readbackResultKeepsActualValuesAndDistinguishesPartialUnknownAndSuperseded() {
        let address = DeviceAddress.direct(DeviceSessionID(physicalDeviceID: host().descriptor.id))
        let session = LogicalDeviceSessionID(address: address)
        let before = DeviceSettingsSnapshot(session: session, revision: 1, capturedAt: date,
            settings: DeviceSettings(currentDPI: DPISetting(400), pollingRateHz: 500))
        let request = SettingChangeRequest(target: session, expectedRevision: 1, change: DeviceSettingsChange(currentDPI: DPISetting(800), pollingRateHz: 1000))
        let observed = DeviceSettingsSnapshot(session: session, revision: 2, capturedAt: date,
            settings: DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 500))
        let partial = SettingChangeResult.verifying(request: request, before: before, observed: observed, acknowledged: true, finishedAt: date)
        #expect(partial.status == .partialFailure); #expect(partial.observed?.settings.pollingRateHz == 500)
        #expect(partial.fields.first(where: { $0.field == .pollingRate })?.status == .readbackMismatch)
        #expect(SettingChangeResult.verifying(request: request, before: before, observed: nil, acknowledged: true, finishedAt: date).status == .outcomeUnknown)
        #expect(SettingChangeResult.verifying(request: request, before: before, observed: before, acknowledged: true, finishedAt: date).status == .superseded)
        let stale = SettingChangeRequest(target: session, expectedRevision: 0, change: request.change)
        #expect(SettingChangeResult.verifying(request: stale, before: before, observed: observed, acknowledged: true, finishedAt: date).status == .superseded)
    }
    @Test func transactionFailuresPreserveObservedMismatchesAndFailureWithoutReadback() {
        let session = LogicalDeviceSessionID(address: .direct(DeviceSessionID(physicalDeviceID: host().descriptor.id)))
        let before = DeviceSettingsSnapshot(session: session, revision: 1, capturedAt: date,
            settings: DeviceSettings(currentDPI: DPISetting(400), pollingRateHz: 500))
        let request = SettingChangeRequest(target: session, expectedRevision: 1,
            change: DeviceSettingsChange(currentDPI: DPISetting(800), pollingRateHz: 1000))
        let observed = DeviceSettingsSnapshot(session: session, revision: 2, capturedAt: date,
            settings: DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 500))
        let failure = TelemetryFailure(category: .malformedResponse, message: "Full image verification failed")
        let result = SettingChangeResult.verifying(request: request, before: before, observed: observed,
            acknowledged: false, finishedAt: date, failure: failure)
        #expect(result.status == .partialFailure)
        #expect(result.fields.first(where: { $0.field == .currentDPI })?.status == .outcomeUnknown)
        #expect(result.fields.first(where: { $0.field == .pollingRate })?.status == .readbackMismatch)
        #expect(result.fields.allSatisfy { $0.status != .verified })
        #expect(result.observed == observed)
        let unread = SettingChangeResult.verifying(request: request, before: before, observed: nil,
            acknowledged: true, finishedAt: date, failure: failure)
        #expect(unread.status == .outcomeUnknown); #expect(unread.message == failure.message)
        let stale = SettingChangeResult.verifying(request: request, before: before, observed: before,
            acknowledged: true, finishedAt: date, failure: failure)
        #expect(stale.status == .superseded)
    }

    @Test func logicalPrimarySelectionPersistsPerChildAndNotReceiverHost() throws {
        let item = host(), epoch = UUID()
        var store = DeviceStore(); store.reconcile([item], at: date)
        let hostSession = try #require(store.devices[item.descriptor.id]?.sessionID)
        let a = child(hostSession, index: 1, unit: "A", epoch: epoch), b = child(hostSession, index: 2, unit: "B", epoch: epoch)
        store.reconcileLogicalDevices([a, b], for: hostSession)
        store.setPrimaryLogical(b.id)
        #expect(store.primaryLogicalDeviceID == b.id)
        #expect(store.preferences.primaryIdentity == b.preferenceIdentity?.rawValue)
        var reloaded = DeviceStore(preferences: store.preferences); reloaded.reconcile([item], at: date)
        let newHost = try #require(reloaded.devices[item.descriptor.id]?.sessionID)
        reloaded.reconcileLogicalDevices([child(newHost, index: 1, unit: "A", epoch: UUID()), child(newHost, index: 2, unit: "B", epoch: UUID())], for: newHost)
        #expect(reloaded.primaryLogicalDeviceID == b.id)
        #expect(reloaded.logicalDevices[a.id]?.battery == nil)
    }
    @Test func logicalNotificationsRequireThisQueryAndExcludeCoarseVoltageAndChargingFailure() throws {
        let item = host(), epoch = UUID()
        var store = DeviceStore(); store.reconcile([item], at: date)
        let hostSession = try #require(store.devices[item.descriptor.id]?.sessionID)
        let a = child(hostSession, index: 1, unit: "A", epoch: epoch,
            capabilities: DeviceCapabilities(battery: .candidate, powerSource: .replaceableBattery))
        store.reconcileLogicalDevices([a], for: hostSession)
        let session = try #require(store.logicalDevices[a.id]?.sessionID)
        store.apply(update(.percentage(20)), to: session)
        #expect(LowBatteryPolicy().evaluate(try #require(store.logicalDevices[a.id]), at: date, record: LowBatteryRecord()) == .notify(percent: 20))
        let failure = TelemetryFailure(category: .timeout, message: "synthetic battery timeout")
        store.apply(DeviceTelemetryUpdate(startedAt: date.addingTimeInterval(1), finishedAt: date.addingTimeInterval(1),
            battery: nil, batteryFailure: failure, charging: nil, chargingFailure: nil), to: session)
        #expect(LowBatteryPolicy().evaluate(try #require(store.logicalDevices[a.id]), at: date.addingTimeInterval(1), record: LowBatteryRecord()) == .none)
        for value in [BatteryValue.voltageOnly(millivolts: 1000), .approximateLevel(.critical)] {
            store.apply(update(value), to: session)
            #expect(LowBatteryPolicy().evaluate(try #require(store.logicalDevices[a.id]), at: date, record: LowBatteryRecord()) == .none)
        }
    }

}
