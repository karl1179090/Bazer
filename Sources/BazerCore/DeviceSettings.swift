// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct DPISetting: Equatable, Codable, Sendable {
    public let x: UInt16
    public let y: UInt16
    public init(x: UInt16, y: UInt16) { self.x = x; self.y = y }
    public init(_ unified: UInt16) { self.init(x: unified, y: unified) }
}
public struct DPIStage: Equatable, Codable, Sendable {
    /// Protocol stage identifier; it is deliberately not a UI array index.
    public let id: UInt8
    public let dpi: DPISetting
    public init(id: UInt8, dpi: DPISetting) { self.id = id; self.dpi = dpi }
}
public struct DPIStageTable: Equatable, Codable, Sendable {
    public let stages: [DPIStage]
    public let activeStageID: UInt8
    public let defaultStageID: UInt8?
    /// Complete original payload enables adapters to preserve unknown fields.
    public let opaqueBytes: [UInt8]
    public init(stages: [DPIStage], activeStageID: UInt8, opaqueBytes: [UInt8] = [], defaultStageID: UInt8? = nil) {
        self.stages = stages; self.activeStageID = activeStageID; self.opaqueBytes = opaqueBytes; self.defaultStageID = defaultStageID
    }
    public var isValid: Bool {
        !stages.isEmpty && Set(stages.map(\.id)).count == stages.count && stages.contains { $0.id == activeStageID } && (defaultStageID.map { id in stages.contains { $0.id == id } } ?? true)
    }
}
public struct DeviceSettings: Equatable, Codable, Sendable {
    public let currentDPI: DPISetting?
    public let pollingRateHz: Int?
    public let stages: DPIStageTable?
    public let activeProfileID: Int?
    public let currentStageID: UInt8?
    public init(currentDPI: DPISetting? = nil, pollingRateHz: Int? = nil, stages: DPIStageTable? = nil, activeProfileID: Int? = nil, currentStageID: UInt8? = nil) {
        self.currentDPI = currentDPI; self.pollingRateHz = pollingRateHz; self.stages = stages; self.activeProfileID = activeProfileID; self.currentStageID = currentStageID
    }
}
public struct DeviceSettingsSnapshot: Equatable, Codable, Sendable {
    public let session: LogicalDeviceSessionID
    public let revision: UInt64
    public let capturedAt: Date
    public let settings: DeviceSettings
    public init(session: LogicalDeviceSessionID, revision: UInt64, capturedAt: Date, settings: DeviceSettings) {
        self.session = session; self.revision = revision; self.capturedAt = capturedAt; self.settings = settings
    }
}
public enum SettingField: String, CaseIterable, Codable, Sendable { case currentDPI, pollingRate, stages, activeProfile, currentStage }
public struct DeviceSettingsChange: Equatable, Codable, Sendable {
    public let currentDPI: DPISetting?
    public let pollingRateHz: Int?
    public let stages: DPIStageTable?
    public let activeProfileID: Int?
    public let currentStageID: UInt8?
    public let persistence: SettingPersistence
    public init(currentDPI: DPISetting? = nil, pollingRateHz: Int? = nil, stages: DPIStageTable? = nil,
                activeProfileID: Int? = nil, persistence: SettingPersistence = .runtime, currentStageID: UInt8? = nil) {
        self.currentDPI = currentDPI; self.pollingRateHz = pollingRateHz; self.stages = stages
        self.activeProfileID = activeProfileID; self.persistence = persistence; self.currentStageID = currentStageID
    }
    public var fields: [SettingField] {
        var fields: [SettingField] = []
        if currentDPI != nil { fields.append(.currentDPI) }; if pollingRateHz != nil { fields.append(.pollingRate) }
        if stages != nil { fields.append(.stages) }; if activeProfileID != nil { fields.append(.activeProfile) }
        if currentStageID != nil { fields.append(.currentStage) }
        return fields
    }
    public func matches(_ settings: DeviceSettings, field: SettingField) -> Bool {
        switch field {
        case .currentDPI: currentDPI != nil && currentDPI == settings.currentDPI
        case .pollingRate: pollingRateHz != nil && pollingRateHz == settings.pollingRateHz
        case .activeProfile: activeProfileID != nil && activeProfileID == settings.activeProfileID
        case .currentStage: currentStageID != nil && currentStageID == settings.currentStageID
        case .stages:
            stages != nil && stages?.stages == settings.stages?.stages && stages?.activeStageID == settings.stages?.activeStageID && stages?.defaultStageID == settings.stages?.defaultStageID
        }
    }
    /// No I/O. Unknown ranges and unproven writes are rejected before constructing a frame.
    public func validate(capabilities: DeviceCapabilities) -> [SettingValidationIssue] {
        var issues: [SettingValidationIssue] = []
        if fields.isEmpty { issues.append(SettingValidationIssue(field: nil, reason: "No settings were requested.")) }
        if persistence == .unknown { issues.append(SettingValidationIssue(field: nil, reason: "A concrete persistence scope is required.")) }
        func check(_ operation: DeviceOperation, field: SettingField, values: [Int] = []) {
            let capability = capabilities[operation]
            if !capability.permits(operation) { issues.append(SettingValidationIssue(field: field, reason: capability.failureReason ?? "Operation \(operation.rawValue) is not write verified.")) }
            if !capability.constraints.persistenceScopes.contains(persistence) {
                issues.append(SettingValidationIssue(field: field, reason: "The requested persistence scope is not supported."))
            }
            if !values.isEmpty && (!capability.constraints.hasNumericDomain || !values.allSatisfy(capability.constraints.accepts)) {
                issues.append(SettingValidationIssue(field: field, reason: "Value is outside the proven range or discrete set."))
            }
        }
        func checkAxes(_ dpi: DPISetting, field: SettingField, operation: DeviceOperation) {
            if dpi.x != dpi.y && !capabilities.permits(.independentXY) {
                issues.append(SettingValidationIssue(field: field, reason: "Independent X/Y DPI is not verified."))
            }
            if let pairs = capabilities[operation].constraints.allowedDPIPairs, !pairs.contains(dpi) {
                issues.append(SettingValidationIssue(field: field, reason: "The requested X/Y pair is outside the exact proven combinations."))
            }
        }
        if let currentDPI { check(.dpiWrite, field: .currentDPI, values: [Int(currentDPI.x), Int(currentDPI.y)]); checkAxes(currentDPI, field: .currentDPI, operation: .dpiWrite) }
        if let pollingRateHz { check(.pollingRateWrite, field: .pollingRate, values: [pollingRateHz]) }
        if let stages {
            check(.stagesWrite, field: .stages, values: stages.stages.flatMap { [Int($0.dpi.x), Int($0.dpi.y)] })
            if !stages.isValid || capabilities[.stagesWrite].constraints.maximumStages.map({ stages.stages.count > $0 }) ?? true {
                issues.append(SettingValidationIssue(field: .stages, reason: "Invalid stage identifiers, active stage or unproven stage count."))
            }
            for stage in stages.stages { checkAxes(stage.dpi, field: .stages, operation: .stagesWrite) }
        }
        if let currentStageID { check(.stageSelect, field: .currentStage, values: [Int(currentStageID)]) }
        if let activeProfileID {
            check(.onboardWrite, field: .activeProfile, values: [activeProfileID])
            if activeProfileID < 0 { issues.append(SettingValidationIssue(field: .activeProfile, reason: "Profile identifiers cannot be negative.")) }
        }
        if persistence == .onboard && !capabilities.permits(.onboardPersist) {
            issues.append(SettingValidationIssue(field: nil, reason: "Onboard persistence is not verified."))
        }
        return issues
    }
}
public struct SettingValidationIssue: Equatable, Codable, Sendable {
    public let field: SettingField?
    public let reason: String
    public init(field: SettingField?, reason: String) { self.field = field; self.reason = reason }
}
public struct SettingChangeRequest: Equatable, Codable, Sendable {
    public let id: UUID
    public let target: LogicalDeviceSessionID
    public let expectedRevision: UInt64
    public let change: DeviceSettingsChange
    public init(id: UUID = UUID(), target: LogicalDeviceSessionID, expectedRevision: UInt64, change: DeviceSettingsChange) {
        self.id = id; self.target = target; self.expectedRevision = expectedRevision; self.change = change
    }
}
