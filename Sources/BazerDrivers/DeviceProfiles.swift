// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore

public struct RazerDeviceProfile: Equatable, Codable, Sendable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let productName: String
    public let reportID: UInt8
    public let frameLength: Int
    public let transactionID: UInt8

    // A candidate protocol configuration, not a claim of successful hardware telemetry.
    public static let deathAdderV3HyperSpeed = RazerDeviceProfile(
        vendorID: 0x1532, productID: 0x00C5, productName: "Razer DeathAdder V3 HyperSpeed",
        reportID: 0, frameLength: 90, transactionID: 0x1F
    )

    public func matches(_ device: PhysicalDeviceDescriptor) -> Bool {
        device.isExternalUSB && !device.interfaces.isEmpty && device.interfaces.allSatisfy {
            $0.vendorID == vendorID && $0.productID == productID
        } && device.allUsages.contains(.mouse)
    }
}

public enum InterfaceRejectionReason: String, Codable, Sendable {
    case physicalDeviceMismatch, notExternalUSB, notMouseUsage, missingDescriptor,
         malformedDescriptor, explicitReportID, missingFeatureLayout, featureLengthMismatch
}

public struct InterfaceRejection: Equatable, Codable, Sendable {
    public let registryEntryID: UInt64
    public let reasons: [InterfaceRejectionReason]
}

public enum InterfaceSelectionIssue: String, Codable, Sendable { case noCandidate, ambiguousCandidates }

public struct InterfaceSelection: Equatable, Codable, Sendable {
    public let selected: HIDInterfaceDescriptor?
    public let candidates: [HIDInterfaceDescriptor]
    public let rejections: [InterfaceRejection]
    public let issue: InterfaceSelectionIssue?
}

public enum InterfaceSelector {
    /// Rejection details are diagnostics; more than one valid endpoint is never guessed.
    public static func razerControlInterface(
        in device: PhysicalDeviceDescriptor,
        profile: RazerDeviceProfile = .deathAdderV3HyperSpeed
    ) -> InterfaceSelection {
        var candidates: [HIDInterfaceDescriptor] = []
        var rejected: [InterfaceRejection] = []
        for descriptor in device.interfaces {
            var reasons: [InterfaceRejectionReason] = []
            if !profile.matches(device) { reasons.append(.physicalDeviceMismatch) }
            if !descriptor.isExternalUSB { reasons.append(.notExternalUSB) }
            if !descriptor.allUsages.contains(.mouse) { reasons.append(.notMouseUsage) }
            if descriptor.reportDescriptor.isEmpty {
                reasons.append(.missingDescriptor)
            } else if let summary = descriptor.descriptorSummary {
                if !summary.explicitReportIDs.isEmpty { reasons.append(.explicitReportID) }
                if !summary.hasReport(kind: .feature, reportID: profile.reportID, byteCount: profile.frameLength) {
                    reasons.append(.missingFeatureLayout)
                }
            } else {
                reasons.append(.malformedDescriptor)
            }
            if descriptor.maxFeatureReportSize != profile.frameLength { reasons.append(.featureLengthMismatch) }
            if reasons.isEmpty { candidates.append(descriptor) }
            else { rejected.append(InterfaceRejection(registryEntryID: descriptor.registryEntryID, reasons: reasons)) }
        }
        let issue: InterfaceSelectionIssue? = candidates.isEmpty ? .noCandidate : (candidates.count > 1 ? .ambiguousCandidates : nil)
        return InterfaceSelection(selected: candidates.count == 1 ? candidates[0] : nil, candidates: candidates, rejections: rejected, issue: issue)
    }
}

public enum GenericKeyboardDriver {
    /// Identification only. A keyboard collection provides no battery capability.
    public static func supports(_ device: PhysicalDeviceDescriptor) -> Bool {
        device.isExternalUSB && device.allUsages.contains(.keyboard)
            && !RazerDeviceProfile.deathAdderV3HyperSpeed.matches(device)
    }
    public static let capabilities = DeviceCapabilities.identificationOnly
}
