// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import CryptoKit
import Foundation
import LogitechHIDPP

/// Values from one current, read-only peripheral handshake and complete CRC reads.
/// No host address, receiver slot, feature index or raw unit is a profile key.
struct LogitechHardwareObservation: Sendable {
    var hostVendorID: UInt16?
    var hostProductID: UInt16?
    var controlDescriptorSHA256: String
    var peripheralVendorID: UInt16
    var wirelessProductID: UInt16?
    var protocolVersion: String?
    var firmwareSHA256: String?
    var isReceiver: Bool
    var identityIsReliable: Bool
    var features: [HIDPPFeature]
    var dpiValues: [UInt16]
    var supportsIndependentXY: Bool
    var currentDPI: DPISetting
    var rateValues: [Int]
    var currentRate: HIDPPReportRate
    var onboardInfo: HIDPPOnboardInfo
    var onboardMode: UInt8
    var directory: HIDPPProfileSector
    var profile: HIDPPProfileSector
    var currentStageID: UInt8
}

/// Source-controlled hardware evidence is independent of candidate request grants.
/// It is never loaded from user files, a reference string, preferences or a cache.
enum LogitechVerifiedHardwareProfile {
    static let profileID="logitech.gpw1.c539.4079.2026-11-04"
    static let firmwareEncoding="hidpp-identity-firmware-utf8-v1"
    static let expectedFirmwareSHA256="6c3febc323a0ace99538346acc368605049c9c2c164bbad98e6ae13fdf492254"
    static let expectedDescriptorSHA256="d76eaabc974fc43a510e1580690aa52de12554d79f8215c8c9c86f5048d63d01"

    /// V1 hashes the exact UTF-8 firmware string emitted by the identity decoder:
    /// ordered entities joined with ';', each decimal kind + ':' + full uppercase
    /// hexadecimal response bytes. There is no normalization, prefix or truncation.
    static func firmwareSHA256(_ identityFirmware: String?) -> String? {
        guard let identityFirmware, !identityFirmware.isEmpty else { return nil }
        return SHA256.hash(data:Data(identityFirmware.utf8)).map { String(format:"%02x",$0) }.joined()
    }

    private struct FeatureSignature: Hashable, Sendable {
        let id: UInt16, flags: UInt8, version: UInt8
        init(_ id: UInt16,_ flags: UInt8,_ version: UInt8) { self.id=id; self.flags=flags; self.version=version }
        init(_ feature: HIDPPFeature) { self.init(feature.id,feature.flags,feature.version) }
    }
    private static let expectedFeatures: Set<FeatureSignature>=[
        .init(0x0000,0,1),.init(0x0001,0,1),.init(0x0003,0,2),.init(0x0005,0,0),
        .init(0x1D4B,0,0),.init(0x0020,0,0),.init(0x1001,0,2),.init(0x8070,0,4),
        .init(0x1300,0,0),.init(0x8100,0,0),.init(0x8110,0,0),.init(0x8060,0,0),
        .init(0x2201,0,1),.init(0x1802,0x60,0),.init(0x1803,0x60,0),.init(0x1805,0x60,0),
        .init(0x1806,0x60,4),.init(0x1811,0x60,0),.init(0x1830,0x60,0),.init(0x1890,0x60,2),
        .init(0x1891,0x60,2),.init(0x18A1,0x60,0),.init(0x1801,0x60,0),.init(0x18B1,0x60,0),
        .init(0x1DF3,0x60,0),.init(0x1E00,0x40,0),.init(0x1EB0,0x60,0),.init(0x1863,0x60,0),
        .init(0x1E22,0x60,0)
    ]
    private static let expectedDPIValues=Array(stride(from:UInt16(100),through:25600,by:50))
    private static let expectedRateValues=[125,250,500,1000]
    // Full 16-byte getInfo payload from the reviewed live configuration. Counts,
    // layout/flags and reserved bytes are part of the proof's metadata binding.
    private static let expectedOnboardInfoBytes: [UInt8]=[1,3,1,5,1,8,16,0,255,10,4,0,0,0,0,0]

    static func matches(_ observation: LogitechHardwareObservation) -> Bool {
        let info=observation.onboardInfo
        guard observation.hostVendorID == 0x046D, observation.hostProductID == 0xC539,
              observation.controlDescriptorSHA256 == expectedDescriptorSHA256,
              observation.peripheralVendorID == 0x046D, observation.wirelessProductID == 0x4079,
              observation.protocolVersion == "4.2", observation.firmwareSHA256 == expectedFirmwareSHA256,
              observation.isReceiver, observation.identityIsReliable,
              observation.features.count == expectedFeatures.count,
              Set(observation.features.map(FeatureSignature.init)) == expectedFeatures,
              observation.dpiValues == expectedDPIValues, !observation.supportsIndependentXY,
              observation.rateValues.sorted() == expectedRateValues, !observation.currentRate.extended,
              expectedRateValues.contains(observation.currentRate.hertz), observation.onboardMode == 1,
              info.rawBytes == expectedOnboardInfoBytes,
              info.memoryType == 1, info.profileFormat == 3, info.macroFormat == 1,
              info.sectorSize == 255, info.knownWritableLayout,
              observation.profile.info == info, observation.directory.info == info,
              observation.directory.sector == 0, observation.profile.sector > 0,
              observation.profile.sector < UInt16(info.sectorCount),
              observation.profile.bytes.count == 255, observation.directory.bytes.count == 255,
              let entries=try? HIDPPProfileDirectoryEntry.parse(observation.directory),
              entries.contains(where:{ $0.sector == observation.profile.sector && $0.enabled }),
              let values=observation.profile.dpiValues else { return false }
        let stages=values.enumerated().filter { $0.element > 0 }
        guard !stages.isEmpty, stages.allSatisfy({ expectedDPIValues.contains($0.element) }),
              stages.contains(where:{ $0.offset == Int(observation.currentStageID) }),
              stages.contains(where:{ $0.offset == Int(observation.profile.bytes[1]) }),
              observation.currentDPI == DPISetting(values[Int(observation.currentStageID)]),
              let storedRate=try? HIDPPReportRate(code:observation.profile.bytes[0],extended:false),
              storedRate == observation.currentRate else { return false }
        return true
    }

    private struct OrdinaryGrant: Sendable {
        let operation: DeviceOperation
        let evidence: CapabilityEvidence
        let source: String
    }
    // These source-controlled grants record reviewed physical evidence. They only
    // affect capabilities after every current observation matches this profile.
    static let ordinaryPromotionEnabled=true
    private static let runtimeEvidenceSource="builtin:\(profileID); docs/evidence/gpw1-live-baseline-2026-11-04.json; sha256:5e2c203d4b82022b7e21adace887166a82be76b33b4cb3d09a0997880c5588a6"
    private static let onboardEvidenceSource="builtin:\(profileID); docs/evidence/gpw1-live-persistence-2026-11-04.json; sha256:1b7997da0fba55890d8968c6a5925ed19d5c27f6f35ec199c7509962a447b895"
    private static let rateEvidenceSource="builtin:\(profileID); docs/evidence/gpw1-live-rate-readback-2026-11-04.json; sha256:e2392f8bbd5374cbefcf80073ceb537132b22fe89eb55204d354f7ed858f456c"
    private static let ordinaryGrants: [OrdinaryGrant]=[
        OrdinaryGrant(operation:.stageSelect,evidence:.writeVerified,source:runtimeEvidenceSource),
        OrdinaryGrant(operation:.stagesWrite,evidence:.writeVerified,source:onboardEvidenceSource),
        OrdinaryGrant(operation:.onboardPersist,evidence:.persistenceVerified,source:onboardEvidenceSource),
        OrdinaryGrant(operation:.pollingRateWrite,evidence:.writeVerified,source:rateEvidenceSource)
    ]

    static func promoting(_ capabilities: DeviceCapabilities, observation: LogitechHardwareObservation) -> DeviceCapabilities {
        guard ordinaryPromotionEnabled, matches(observation) else { return capabilities }
        var result=capabilities
        for grant in ordinaryGrants {
            let constraints: CapabilityConstraints
            switch grant.operation {
            case .stageSelect:
                guard grant.evidence == .writeVerified else { continue }
                let ids=(observation.profile.dpiValues ?? []).enumerated().filter { $0.element > 0 }.map(\.offset)
                constraints=CapabilityConstraints(allowedValues:ids,persistenceScopes:[.runtime])
            case .stagesWrite:
                guard grant.evidence == .writeVerified else { continue }
                constraints=CapabilityConstraints(allowedValues:observation.dpiValues.map(Int.init),maximumStages:5,persistenceScopes:[.onboard])
            case .pollingRateWrite:
                guard grant.evidence == .writeVerified else { continue }
                constraints=CapabilityConstraints(allowedValues:observation.rateValues,persistenceScopes:[.onboard])
            case .onboardPersist:
                guard grant.evidence == .persistenceVerified else { continue }
                constraints=CapabilityConstraints(persistenceScopes:[.onboard])
            default: continue
            }
            result.record(OperationCapability(evidence:grant.evidence,constraints:constraints,source:grant.source),for:grant.operation)
        }
        return result
    }
}
