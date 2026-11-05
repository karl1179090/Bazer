// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Opaque UI identity. It is deliberately distinct from a persistent preference key.
public struct BluetoothAudioDeviceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct BluetoothAudioSession: Hashable, Codable, Sendable {
    public let id: UUID
    public let generation: UInt64
    public init(id: UUID = UUID(), generation: UInt64) { self.id = id; self.generation = generation }
}

public enum BluetoothAudioConnection: String, Codable, Sendable { case connected, disconnected, uncertain }
public enum BluetoothAudioIdentityQuality: String, Codable, Sendable { case verified, sessionOnly, ambiguous }
public enum BluetoothAudioComponent: String, CaseIterable, Codable, Sendable { case single, left, right, `case`, unknown }
public enum BluetoothAudioReadStatus: String, Codable, Sendable { case success, partial, failed, unavailable }

/// observedAt is when Bazer read the system report, never a fabricated hardware timestamp.
public struct BluetoothAudioBatteryReading: Equatable, Codable, Sendable {
    public let component: BluetoothAudioComponent
    /// Source-scoped part key for presentation, distinct from part semantics.
    public let componentID: String
    public let percent: Int?
    public let charging: ChargingState
    public let source: String
    public let observedAt: Date
    public let sourceUpdatedAt: Date?
    public let session: BluetoothAudioSession
    public let isPresent: Bool
    public let isNative: Bool
    public init(component: BluetoothAudioComponent = .single, componentID: String? = nil, percent: Int?, charging: ChargingState = .unknown,
                source: String, observedAt: Date, sourceUpdatedAt: Date? = nil, session: BluetoothAudioSession,
                isPresent: Bool = true, isNative: Bool = true) {
        self.component = component; self.componentID = componentID ?? component.rawValue
        self.percent = percent.flatMap { (0...100).contains($0) ? $0 : nil }
        self.charging = charging; self.source = source; self.observedAt = observedAt
        self.sourceUpdatedAt = sourceUpdatedAt; self.session = session; self.isPresent = isPresent; self.isNative = isNative
    }
    public func isFresh(at date: Date, maximumAge: TimeInterval = 180) -> Bool {
        guard date >= observedAt, date.timeIntervalSince(observedAt) < maximumAge else { return false }
        if let updated = sourceUpdatedAt {
            return updated <= date && updated <= observedAt && date.timeIntervalSince(updated) < maximumAge
        }
        return true
    }
}

public struct BluetoothAudioDevice: Equatable, Codable, Sendable, Identifiable {
    public let id: BluetoothAudioDeviceID
    public var name: String
    public var session: BluetoothAudioSession
    public var connection: BluetoothAudioConnection
    public var identityQuality: BluetoothAudioIdentityQuality
    /// Only supplied by an explicitly verified identity policy; names and source IDs never qualify.
    public var preferenceIdentity: String?
    public var batteryReadings: [BluetoothAudioBatteryReading]
    public var lastReadings: [BluetoothAudioBatteryReading]
    public var readStatus: BluetoothAudioReadStatus
    public var statusMessage: String?
    public var lastSeenAt: Date
    public var eventVersion: UInt64
    public init(id: BluetoothAudioDeviceID, name: String, session: BluetoothAudioSession,
                connection: BluetoothAudioConnection = .connected, identityQuality: BluetoothAudioIdentityQuality = .sessionOnly,
                preferenceIdentity: String? = nil, batteryReadings: [BluetoothAudioBatteryReading] = [],
                lastReadings: [BluetoothAudioBatteryReading] = [], readStatus: BluetoothAudioReadStatus = .success,
                statusMessage: String? = nil, lastSeenAt: Date, eventVersion: UInt64 = 0) {
        self.id = id; self.name = name; self.session = session; self.connection = connection
        self.identityQuality = identityQuality
        self.preferenceIdentity = identityQuality == .verified ? preferenceIdentity : nil
        self.batteryReadings = batteryReadings; self.lastReadings = lastReadings; self.readStatus = readStatus
        self.statusMessage = statusMessage; self.lastSeenAt = lastSeenAt; self.eventVersion = eventVersion
    }
    public func currentReadings(at date: Date) -> [BluetoothAudioBatteryReading] {
        guard connection == .connected, readStatus == .success else { return [] }
        return batteryReadings.filter { $0.session == session && $0.isPresent && $0.isFresh(at: date) }
    }
    public func currentPercent(at date: Date) -> Int? {
        let readings = currentReadings(at: date)
        if let single = readings.first(where: { $0.component == .single }) { return single.percent }
        return readings.filter { $0.component == .left || $0.component == .right }.compactMap(\.percent).min()
    }
    public func notificationReadings(at date: Date) -> [BluetoothAudioBatteryReading] {
        guard identityQuality == .verified, preferenceIdentity != nil else { return [] }
        let current = currentReadings(at: date).filter { [.single, .left, .right].contains($0.component) }
        guard !current.isEmpty, current.allSatisfy({ $0.percent != nil && $0.isNative && ($0.charging == .discharging || $0.charging == .notCharging) }) else { return [] }
        return current
    }
}

public struct BluetoothAudioSnapshot: Equatable, Sendable {
    public let epoch: UInt64
    public let requestID: UInt64
    public let startedAt: Date
    public let finishedAt: Date
    public let devices: [BluetoothAudioDevice]
    public let discoveryStatus: BluetoothAudioReadStatus
    public let powerStatus: BluetoothAudioReadStatus
    public let statusMessage: String?
    public init(epoch: UInt64 = 0, requestID: UInt64 = 0, startedAt: Date = .distantPast, finishedAt: Date = .distantPast,
                devices: [BluetoothAudioDevice] = [], discoveryStatus: BluetoothAudioReadStatus = .unavailable,
                powerStatus: BluetoothAudioReadStatus = .unavailable, statusMessage: String? = nil) {
        self.epoch = epoch; self.requestID = requestID; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.devices = devices; self.discoveryStatus = discoveryStatus; self.powerStatus = powerStatus; self.statusMessage = statusMessage
    }
}
