// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
@testable import BazerDrivers
import CryptoKit
import Foundation
import Testing

enum RazerVerifiedTestFixtures {
    static let unitID = "razer-serial-sha256:" + SHA256.hash(data: Data(Array("Bazer/RazerBackupIdentity/v1".utf8)
        + [0x15, 0x32, 0, 0xC5] + Array("OFFLINE-UNIT-123".utf8))).map { String(format: "%02x", $0) }.joined()
    static func profile(descriptorSHA256: String = String(repeating: "a", count: 64), persisted: Bool = false, xy: Bool = false) -> RazerVerifiedHardwareProfile {
        RazerVerifiedHardwareProfile(id: "offline.synthetic.razer", descriptorSHA256: descriptorSHA256,
            firmware: "1.2", unitID: unitID, dpiValues: [400, 800, 1600, 1800, 3200],
            independentDPIValues: xy ? [DPISetting(x: 800, y: 1600), DPISetting(x: 1600, y: 800)] : [], pollingRateValues: [125, 500, 1000],
            persistedSettings: persisted ? [xy ? RazerPersistedCurrentSettings(x: 800, y: 1600, pollingRateHz: 500) : RazerPersistedCurrentSettings(dpi: 1600, pollingRateHz: 500)] : [],
            writeEvidenceSource: "offline synthetic test; never physical evidence", persistenceEvidenceSource: persisted ? "offline synthetic persistence" : nil)
    }
}

@Suite("Razer hardware evidence limits — pure values only")
struct RazerVerifiedHardwareProfileTests {
    private func observation(profile: RazerVerifiedHardwareProfile, session: LogicalDeviceSessionID,
                             variant: Int = -1) -> RazerHardwareObservation {
        RazerHardwareObservation(session: variant == 0 ? LogicalDeviceSessionID(address: session.address) : session,
            identity: ProfileBackupIdentity(vendorID: variant == 1 ? 0x046D : 0x1532, productID: variant == 2 ? 0x00C6 : 0x00C5,
                unitID: variant == 3 ? nil : variant == 4 ? "razer-serial-sha256:" + String(repeating: "b", count: 64) : profile.unitID,
                firmware: variant == 5 ? "1.3" : profile.firmware, formatID: "razer.00c5.dpi-stage-payload", formatVersion: 0,
                descriptorSHA256: variant == 6 ? String(repeating: "b", count: 64) : profile.descriptorSHA256),
            identityIsAmbiguous: variant == 7, currentDPI: variant == 8 ? nil : variant == 9 ? DPISetting(x: 800, y: 1200) : variant == 10 ? DPISetting(850) : DPISetting(800),
            dpiStorage: variant == 11 ? 0 : 1, pollingRateHz: variant == 12 ? nil : variant == 13 ? 250 : 1000,
            hasCompleteStageImage: variant != 14, readFailed: variant == 15)
    }
    private var session: LogicalDeviceSessionID {
        LogicalDeviceSessionID(address: .direct(DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "usb-parent:10"))))
    }
    @Test func publishedProfilesKeepNarrowDomainsAndRejectOtherUnitsAndFirmware() throws {
        let profile = try #require(RazerVerifiedHardwareProfile.reviewed.first), session = session
        #expect(RazerVerifiedHardwareProfile.reviewed.count == 1)
        #expect(profile.matches(observation(profile: profile, session: session), session: session))
        for variant in 0...15 {
            #expect(!profile.matches(observation(profile: profile, session: session, variant: variant), session: session))
        }
        let capabilities = DeviceCapabilities(operations: profile.capabilityUpdates)
        #expect(capabilities[.dpiWrite].constraints.allowedValues == [400, 800, 1600, 3200])
        #expect(capabilities[.dpiWrite].constraints.allowedDPIPairs != nil)
        #expect(capabilities[.pollingRateWrite].constraints.allowedValues == [125, 500, 1000])
        #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(850), persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(pollingRateHz: 250, persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(pollingRateHz: 8000, persistence: .onboard)))
        for operation in [DeviceOperation.stagesWrite, .stageSelect, .onboardWrite] { #expect(!capabilities.permits(operation)) }
    }
    @Test func publishedXYAndColdEvidenceApplyOnlyToTheExactMeasuredCombinations() throws {
        let profile = try #require(RazerVerifiedHardwareProfile.reviewed.first)
        let capabilities = DeviceCapabilities(operations: profile.capabilityUpdates)
        let pairs = [DPISetting(400), DPISetting(800), DPISetting(x: 800, y: 1600),
            DPISetting(x: 1600, y: 800), DPISetting(1600), DPISetting(3200)]
        #expect(capabilities[.dpiWrite].constraints.allowedDPIPairs == pairs)
        #expect(capabilities[.independentXY].constraints.allowedDPIPairs == [DPISetting(x: 800, y: 1600), DPISetting(x: 1600, y: 800)])
        #expect(capabilities.permits(.independentXY))
        #expect(capabilities[.onboardPersist].evidence == .writeVerified)
        #expect(profile.persistedSettings == [RazerPersistedCurrentSettings(x: 800, y: 1600, pollingRateHz: 500)])
        #expect(profile.persistenceEvidenceSource?.contains("39efcf566e6a104f682b90935f05d41b55146e6b77ef818fb688a95abdb2da78") == true)
        #expect(capabilities[.independentXY].source?.contains("39efcf566e6a104f682b90935f05d41b55146e6b77ef818fb688a95abdb2da78") == true)
        for x in [UInt16(400), 800, 1600, 3200] {
            for y in [UInt16(400), 800, 1600, 3200] {
                for rate in [125, 500, 1000] {
                    let pair = DPISetting(x: x, y: y)
                    let change = DeviceSettingsChange(currentDPI: pair, pollingRateHz: rate, persistence: .onboard)
                    #expect(profile.permits(change) == pairs.contains(pair), "\(x)/\(y) @ \(rate)")
                    let expected: SettingPersistence = x == 800 && y == 1600 && rate == 500 ? .onboard : .unknown
                    #expect(profile.persistence(for: change, observed: DeviceSettings(currentDPI: pair, pollingRateHz: rate)) == expected,
                        "Power-removal evidence must not spread from 800/1600 @ 500 to \(x)/\(y) @ \(rate)")
                }
            }
        }
        for rate in [250, 2000, 4000, 8000] {
            #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(x: 800, y: 1600), pollingRateHz: rate, persistence: .onboard)))
        }
        #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(x: 800, y: 1600), persistence: .runtime)))
    }
    @Test(arguments: Array(0...15)) func nonExactIdentityOrIncompleteCurrentReadNeverPromotes(variant: Int) {
        let profile = RazerVerifiedTestFixtures.profile(), session = session
        #expect(!profile.matches(observation(profile: profile, session: session, variant: variant), session: session))
    }
    @Test func onlyTestedUnifiedValuesAndStorageScopeArePermitted() {
        let profile = RazerVerifiedTestFixtures.profile(), session = session
        #expect(profile.matches(observation(profile: profile, session: session), session: session))
        let capabilities = DeviceCapabilities(operations: profile.capabilityUpdates)
        for operation in DeviceOperation.allCases where operation.isWrite {
            #expect(capabilities.permits(operation) == [.dpiWrite, .pollingRateWrite, .onboardPersist].contains(operation))
        }
        #expect(capabilities[.dpiWrite].constraints.allowedValues == [400, 800, 1600, 1800, 3200])
        #expect(capabilities[.dpiWrite].constraints.minimum == nil)
        #expect(profile.permits(DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(850), persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(x: 800, y: 1600), persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .runtime)))
        #expect(!profile.permits(DeviceSettingsChange(pollingRateHz: 250, persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(pollingRateHz: 8000, persistence: .onboard)))
        #expect(capabilities[.onboardPersist].evidence == .writeVerified)
        #expect(profile.persistence(for: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard),
            observed: DeviceSettings(currentDPI: DPISetting(1600), pollingRateHz: 500)) == .unknown)
    }
    @Test func persistenceEvidenceDoesNotSpreadToOtherTestedWriteValues() {
        let profile = RazerVerifiedTestFixtures.profile(persisted: true)
        #expect(profile.persistence(for: DeviceSettingsChange(currentDPI: DPISetting(1600), pollingRateHz: 500, persistence: .onboard),
            observed: DeviceSettings(currentDPI: DPISetting(1600), pollingRateHz: 500)) == .onboard)
        #expect(profile.persistence(for: DeviceSettingsChange(currentDPI: DPISetting(800), pollingRateHz: 500, persistence: .onboard),
            observed: DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 500)) == .unknown)
        #expect(profile.persistence(for: DeviceSettingsChange(currentDPI: DPISetting(1600), pollingRateHz: 1000, persistence: .onboard),
            observed: DeviceSettings(currentDPI: DPISetting(1600), pollingRateHz: 1000)) == .unknown)
        #expect(profile.persistence(for: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard),
            observed: DeviceSettings(currentDPI: DPISetting(1600), pollingRateHz: 1000)) == .unknown)
        #expect(profile.persistence(for: DeviceSettingsChange(pollingRateHz: 500, persistence: .onboard),
            observed: DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 500)) == .unknown)
        #expect(profile.capabilityUpdates[.onboardPersist]?.evidence == .writeVerified)
    }
    @Test func independentXYAllowsExactPairsWithoutGrantingUntestedCartesianProducts() {
        let profile = RazerVerifiedTestFixtures.profile(persisted: true, xy: true)
        let capabilities = DeviceCapabilities(operations: profile.capabilityUpdates)
        #expect(capabilities.permits(.independentXY))
        #expect(profile.permits(DeviceSettingsChange(currentDPI: DPISetting(x: 800, y: 1600), persistence: .onboard)))
        #expect(profile.permits(DeviceSettingsChange(currentDPI: DPISetting(x: 1600, y: 800), persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(x: 400, y: 1600), persistence: .onboard)))
        #expect(!profile.permits(DeviceSettingsChange(currentDPI: DPISetting(x: 1600, y: 3200), persistence: .onboard)))
        #expect(!capabilities.permits(.stagesWrite)); #expect(!capabilities.permits(.stageSelect))
        let forward = DeviceSettingsChange(currentDPI: DPISetting(x: 800, y: 1600), pollingRateHz: 500, persistence: .onboard)
        #expect(profile.persistence(for: forward, observed: DeviceSettings(currentDPI: forward.currentDPI, pollingRateHz: 500)) == .onboard)
        let reverse = DeviceSettingsChange(currentDPI: DPISetting(x: 1600, y: 800), pollingRateHz: 500, persistence: .onboard)
        #expect(profile.persistence(for: reverse, observed: DeviceSettings(currentDPI: reverse.currentDPI, pollingRateHz: 500)) == .unknown)
    }
}
