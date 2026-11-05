// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import Testing
@testable import BazerApp

@Suite("Estimated voltage presentation — offline")
struct BatteryEstimatePresentationTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(estimate: Bool = true) throws -> BatterySample {
        BatterySample(value: .voltageOnly(millivolts: 3845), rawBytes: [15,5,0], receivedAt: date,
            source: "HID++ 1001 runtime feature", percentageEstimate: estimate ? try #require(BatteryPercentageEstimate(value: 55, source: "Solaar synthetic curve", resolution: "5% 显示步进；通用曲线，未校准；非原生百分比")) : nil)
    }
    @Test func estimateAlwaysHasApproximateLabelAndVoltageDetails() throws {
        let value = try sample()
        #expect(DevicePresentation.batteryText(value) == "约 55%")
        #expect(DevicePresentation.batteryText(value, showEstimate: false) == "3845 mV")
        let detail = DevicePresentation.batteryEstimateExplanation(value)
        #expect(detail?.contains("未校准") == true); #expect(detail?.contains("非原生") == true)
        #expect(value.percentageEstimate?.source.contains("Solaar") == true)
        #expect(DevicePresentation.batteryText(try sample(estimate: false)) == "3845 mV")
        #expect(DevicePresentation.batteryText(BatterySample(value: .percentage(55), receivedAt: date, source: "native")) == "55%")
    }
    @Test func logicalProjectionClearsEstimateOnFailureChargingReplacementExpiryAndRemoval() throws {
        let endpoint = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 1, vendorID: 0x046D,
            productID: 0xC539, product: "Synthetic", transport: "USB", primaryUsage: .mouse)
        let host = IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([endpoint])[0], kind: .other,
            capabilities: .identificationOnly, controlEndpointRegistryEntryID: 101, isReceiver: true)
        var store = DeviceStore(); store.reconcile([host], at: date)
        let hostSession = try #require(store.devices[host.descriptor.id]?.sessionID)
        let identity = LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: "synthetic-unit")
        let child = LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: hostSession, target: .receiver(index: 1, identity: identity), pairingGeneration: UUID()),
            product: "Synthetic GPW1", kind: .mouse, capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: 101)
        store.reconcileLogicalDevices([child], for: hostSession)
        let session = try #require(store.logicalDevices[child.id]?.sessionID)
        func update(_ value: BatterySample?, state: ChargingState = .discharging, failure: TelemetryFailure? = nil) -> DeviceTelemetryUpdate {
            DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: value, batteryFailure: failure,
                charging: failure == nil ? ChargingSample(state: state, rawValue: 0, receivedAt: date, source: "test") : nil, chargingFailure: failure)
        }
        store.apply(update(try sample()), to: session)
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date).batteryText == "约 55%")
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date).chargingText == "放电中")
        store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: nil, batteryFailure: nil,
            charging: ChargingSample(state: .charging, rawValue: 128, receivedAt: date, source: "test"), chargingFailure: nil), to: session)
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date).batteryText == "3845 mV")
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date).chargingText == "充电中")
        store.apply(update(try sample()), to: session)
        store.apply(update(nil, failure: TelemetryFailure(category: .timeout, message: "test")), to: session)
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date).batteryText == "--")
        #expect(store.logicalDevices[child.id]?.battery?.percentageEstimate?.value == 55) // History survives without becoming current.
        store.apply(update(try sample(estimate: false), state: .charging), to: session)
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date).batteryText == "3845 mV")
        store.apply(update(try sample()), to: session)
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date.addingTimeInterval(180)).batteryText == "--")
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date.addingTimeInterval(180)).chargingText == "充电状态未知")
        store.reconcile([], at: date.addingTimeInterval(1))
        #expect(LogicalDevicePresentation(try #require(store.logicalDevices[child.id]), at: date).batteryText == "--")
    }
}
