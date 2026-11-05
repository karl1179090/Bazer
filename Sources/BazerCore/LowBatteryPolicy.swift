// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only notification history is durable. This never restores battery samples.
public struct LowBatteryRecord: Equatable, Codable, Sendable {
    public var isArmed: Bool
    public var lastNotifiedAt: Date?
    /// The ears involved in a low event must all be observed recovered before rearming.
    public var recoveryComponents: Set<String>
    public init(isArmed: Bool = true, lastNotifiedAt: Date? = nil, recoveryComponents: Set<String> = []) {
        self.isArmed = isArmed; self.lastNotifiedAt = lastNotifiedAt; self.recoveryComponents = recoveryComponents
    }
    private enum CodingKeys: String, CodingKey { case isArmed, lastNotifiedAt, recoveryComponents }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isArmed = try c.decodeIfPresent(Bool.self, forKey: .isArmed) ?? true
        lastNotifiedAt = try c.decodeIfPresent(Date.self, forKey: .lastNotifiedAt)
        recoveryComponents = try c.decodeIfPresent(Set<String>.self, forKey: .recoveryComponents) ?? []
    }
}

public enum LowBatteryDecision: Equatable, Sendable {
    case none, rearm, notify(percent: Int)
}

public struct LowBatteryPolicy: Sendable {
    public static let threshold = 20
    public static let recoveryThreshold = 25
    public static let cooldown: TimeInterval = 6 * 60 * 60
    public init() {}

    public func evaluate(_ device: DeviceState, at now: Date, record: LowBatteryRecord) -> LowBatteryDecision {
        guard device.preferenceIdentity != nil, device.hostPresence == .present, !device.isRefreshing,
              device.capabilities.battery == .verified, device.access == .ready, device.consecutiveFailures == 0,
              device.batteryFailure == nil, device.chargingFailure == nil,
              let started = device.lastAttemptedAt, let finished = device.lastFinishedAt,
              finished >= started, finished <= now,
              let battery = device.battery, let percent = battery.percent, !battery.isEstimated,
              battery.receivedAt >= started, battery.receivedAt <= finished,
              now >= battery.receivedAt, !battery.isStale(at: now) else { return .none }
        let discharging: Bool
        if device.capabilities.powerSource == .replaceableBattery && !device.capabilities.chargingQuery {
            // A replaceable battery is not rechargeable over USB. Fresh battery evidence suffices.
            discharging = true
        } else {
            guard let charging = device.charging, charging.receivedAt >= started, charging.receivedAt <= finished,
                  now >= charging.receivedAt, !charging.isStale(at: now) else { return .none }
            discharging = charging.state == .notCharging || charging.state == .discharging
        }
        if percent >= Self.recoveryThreshold { return record.isArmed ? .none : .rearm }
        guard discharging, percent <= Self.threshold, record.isArmed else { return .none }
        if let last = record.lastNotifiedAt, now.timeIntervalSince(last) < Self.cooldown { return .none }
        return .notify(percent: percent)
    }
    public func evaluate(_ device: LogicalDeviceState, at now: Date, record: LowBatteryRecord) -> LowBatteryDecision {
        guard device.descriptor.preferenceIdentity != nil, device.hostPresence == .present, device.peerPresence != .unreachable, !device.isRefreshing,
              device.capabilities.battery == .verified, device.access == .ready, device.consecutiveFailures == 0,
              device.batteryFailure == nil, device.chargingFailure == nil,
              let started = device.lastAttemptedAt, let finished = device.lastFinishedAt, finished >= started, finished <= now,
              let battery = device.battery, let percent = battery.percent, !battery.isEstimated,
              battery.receivedAt >= started, battery.receivedAt <= finished, now >= battery.receivedAt,
              !battery.isStale(at: now) else { return .none }
        let discharging: Bool
        if device.capabilities.powerSource == .replaceableBattery && !device.capabilities.chargingQuery { discharging = true }
        else {
            guard let charging = device.charging, charging.receivedAt >= started, charging.receivedAt <= finished,
                  now >= charging.receivedAt, !charging.isStale(at: now) else { return .none }
            discharging = charging.state == .notCharging || charging.state == .discharging
        }
        if percent >= Self.recoveryThreshold { return record.isArmed ? .none : .rearm }
        guard discharging, percent <= Self.threshold, record.isArmed else { return .none }
        if let last = record.lastNotifiedAt, now.timeIntervalSince(last) < Self.cooldown { return .none }
        return .notify(percent: percent)
    }

}

public struct NotificationPreferences: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 2
    public private(set) var schemaVersion: Int
    public var isEnabled: Bool
    public var records: [String: LowBatteryRecord]
    public init(isEnabled: Bool = false, records: [String: LowBatteryRecord] = [:]) {
        schemaVersion = Self.currentSchemaVersion; self.isEnabled = isEnabled; self.records = records
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, isEnabled, records }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported notification schema.")
        }
        schemaVersion = version; isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        records = try c.decodeIfPresent([String: LowBatteryRecord].self, forKey: .records) ?? [:]
    }
    public mutating func upgradeSchema() { schemaVersion = Self.currentSchemaVersion }
    @discardableResult public mutating func migrateLegacyHost(_ host: DevicePreferenceIdentity,
        to children: [DevicePreferenceIdentity], isDirectPeripheral: Bool) -> Bool {
        guard isDirectPeripheral, children.count == 1, let child = children.first else { return false }
        if let record = records[host.rawValue], records[child.rawValue] == nil { records[child.rawValue] = record }
        if host != child { records.removeValue(forKey: host.rawValue) }
        return true
    }
}

public protocol NotificationPreferencesPersisting: Sendable {
    func load() throws -> NotificationPreferences
    func save(_ preferences: NotificationPreferences) throws
}

public struct FileNotificationPreferences: NotificationPreferencesPersisting {
    public let url: URL
    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Bazer/notification-preferences.json")) { self.url = url }
    public func load() throws -> NotificationPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return NotificationPreferences() }
        let original = try Data(contentsOf: url)
        var preferences = try JSONDecoder().decode(NotificationPreferences.self, from: original)
        if preferences.schemaVersion < NotificationPreferences.currentSchemaVersion {
            let backup = url.appendingPathExtension("schema-v1.backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, options: .withoutOverwriting) }
            preferences.upgradeSchema(); try save(preferences)
        }
        return preferences
    }
    public func save(_ preferences: NotificationPreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var current = preferences; current.upgradeSchema()
        try JSONEncoder().encode(current).write(to: url, options: .atomic)
    }
}
