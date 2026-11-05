// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SettingChangeStatus: String, Codable, Sendable {
    case verified, rejected, superseded, outcomeUnknown, readbackMismatch, partialFailure
}
/// Adapters must explicitly distinguish validation failures from a missing write ACK.
public enum SettingFailureScope: String, Codable, Sendable {
    /// Complete validation failed; matching known values cannot prove any requested field.
    case transaction
    /// Only the explicitly named fields failed validation.
    case perField
    /// Only receipt of a write ACK failed; valid independent readback may resolve it.
    case acknowledgement
}
public struct SettingFieldResult: Equatable, Codable, Sendable {
    public let field: SettingField
    public let status: SettingChangeStatus
    public let message: String?
    public init(field: SettingField, status: SettingChangeStatus, message: String? = nil) {
        self.field = field; self.status = status; self.message = message
    }
}
public struct SettingChangeResult: Equatable, Codable, Sendable {
    public let request: SettingChangeRequest
    public var requested: DeviceSettingsChange { request.change }
    public let before: DeviceSettingsSnapshot?
    public let observed: DeviceSettingsSnapshot?
    public let persistence: SettingPersistence
    public let status: SettingChangeStatus
    public let fields: [SettingFieldResult]
    public let message: String?
    public let finishedAt: Date
    public init(request: SettingChangeRequest, before: DeviceSettingsSnapshot?, observed: DeviceSettingsSnapshot?,
                persistence: SettingPersistence, status: SettingChangeStatus, fields: [SettingFieldResult] = [],
                message: String? = nil, finishedAt: Date) {
        self.request = request; self.before = before; self.observed = observed; self.persistence = persistence
        self.status = status; self.fields = fields; self.message = message; self.finishedAt = finishedAt
    }
    /// ACK is not proof of the requested state. An adapter's validation failures also constrain readback.
    public static func verifying(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                                 observed: DeviceSettingsSnapshot?, acknowledged: Bool, finishedAt: Date,
                                 persistence: SettingPersistence = .unknown, failure: TelemetryFailure? = nil,
                                 fieldFailures: [SettingField: TelemetryFailure] = [:],
                                 failureScope: SettingFailureScope = .transaction) -> Self {
        let reportedFailure = failure ?? fieldFailures.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value
        guard before.session == request.target, before.revision == request.expectedRevision else {
            return Self(request: request, before: before, observed: observed, persistence: persistence, status: .superseded,
                        message: "The editing session or settings revision changed.", finishedAt: finishedAt)
        }
        guard let observed else {
            return Self(request: request, before: before, observed: nil, persistence: persistence, status: .outcomeUnknown,
                        message: reportedFailure?.message ?? (acknowledged ? "Write acknowledged; readback unavailable." : "Write outcome is unknown; read before retrying."), finishedAt: finishedAt)
        }
        guard observed.session == request.target, observed.revision > before.revision, observed.capturedAt >= before.capturedAt else {
            return Self(request: request, before: before, observed: observed, persistence: persistence, status: .superseded,
                        message: "Readback belongs to another session or is not newer than the original snapshot.", finishedAt: finishedAt)
        }
        let requestedFields = Set(request.change.fields)
        // Per-field scope is a positive adapter assertion. A missing or unrelated
        // field map cannot narrow an otherwise transaction-wide failure.
        let scoped = failureScope != .transaction && Set(fieldFailures.keys).isSubset(of: requestedFields)
            && (failure == nil || !fieldFailures.isEmpty)
        let hasFailure = failure != nil || !fieldFailures.isEmpty
        let globalFailure = hasFailure && !scoped
        let results = request.change.fields.map { field in
            let fieldFailure = fieldFailures[field]
            let status: SettingChangeStatus
            let hasValue: Bool = switch field {
            case .currentDPI: observed.settings.currentDPI != nil
            case .pollingRate: observed.settings.pollingRateHz != nil
            case .stages: observed.settings.stages != nil
            case .activeProfile: observed.settings.activeProfileID != nil
            case .currentStage: observed.settings.currentStageID != nil
            }
            if !hasValue {
                status = .outcomeUnknown
            } else if !request.change.matches(observed.settings, field: field) {
                status = .readbackMismatch
            } else if globalFailure || (fieldFailure != nil && failureScope != .acknowledgement) {
                status = .outcomeUnknown
            } else {
                status = .verified
            }
            return SettingFieldResult(field: field, status: status,
                message: fieldFailure?.message ?? (globalFailure ? reportedFailure?.message : nil))
        }
        let status: SettingChangeStatus
        if results.isEmpty { status = .rejected }
        else if results.allSatisfy({ $0.status == .verified }) { status = .verified }
        else if results.allSatisfy({ $0.status == .readbackMismatch }) { status = .readbackMismatch }
        else if results.allSatisfy({ $0.status == .outcomeUnknown }) { status = .outcomeUnknown }
        else { status = .partialFailure }
        return Self(request: request, before: before, observed: observed, persistence: persistence, status: status,
                    fields: results, message: reportedFailure?.message, finishedAt: finishedAt)
    }
}
