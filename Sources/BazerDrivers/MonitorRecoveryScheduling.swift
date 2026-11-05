// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// Value-only retry state. BatteryMonitor owns the single timer, in-flight work,
/// and lifecycle checks; this value never holds a settings request or HID handle.
struct MonitorRecoveryScheduling: Sendable {
    enum Key: Hashable, Sendable {
        case eventSubscription, wake, logicalDiscovery(DeviceSessionID)
        fileprivate var order: String {
            switch self {
            case .eventSubscription: "0"
            case .wake: "1"
            case .logicalDiscovery(let session): "2\(session.physicalDeviceID.rawValue)\(session.generation)"
            }
        }
    }
    private struct Failure: Sendable {
        let message: String
        let count: Int
        var due: Date?
    }
    private var failures: [Key: Failure] = [:]
    var nextDate: Date? { failures.values.compactMap(\.due).min() }
    var failureDescription: String? {
        let messages = failures.sorted { $0.key.order < $1.key.order }.map(\.value.message)
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    mutating func fail(_ key: Key, message: String, at now: Date, policy: RefreshPolicy, retry: Bool) {
        let count = min(10, (failures[key]?.count ?? 0) + 1)
        // Short recovery attempts are separate from the ordinary battery interval.
        // Even injected sub-second policies cannot create a tight recovery loop.
        let initial = max(1, min(2, policy.regularInterval))
        let delay = min(300, initial * pow(2, Double(count - 1)))
        failures[key] = Failure(message: message, count: count, due: retry ? now.addingTimeInterval(delay) : nil)
    }
    mutating func takeDue(at now: Date) -> [Key] {
        let keys = failures.filter { $0.value.due.map { $0 <= now } ?? false }.keys.sorted { $0.order < $1.order }
        for key in keys { failures[key]?.due = nil }
        return keys
    }
    mutating func unschedule(_ key: Key) { failures[key]?.due = nil }
    mutating func succeed(_ key: Key) { failures.removeValue(forKey: key) }
    mutating func removeAll() { failures.removeAll() }
}
