// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum HostPresence: String, Codable, Sendable { case present, removed }
public enum AccessState: String, Codable, Sendable { case untested, ready, denied, busy, failed }
public enum PeerPresence: String, Codable, Sendable { case unknown, reachable, unreachable }
public enum BatterySupport: String, Codable, Sendable { case unsupported, candidate, verified }
public enum DeviceKind: String, Codable, Sendable { case mouse, keyboard, other }
public enum ChargingState: String, Codable, Sendable {
    case charging, discharging, full, notApplicable, unknown, slow, error
    /// Kept for the verified Razer 07/84 zero response; it is not a universal HID++ mapping.
    case notCharging
}

public enum ApproximateBatteryLevel: String, Codable, Sendable { case critical, low, good, full, unknown }
public enum BatteryValue: Equatable, Codable, Sendable {
    case percentage(Int)
    case approximateLevel(ApproximateBatteryLevel)
    case voltageOnly(millivolts: Int)
    case unknown
    case notApplicable
}

/// Optional display metadata derived from a voltage sample, never native SOC.
/// Display resolution is not an accuracy or a device-specific calibration claim.
public struct BatteryPercentageEstimate: Equatable, Codable, Sendable {
    public let value: Int
    public let source: String
    public let resolution: String
    public var isEstimated: Bool { true }
    public var isCalibrated: Bool { false }
    public init?(value: Int, source: String, resolution: String) {
        guard (0...100).contains(value), !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !resolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.value = value; self.source = source; self.resolution = resolution
    }
    private enum CodingKeys: String, CodingKey { case value, source, resolution, isEstimated, isCalibrated }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let estimate = Self(value: try c.decode(Int.self, forKey: .value), source: try c.decode(String.self, forKey: .source),
                                  resolution: try c.decode(String.self, forKey: .resolution)),
              try c.decodeIfPresent(Bool.self, forKey: .isEstimated) != false,
              try c.decodeIfPresent(Bool.self, forKey: .isCalibrated) != true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid uncalibrated percentage estimate"))
        }
        self = estimate
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value); try c.encode(source, forKey: .source); try c.encode(resolution, forKey: .resolution)
        try c.encode(true, forKey: .isEstimated); try c.encode(false, forKey: .isCalibrated)
    }
}

public struct BatterySample: Equatable, Codable, Sendable {
    public let value: BatteryValue
    public let rawBytes: [UInt8]
    public let receivedAt: Date
    /// Protocol conversion provenance, not a claim of physical measurement accuracy.
    public let source: String
    public let resolution: String?
    public let isEstimated: Bool
    /// Only attached to voltage values. `percent` remains native-protocol-only.
    public let percentageEstimate: BatteryPercentageEstimate?
    public var percent: Int? { if case let .percentage(value) = value { return value }; return nil }
    public var millivolts: Int? { if case let .voltageOnly(value) = value { return value }; return nil }
    /// Compatibility access to a single protocol byte. Voltage is never squeezed into UInt8.
    public var rawValue: UInt8? { rawBytes.count == 1 ? rawBytes[0] : nil }

    public init(value: BatteryValue, rawBytes: [UInt8] = [], receivedAt: Date, source: String,
                resolution: String? = nil, isEstimated: Bool = false, percentageEstimate: BatteryPercentageEstimate? = nil) {
        switch value {
        case let .percentage(percent) where !(0...100).contains(percent): self.value = .unknown
        case let .voltageOnly(millivolts) where millivolts < 0: self.value = .unknown
        default: self.value = value
        }
        self.rawBytes = rawBytes; self.receivedAt = receivedAt; self.source = source
        self.resolution = resolution; self.isEstimated = isEstimated
        if case .voltageOnly = self.value { self.percentageEstimate = percentageEstimate }
        else { self.percentageEstimate = nil }
    }
    /// Legacy Razer raw255 conversion. Legal zero and historical rounding are preserved.
    /// Native percent protocols must use init(value: .percentage(...)), never this initializer.
    public init(rawValue: UInt8, receivedAt: Date, source: String) {
        self.init(value: .percentage(Int((Double(rawValue) * 100 / 255).rounded())), rawBytes: [rawValue],
                  receivedAt: receivedAt, source: source, resolution: "Razer 0…255 normalized to 1% display")
    }
    public func isStale(at date: Date, maximumAge: TimeInterval = 180) -> Bool {
        date < receivedAt || date.timeIntervalSince(receivedAt) >= maximumAge
    }
    private enum CodingKeys: String, CodingKey { case value, rawBytes, rawValue, receivedAt, source, resolution, isEstimated, percentageEstimate }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let date = try c.decode(Date.self, forKey: .receivedAt), source = try c.decode(String.self, forKey: .source)
        if let value = try c.decodeIfPresent(BatteryValue.self, forKey: .value) {
            self.init(value: value, rawBytes: try c.decodeIfPresent([UInt8].self, forKey: .rawBytes) ?? [], receivedAt: date,
                      source: source, resolution: try c.decodeIfPresent(String.self, forKey: .resolution),
                      isEstimated: try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false,
                      percentageEstimate: try? c.decodeIfPresent(BatteryPercentageEstimate.self, forKey: .percentageEstimate))
        } else {
            self.init(rawValue: try c.decode(UInt8.self, forKey: .rawValue), receivedAt: date, source: source)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value); try c.encode(rawBytes, forKey: .rawBytes)
        try c.encode(receivedAt, forKey: .receivedAt); try c.encode(source, forKey: .source)
        try c.encodeIfPresent(resolution, forKey: .resolution); try c.encode(isEstimated, forKey: .isEstimated)
        try c.encodeIfPresent(percentageEstimate, forKey: .percentageEstimate)
    }
}

public struct ChargingSample: Equatable, Codable, Sendable {
    public let state: ChargingState
    public let rawValue: UInt8?
    public let receivedAt: Date
    public let source: String

    public init(state: ChargingState, rawValue: UInt8?, receivedAt: Date, source: String) {
        self.state = state
        self.rawValue = rawValue
        self.receivedAt = receivedAt
        self.source = source
    }
    public func isStale(at date: Date, maximumAge: TimeInterval = 180) -> Bool {
        date.timeIntervalSince(receivedAt) >= maximumAge
    }
}

public enum TelemetryFailureCategory: String, Codable, Sendable {
    case denied, busy, timeout, removed, transport, malformedResponse, deviceStatus, unsupported, cancelled
}

public struct TelemetryFailure: Error, Equatable, Codable, Sendable {
    public let category: TelemetryFailureCategory
    public let message: String
    public let ioReturn: Int32?
    public let operation: String?
    public let endpointRegistryEntryID: UInt64?
    public let protocolStatus: UInt8?

    public init(category: TelemetryFailureCategory, message: String, ioReturn: Int32? = nil, operation: String? = nil, endpointRegistryEntryID: UInt64? = nil, protocolStatus: UInt8? = nil) {
        self.category = category
        self.message = message
        self.ioReturn = ioReturn
        self.operation = operation
        self.endpointRegistryEntryID = endpointRegistryEntryID
        self.protocolStatus = protocolStatus
    }
}
