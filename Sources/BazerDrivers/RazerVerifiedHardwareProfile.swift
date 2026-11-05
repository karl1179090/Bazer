// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// One current explicit read. Receiver topology alone is never a mouse identity.
struct RazerHardwareObservation: Sendable {
    let session: LogicalDeviceSessionID
    let identity: ProfileBackupIdentity
    let identityIsAmbiguous: Bool
    let currentDPI: DPISetting?
    let dpiStorage: UInt8?
    let pollingRateHz: Int?
    let hasCompleteStageImage: Bool
    let readFailed: Bool
}

struct RazerPersistedCurrentSettings: Hashable, Sendable {
    let x: UInt16
    let y: UInt16
    let pollingRateHz: Int
    init(x: UInt16, y: UInt16, pollingRateHz: Int) { self.x = x; self.y = y; self.pollingRateHz = pollingRateHz }
    init(dpi: UInt16, pollingRateHz: Int) { self.init(x: dpi, y: dpi, pollingRateHz: pollingRateHz) }
}

/// Reviewed, source-controlled physical evidence; no file, cache or validation
/// token can add a profile or enlarge its tested value sets.
struct RazerVerifiedHardwareProfile: Sendable {
    let id: String
    let descriptorSHA256: String
    let firmware: String
    let unitID: String
    let dpiValues: [Int]
    let independentDPIValues: [DPISetting]
    let pollingRateValues: [Int]
    let persistedSettings: [RazerPersistedCurrentSettings]
    let writeEvidenceSource: String
    let persistenceEvidenceSource: String?

    // Actual production transactions, independent readbacks and complete original
    // restorations were reviewed before these operation/value grants were added.
    // XY and power-removal grants use their separate exact-unit live receipt;
    // the single persisted triple does not establish other combinations.
    static let reviewed: [Self] = [Self(
        id: "razer.1532.00c5.exact-unit.fw1.10.2026-11-05",
        descriptorSHA256: "5ee345d9eaa00bee91303620e6adfbb5613884b4abad54adf921ddf3b236964a",
        firmware: "1.10",
        unitID: "razer-serial-sha256:baef569b7221f277cdedab36bddf869a5139ba1444dde9aae0194abe10c3dbfc",
        dpiValues: [400, 800, 1600, 3200],
        independentDPIValues: [DPISetting(x: 800, y: 1600), DPISetting(x: 1600, y: 800)], pollingRateValues: [125, 500, 1000],
        persistedSettings: [RazerPersistedCurrentSettings(x: 800, y: 1600, pollingRateHz: 500)],
        writeEvidenceSource: "docs/evidence/razer-unified-dpi-rate-live-readback-2026-11-05.json; sha256:e4247cce6ab9229811c665c1da82b52ec6211c1b98158cdd7ace483ee2ea4350; docs/evidence/razer-xy-persistence-live-2026-11-05.json; sha256:39efcf566e6a104f682b90935f05d41b55146e6b77ef818fb688a95abdb2da78",
        persistenceEvidenceSource: "docs/evidence/razer-xy-persistence-live-2026-11-05.json; sha256:39efcf566e6a104f682b90935f05d41b55146e6b77ef818fb688a95abdb2da78")]
    static let managedOperations: [DeviceOperation] = [.dpiWrite, .independentXY, .pollingRateWrite, .onboardPersist]
    static var revokedCapabilities: [DeviceOperation: OperationCapability] {
        Dictionary(uniqueKeysWithValues: managedOperations.map { ($0, OperationCapability()) })
    }

    private var isValid: Bool {
        func hash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
        let prefix = "razer-serial-sha256:"
        func validDPI(_ value: Int) -> Bool { (100...26000).contains(value) && value % 50 == 0 }
        return !id.isEmpty && hash(descriptorSHA256) && !firmware.isEmpty
            && unitID.hasPrefix(prefix) && hash(String(unitID.dropFirst(prefix.count)))
            && (!allowedDPIPairs.isEmpty || !pollingRateValues.isEmpty) && !writeEvidenceSource.isEmpty
            && Set(dpiValues).count == dpiValues.count && Set(pollingRateValues).count == pollingRateValues.count
            && dpiValues.allSatisfy(validDPI)
            && independentDPIValues.allSatisfy { $0.x != $0.y && validDPI(Int($0.x)) && validDPI(Int($0.y)) }
            && pollingRateValues.allSatisfy { [125, 500, 1000].contains($0) }
            && persistedSettings.allSatisfy { allowedDPIPairs.contains(DPISetting(x: $0.x, y: $0.y)) && pollingRateValues.contains($0.pollingRateHz) }
            && (persistedSettings.isEmpty || persistenceEvidenceSource?.isEmpty == false)
    }
    private var allowedDPIPairs: [DPISetting] { dpiValues.compactMap { UInt16(exactly: $0).map(DPISetting.init) } + independentDPIValues }

    func matches(_ observation: RazerHardwareObservation, session: LogicalDeviceSessionID) -> Bool {
        guard isValid, observation.session == session, !observation.identityIsAmbiguous, !observation.readFailed,
              observation.identity.vendorID == 0x1532, observation.identity.productID == 0x00C5,
              observation.identity.descriptorSHA256 == descriptorSHA256,
              observation.identity.firmware == firmware, observation.identity.unitID == unitID,
              observation.dpiStorage == 1, observation.hasCompleteStageImage,
              let dpi = observation.currentDPI,
              let rate = observation.pollingRateHz else { return false }
        // The original value must also be in the tested restoration domain.
        return (allowedDPIPairs.isEmpty || allowedDPIPairs.contains(dpi))
            && (pollingRateValues.isEmpty || pollingRateValues.contains(rate))
    }

    var capabilityUpdates: [DeviceOperation: OperationCapability] {
        guard isValid else { return Self.revokedCapabilities }
        var updates = Self.revokedCapabilities
        let source = "builtin:\(id); \(writeEvidenceSource)"
        if !allowedDPIPairs.isEmpty {
            updates[.dpiWrite] = OperationCapability(evidence: .writeVerified,
                constraints: CapabilityConstraints(allowedValues: allowedDPIPairs.flatMap { [Int($0.x), Int($0.y)] },
                    persistenceScopes: [.onboard], allowedDPIPairs: allowedDPIPairs), source: source)
        }
        if !independentDPIValues.isEmpty {
            updates[.independentXY] = OperationCapability(evidence: .writeVerified,
                constraints: CapabilityConstraints(persistenceScopes: [.onboard], allowedDPIPairs: independentDPIValues), source: source)
        }
        if !pollingRateValues.isEmpty {
            updates[.pollingRateWrite] = OperationCapability(evidence: .writeVerified,
                constraints: CapabilityConstraints(allowedValues: pollingRateValues, persistenceScopes: [.onboard]), source: source)
        }
        let allValuesPersisted = !allowedDPIPairs.isEmpty && !pollingRateValues.isEmpty && allowedDPIPairs.allSatisfy { dpi in
            pollingRateValues.allSatisfy { rate in persistedSettings.contains(RazerPersistedCurrentSettings(x: dpi.x, y: dpi.y, pollingRateHz: rate)) }
        }
        updates[.onboardPersist] = OperationCapability(evidence: allValuesPersisted ? .persistenceVerified : .writeVerified,
            constraints: CapabilityConstraints(persistenceScopes: [.onboard]),
            source: allValuesPersisted ? "\(source); \(persistenceEvidenceSource ?? "")" : "\(source); device storage selector 1; power-removal persistence unverified for other values")
        return updates
    }

    func permits(_ change: DeviceSettingsChange) -> Bool {
        change.validate(capabilities: DeviceCapabilities(operations: capabilityUpdates)).isEmpty
    }

    /// A selector or ACK cannot prove power-removal persistence. Evidence is
    /// restricted to the exact complete settings combinations that survived it.
    func persistence(for change: DeviceSettingsChange, observed: DeviceSettings) -> SettingPersistence {
        guard permits(change), change.fields.allSatisfy({ change.matches(observed, field: $0) }),
              let dpi = observed.currentDPI, let rate = observed.pollingRateHz,
              persistedSettings.contains(RazerPersistedCurrentSettings(x: dpi.x, y: dpi.y, pollingRateHz: rate)) else { return .unknown }
        return .onboard
    }
}
