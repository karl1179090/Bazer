// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Control-channel diagnostics only. Never place ordinary HID input, keys or motion in this envelope.
public struct DeviceDiagnosticEnvelope: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let capturedAt: Date
    public let hostSession: DeviceSessionID
    public let logicalSession: LogicalDeviceSessionID?
    public let operation: DeviceOperation
    public let endpointRegistryEntryID: UInt64?
    public let durationMilliseconds: Double?
    public let evidence: CapabilityEvidence
    public let failure: TelemetryFailure?
    public init(capturedAt: Date, hostSession: DeviceSessionID, logicalSession: LogicalDeviceSessionID? = nil,
                operation: DeviceOperation, endpointRegistryEntryID: UInt64? = nil, durationMilliseconds: Double? = nil,
                evidence: CapabilityEvidence = .unknown, failure: TelemetryFailure? = nil) {
        schemaVersion = 1; self.capturedAt = capturedAt; self.hostSession = hostSession; self.logicalSession = logicalSession
        self.operation = operation; self.endpointRegistryEntryID = endpointRegistryEntryID
        self.durationMilliseconds = durationMilliseconds; self.evidence = evidence; self.failure = failure
    }
}
