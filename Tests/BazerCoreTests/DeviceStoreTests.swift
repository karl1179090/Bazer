// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import Testing

private func storedDevice(_ parent: UInt64 = 10, endpoint: UInt64 = 101, location: UInt32? = 1000) -> IdentifiedDevice {
    let descriptor = HIDInterfaceDescriptor(registryEntryID: endpoint, usbParentRegistryEntryID: parent,
        vendorID: 0x1532, productID: 0x00C5, product: "Synthetic mouse", transport: "USB", locationID: location,
        primaryUsage: .mouse, usages: [.mouse], maxFeatureReportSize: 90,
        reportDescriptor: [0x05, 1, 0x09, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0])
    return IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([descriptor])[0], kind: .mouse,
        capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: endpoint)
}

private func storeUpdate(at date: Date, raw: UInt8? = nil, charging: ChargingState? = nil, failure: TelemetryFailure? = nil) -> DeviceTelemetryUpdate {
    DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
        battery: raw.map { BatterySample(rawValue: $0, receivedAt: date, source: "synthetic") },
        batteryFailure: raw == nil ? failure : nil,
        charging: charging.map { ChargingSample(state: $0, rawValue: $0 == .charging ? 1 : 0, receivedAt: date, source: "synthetic") },
        chargingFailure: charging == nil ? failure : nil)
}

struct DeviceStoreTests {
    @Test func legacyScalarCapabilityConstraintsDecodeWithoutAddingPairPermissions() throws {
        let raw = Data(#"{"allowedValues":[800,1600],"persistenceScopes":["onboard"]}"#.utf8)
        let constraints = try JSONDecoder().decode(CapabilityConstraints.self, from: raw)
        #expect(constraints.allowedDPIPairs == nil)
        #expect(constraints.accepts(DPISetting(x: 800, y: 1600)))
        let explicit = CapabilityConstraints(allowedValues: [800, 1600], persistenceScopes: [.onboard],
            allowedDPIPairs: [DPISetting(800), DPISetting(x: 800, y: 1600)])
        #expect(explicit.accepts(DPISetting(x: 800, y: 1600)))
        #expect(!explicit.accepts(DPISetting(x: 1600, y: 800)))
        #expect(!explicit.accepts(DPISetting(1600)))
        #expect(try JSONDecoder().decode(CapabilityConstraints.self, from: JSONEncoder().encode(explicit)) == explicit)
    }
    @Test func settingsWriteEvidenceIsSessionBoundAndDoesNotReplaceTelemetryCapabilities() throws {
        var store = DeviceStore(); let item = storedDevice(), date = Date(timeIntervalSince1970: 1000)
        store.reconcile([item], at: date)
        let id = LogicalDeviceID.direct(item.descriptor.id), session = try #require(store.logicalDevices[id]?.sessionID)
        let snapshot = DeviceSettingsSnapshot(session: session, revision: 1, capturedAt: date, settings: DeviceSettings(currentDPI: DPISetting(800)))
        let writes: [DeviceOperation: OperationCapability] = [
            .dpiWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [800, 1600], persistenceScopes: [.onboard])),
            .batteryRead: OperationCapability(evidence: .unsupported)
        ]
        let applied = store.applySettings(snapshot, capabilityUpdates: writes)
        #expect(applied)
        #expect(store.logicalDevices[id]?.capabilities.permits(.dpiWrite) == true)
        #expect(store.logicalDevices[id]?.capabilities[.batteryRead].evidence == .catalogued)
        let revoked = store.failSettingsRead(TelemetryFailure(category: .timeout, message: "offline failure"), session: session, at: date,
            capabilityUpdates: [.dpiWrite: OperationCapability()])
        #expect(revoked)
        #expect(store.logicalDevices[id]?.capabilities.permits(.dpiWrite) == false)
        store.reconcile([], at: date); store.reconcile([item], at: date)
        let fresh = try #require(store.logicalDevices[id]?.sessionID)
        #expect(fresh != session)
        let staleApplied = store.applySettings(snapshot, capabilityUpdates: writes)
        let staleFailed = store.failSettingsRead(TelemetryFailure(category: .timeout, message: "late failure"), session: session, at: date, capabilityUpdates: writes)
        #expect(!staleApplied); #expect(!staleFailed)
        #expect(store.logicalDevices[id]?.capabilities.permits(.dpiWrite) == false)
    }
    @Test func initialUnknownAndIndependentExpiryPreserveActualSampleTimes() throws {
        var store = DeviceStore(); let item = storedDevice(); let start = Date(timeIntervalSince1970: 1000)
        store.reconcile([item], at: start)
        let initial = try #require(store.devices[item.descriptor.id])
        #expect(initial.battery == nil); #expect(initial.charging == nil)
        #expect(initial.currentBattery(at: start) == nil); #expect(initial.currentCharging(at: start) == .unknown)
        let battery = BatterySample(rawValue: 0, receivedAt: start, source: "synthetic")
        let charging = ChargingSample(state: .charging, rawValue: 1, receivedAt: start.addingTimeInterval(10), source: "synthetic")
        store.apply(DeviceTelemetryUpdate(startedAt: start, finishedAt: start.addingTimeInterval(10), battery: battery,
            batteryFailure: nil, charging: charging, chargingFailure: nil), to: initial.sessionID)
        let state = try #require(store.devices[item.descriptor.id])
        #expect(state.currentBattery(at: start.addingTimeInterval(179))?.percent == 0)
        #expect(state.currentBattery(at: start.addingTimeInterval(180)) == nil)
        #expect(state.currentCharging(at: start.addingTimeInterval(180)) == .charging)
        #expect(state.currentCharging(at: start.addingTimeInterval(190)) == .unknown)
        #expect(state.battery?.receivedAt == start); #expect(state.charging?.receivedAt == start.addingTimeInterval(10))
    }

    @Test func chargingFailureIsUnknownAndBatteryFailureNeverRefreshesHistory() throws {
        var store = DeviceStore(); let item = storedDevice(), start = Date(timeIntervalSince1970: 1000)
        store.reconcile([item], at: start); let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(storeUpdate(at: start, raw: 128, charging: .charging), to: session)
        let failure = TelemetryFailure(category: .deviceStatus, message: "0x04", protocolStatus: 4)
        store.apply(storeUpdate(at: start.addingTimeInterval(60), raw: 129, failure: failure), to: session)
        var state = try #require(store.devices[item.descriptor.id])
        #expect(state.battery?.rawValue == 129); #expect(state.currentCharging(at: start.addingTimeInterval(60)) == .unknown)
        #expect(state.charging?.receivedAt == start); #expect(state.consecutiveFailures == 0)
        #expect(state.nextRefreshAt == start.addingTimeInterval(120))
        store.apply(storeUpdate(at: start.addingTimeInterval(120), failure: failure), to: session)
        state = try #require(store.devices[item.descriptor.id])
        #expect(state.battery?.receivedAt == start.addingTimeInterval(60))
        #expect(state.battery?.rawValue == 129); #expect(state.peerPresence == .unknown)
        #expect(state.batteryFailure?.protocolStatus == 4)
    }

    @Test func failureBackoffAndSuccessRecovery() throws {
        var store = DeviceStore(); let item = storedDevice(), start = Date(timeIntervalSince1970: 1000)
        store.reconcile([item], at: start); let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        let failure = TelemetryFailure(category: .denied, message: "synthetic denial")
        for (offset, delay) in [(0.0, 60.0), (60, 120), (180, 300), (480, 300)] {
            let date = start.addingTimeInterval(offset)
            store.apply(storeUpdate(at: date, failure: failure), to: session)
            #expect(store.devices[item.descriptor.id]?.nextRefreshAt == date.addingTimeInterval(delay))
            #expect(store.devices[item.descriptor.id]?.access == .denied)
            #expect(store.devices[item.descriptor.id]?.capabilities.battery == .candidate)
        }
        store.apply(storeUpdate(at: start.addingTimeInterval(780), raw: 255, charging: .notCharging), to: session)
        let state = try #require(store.devices[item.descriptor.id])
        #expect(state.consecutiveFailures == 0); #expect(state.nextRefreshAt == start.addingTimeInterval(840))
        #expect(state.capabilities.battery == .verified); #expect(state.access == .ready)
    }

    @Test func removalAndReconnectOfSameIDRejectOldGeneration() throws {
        var store = DeviceStore(); let item = storedDevice(), date = Date(timeIntervalSince1970: 1000)
        store.reconcile([item], at: date); let old = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(storeUpdate(at: date, raw: 128, charging: .charging), to: old)
        #expect(store.reconcile([], at: date).invalidated == [old])
        let removedApplied = store.apply(storeUpdate(at: date, raw: 255), to: old)
        #expect(!removedApplied)
        #expect(store.devices[item.descriptor.id]?.hostPresence == .removed)
        #expect(store.devices[item.descriptor.id]?.currentBattery(at: date) == nil)
        store.reconcile([item], at: date); let new = try #require(store.devices[item.descriptor.id]?.sessionID)
        #expect(new != old); #expect(store.devices[item.descriptor.id]?.battery == nil)
        let oldApplied = store.apply(storeUpdate(at: date, raw: 255), to: old)
        let newApplied = store.apply(storeUpdate(at: date, raw: 0), to: new)
        #expect(!oldApplied); #expect(newApplied)
        #expect(store.devices[item.descriptor.id]?.battery?.rawValue == 0)
    }

    @Test func endpointReplacementInvalidatesAndSameModelDevicesAreIsolated() throws {
        var store = DeviceStore(); let first = storedDevice(), second = storedDevice(20, endpoint: 201, location: 2000)
        let date = Date(timeIntervalSince1970: 1000)
        store.reconcile([first, second], at: date)
        let old = try #require(store.devices[first.descriptor.id]?.sessionID)
        store.apply(storeUpdate(at: date, raw: 128), to: old)
        #expect(store.devices[second.descriptor.id]?.battery == nil)
        let replacement = storedDevice(endpoint: 102)
        let change = store.reconcile([replacement, second], at: date)
        #expect(change.invalidated == [old]); #expect(store.devices[first.descriptor.id]?.battery == nil)
        let oldApplied = store.apply(storeUpdate(at: date, raw: 255), to: old)
        #expect(!oldApplied)
    }

    @Test func preferenceRoundTripOnlyRestoresAliasAndPrimaryAtSamePort() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = FileDevicePreferences(url: folder.appendingPathComponent("preferences.json"))
        var store = DeviceStore(); let first = storedDevice(), second = storedDevice(20, endpoint: 201, location: 2000)
        let date = Date(timeIntervalSince1970: 1000)
        store.reconcile([first, second], at: date)
        store.setAlias("  Desk mouse  ", for: first.descriptor.id); store.setPrimary(first.descriptor.id)
        let session = try #require(store.devices[first.descriptor.id]?.sessionID)
        store.apply(storeUpdate(at: date, raw: 227, charging: .notCharging), to: session)
        try persistence.save(store.preferences)
        let serialized = try String(contentsOf: persistence.url, encoding: .utf8)
        #expect(!serialized.contains("rawValue")); #expect(!serialized.contains("receivedAt"))
        #expect(!serialized.contains("registry")); #expect(!serialized.contains("usb-parent"))
        var relaunched = DeviceStore(preferences: try persistence.load())
        let samePortNewRegistry = storedDevice(99, endpoint: 909, location: 1000)
        relaunched.reconcile([samePortNewRegistry, second], at: date)
        #expect(relaunched.devices[samePortNewRegistry.descriptor.id]?.alias == "Desk mouse")
        #expect(relaunched.primaryDeviceID == samePortNewRegistry.descriptor.id)
        #expect(relaunched.devices[samePortNewRegistry.descriptor.id]?.battery == nil)
        #expect(relaunched.devices[samePortNewRegistry.descriptor.id]?.charging == nil)
        let changedPort = storedDevice(88, endpoint: 808, location: 3000)
        relaunched.reconcile([changedPort, second], at: date)
        #expect(relaunched.devices[changedPort.descriptor.id]?.alias == nil)
    }

    @Test func ambiguousOrMissingTopologyNeverPersistsAliasesByVIDPID() throws {
        var store = DeviceStore(); let first = storedDevice(), collision = storedDevice(20, endpoint: 201, location: 1000)
        let missing = storedDevice(30, endpoint: 301, location: nil)
        store.reconcile([first, collision, missing], at: Date())
        for item in [first, collision, missing] {
            #expect(store.devices[item.descriptor.id]?.preferenceIdentity == nil)
            store.setAlias("ephemeral", for: item.descriptor.id)
        }
        #expect(store.preferences.aliases.isEmpty)
        store.setPrimary(missing.descriptor.id); #expect(store.preferences.primaryIdentity == nil)
    }
}
