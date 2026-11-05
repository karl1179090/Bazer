// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum DeviceOperation: String, Codable, CaseIterable, Sendable {
    case batteryRead, chargingRead, voltageRead
    case dpiRead, dpiWrite, independentXY, stagesRead, stagesWrite, stageSelect
    case pollingRateRead, pollingRateWrite, onboardRead, onboardWrite, onboardPersist
    public var isWrite: Bool {
        [.dpiWrite, .independentXY, .stagesWrite, .stageSelect, .pollingRateWrite, .onboardWrite, .onboardPersist].contains(self)
    }
}

/// Evidence is per operation. Reading a battery never authorizes a settings write.
public enum CapabilityEvidence: String, Codable, Sendable {
    case unknown, unsupported, catalogued, discovered, readVerified, writeVerified, persistenceVerified
    public var permitsRead: Bool { [.discovered, .readVerified, .writeVerified, .persistenceVerified].contains(self) }
    public var permitsWrite: Bool { [.writeVerified, .persistenceVerified].contains(self) }
}

public enum SettingPersistence: String, Codable, CaseIterable, Sendable {
    case runtime, onboard, unknown
}

public enum PowerSource: String, Codable, Sendable { case unknown, rechargeableBattery, replaceableBattery, wired }

public struct CapabilityConstraints: Equatable, Codable, Sendable {
    public let minimum: Int?
    public let maximum: Int?
    public let step: Int?
    public let allowedValues: [Int]
    public let maximumStages: Int?
    public let persistenceScopes: Set<SettingPersistence>
    /// Optional exact X/Y pairs. Absence preserves legacy scalar constraints;
    /// a pair list never grants its axes' untested Cartesian product.
    public let allowedDPIPairs: [DPISetting]?
    public init(minimum: Int? = nil, maximum: Int? = nil, step: Int? = nil,
                allowedValues: [Int] = [], maximumStages: Int? = nil,
                persistenceScopes: Set<SettingPersistence> = [], allowedDPIPairs: [DPISetting]? = nil) {
        self.minimum = minimum; self.maximum = maximum; self.step = step
        self.allowedValues = Array(Set(allowedValues)).sorted(); self.maximumStages = maximumStages
        self.persistenceScopes = persistenceScopes
        self.allowedDPIPairs = allowedDPIPairs.map { pairs in
            pairs.reduce(into: [DPISetting]()) { if !$0.contains($1) { $0.append($1) } }.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        }
    }
    public func accepts(_ value: Int) -> Bool {
        if let minimum, value < minimum { return false }
        if let maximum, value > maximum { return false }
        if !allowedValues.isEmpty && !allowedValues.contains(value) { return false }
        if let step {
            let (offset, overflow) = value.subtractingReportingOverflow(minimum ?? 0)
            guard step > 0, !overflow, offset % step == 0 else { return false }
        }
        return true
    }
    public var hasNumericDomain: Bool { !allowedValues.isEmpty || (minimum != nil && maximum != nil) }
    public func accepts(_ dpi: DPISetting) -> Bool {
        accepts(Int(dpi.x)) && accepts(Int(dpi.y)) && (allowedDPIPairs.map { $0.contains(dpi) } ?? true)
    }
}

public struct OperationCapability: Equatable, Codable, Sendable {
    public let evidence: CapabilityEvidence
    public let constraints: CapabilityConstraints
    public let source: String?
    public let failureReason: String?
    public init(evidence: CapabilityEvidence = .unknown, constraints: CapabilityConstraints = CapabilityConstraints(),
                source: String? = nil, failureReason: String? = nil) {
        self.evidence = evidence; self.constraints = constraints; self.source = source; self.failureReason = failureReason
    }
    public func permits(_ operation: DeviceOperation) -> Bool {
        operation.isWrite ? evidence.permitsWrite : evidence.permitsRead
    }
}

public struct DeviceCapabilities: Equatable, Codable, Sendable {
    public private(set) var battery: BatterySupport
    public let chargingQuery: Bool
    public let powerSource: PowerSource
    public private(set) var operations: [DeviceOperation: OperationCapability]
    public init(battery: BatterySupport = .unsupported, chargingQuery: Bool = false,
                powerSource: PowerSource = .unknown, operations: [DeviceOperation: OperationCapability] = [:]) {
        self.battery = battery; self.chargingQuery = chargingQuery; self.powerSource = powerSource
        self.operations = operations
        if self.operations[.batteryRead] == nil, battery != .unsupported {
            self.operations[.batteryRead] = OperationCapability(evidence: battery == .verified ? .readVerified : .catalogued)
        }
        if self.operations[.chargingRead] == nil, chargingQuery {
            self.operations[.chargingRead] = OperationCapability(evidence: .catalogued)
        }
    }
    public subscript(_ operation: DeviceOperation) -> OperationCapability { operations[operation] ?? OperationCapability() }
    public func permits(_ operation: DeviceOperation) -> Bool { self[operation].permits(operation) }
    public var canReadSettings: Bool { [.dpiRead, .stagesRead, .pollingRateRead, .onboardRead].contains { ![.unknown, .unsupported].contains(self[$0].evidence) } }
    public mutating func record(_ capability: OperationCapability, for operation: DeviceOperation) { operations[operation] = capability }
    public mutating func recordBatteryRead() {
        battery = .verified
        let prior = self[.batteryRead]
        if [.unknown, .unsupported, .catalogued, .discovered].contains(prior.evidence) { operations[.batteryRead] = OperationCapability(evidence: .readVerified, constraints: prior.constraints, source: prior.source) }
    }
    public mutating func preserveReadEvidence(from prior: DeviceCapabilities) {
        for operation in [DeviceOperation.dpiRead, .stagesRead, .pollingRateRead, .onboardRead, .voltageRead, .chargingRead] {
            let incoming = self[operation], old = prior[operation]
            if old.evidence == .readVerified && [.catalogued, .discovered].contains(incoming.evidence) {
                operations[operation] = OperationCapability(evidence: .readVerified, constraints: incoming.constraints, source: incoming.source)
            }
        }
    }
    public static let identificationOnly = DeviceCapabilities()
}
