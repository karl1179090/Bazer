// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
@testable import BazerDrivers
import Foundation
import LogitechHIDPP
import Testing

@Suite("Exact GPW1 voltage estimate — pure fixtures, no HID")
struct LogitechBatteryEstimateTests {
    private var context: LogitechBatteryEstimateContext {
        LogitechBatteryEstimateContext(hostVendorID: 0x046D, hostProductID: 0xC539,
            controlDescriptorSHA256: LogitechVerifiedHardwareProfile.expectedDescriptorSHA256,
            identity: LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: "synthetic-confirmed-unit",
                protocolVersion: "4.2", firmware: "1:01424F547402002600AADF85EE714A00;0:004D504D1502002601407985EE714A00;5:05000000000000A90000000000000000"),
            isReceiver: true, identityIsReliable: true, kind: .mouse,
            features: [HIDPPFeature(id: 0x1001, index: 17, flags: 0, version: 2)])
    }
    private func voltage(_ mv: Int = 3845, flags: UInt8 = 0) throws -> HIDPPBattery {
        try HIDPPBattery.parse(featureID: 0x1001, payload: [UInt8(mv >> 8), UInt8(mv & 255), flags])
    }
    @Test func sourcedCurveUsesFivePercentDisplayStepsWithoutChangingRawValue() throws {
        for (mv, expected) in [(3500,0),(3579,0),(3646,5),(3717,20),(3811,50),(3845,55),(3859,60),(4067,90),(4186,100)] {
            let raw = try voltage(mv)
            let estimate = try #require(LogitechBatteryPercentageEstimator.estimate(for: raw, context: context))
            #expect(estimate.value == expected); #expect(estimate.isEstimated); #expect(!estimate.isCalibrated)
            #expect(estimate.source.contains("e7304c4c451cc9bb4f206a914844525e67856a28"))
            #expect(estimate.resolution.contains("5%")); #expect(estimate.resolution.contains("未校准"))
            #expect(raw.level == .voltage(mv)); #expect(raw.status == 0)
        }
    }
    @Test func chargingUnknownAndCriticalFlagsNeverProduceSOC() throws {
        for flags in UInt8(1)...UInt8.max {
            #expect(LogitechBatteryPercentageEstimator.estimate(for: try voltage(flags: flags), context: context) == nil)
        }
    }
    @Test func outOfCurveAndNativeOrCoarseProtocolsStayUnchanged() throws {
        for mv in [0, 3499, 4187, 5000, 65535] {
            #expect(LogitechBatteryPercentageEstimator.estimate(for: try voltage(mv), context: context) == nil)
        }
        for native in [try HIDPPBattery.parse(featureID: 0x1000, payload: [50,20,0]),
                       try HIDPPBattery.parse(featureID: 0x1004, payload: [50,4,0,0], unifiedCapabilities: [15,3]),
                       try HIDPPBattery.parse(featureID: 0x1004, payload: [0,2,0,0], unifiedCapabilities: [15,1])] {
            #expect(LogitechBatteryPercentageEstimator.estimate(for: native, context: context) == nil)
        }
    }
    @Test(arguments: Array(0..<15)) func unprovenIdentityOrSchemaFailsClosed(dimension: Int) throws {
        var changed = context
        let original = changed.identity
        switch dimension {
        case 0: changed.hostVendorID = 0x1532
        case 1: changed.hostProductID = 0xC537
        case 2: changed.controlDescriptorSHA256 = "unproven"
        case 3: changed.identity = LogicalPeripheralIdentity(vendorID: 0, wirelessProductID: original.wirelessProductID, unitID: original.unitID, protocolVersion: original.protocolVersion, firmware: original.firmware)
        case 4: changed.identity = LogicalPeripheralIdentity(vendorID: original.vendorID, wirelessProductID: 0x4093, unitID: original.unitID, protocolVersion: original.protocolVersion, firmware: original.firmware)
        case 5: changed.identity = LogicalPeripheralIdentity(vendorID: original.vendorID, wirelessProductID: original.wirelessProductID, unitID: nil, protocolVersion: original.protocolVersion, firmware: original.firmware)
        case 6: changed.identity = LogicalPeripheralIdentity(vendorID: original.vendorID, wirelessProductID: original.wirelessProductID, unitID: original.unitID, protocolVersion: "4.3", firmware: original.firmware)
        case 7: changed.identity = LogicalPeripheralIdentity(vendorID: original.vendorID, wirelessProductID: original.wirelessProductID, unitID: original.unitID, protocolVersion: original.protocolVersion, firmware: "different")
        case 8: changed.isReceiver = false
        case 9: changed.identityIsReliable = false
        case 10: changed.kind = .keyboard
        case 11: changed.features = [HIDPPFeature(id: 0x1001, index: 17, flags: 0, version: 1)]
        case 12: changed.features = [HIDPPFeature(id: 0x1001, index: 17, flags: 1, version: 2)]
        case 13: changed.features = []
        default: changed.features.append(HIDPPFeature(id: 0x1004, index: 18, flags: 0, version: 0))
        }
        #expect(LogitechBatteryPercentageEstimator.estimate(for: try voltage(), context: changed) == nil)
    }
}
