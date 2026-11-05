// SPDX-License-Identifier: GPL-3.0-or-later
// Curve and interpolation adapted from Solaar, GPL-2.0-or-later:
// Copyright (C) 2012-2013 Daniel Pavel
// Copyright (C) 2014-2024 Solaar Contributors https://pwr-solaar.github.io/Solaar/
// Fixed source and limitations are recorded in THIRD_PARTY_NOTICES.md.
import BazerCore
import Foundation
import LogitechHIDPP

/// Telemetry-only identity context. It cannot grant settings or protocol writes.
struct LogitechBatteryEstimateContext {
    var hostVendorID: UInt16?
    var hostProductID: UInt16?
    var controlDescriptorSHA256: String
    var identity: LogicalPeripheralIdentity
    var isReceiver: Bool
    var identityIsReliable: Bool
    var kind: DeviceKind
    var features: [HIDPPFeature]
}

enum LogitechBatteryPercentageEstimator {
    static let source = "https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L2280-L2319"
    static let resolution = "5% 显示步进；通用电压曲线，未校准；非原生百分比"
    // A nonlinear generic curve, with interpolation only between adjacent points.
    // Five-percent quantization deliberately avoids implying one-percent accuracy.
    private static let curve: [(millivolts: Int, percent: Int)] = [
        (3500,0),(3579,2),(3646,5),(3671,10),(3717,20),(3751,30),(3778,40),
        (3811,50),(3859,60),(3922,70),(3989,80),(4067,90),(4186,100)
    ]

    static func estimate(for battery: HIDPPBattery, context: LogitechBatteryEstimateContext) -> BatteryPercentageEstimate? {
        let identity = context.identity
        guard context.hostVendorID == 0x046D, context.hostProductID == 0xC539,
              context.controlDescriptorSHA256 == LogitechVerifiedHardwareProfile.expectedDescriptorSHA256,
              identity.vendorID == 0x046D, identity.wirelessProductID == 0x4079,
              identity.protocolVersion == "4.2",
              LogitechVerifiedHardwareProfile.firmwareSHA256(identity.firmware) == LogitechVerifiedHardwareProfile.expectedFirmwareSHA256,
              identity.unitID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              context.isReceiver, context.identityIsReliable, context.kind == .mouse,
              context.features.filter({ $0.id == 0x1001 }).count == 1,
              context.features.contains(where: { $0.id == 0x1001 && $0.version == 2 && $0.flags == 0 }),
              !context.features.contains(where: { $0.id == 0x1000 || $0.id == 0x1004 }),
              battery.featureID == 0x1001, battery.status == 0,
              case let .voltage(millivolts) = battery.level,
              (3500...4186).contains(millivolts) else { return nil }
        // flags == 0 is the captured, definite discharge state. Charging, critical,
        // unknown or unexplained bits do not get converted to numerical SOC.
        for (lower, upper) in zip(curve, curve.dropFirst()) where millivolts <= upper.millivolts {
            let percent = Double(lower.percent) + Double(upper.percent - lower.percent)
                * Double(millivolts - lower.millivolts) / Double(upper.millivolts - lower.millivolts)
            let displayed = Int((percent / 5).rounded()) * 5
            return BatteryPercentageEstimate(value: displayed, source: source, resolution: resolution)
        }
        return nil
    }
}
