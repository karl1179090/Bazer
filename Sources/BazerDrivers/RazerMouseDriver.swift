// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import Foundation
import RazerProtocol

/// Exact 1532:00C5 settings adapter. Background telemetry stays in RazerBatteryDriver.
public actor RazerMouseDriver: DeviceSettingsValidationAuthorizing, DeviceProfileBacking, DeviceStageLayoutCapturing, DeviceSettingsCapabilityReporting {
    private let discovery: HIDDiscovery
    private let verifiedProfiles: [RazerVerifiedHardwareProfile]
    private var hardwareObservations: [LogicalDeviceSessionID: RazerHardwareObservation] = [:]
    private var currentSettingsBackups: [LogicalDeviceSessionID: ProfileBackup] = [:]
    private var stageEvidence: [LogicalDeviceSessionID: LoadedRazerStageLayoutEvidence] = [:]
    private var validationLayoutDigests: [UUID: String] = [:]
    private var stageBackups: [LogicalDeviceSessionID: ProfileBackup] = [:]
    private var lastReadFirmware: [LogicalDeviceSessionID: String] = [:]
    private var lastReadSettings: [LogicalDeviceSessionID: DeviceSettings] = [:]
    private var validationFirmware: [UUID: String] = [:]
    public init(discovery: HIDDiscovery) { self.discovery = discovery; verifiedProfiles = RazerVerifiedHardwareProfile.reviewed }
    init(discovery: HIDDiscovery, verifiedProfiles: [RazerVerifiedHardwareProfile]) {
        self.discovery = discovery; self.verifiedProfiles = verifiedProfiles
    }
    public static let candidateReadCapabilities: [DeviceOperation: OperationCapability] = [
        .dpiRead: OperationCapability(evidence: .catalogued, constraints: CapabilityConstraints(minimum: 100, maximum: 26000, step: 50), source: "00C5 source-backed 04/85, storage selector 1; hardware settings unverified"),
        .stagesRead: OperationCapability(evidence: .catalogued, source: "00C5 04/86 complete payload; stage ID layout not inferred"),
        .pollingRateRead: OperationCapability(evidence: .catalogued, constraints: CapabilityConstraints(allowedValues: [125, 500, 1000]), source: "00C5 traditional 00/85; hardware settings unverified")]

    private struct ReadImage: Sendable {
        let dpi: RazerDPISnapshot?
        let stages: RazerStageTable?
        let rate: RazerTraditionalPollingRate?
        let firmware: String?
        let failure: TelemetryFailure?
        let fieldFailures: [SettingField: TelemetryFailure]
        let stagesResponse: [UInt8]?
        let dpiResponse: [UInt8]?
        let capturedAt: Date
        var settings: DeviceSettings {
            DeviceSettings(currentDPI: dpi.map { DPISetting(x: $0.x, y: $0.y) }, pollingRateHz: rate.map { Int($0.rawValue) },
                stages: stages.map { DPIStageTable(stages: $0.stages.map { DPIStage(id: $0.id, dpi: DPISetting(x: $0.x, y: $0.y)) }, activeStageID: $0.rawActiveStage, opaqueBytes: $0.payload) })
        }
    }
    public func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async throws -> DeviceSettings {
        // A failed or partial new read must not retain a previous promotion.
        hardwareObservations.removeValue(forKey: session)
        lastReadFirmware.removeValue(forKey: session); lastReadSettings.removeValue(forKey: session)
        let binding = try await bind(target: target, session: session)
        let evidence = try stageEvidence[session].map(Self.reload)
        let base = try await backupIdentity(target: target, session: session, firmware: nil, unitHash: nil, knownLayout: false)
        let readUnit = !verifiedProfiles.isEmpty
        let (image, identity) = try await discovery.withFeatureTransaction(session: binding) { transaction in
            try Self.boundRead(transaction, base: base, evidence: evidence, readUnit: readUnit)
        }
        guard image.dpi != nil || image.stages != nil || image.rate != nil else {
            throw image.failure ?? TelemetryFailure(category: .malformedResponse, message: "No validated Razer settings were returned.")
        }
        lastReadFirmware[session] = image.firmware; lastReadSettings[session] = image.settings
        hardwareObservations[session] = Self.observation(image, identity: identity, target: target, session: session)
        return image.settings
    }
    func settingsCapabilityUpdates(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> [DeviceOperation: OperationCapability] {
        matchingProfile(target: target, session: session)?.capabilityUpdates ?? RazerVerifiedHardwareProfile.revokedCapabilities
    }
    private func matchingProfile(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> RazerVerifiedHardwareProfile? {
        guard !target.isIdentityAmbiguous, target.address == session.address, let observation = hardwareObservations[session] else { return nil }
        let matches = verifiedProfiles.filter { $0.matches(observation, session: session) }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func observation(_ image: ReadImage, identity: ProfileBackupIdentity,
                                    target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> RazerHardwareObservation {
        RazerHardwareObservation(session: session, identity: identity, identityIsAmbiguous: target.isIdentityAmbiguous,
            currentDPI: image.settings.currentDPI, dpiStorage: image.dpi?.storage.rawValue,
            pollingRateHz: image.settings.pollingRateHz, hasCompleteStageImage: image.stages?.payload.count == 80,
            readFailed: image.failure != nil || !image.fieldFailures.isEmpty)
    }
    public func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                              target: LogicalDeviceDescriptor) async throws -> SettingAdapterTransaction {
        try await performSettings(request: request, before: before, target: target, isValidation: false)
    }
    public func applyValidationSettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                                        target: LogicalDeviceDescriptor, authorization: SettingValidationAuthorization) async throws -> SettingAdapterTransaction {
        guard authorization.matches(request, at: Date()), before.revision == request.expectedRevision,
              authorization.profileID == "razer.1532.00c5.storage1.traditional",
              request.change.validate(capabilities: authorization.capabilities).isEmpty else {
            throw RazerSettingsPreflightRejection(message: "The explicit Razer validation authorization no longer matches this exact request.")
        }
        return try await performSettings(request: request, before: before, target: target, isValidation: true)
    }
    private func performSettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                                 target: LogicalDeviceDescriptor, isValidation: Bool) async throws -> SettingAdapterTransaction {
        let currentProfile = matchingProfile(target: target, session: request.target)
        hardwareObservations.removeValue(forKey: request.target)
        guard request.target == before.session, request.target.address == target.address, !target.isIdentityAmbiguous, request.change.persistence == .onboard else {
            throw TelemetryFailure(category: .unsupported, message: "00C5 uses device storage selector 1; runtime-only writes are not established.")
        }
        let binding = try await bind(target: target, session: request.target)
        let evidence = try stageEvidence[request.target].map(Self.reload), backup = stageBackups[request.target]
        if request.change.stages != nil {
            guard evidence != nil, backup != nil else { throw TelemetryFailure(category: .unsupported, message: "Stage writes require an exact-session backup and explicit hardware layout evidence.") }
        }
        let layout: RazerStageLayout = evidence == nil ? .unknown : .sevenByteRecords
        let base = try await backupIdentity(target: target, session: request.target, firmware: nil, unitHash: nil, knownLayout: false)
        let change = request.change
        let candidateFirmware = validationFirmware.removeValue(forKey: request.id)
        let validation = isValidation ? candidateFirmware : nil
        if isValidation, validation == nil { throw RazerSettingsPreflightRejection(message: "The exact Razer validation request has no current single-use firmware binding.") }
        let ordinaryProfile = validation == nil ? currentProfile : nil
        let recoveryBackup = currentSettingsBackups.removeValue(forKey: request.target)
        if validation == nil {
            guard let ordinaryProfile, ordinaryProfile.permits(change), recoveryBackup != nil else {
                throw RazerSettingsPreflightRejection(message: "A matching current Razer hardware profile and saved current-settings recovery backup are required for an ordinary write.")
            }
        }
        let expectedFirmware = validation ?? lastReadFirmware[request.target]
        guard let expectedFirmware else { throw Self.validationFailure() }
        if change.stages != nil, backup?.identity.firmware != expectedFirmware { throw Self.validationFailure() }
        if let expectedDigest = validationLayoutDigests.removeValue(forKey: request.id), expectedDigest != evidence?.documentSHA256 { throw Self.validationFailure() }
        let (result, readbackObservation) = try await discovery.withFeatureTransaction(session: binding) { transaction -> (SettingAdapterTransaction, RazerHardwareObservation?) in
            let readUnit = evidence != nil || ordinaryProfile != nil
            let (actual, actualIdentity) = try Self.boundRead(transaction, base: base, evidence: evidence, readUnit: readUnit)
            let actualObservation = Self.observation(actual, identity: actualIdentity, target: target, session: request.target)
            if let ordinaryProfile {
                guard ordinaryProfile.matches(actualObservation, session: request.target), ordinaryProfile.permits(change),
                      let recoveryBackup, try Self.currentSettingsBackupMatches(recoveryBackup, image: actual, identity: actualIdentity) else {
                    throw RazerSettingsPreflightRejection(message: "The Razer unit, firmware, descriptor or backed-up current settings changed; no settings were sent.")
                }
            }
            guard actual.firmware == expectedFirmware, actual.settings == before.settings else {
                return (SettingAdapterTransaction(before: actual.settings, observed: actual.settings, acknowledged: false, persistence: .unknown, superseded: true), actualObservation)
            }
            var requests: [(SettingField, RazerSettingRequest)] = []
            let constraints = try RazerDPIConstraints(minimum: 100, maximum: 26000, step: 50)
            if let requestedStages = change.stages {
                guard let original = actual.stages, let backup, backup.regions.first?.bytes == original.payload,
                      requestedStages.opaqueBytes == original.payload, requestedStages.isValid,
                      requestedStages.stages.count == original.stages.count,
                      requestedStages.stages.map(\.id) == original.stages.map(\.id) else {
                    throw TelemetryFailure(category: .unsupported, message: "Stage backup, layout or original complete image changed; refusing whole-table write.")
                }
                var table = original
                for stage in requestedStages.stages {
                    table = try table.updating(stageID: stage.id, x: stage.dpi.x, y: stage.dpi.y, constraints: constraints)
                }
                table = try table.selecting(activeStageID: requestedStages.activeStageID)
                requests.append((.stages, try .writeStages(from: table)))
            }
            if let dpi = change.currentDPI {
                guard let actualDPI = actual.dpi else { throw TelemetryFailure(category: .unsupported, message: "Complete DPI read is required before writing DPI.") }
                requests.append((.currentDPI, try .writeDPI(from: actualDPI, x: dpi.x, y: dpi.y, constraints: constraints)))
            }
            if let rate = change.pollingRateHz {
                guard let value = UInt16(exactly: rate), let rate = RazerTraditionalPollingRate(rawValue: value) else {
                    throw TelemetryFailure(category: .unsupported, message: "00C5 traditional rate must be 125, 500 or 1000 Hz.")
                }
                requests.append((.pollingRate, .writePollingRate(rate)))
            }
            guard change.activeProfileID == nil, change.currentStageID == nil, !requests.isEmpty else { throw TelemetryFailure(category: .unsupported, message: "00C5 profile switching is not implemented by this adapter.") }
            var fieldFailures: [SettingField: TelemetryFailure] = [:]
            var missingAcknowledgements = Set<SettingField>()
            var acknowledged = true
            for (field, command) in requests {
                let operation = try Self.operation(for: command)
                let stageProof = field == .stages ? try transaction.confirmStageLayout(hardwareEvidenceReference: evidence!.reference) : nil
                let intent = try HIDFeatureWriteIntent(session: binding, operation: operation, stageEvidence: stageProof)
                let response = try Self.query(transaction, commands: [command], intent: .userInitiatedWrite(intent), layout: layout)
                if let failure = response.commands.first?.failure {
                    fieldFailures[field] = failure; acknowledged = false
                    if let attempt = response.commands.first?.attempts.last,
                       attempt.operations.contains(where: { $0.phase == "setFeature" && $0.rawIOReturn == 0 }),
                       attempt.operations.contains(where: { $0.phase == "getFeature" && $0.rawIOReturn != 0 }) {
                        missingAcknowledgements.insert(field)
                    }
                    // A sent write is never retried or silently downgraded. Observe before any further action.
                    break
                }
                if response.commands.first?.response == nil {
                    fieldFailures[field] = TelemetryFailure(category: .timeout, message: "Write had no validated acknowledgement.")
                    acknowledged = false; break
                }
            }
            let readback: (ReadImage, ProfileBackupIdentity)?
            do { readback = try Self.boundRead(transaction, base: base, evidence: evidence, readUnit: readUnit) }
            catch { readback = nil }
            let observed = readback?.0
            guard observed?.firmware == expectedFirmware, readback?.1 == actualIdentity else {
                return (SettingAdapterTransaction(before: actual.settings, observed: nil, acknowledged: acknowledged, persistence: .unknown,
                    failure: TelemetryFailure(category: .removed, message: "Device identity or firmware changed during the transaction; write outcome cannot be confirmed."), fieldFailures: fieldFailures), nil)
            }
            let requestedFields = Set(change.fields)
            let readFailures = observed?.fieldFailures.filter { requestedFields.contains($0.key) } ?? [:]
            // A validated independent read can resolve a missing ACK, but a failed
            // read remains authoritative for its field. Unscoped failures stay global.
            let blocking = fieldFailures.filter { !missingAcknowledgements.contains($0.key) }
                .merging(readFailures) { _, readFailure in readFailure }
            let invariantFailure: TelemetryFailure?
            if ordinaryProfile != nil, let observed, !Self.preservesCurrentSettingsImage(before: actual, after: observed, change: change) {
                invariantFailure = TelemetryFailure(category: .malformedResponse,
                    message: "An unedited Razer field changed or could not be read after writing; no further write or automatic restoration was attempted.")
            } else { invariantFailure = nil }
            let unscopedReadFailure = observed?.fieldFailures.isEmpty == true ? observed?.failure : nil
            let scope: SettingFailureScope = invariantFailure != nil || unscopedReadFailure != nil ? .transaction
                : (!blocking.isEmpty ? .perField : (!fieldFailures.isEmpty ? .acknowledgement : .transaction))
            let failures = blocking.isEmpty ? fieldFailures : blocking
            let reportedFailure = invariantFailure ?? unscopedReadFailure ?? readFailures.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value
                ?? fieldFailures.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value
            let nextObservation = invariantFailure == nil ? readback.map { Self.observation($0.0, identity: $0.1, target: target, session: request.target) } : nil
            let persistence: SettingPersistence
            if let ordinaryProfile, let nextObservation, ordinaryProfile.matches(nextObservation, session: request.target),
               let observed, change.fields.allSatisfy({ change.matches(observed.settings, field: $0) }) {
                persistence = ordinaryProfile.persistence(for: change, observed: observed.settings)
            } else { persistence = .unknown }
            return (SettingAdapterTransaction(before: actual.settings, observed: observed?.settings, acknowledged: acknowledged,
                persistence: persistence, failure: reportedFailure,
                fieldFailures: failures, failureScope: scope),
                nextObservation)
        }
        hardwareObservations[request.target] = readbackObservation
        if result.superseded {
            hardwareObservations.removeValue(forKey: request.target)
            lastReadFirmware.removeValue(forKey: request.target); lastReadSettings.removeValue(forKey: request.target)
        }
        else if let observed = result.observed { lastReadSettings[request.target] = observed }
        return result
    }
    public func authorizeValidation(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                                    target: LogicalDeviceDescriptor, operation: SettingValidationOperation) async throws -> SettingValidationAuthorization {
        _ = try await bind(target: target, session: request.target)
        guard before.session == request.target, before.revision == request.expectedRevision, request.change.persistence == .onboard else {
            throw TelemetryFailure(category: .unsupported, message: "Validation must bind current settings and device-storage scope.")
        }
        guard lastReadSettings[request.target] == before.settings, let firmware = lastReadFirmware[request.target] else { throw Self.validationFailure() }
        let change = request.change
        var capabilities = DeviceCapabilities()
        let dpi = CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, persistenceScopes: [.onboard])
        switch operation {
        case .razer00C5DPI, .razer00C5IndependentXY:
            guard change.fields == [.currentDPI], let requestedDPI = change.currentDPI, before.settings.currentDPI != nil,
                  operation == .razer00C5IndependentXY || requestedDPI.x == requestedDPI.y else { throw Self.validationFailure() }
            capabilities.record(OperationCapability(evidence: .writeVerified, constraints: dpi, source: "Single exact-request validation authorization; not published evidence"), for: .dpiWrite)
            if operation == .razer00C5IndependentXY { capabilities.record(OperationCapability(evidence: .writeVerified), for: .independentXY) }
        case .razer00C5PollingRate:
            guard change.fields == [.pollingRate], before.settings.pollingRateHz != nil else { throw Self.validationFailure() }
            capabilities.record(OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [125, 500, 1000], persistenceScopes: [.onboard])), for: .pollingRateWrite)
        case .razer00C5Stages:
            guard !target.isIdentityAmbiguous, let cachedEvidence = stageEvidence[request.target] else { throw Self.validationFailure() }
            let loaded = try Self.reload(cachedEvidence)
            let actual = try await exportProfileBackup(target: target, session: request.target, hardwareEvidenceReference: loaded.reference)
            guard change.fields == [.stages], let stages = change.stages, let original = before.settings.stages,
                  let backup = stageBackups[request.target], actual.identity == backup.identity,
                  actual.regions == backup.regions,
                  backup.identity.firmware == firmware,
                  stages.opaqueBytes == original.opaqueBytes, backup.regions.first?.bytes == original.opaqueBytes,
                  stages.stages.map(\.id) == original.stages.map(\.id), original.isValid else { throw Self.validationFailure() }
            capabilities.record(OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, maximumStages: 5, persistenceScopes: [.onboard])), for: .stagesWrite)
            capabilities.record(OperationCapability(evidence: .writeVerified), for: .independentXY)
            validationLayoutDigests[request.id] = loaded.documentSHA256
        default: throw Self.validationFailure()
        }
        capabilities.record(OperationCapability(evidence: .writeVerified), for: .onboardPersist)
        guard change.validate(capabilities: capabilities).isEmpty else { throw Self.validationFailure() }
        validationFirmware[request.id] = firmware
        return SettingValidationAuthorization(request: request, operation: operation, profileID: "razer.1532.00c5.storage1.traditional", capabilities: capabilities)
    }
    /// Only a validated local hardware document enables known-layout interpretation; a string is never evidence.
    public func exportProfileBackup(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID,
                                    hardwareEvidenceReference: String? = nil) async throws -> ProfileBackup {
        let binding = try await bind(target: target, session: session)
        let evidence: LoadedRazerStageLayoutEvidence?
        if let reference = hardwareEvidenceReference {
            guard !target.isIdentityAmbiguous else { throw Self.validationFailure() }
            evidence = try RazerStageLayoutEvidenceFile.load(reference: reference)
        } else { evidence = nil }
        let base = try await backupIdentity(target: target, session: session, firmware: nil, unitHash: nil, knownLayout: false)
        let (image, identity) = try await discovery.withFeatureTransaction(session: binding) { transaction in
            try Self.boundRead(transaction, base: base, evidence: evidence, readUnit: true)
        }
        guard let table = image.stages else { throw image.failure ?? Self.validationFailure() }
        let backup = ProfileBackup(capturedAt: image.capturedAt, identity: identity, session: session,
            regions: [ProfileBackupRegion(id: "dpi-stage-payload", bytes: table.payload)], hardwareEvidenceReference: evidence?.reference)
        try backup.validateIntegrity()
        if let evidence { stageEvidence[session] = evidence }
        return backup
    }
    /// Read-only capture. It always writes an unconfirmed template and never sets stageEvidence or a write grant.
    public func captureStageLayoutEvidence(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID,
                                          saveTo url: URL) async throws -> RazerStageLayoutEvidence {
        let binding = try await bind(target: target, session: session)
        let base = try await backupIdentity(target: target, session: session, firmware: nil, unitHash: nil, knownLayout: false)
        let (image, identity) = try await discovery.withFeatureTransaction(session: binding) { transaction in
            try Self.boundRead(transaction, base: base, evidence: nil, readUnit: true)
        }
        guard let table = image.stages, let dpi = image.dpi, let stagesResponse = image.stagesResponse, let dpiResponse = image.dpiResponse else {
            throw image.failure ?? Self.validationFailure()
        }
        let observation = RazerStageLayoutObservation(selectedStageID: nil, observedAt: image.capturedAt,
            reportedActiveField: table.rawActiveStage, observedCurrentDPI: DPISetting(x: dpi.x, y: dpi.y),
            stagesResponse: stagesResponse, dpiResponse: dpiResponse)
        let document = RazerStageLayoutEvidence.unconfirmed(capturedAt: image.capturedAt, identity: identity,
            payload: table.payload, observations: [observation])
        try RazerStageLayoutEvidenceFile.saveUnconfirmed(document, to: url)
        return document
    }
    public func exportProfileBackup(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID,
                                    hardwareEvidenceReference: String, saveTo url: URL) async throws -> ProfileBackup {
        let backup = try await exportProfileBackup(target: target, session: session, hardwareEvidenceReference: hardwareEvidenceReference)
        try FileProfileBackup(url: url).save(backup)
        stageBackups[session] = backup
        return backup
    }
    public func prepareProfileRestore(backupURL: URL, rollbackBackupURL: URL, target: LogicalDeviceDescriptor,
                                      session: LogicalDeviceSessionID, hardwareEvidenceReference: String) async throws -> DeviceSettingsChange {
        let backup = try FileProfileBackup(url: backupURL).load()
        let change = try await prepareProfileRestore(backup, target: target, session: session, hardwareEvidenceReference: hardwareEvidenceReference)
        guard let actual = stageBackups[session] else { throw Self.validationFailure() }
        do { try FileProfileBackup(url: rollbackBackupURL).save(actual) }
        catch { stageBackups.removeValue(forKey: session); throw error }
        return change
    }

    /// Restoring changes only the known stage DPI and active-ID fields; all reserved bytes remain from the new actual read.
    private func prepareProfileRestore(_ backup: ProfileBackup, target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID,
                                      hardwareEvidenceReference: String) async throws -> DeviceSettingsChange {
        let current = try await exportProfileBackup(target: target, session: session, hardwareEvidenceReference: hardwareEvidenceReference)
        try backup.validateRestore(to: current.identity, session: session, expectedRegionLengths: ["dpi-stage-payload": 80])
        let table = try Self.parseBackupStages(backup)
        let currentTable = try Self.parseBackupStages(current)
        guard table.stages.map(\.id) == currentTable.stages.map(\.id), table.stages.count == currentTable.stages.count else { throw ProfileBackupError.regionLayoutMismatch }
        var expected = currentTable.payload
        expected[1] = table.rawActiveStage
        for index in table.stages.indices {
            let offset = 3 + index * 7
            expected[(offset + 1)...(offset + 4)] = table.payload[(offset + 1)...(offset + 4)]
        }
        guard expected == table.payload else { throw ProfileBackupError.regionLayoutMismatch }
        stageBackups[session] = current
        let stages = DPIStageTable(stages: table.stages.map { DPIStage(id: $0.id, dpi: DPISetting(x: $0.x, y: $0.y)) },
            activeStageID: table.rawActiveStage, opaqueBytes: currentTable.payload)
        return DeviceSettingsChange(stages: stages, persistence: .onboard)
    }
    public func exportProfile(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, saveTo url: URL,
                              hardwareEvidenceReference: String?) async throws -> ProfileBackup {
        if let reference = hardwareEvidenceReference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await exportProfileBackup(target: target, session: session, hardwareEvidenceReference: reference, saveTo: url)
        }
        if let profile = matchingProfile(target: target, session: session) {
            let backup = try await exportCurrentSettingsBackup(target: target, session: session, profile: profile)
            try FileProfileBackup(url: url).save(backup)
            currentSettingsBackups[session] = backup
            return backup
        }
        let backup = try await exportProfileBackup(target: target, session: session)
        try FileProfileBackup(url: url).save(backup)
        return backup
    }
    public func prepareRestore(backupURL: URL, rollbackBackupURL: URL, target: LogicalDeviceDescriptor,
                               session: LogicalDeviceSessionID, hardwareEvidenceReference: String?) async throws -> DeviceSettingsChange {
        let backup = try FileProfileBackup(url: backupURL).load()
        if backup.identity.formatID == Self.currentSettingsFormat {
            guard hardwareEvidenceReference == nil else {
                throw RazerSettingsPreflightRejection(message: "Current-settings recovery does not interpret or write DPI stage-layout evidence.")
            }
            _ = try await readSettings(target: target, session: session)
            guard let profile = matchingProfile(target: target, session: session) else {
                throw RazerSettingsPreflightRejection(message: "A current matching Razer hardware profile is required to restore DPI and traditional rate.")
            }
            let current = try await exportCurrentSettingsBackup(target: target, session: session, profile: profile)
            try backup.validateRestore(to: current.identity, session: session, expectedRegionLengths: Self.currentSettingsRegionLengths)
            guard backup.regions.first(where: { $0.id == "dpi-stage-payload" })?.bytes == current.regions.first(where: { $0.id == "dpi-stage-payload" })?.bytes else {
                throw ProfileBackupError.regionLayoutMismatch
            }
            let values = try Self.currentSettingsValues(backup)
            let change = DeviceSettingsChange(currentDPI: values.0, pollingRateHz: values.1, persistence: .onboard)
            guard profile.permits(change) else { throw RazerSettingsPreflightRejection(message: "The backup requests values outside the reviewed Razer write domain.") }
            try FileProfileBackup(url: rollbackBackupURL).save(current)
            currentSettingsBackups[session] = current
            return change
        }
        guard let reference = hardwareEvidenceReference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TelemetryFailure(category: .unsupported, message: "Razer stage restore requires explicit hardware layout evidence.")
        }
        return try await prepareProfileRestore(backupURL: backupURL, rollbackBackupURL: rollbackBackupURL,
            target: target, session: session, hardwareEvidenceReference: reference)
    }

    private static let currentSettingsFormat = "razer.00c5.current-settings"
    private static let currentSettingsRegionLengths = ["current-dpi-payload": 80, "traditional-polling-rate": 1, "dpi-stage-payload": 80]
    private func exportCurrentSettingsBackup(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID,
                                             profile: RazerVerifiedHardwareProfile) async throws -> ProfileBackup {
        currentSettingsBackups.removeValue(forKey: session)
        hardwareObservations.removeValue(forKey: session)
        let binding = try await bind(target: target, session: session)
        let base = try await backupIdentity(target: target, session: session, firmware: nil, unitHash: nil, knownLayout: false)
        let (image, identity) = try await discovery.withFeatureTransaction(session: binding) { transaction in
            try Self.boundRead(transaction, base: base, evidence: nil, readUnit: true)
        }
        let observation = Self.observation(image, identity: identity, target: target, session: session)
        guard profile.matches(observation, session: session), let dpi = image.dpi, let rate = image.rate, let stages = image.stages else {
            throw RazerSettingsPreflightRejection(message: "A complete matching Razer current-settings image is required before saving recovery data.")
        }
        hardwareObservations[session] = observation
        let backup = ProfileBackup(capturedAt: image.capturedAt, identity: Self.currentSettingsIdentity(identity), session: session,
            regions: [ProfileBackupRegion(id: "current-dpi-payload", bytes: dpi.payload),
                ProfileBackupRegion(id: "traditional-polling-rate", bytes: [rate.code]),
                ProfileBackupRegion(id: "dpi-stage-payload", bytes: stages.payload)])
        try backup.validateIntegrity()
        return backup
    }
    private static func currentSettingsIdentity(_ identity: ProfileBackupIdentity) -> ProfileBackupIdentity {
        ProfileBackupIdentity(vendorID: identity.vendorID, productID: identity.productID, unitID: identity.unitID,
            firmware: identity.firmware, formatID: currentSettingsFormat, formatVersion: 1, descriptorSHA256: identity.descriptorSHA256)
    }
    private static func currentSettingsValues(_ backup: ProfileBackup) throws -> (DPISetting, Int) {
        try backup.validateIntegrity()
        guard backup.identity.formatID == currentSettingsFormat, backup.identity.formatVersion == 1,
              Dictionary(uniqueKeysWithValues: backup.regions.map { ($0.id, $0.bytes.count) }) == currentSettingsRegionLengths,
              let dpi = backup.regions.first(where: { $0.id == "current-dpi-payload" })?.bytes, dpi[0] == 1,
              let rate = backup.regions.first(where: { $0.id == "traditional-polling-rate" })?.bytes.first else {
            throw ProfileBackupError.unknownFormat
        }
        return (DPISetting(x: UInt16(dpi[1]) << 8 | UInt16(dpi[2]), y: UInt16(dpi[3]) << 8 | UInt16(dpi[4])),
            Int(try RazerTraditionalPollingRate(code: rate).rawValue))
    }
    private static func currentSettingsBackupMatches(_ backup: ProfileBackup, image: ReadImage, identity: ProfileBackupIdentity) throws -> Bool {
        try backup.validateRestore(to: currentSettingsIdentity(identity), session: backup.session, expectedRegionLengths: currentSettingsRegionLengths)
        return backup.regions.first(where: { $0.id == "current-dpi-payload" })?.bytes == image.dpi?.payload
            && backup.regions.first(where: { $0.id == "traditional-polling-rate" })?.bytes == image.rate.map { [$0.code] }
            && backup.regions.first(where: { $0.id == "dpi-stage-payload" })?.bytes == image.stages?.payload
    }
    private static func preservesCurrentSettingsImage(before: ReadImage, after: ReadImage, change: DeviceSettingsChange) -> Bool {
        guard let original = before.dpi, let observed = after.dpi,
              let originalStages = before.stages, let observedStages = after.stages,
              originalStages.payload == observedStages.payload,
              original.payload.count == 80, observed.payload.count == 80,
              (0..<80).allSatisfy({ (1...4).contains($0) || original.payload[$0] == observed.payload[$0] }),
              before.rate != nil else { return false }
        return (change.currentDPI != nil || before.settings.currentDPI == after.settings.currentDPI)
            && (change.pollingRateHz != nil || before.rate == after.rate)
    }

    private static func reload(_ cached: LoadedRazerStageLayoutEvidence) throws -> LoadedRazerStageLayoutEvidence {
        let loaded = try RazerStageLayoutEvidenceFile.load(reference: cached.reference)
        guard loaded.documentSHA256 == cached.documentSHA256 else { throw RazerStageEvidenceError.notHardwareConfirmed }
        return loaded
    }
    private static func boundRead(_ transaction: HIDFeatureTransaction, base: ProfileBackupIdentity,
                                  evidence: LoadedRazerStageLayoutEvidence?, readUnit: Bool) throws -> (ReadImage, ProfileBackupIdentity) {
        let raw = try readImage(transaction, layout: .unknown)
        let unit = readUnit ? try backupUnitIdentity(transaction) : evidence?.document.identity.unitID
        let identity = ProfileBackupIdentity(vendorID: base.vendorID, productID: base.productID, unitID: unit,
            firmware: raw.firmware, formatID: base.formatID, formatVersion: evidence == nil ? 0 : 1, descriptorSHA256: base.descriptorSHA256)
        guard let evidence else { return (raw, identity) }
        guard let table = raw.stages, let response = raw.stagesResponse else { throw validationFailure() }
        try evidence.document.validate(currentIdentity: identity, currentPayload: table.payload)
        guard case let .stages(interpreted) = try RazerSettingResponse.parse(response, for: .readStages(), stageLayout: .sevenByteRecords) else { throw validationFailure() }
        return (ReadImage(dpi: raw.dpi, stages: interpreted, rate: raw.rate, firmware: raw.firmware, failure: raw.failure, fieldFailures: raw.fieldFailures,
            stagesResponse: raw.stagesResponse, dpiResponse: raw.dpiResponse, capturedAt: raw.capturedAt), identity)
    }
    private func bind(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async throws -> HIDFeatureSessionBinding {
        guard target.address == session.address, case .direct = target.address.target, let endpoint = target.controlEndpointRegistryEntryID else { throw Self.validationFailure() }
        return try await discovery.bindFeatureSession(physicalDeviceID: target.address.hostSessionID.physicalDeviceID,
            registryEntryID: endpoint, profile: .razer00C5SettingsCandidate)
    }
    private func backupIdentity(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, firmware: String?, unitHash: String?, knownLayout: Bool) async throws -> ProfileBackupIdentity {
        let snapshot = try await discovery.snapshot()
        guard let device = snapshot.devices.first(where: { $0.id == session.address.hostSessionID.physicalDeviceID }),
              let endpoint = device.interfaces.first(where: { $0.registryEntryID == target.controlEndpointRegistryEntryID }),
              device.vendorID == 0x1532, device.productID == 0x00C5 else { throw ProfileBackupError.wrongDevice }
        return ProfileBackupIdentity(vendorID: 0x1532, productID: 0x00C5, unitID: unitHash.map { "razer-serial-sha256:" + $0 }, firmware: firmware,
            formatID: "razer.00c5.dpi-stage-payload", formatVersion: knownLayout ? 1 : 0, descriptorSHA256: endpoint.descriptorSHA256)
    }
    private static func backupUnitIdentity(_ transaction: HIDFeatureTransaction) throws -> String? {
        let request = RazerSettingRequest.readBackupIdentity()
        let result = try query(transaction, commands: [request], intent: .backupIdentityRead, layout: .unknown)
        guard let frame = result.commands.first?.response,
              case let .backupIdentity(hash) = try? RazerSettingResponse.parse(frame, for: request) else { return nil }
        return "razer-serial-sha256:" + hash
    }
    private static func parseBackupStages(_ backup: ProfileBackup) throws -> RazerStageTable {
        try backup.validateIntegrity()
        guard backup.identity.formatID == "razer.00c5.dpi-stage-payload", backup.identity.formatVersion == 1,
              backup.regions.count == 1, let payload = backup.regions.first?.bytes, payload.count == 80 else { throw ProfileBackupError.unknownFormat }
        let request = RazerSettingRequest.readStages()
        var frame = request.bytes; frame[0] = 2; frame[8...87] = payload[...]; frame[88] = frame[2...87].reduce(0, ^)
        guard case let .stages(table) = try RazerSettingResponse.parse(frame, for: request, stageLayout: .sevenByteRecords) else { throw ProfileBackupError.unknownFormat }
        return table
    }
    private static func validationFailure() -> TelemetryFailure { TelemetryFailure(category: .unsupported, message: "No exact known Razer validation operation, current read image or layout evidence matches this request.") }
    private static func operation(for request: RazerSettingRequest) throws -> HIDFeatureOperation {
        switch request.command {
        case .readFirmware: return .readFirmware
        case .readBackupIdentity: return .readBackupIdentity
        case .readDPI: return .readDPI(storage: request.storage!.rawValue)
        case .readStages: return .readDPIStages(storage: request.storage!.rawValue)
        case .readPollingRate: return .readPollingRate
        case .writeDPI: return .setDPI(storage: request.storage!.rawValue, x: UInt16(request.payload[1]) << 8 | UInt16(request.payload[2]), y: UInt16(request.payload[3]) << 8 | UInt16(request.payload[4]))
        case .writeStages: return .setDPIStages(payload: request.payload)
        case .writePollingRate:
            guard let rate = try? RazerTraditionalPollingRate(code: request.payload[0]) else { throw validationFailure() }
            return .setPollingRate(hertz: rate.rawValue)
        default: throw validationFailure()
        }
    }
    private static func query(_ transaction: HIDFeatureTransaction, commands: [RazerSettingRequest], intent: HIDFeatureIntent = .explicitRead,
                              layout: RazerStageLayout) throws -> HIDFeatureGroupResult {
        let requests = try commands.map { HIDReadOnlyFeatureRequest(operation: try operation(for: $0), bytes: $0.bytes) }
        return try transaction.query(requests: requests, intent: intent) { request, response in
            guard let command = commands.first(where: { $0.bytes == request.bytes }) else {
                return HIDReportValidation(valid: false, retryable: false, error: "Unknown typed Razer command", checks: [], failureCategory: .unsupported)
            }
            do {
                _ = try RazerSettingResponse.parse(response, for: command, stageLayout: layout)
                return HIDReportValidation(valid: true, retryable: false, error: nil, checks: [])
            } catch RazerProtocolError.busy {
                return HIDReportValidation(valid: false, retryable: !command.command.isWrite, error: "Razer device busy", checks: [], failureCategory: .busy)
            } catch RazerProtocolError.deviceStatus(let status) {
                return HIDReportValidation(valid: false, retryable: false, error: "Razer status \(status)", checks: [], failureCategory: .deviceStatus, protocolStatus: status)
            } catch {
                return HIDReportValidation(valid: false, retryable: !command.command.isWrite, error: String(describing: error), checks: [], failureCategory: .malformedResponse)
            }
        }
    }
    private static func readImage(_ transaction: HIDFeatureTransaction, layout: RazerStageLayout) throws -> ReadImage {
        let commands: [RazerSettingRequest] = [.readFirmware(), .readDPI(), .readStages(), .readPollingRate()]
        let result = try query(transaction, commands: commands, layout: layout)
        var dpi: RazerDPISnapshot?, stages: RazerStageTable?, rate: RazerTraditionalPollingRate?, firmware: String?
        var fieldFailures: [SettingField: TelemetryFailure] = [:]
        var stagesResponse: [UInt8]?, dpiResponse: [UInt8]?
        for (request, command) in zip(commands, result.commands) {
            if let failure = command.failure {
                switch request.command {
                case .readDPI: fieldFailures[.currentDPI] = failure
                case .readStages: fieldFailures[.stages] = failure
                case .readPollingRate: fieldFailures[.pollingRate] = failure
                default: break
                }
            }
            guard let bytes = command.response else { continue }
            switch try RazerSettingResponse.parse(bytes, for: request, stageLayout: layout) {
            case let .dpi(value): dpi = value; dpiResponse = bytes
            case let .stages(value): stages = value; stagesResponse = bytes
            case let .pollingRate(value): rate = value
            case let .firmware(major, minor): firmware = "\(major).\(minor)"
            default: break
            }
        }
        return ReadImage(dpi: dpi, stages: stages, rate: rate, firmware: firmware, failure: result.commands.compactMap(\.failure).first,
            fieldFailures: fieldFailures, stagesResponse: stagesResponse, dpiResponse: dpiResponse, capturedAt: result.finishedAt)
    }
}

private struct RazerSettingsPreflightRejection: DeviceSettingsPreflightRejecting {
    let message: String
    var rejectionMessage: String { message }
}
