// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// Values returned by a real transport transaction, never echoes of requested values.
public struct SettingAdapterTransaction: Sendable {
    public let before: DeviceSettings
    public let observed: DeviceSettings?
    public let acknowledged: Bool
    public let persistence: SettingPersistence
    public let failure: TelemetryFailure?
    public let fieldFailures: [SettingField: TelemetryFailure]
    /// Defaults to whole-transaction failure. Narrowing requires positive adapter evidence.
    public let failureScope: SettingFailureScope
    public let superseded: Bool
    public init(before: DeviceSettings, observed: DeviceSettings?, acknowledged: Bool, persistence: SettingPersistence,
                failure: TelemetryFailure? = nil, fieldFailures: [SettingField: TelemetryFailure] = [:],
                failureScope: SettingFailureScope = .transaction, superseded: Bool = false) {
        self.before = before; self.observed = observed; self.acknowledged = acknowledged; self.persistence = persistence
        self.failure = failure; self.fieldFailures = fieldFailures; self.failureScope = failureScope; self.superseded = superseded
    }
}

/// Adapter errors that are raised before any settings write is sent.
public protocol DeviceSettingsPreflightRejecting: Error { var rejectionMessage: String { get } }

public protocol DeviceSettingsAdapter: Sendable {
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async throws -> DeviceSettings
    /// Must hold the host transport lease over actual before → compare → write → readback.
    /// A changed before snapshot returns superseded without writing. Timeout never retries a write.
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                       target: LogicalDeviceDescriptor) async throws -> SettingAdapterTransaction
}

/// An adapter may replace only its current-session settings write evidence after
/// a real read or transaction. Other adapters keep their existing capabilities.
protocol DeviceSettingsCapabilityReporting: DeviceSettingsAdapter {
    func settingsCapabilityUpdates(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async -> [DeviceOperation: OperationCapability]
}

public protocol DeviceStageLayoutCapturing: DeviceSettingsAdapter {
    func captureStageLayoutEvidence(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID,
                                    saveTo: URL) async throws -> RazerStageLayoutEvidence
}

public protocol DeviceProfileBacking: DeviceSettingsAdapter {
    func exportProfile(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, saveTo: URL,
                       hardwareEvidenceReference: String?) async throws -> ProfileBackup
    func prepareRestore(backupURL: URL, rollbackBackupURL: URL, target: LogicalDeviceDescriptor,
                        session: LogicalDeviceSessionID, hardwareEvidenceReference: String?) async throws -> DeviceSettingsChange
}

/// Explicit first-validation workflows, separate from normal write-verified UI actions.
public enum SettingValidationOperation: String, Codable, Sendable {
    case razer00C5DPI, razer00C5IndependentXY, razer00C5PollingRate, razer00C5Stages
    case logitechHIDPP2201DPI, logitechHIDPP8060PollingRate, logitechHIDPP8100Profile
}
public struct SettingValidationAuthorization: Equatable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let target: LogicalDeviceSessionID
    public let expectedRevision: UInt64
    public let operation: SettingValidationOperation
    public let profileID: String
    public let expiresAt: Date
    let change: DeviceSettingsChange
    let capabilities: DeviceCapabilities
    // Only an adapter in this module can mint one, and the controller must register it.
    init(request: SettingChangeRequest, operation: SettingValidationOperation, profileID: String,
         capabilities: DeviceCapabilities, expiresAt: Date = Date().addingTimeInterval(60)) {
        id = UUID(); requestID = request.id; target = request.target; expectedRevision = request.expectedRevision
        self.operation = operation; self.profileID = profileID; self.expiresAt = expiresAt
        change = request.change; self.capabilities = capabilities
    }
    func matches(_ request: SettingChangeRequest, at date: Date) -> Bool {
        requestID == request.id && target == request.target && expectedRevision == request.expectedRevision
        && change == request.change && date < expiresAt
    }
}
public protocol DeviceSettingsValidationAuthorizing: DeviceSettingsAdapter {
    func authorizeValidation(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                             target: LogicalDeviceDescriptor, operation: SettingValidationOperation) async throws -> SettingValidationAuthorization
    func applyValidationSettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                                 target: LogicalDeviceDescriptor, authorization: SettingValidationAuthorization) async throws -> SettingAdapterTransaction
}
public extension DeviceSettingsValidationAuthorizing {
    func applyValidationSettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                                 target: LogicalDeviceDescriptor, authorization: SettingValidationAuthorization) async throws -> SettingAdapterTransaction {
        try await applySettings(request: request, before: before, target: target)
    }
}

private final class SettingQueueCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Business actions for App and CLI. Each host queue includes all of its logical children.
public actor DeviceController {
    private let monitor: BatteryMonitor
    private let registry: DriverRegistry?
    private var tails: [PhysicalDeviceID: (UUID, Task<Void, Never>)] = [:]
    private var latestPending: [LogicalDeviceID: UUID] = [:]
    private var validationAuthorizations: [UUID: SettingValidationAuthorization] = [:]
    public init(monitor: BatteryMonitor, registry: DriverRegistry? = nil) { self.monitor = monitor; self.registry = registry }

    /// Capture actual control replies into a private unconfirmed document. This never creates a write grant.
    public func captureStageLayoutEvidence(logicalDeviceID: LogicalDeviceID, saveTo url: URL) async throws -> RazerStageLayoutEvidence {
        guard let target = (await monitor.snapshot()).logicalDevices.first(where: { $0.id == logicalDeviceID }),
              let actual = await current(target.sessionID),
              let capturing = await adapter(for: actual) as? any DeviceStageLayoutCapturing else {
            throw TelemetryFailure(category: .unsupported, message: "No read-only stage-layout capture adapter for this target.")
        }
        let document = try await capturing.captureStageLayoutEvidence(target: actual.descriptor, session: actual.sessionID, saveTo: url)
        guard await current(actual.sessionID) != nil else { throw ProfileBackupError.staleAnonymousSession }
        return document
    }

    public func exportProfile(logicalDeviceID: LogicalDeviceID, saveTo url: URL,
                              hardwareEvidenceReference: String? = nil, expectedSession: LogicalDeviceSessionID? = nil) async throws -> ProfileBackup {
        let initial = try await readSettings(logicalDeviceID: logicalDeviceID, expectedSession: expectedSession)
        guard let target = (await monitor.snapshot()).logicalDevices.first(where: { $0.id == logicalDeviceID }), target.sessionID == initial.session, !target.descriptor.isIdentityAmbiguous,
              let backing = await adapter(for: target) as? any DeviceProfileBacking else {
            throw TelemetryFailure(category: .unsupported, message: "No profile backup adapter for this logical target.")
        }
        let backup = try await backing.exportProfile(target: target.descriptor, session: target.sessionID, saveTo: url,
            hardwareEvidenceReference: hardwareEvidenceReference)
        guard await current(target.sessionID) != nil else { throw ProfileBackupError.staleAnonymousSession }
        _ = try await readSettings(logicalDeviceID: logicalDeviceID, expectedSession: target.sessionID)
        return backup
    }
    /// Verifies the backup, saves current recovery bytes and creates an explicit draft. Does not write settings.
    public func prepareProfileRestore(backupURL: URL, rollbackBackupURL: URL, logicalDeviceID: LogicalDeviceID,
                                      hardwareEvidenceReference: String? = nil, expectedSession: LogicalDeviceSessionID? = nil) async throws -> SettingChangeRequest {
        guard let target = (await monitor.snapshot()).logicalDevices.first(where: { $0.id == logicalDeviceID }), expectedSession == nil || target.sessionID == expectedSession, !target.descriptor.isIdentityAmbiguous,
              let backing = await adapter(for: target) as? any DeviceProfileBacking else {
            throw TelemetryFailure(category: .unsupported, message: "No profile restore adapter for this logical target.")
        }
        let change = try await backing.prepareRestore(backupURL: backupURL, rollbackBackupURL: rollbackBackupURL,
            target: target.descriptor, session: target.sessionID, hardwareEvidenceReference: hardwareEvidenceReference)
        let snapshot = try await readSettings(logicalDeviceID: logicalDeviceID, expectedSession: target.sessionID)
        guard snapshot.session == target.sessionID else { throw ProfileBackupError.staleAnonymousSession }
        return SettingChangeRequest(target: snapshot.session, expectedRevision: snapshot.revision, change: change)
    }

    /// A normal verified onboard action first creates a private recovery file and rebinds only an unchanged actual draft.
    /// Candidate first-validation workflows still require their separate exact-operation authorization.
    public func prepareOnboardChange(_ request: SettingChangeRequest, saveBackupTo url: URL,
                                     hardwareEvidenceReference: String? = nil) async throws -> SettingChangeRequest {
        guard request.change.persistence == .onboard, let target = await current(request.target),
              let before = target.settings, before.revision == request.expectedRevision,
              request.change.validate(capabilities: target.capabilities).isEmpty else {
            throw TelemetryFailure(category: .unsupported, message: "A current write-verified onboard draft is required before preparing its recovery backup.")
        }
        let reference = hardwareEvidenceReference ?? (target.capabilities.permits(.stagesWrite) ? target.capabilities[.stagesWrite].source : nil)
        _ = try await exportProfile(logicalDeviceID: target.id, saveTo: url, hardwareEvidenceReference: reference, expectedSession: request.target)
        guard let refreshed = await current(request.target), let actual = refreshed.settings, actual.settings == before.settings else {
            throw TelemetryFailure(category: .cancelled, message: "The device changed while saving the recovery backup; the draft was not applied. Read it again before editing.")
        }
        return SettingChangeRequest(target: actual.session, expectedRevision: actual.revision, change: request.change)
    }

    public func preview(_ request: SettingChangeRequest) async -> [SettingValidationIssue] {
        let snapshot = await monitor.snapshot()
        guard snapshot.isMonitoring, !snapshot.isSuspended,
              let device = snapshot.logicalDevices.first(where: { $0.id == request.target.deviceID && $0.hostPresence == .present }),
              device.sessionID == request.target else {
            return [SettingValidationIssue(field: nil, reason: "The logical device session is no longer available.")]
        }
        var issues = request.change.validate(capabilities: device.capabilities)
        if device.descriptor.isIdentityAmbiguous { issues.append(SettingValidationIssue(field: nil, reason: "The device identity is ambiguous; settings writes are disabled.")) }
        if device.settings?.revision != request.expectedRevision { issues.append(SettingValidationIssue(field: nil, reason: "Settings changed; read the device before applying this draft.")) }
        return issues
    }
    public func readSettings(logicalDeviceID: LogicalDeviceID, expectedSession: LogicalDeviceSessionID? = nil) async throws -> DeviceSettingsSnapshot {
        let snapshot = await monitor.snapshot()
        guard let target = snapshot.logicalDevices.first(where: { $0.id == logicalDeviceID }),
              expectedSession == nil || target.sessionID == expectedSession else {
            throw TelemetryFailure(category: .removed, message: "The logical device no longer exists.")
        }
        let session = target.sessionID, host = session.address.hostSessionID.physicalDeviceID
        let id = UUID(), previous = tails[host]?.1
        let work = Task { [weak self] () throws -> DeviceSettingsSnapshot in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.performRead(session)
        }
        tails[host] = (id, Task { _ = try? await work.value })
        do { let result = try await work.value; finishQueue(host, id: id); return result }
        catch { finishQueue(host, id: id); throw error }
    }
    public func authorizeValidation(_ request: SettingChangeRequest, operation: SettingValidationOperation) async throws -> SettingValidationAuthorization {
        guard let target = await current(request.target), !target.descriptor.isIdentityAmbiguous, let before = target.settings, before.revision == request.expectedRevision,
              let adapter = await adapter(for: target) as? any DeviceSettingsValidationAuthorizing else {
            throw TelemetryFailure(category: .unsupported, message: "No current exact-target validation adapter is available.")
        }
        let authorization = try await adapter.authorizeValidation(request: request, before: before, target: target.descriptor, operation: operation)
        guard authorization.operation == operation, authorization.matches(request, at: Date()),
              request.change.validate(capabilities: authorization.capabilities).isEmpty,
              await current(request.target)?.settings?.revision == request.expectedRevision else {
            throw TelemetryFailure(category: .unsupported, message: "Validation authorization does not match the current request and proven protocol constraints.")
        }
        validationAuthorizations = validationAuthorizations.filter { $0.value.expiresAt > Date() }
        validationAuthorizations[authorization.id] = authorization
        return authorization
    }
    public func applyValidation(_ request: SettingChangeRequest, authorization: SettingValidationAuthorization) async -> SettingChangeResult {
        guard validationAuthorizations.removeValue(forKey: authorization.id) == authorization, authorization.matches(request, at: Date()) else {
            return result(request, status: .rejected, message: "Validation authorization is expired, reused or belongs to another request.")
        }
        return await enqueueApply(request, authorization: authorization)
    }
    public func apply(_ request: SettingChangeRequest) async -> SettingChangeResult { await enqueueApply(request, authorization: nil) }
    private func enqueueApply(_ request: SettingChangeRequest, authorization: SettingValidationAuthorization?) async -> SettingChangeResult {
        let host = request.target.address.hostSessionID.physicalDeviceID, id = UUID(), previous = tails[host]?.1
        let cancellation = SettingQueueCancellation()
        latestPending[request.target.deviceID] = request.id
        let work = Task { [weak self] in
            await previous?.value
            guard let self else {
                return SettingChangeResult(request: request, before: nil, observed: nil, persistence: .unknown, status: .superseded,
                    message: "The controller was closed.", finishedAt: Date())
            }
            return await self.performApply(request, authorization: authorization, cancellation: cancellation)
        }
        tails[host] = (id, Task { _ = await work.value })
        let result = await withTaskCancellationHandler { await work.value } onCancel: { cancellation.cancel() }
        finishQueue(host, id: id); return result
    }
    private func finishQueue(_ host: PhysicalDeviceID, id: UUID) { if tails[host]?.0 == id { tails.removeValue(forKey: host) } }
    private func adapter(for target: LogicalDeviceState) async -> (any DeviceSettingsAdapter)? {
        if let registry {
            let snapshot = await monitor.snapshot()
            if let host = snapshot.devices.first(where: { $0.id == target.sessionID.address.hostSessionID.physicalDeviceID }) {
                return registry.settingsAdapter(for: host.descriptor)
            }
            return nil
        }
        return await monitor.settingsAdapter(for: target.id)
    }
    private func current(_ session: LogicalDeviceSessionID) async -> LogicalDeviceState? {
        let snapshot = await monitor.snapshot()
        guard snapshot.isMonitoring, !snapshot.isSuspended else { return nil }
        return snapshot.logicalDevices.first { $0.id == session.deviceID && $0.sessionID == session && $0.hostPresence == .present }
    }
    private func performRead(_ session: LogicalDeviceSessionID) async throws -> DeviceSettingsSnapshot {
        guard let target = await current(session), target.canRefreshSettings, let adapter = await adapter(for: target) else {
            throw TelemetryFailure(category: .unsupported, message: "No current readable settings adapter is available.")
        }
        guard await monitor.beginSettingsRead(session, at: Date()) else {
            throw TelemetryFailure(category: .removed, message: "The device session changed before settings read.")
        }
        do {
            let settings = try await adapter.readSettings(target: target.descriptor, session: session)
            let capabilities = await capabilityUpdates(adapter, target: target.descriptor, session: session)
            guard let actual = await current(session) else { throw TelemetryFailure(category: .removed, message: "Discarded settings from an old device session.") }
            let revision = (actual.settings?.revision ?? 0) + 1
            let result = DeviceSettingsSnapshot(session: session, revision: revision, capturedAt: Date(), settings: settings)
            guard await monitor.publishSettings(result, capabilityUpdates: capabilities) else { throw TelemetryFailure(category: .removed, message: "The settings read was superseded.") }
            return result
        } catch {
            let failure = Self.failure(error)
            let capabilities = await capabilityUpdates(adapter, target: target.descriptor, session: session)
            await monitor.publishSettingsFailure(failure, session: session, at: Date(), capabilityUpdates: capabilities)
            throw failure
        }
    }
    private func performApply(_ request: SettingChangeRequest, authorization: SettingValidationAuthorization?, cancellation: SettingQueueCancellation) async -> SettingChangeResult {
        let targetID = request.target.deviceID
        guard !cancellation.isCancelled, latestPending[targetID] == request.id else { return result(request, status: .superseded, message: "A newer draft replaced this queued change.") }
        latestPending.removeValue(forKey: targetID)
        guard let target = await current(request.target), let before = target.settings,
              before.revision == request.expectedRevision else {
            return result(request, status: .superseded, message: "The device session or settings revision changed.")
        }
        if let authorization, !authorization.matches(request, at: Date()) {
            return result(request, before: before, status: .rejected, message: "Validation authorization expired while queued.")
        }
        guard !target.descriptor.isIdentityAmbiguous else { return result(request, before: before, status: .rejected, message: "The device identity is ambiguous; no settings were sent.") }
        let issues = request.change.validate(capabilities: authorization?.capabilities ?? target.capabilities)
        guard issues.isEmpty else { return result(request, before: before, status: .rejected, message: issues.map(\.reason).joined(separator: " ")) }
        guard let adapter = await adapter(for: target) else { return result(request, before: before, status: .rejected, message: "No registered settings adapter.") }
        guard !cancellation.isCancelled else { return result(request, before: before, status: .superseded, message: "Queued change cancelled before transaction start; no settings were sent.") }
        do {
            let transaction: SettingAdapterTransaction
            if let authorization, let validating = adapter as? any DeviceSettingsValidationAuthorizing {
                transaction = try await validating.applyValidationSettings(request: request, before: before, target: target.descriptor, authorization: authorization)
            } else {
                transaction = try await adapter.applySettings(request: request, before: before, target: target.descriptor)
            }
            guard let current = await current(request.target), current.settings?.revision == before.revision else {
                return result(request, before: before, status: .superseded, message: "The target changed while the transaction was in progress.")
            }
            let now = Date()
            let actualBefore = DeviceSettingsSnapshot(session: request.target, revision: before.revision, capturedAt: before.capturedAt, settings: transaction.before)
            let observed = transaction.observed.map { DeviceSettingsSnapshot(session: request.target, revision: before.revision + 1, capturedAt: now, settings: $0) }
            let outcome: SettingChangeResult
            if transaction.superseded || transaction.before != before.settings {
                outcome = SettingChangeResult(request: request, before: actualBefore, observed: observed, persistence: transaction.persistence,
                    status: .superseded, message: "Actual device settings changed before the write; no settings were sent.", finishedAt: now)
            } else {
                outcome = SettingChangeResult.verifying(request: request, before: actualBefore, observed: observed,
                    acknowledged: transaction.acknowledged, finishedAt: now, persistence: transaction.persistence,
                    failure: transaction.failure, fieldFailures: transaction.fieldFailures, failureScope: transaction.failureScope)
            }
            let capabilities = await capabilityUpdates(adapter, target: target.descriptor, session: request.target)
            _ = await monitor.publishSettingChange(outcome, capabilityUpdates: capabilities)
            return outcome
        } catch let rejection as any DeviceSettingsPreflightRejecting {
            let outcome = result(request, before: before, status: .rejected, message: rejection.rejectionMessage)
            let capabilities = await capabilityUpdates(adapter, target: target.descriptor, session: request.target)
            _ = await monitor.publishSettingChange(outcome, capabilityUpdates: capabilities)
            return outcome
        } catch {
            let failure = Self.failure(error)
            let outcome = result(request, before: before, status: .outcomeUnknown, message: failure.message)
            let capabilities = await capabilityUpdates(adapter, target: target.descriptor, session: request.target)
            _ = await monitor.publishSettingChange(outcome, capabilityUpdates: capabilities)
            return outcome
        }
    }
    private func capabilityUpdates(_ adapter: any DeviceSettingsAdapter, target: LogicalDeviceDescriptor,
                                   session: LogicalDeviceSessionID) async -> [DeviceOperation: OperationCapability] {
        guard let reporting = adapter as? any DeviceSettingsCapabilityReporting else { return [:] }
        return await reporting.settingsCapabilityUpdates(target: target, session: session)
    }
    private func result(_ request: SettingChangeRequest, before: DeviceSettingsSnapshot? = nil,
                        status: SettingChangeStatus, message: String) -> SettingChangeResult {
        SettingChangeResult(request: request, before: before, observed: nil, persistence: .unknown, status: status, message: message, finishedAt: Date())
    }
    private static func failure(_ error: any Error) -> TelemetryFailure {
        if let failure = error as? TelemetryFailure { return failure }
        if error is CancellationError { return TelemetryFailure(category: .cancelled, message: "Settings transaction cancelled; sent writes are not undone.") }
        return TelemetryFailure(category: .transport, message: String(describing: error), operation: "settings")
    }
}
