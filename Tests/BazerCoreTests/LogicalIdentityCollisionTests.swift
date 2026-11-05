// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BazerCore

@Suite("Ambiguous logical unit identities never share durable preferences — offline")
struct LogicalIdentityCollisionTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private let identity = LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: "duplicate-unit")
    private func host(_ parent: UInt64) -> IdentifiedDevice {
        let endpoint = HIDInterfaceDescriptor(registryEntryID: parent * 10, usbParentRegistryEntryID: parent,
            vendorID: 0x046D, productID: 0xC539, product: "Offline host", transport: "USB", locationID: UInt32(parent * 100), primaryUsage: .mouse, usages: [.mouse])
        return IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([endpoint])[0], kind: .other, capabilities: .identificationOnly, isReceiver: true)
    }
    private func child(_ host: DeviceSessionID, slot: UInt8) -> LogicalDeviceDescriptor {
        LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: host, target: .receiver(index: slot, identity: identity), pairingGeneration: host.generation),
            product: "Offline child", kind: .mouse, capabilities: DeviceCapabilities(battery: .candidate, powerSource: .replaceableBattery), controlEndpointRegistryEntryID: 101)
    }
    @Test func explicitNilCannotBeReDerivedByDescriptorInitializer() {
        let host = DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "host")), automatic = child(DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "host")), slot: 1)
        let explicit = LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: host, target: .receiver(index: 1, identity: identity), pairingGeneration: host.generation),
            product: "child", kind: .mouse, capabilities: .identificationOnly, preferenceIdentity: nil, derivePreferenceIdentity: false)
        #expect(automatic.preferenceIdentity != nil); #expect(explicit.preferenceIdentity == nil)
        let ambiguous = LogicalDeviceDescriptor(address: explicit.address, product: "ambiguous", kind: .mouse,
            capabilities: .identificationOnly, isIdentityAmbiguous: true)
        #expect(ambiguous.preferenceIdentity == nil); #expect(ambiguous.peripheralIdentity == identity)
    }
    @Test func twoSlotsWithSameUnitCannotInheritAliasPrimaryOrNotificationHistory() throws {
        var store = DeviceStore(); let host = host(10); store.reconcile([host], at: now)
        let session = try #require(store.devices[host.descriptor.id]?.sessionID)
        let a = child(session, slot: 1), b = child(session, slot: 2)
        store.reconcileLogicalDevices([a, b], for: session)
        #expect(store.logicalDevices[a.id]?.descriptor.preferenceIdentity == nil)
        #expect(store.logicalDevices[b.id]?.descriptor.preferenceIdentity == nil)
        store.setAlias("Only A", for: a.id); store.setPrimaryLogical(a.id)
        #expect(store.preferences.aliases.isEmpty); #expect(store.preferences.primaryIdentity == nil)
        #expect(store.logicalDevices[b.id]?.alias == nil)
        store.reconcileLogicalDevices([a, b], for: session)
        for target in [a, b] {
            let logical = try #require(store.logicalDevices[target.id]?.sessionID)
            store.apply(DeviceTelemetryUpdate(startedAt: now, finishedAt: now, battery: BatterySample(value: .percentage(20), receivedAt: now, source: "offline"), batteryFailure: nil, charging: nil, chargingFailure: nil), to: logical)
            #expect(LowBatteryPolicy().evaluate(try #require(store.logicalDevices[target.id]), at: now, record: LowBatteryRecord()) == .none)
        }
        #expect(store.preferences.aliases.isEmpty)
    }
    @Test func crossHostCollisionIsQuarantinedAcrossRemovalAndPreferenceRoundTrip() throws {
        let first = host(10), second = host(20), key = try #require(DevicePreferenceIdentity.confirmedLogicalUnit(identity))
        var store = DeviceStore(preferences: DevicePreferences(aliases: [key.rawValue: "Original A"], primaryIdentity: key.rawValue))
        store.reconcile([first, second], at: now)
        let firstSession = try #require(store.devices[first.descriptor.id]?.sessionID), secondSession = try #require(store.devices[second.descriptor.id]?.sessionID)
        let a = child(firstSession, slot: 1), b = child(secondSession, slot: 1)
        store.reconcileLogicalDevices([a], for: firstSession)
        #expect(store.logicalDevices[a.id]?.alias == "Original A")
        store.reconcileLogicalDevices([b], for: secondSession)
        #expect(store.logicalDevices[a.id]?.descriptor.preferenceIdentity == nil); #expect(store.logicalDevices[b.id]?.descriptor.preferenceIdentity == nil)
        #expect(store.logicalDevices[a.id]?.alias == nil); #expect(store.logicalDevices[b.id]?.alias == nil)
        #expect(store.preferences.ambiguousIdentityKeys.contains(key.rawValue)); #expect(store.preferences.primaryIdentity == nil)
        store.reconcile([second], at: now); store.reconcileLogicalDevices([b], for: secondSession)
        #expect(store.logicalDevices[b.id]?.alias == nil)
        let saved = try JSONDecoder().decode(DevicePreferences.self, from: JSONEncoder().encode(store.preferences))
        var reloaded = DeviceStore(preferences: saved); reloaded.reconcile([second], at: now)
        let next = try #require(reloaded.devices[second.descriptor.id]?.sessionID)
        let surviving = child(next, slot: 1); reloaded.reconcileLogicalDevices([surviving], for: next)
        #expect(reloaded.logicalDevices[surviving.id]?.descriptor.preferenceIdentity == nil)
        #expect(reloaded.logicalDevices[surviving.id]?.alias == nil)
        #expect(reloaded.preferences.aliases[key.rawValue] == "Original A")
    }
}
