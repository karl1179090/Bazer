// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BazerCore

@Suite("Voltage estimate metadata — offline")
struct BatteryPercentageEstimateTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func estimate(_ value: Int = 55) throws -> BatteryPercentageEstimate {
        try #require(BatteryPercentageEstimate(value: value, source: "synthetic curve", resolution: "5% display steps; uncalibrated"))
    }
    @Test func estimateNeverChangesMeasuredVoltageOrNativePercentMeaning() throws {
        let sample = BatterySample(value: .voltageOnly(millivolts: 3845), rawBytes: [15, 5, 0], receivedAt: date,
            source: "HID++ 1001 runtime feature", percentageEstimate: try estimate())
        #expect(sample.value == .voltageOnly(millivolts: 3845)); #expect(sample.percent == nil)
        #expect(sample.millivolts == 3845); #expect(sample.rawBytes == [15, 5, 0]); #expect(sample.rawValue == nil)
        #expect(sample.source == "HID++ 1001 runtime feature"); #expect(!sample.isEstimated)
        #expect(sample.percentageEstimate?.isEstimated == true); #expect(sample.percentageEstimate?.isCalibrated == false)
        #expect(try JSONDecoder().decode(BatterySample.self, from: JSONEncoder().encode(sample)) == sample)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        let metadata = try #require(json["percentageEstimate"] as? [String: Any])
        #expect(metadata["isEstimated"] as? Bool == true); #expect(metadata["isCalibrated"] as? Bool == false)
        #expect(metadata["source"] as? String == "synthetic curve")
    }
    @Test func legacyJSONAndNonVoltageKindsNeverAcquireEstimate() throws {
        let old = BatterySample(value: .voltageOnly(millivolts: 3845), receivedAt: date, source: "old")
        #expect(try JSONDecoder().decode(BatterySample.self, from: JSONEncoder().encode(old)).percentageEstimate == nil)
        for value in [BatteryValue.percentage(50), .approximateLevel(.low), .unknown, .notApplicable, .voltageOnly(millivolts: -1)] {
            #expect(BatterySample(value: value, receivedAt: date, source: "test", percentageEstimate: try estimate()).percentageEstimate == nil)
        }
        #expect(BatteryPercentageEstimate(value: -1, source: "test", resolution: "test") == nil)
        #expect(BatteryPercentageEstimate(value: 101, source: "test", resolution: "test") == nil)
        #expect(BatteryPercentageEstimate(value: 55, source: "", resolution: "test") == nil)
        let original = BatterySample(value: .voltageOnly(millivolts: 3845), receivedAt: date, source: "test", percentageEstimate: try estimate())
        let encoded = try JSONEncoder().encode(original)
        for (key, invalid) in [("value", 101 as Any), ("isEstimated", false as Any), ("isCalibrated", true as Any)] {
            var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var metadata = try #require(json["percentageEstimate"] as? [String: Any]); metadata[key] = invalid; json["percentageEstimate"] = metadata
            let decoded = try JSONDecoder().decode(BatterySample.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded.percentageEstimate == nil); #expect(decoded.millivolts == 3845); #expect(decoded.source == "test")
        }
    }
    @Test func neitherPolicyPathUsesEstimateForNotificationOrRearm() throws {
        let endpoint = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 1, vendorID: 0x046D,
            productID: 0xC539, product: "Synthetic", transport: "USB", primaryUsage: .mouse)
        let host = IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([endpoint])[0], kind: .mouse,
            capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: 101)
        var store = DeviceStore(); store.reconcile([host], at: date)
        let hostSession = try #require(store.devices[host.descriptor.id]?.sessionID)
        let identity = LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: "synthetic-unit")
        let child = LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: hostSession, target: .receiver(index: 1, identity: identity), pairingGeneration: UUID()),
            product: "Synthetic GPW1", kind: .mouse, capabilities: host.capabilities, controlEndpointRegistryEntryID: 101)
        store.reconcileLogicalDevices([child], for: hostSession)
        let childSession = try #require(store.logicalDevices[child.id]?.sessionID)
        for percent in [5, 55] {
            let sample = BatterySample(value: .voltageOnly(millivolts: 3700), receivedAt: date, source: "test", percentageEstimate: try estimate(percent))
            let update = DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: sample, batteryFailure: nil,
                charging: ChargingSample(state: .discharging, rawValue: 0, receivedAt: date, source: "test"), chargingFailure: nil)
            store.apply(update, to: hostSession); store.apply(update, to: childSession)
            var direct = try #require(store.devices[host.descriptor.id]); direct.preferenceIdentity = DevicePreferenceIdentity(kind: .confirmedLogicalUnit, rawValue: "synthetic")
            let logical = try #require(store.logicalDevices[child.id])
            #expect(direct.capabilities.battery == .verified); #expect(logical.capabilities.battery == .verified)
            #expect(direct.access == .ready); #expect(logical.access == .ready)
            for record in [LowBatteryRecord(), LowBatteryRecord(isArmed: false)] {
                #expect(LowBatteryPolicy().evaluate(direct, at: date, record: record) == .none)
                #expect(LowBatteryPolicy().evaluate(logical, at: date, record: record) == .none)
            }
        }
    }
}
