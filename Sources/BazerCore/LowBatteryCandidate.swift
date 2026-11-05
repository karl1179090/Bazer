// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A separate, strict adapter boundary for system-reported audio batteries.
/// HID continues to use LowBatteryPolicy's original successful-query rules.
public struct LowBatteryCandidate: Equatable, Sendable {
    public struct Component: Equatable, Sendable {
        public let id: String
        public let percent: Int
        public init(id: String, percent: Int) { self.id = id; self.percent = percent }
    }
    public let identity: String
    public let session: BluetoothAudioSession
    public let eventVersion: UInt64
    public let name: String
    public let components: [Component]
    public let observedAt: Date
    public var percent: Int { components.map(\.percent).min() ?? 100 }
    public var componentIDs: Set<String> { Set(components.map(\.id)) }
    public init?(device: BluetoothAudioDevice, snapshot: BluetoothAudioSnapshot, at now: Date) {
        guard snapshot.devices.filter({ $0.id == device.id }).count == 1, snapshot.devices.contains(device),
              snapshot.powerStatus == .success, snapshot.finishedAt >= snapshot.startedAt, snapshot.finishedAt <= now,
              device.connection == .connected, device.identityQuality == .verified,
              let identity = device.preferenceIdentity, !identity.isEmpty, device.readStatus == .success else { return nil }
        let readings = device.notificationReadings(at: now)
        guard !readings.isEmpty, Set(readings.map(\.component)).count == readings.count,
              readings.allSatisfy({ $0.session == device.session && $0.isPresent && $0.isNative && $0.observedAt >= snapshot.startedAt && $0.observedAt <= snapshot.finishedAt }) else { return nil }
        // Combined and left/right reports mixed in the same round are ambiguous.
        let hasSingle = readings.contains { $0.component == .single }
        guard !hasSingle || readings.count == 1 else { return nil }
        self.identity = identity; session = device.session; eventVersion = device.eventVersion; name = device.name
        components = readings.compactMap { reading in reading.percent.map { Component(id: reading.component.rawValue, percent: $0) } }
        observedAt = readings.map(\.observedAt).min()!
    }
    public func evaluate(record: LowBatteryRecord, at now: Date) -> LowBatteryDecision {
        let required = record.recoveryComponents
        let recovered = required.isSubset(of: componentIDs) && components.allSatisfy { $0.percent >= LowBatteryPolicy.recoveryThreshold }
        if recovered { return record.isArmed ? .none : .rearm }
        guard record.isArmed, percent <= LowBatteryPolicy.threshold else { return .none }
        if let last = record.lastNotifiedAt, now.timeIntervalSince(last) < LowBatteryPolicy.cooldown { return .none }
        return .notify(percent: percent)
    }
    public var componentDescription: String {
        components.map { component in
            let name = component.id == "left" ? "左耳" : (component.id == "right" ? "右耳" : "耳机")
            return "\(name) \(component.percent)%"
        }.joined(separator: "，")
    }
}
