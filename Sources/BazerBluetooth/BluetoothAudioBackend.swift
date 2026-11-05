// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import BazerCore

public struct BluetoothAudioDiscoveryRecord: Equatable, Sendable {
    /// Namespaced, opaque source identity, never a device name or source array index.
    public let key: String
    public let name: String
    public let isConnected: Bool
    public let verifiedPreferenceIdentity: String?
    public init(key: String, name: String, isConnected: Bool = true, verifiedPreferenceIdentity: String? = nil) {
        self.key = key; self.name = name; self.isConnected = isConnected; self.verifiedPreferenceIdentity = verifiedPreferenceIdentity
    }
}

public struct BluetoothAudioPowerRecord: Equatable, Sendable {
    public let key: String
    public let name: String
    public let groupKey: String?
    public let identityKey: String
    public let identifierKind: String?
    public let directDiscoveryKey: String?
    public let verifiedPreferenceIdentity: String?
    public let component: BluetoothAudioComponent
    public let percent: Int?
    public let charging: ChargingState
    public let isPresent: Bool
    public let source: String
    public let observedAt: Date
    public let sourceUpdatedAt: Date?
    public init(key: String, name: String, groupKey: String? = nil, identityKey: String? = nil, identifierKind: String? = nil, directDiscoveryKey: String? = nil,
                verifiedPreferenceIdentity: String? = nil, component: BluetoothAudioComponent = .single,
                percent: Int?, charging: ChargingState = .unknown, isPresent: Bool = true,
                source: String = "macOS IOPS accessory report", observedAt: Date, sourceUpdatedAt: Date? = nil) {
        self.key = key; self.name = name; self.groupKey = groupKey; self.identityKey = identityKey ?? key
        self.identifierKind = identifierKind; self.directDiscoveryKey = directDiscoveryKey
        self.verifiedPreferenceIdentity = verifiedPreferenceIdentity; self.component = component; self.percent = percent
        self.charging = charging; self.isPresent = isPresent; self.source = source; self.observedAt = observedAt; self.sourceUpdatedAt = sourceUpdatedAt
    }
}

public struct BluetoothAudioReadResult<Element: Sendable>: Sendable {
    public let records: [Element]
    public let status: BluetoothAudioReadStatus
    public let message: String?
    public let startedAt: Date?
    public init(records: [Element] = [], status: BluetoothAudioReadStatus, message: String? = nil, startedAt: Date? = nil) {
        self.records = records; self.status = status; self.message = message; self.startedAt = startedAt
    }
}

public protocol BluetoothAudioBackend: Sendable {
    func discover() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>
    func readPower() async -> BluetoothAudioReadResult<BluetoothAudioPowerRecord>
    func startEvents(_ onChange: @escaping @Sendable () -> Void) async
    func stop() async
}
public extension BluetoothAudioBackend {
    func startEvents(_ onChange: @escaping @Sendable () -> Void) async {}
    func stop() async {}
}

public enum AccessoryPowerValue: Equatable, Sendable {
    case string(String), number(Double), boolean(Bool), date(Date)
}

/// Strict typed boundary around the private accessory schema. Unknown fields do not acquire semantics.
public enum AccessoryPowerParser {
    public static func parse(_ values: [String: AccessoryPowerValue], observedAt: Date, verifiedAccessoryKeys: Set<String> = [],
                             opaqueKey: (String) -> String) -> BluetoothAudioPowerRecord? {
        func string(_ key: String) -> String? {
            guard case let .string(s) = values[key], !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }; return s
        }
        func number(_ key: String) -> Double? { guard case let .number(v) = values[key], v.isFinite else { return nil }; return v }
        func boolean(_ key: String) -> Bool? {
            if case let .boolean(v) = values[key] { return v }
            if let n = number(key), n == 0 || n == 1 { return n == 1 }; return nil
        }
        guard string("Transport Type") == "Bluetooth", string("Type") == "Accessory Source",
              let name = string("Name"), let present = boolean("Is Present") else { return nil }
        // Only observed, explicit category spellings qualify. Numeric categories have no
        // verified meaning here; Bluetooth keyboards/mice must never become audio cards.
        let category = string("Accessory Category")?.lowercased()
        guard ["headset", "headphone", "headphones", "earbuds", "audio battery case"].contains(category ?? "") else { return nil }
        let accessory = string("Accessory Identifier")
        let groupIdentifier = string("Group Identifier")
        let sourceID = number("Power Source ID").flatMap { $0 >= 0 && $0.rounded() == $0 ? String($0) : nil }
        // A runtime source handle can retain a legal report whose stable accessory ID is
        // absent. It is never eligible for preferences or notification evidence.
        guard accessory != nil || groupIdentifier != nil || sourceID != nil else { return nil }
        let part = string("Part Identifier")
        let component: BluetoothAudioComponent
        switch part?.lowercased() {
        case "single", "combined": component = .single
        case "left", "left earbud": component = .left
        case "right", "right earbud": component = .right
        case "case", "charging case": component = .case
        default: component = category == "audio battery case" ? .case : .unknown
        }
        var percent: Int?
        if let current = number("Current Capacity"), let max = number("Max Capacity"), max > 0, current >= 0, current <= max {
            percent = Int((current / max * 100).rounded())
        }
        let charging: ChargingState
        if boolean("Is Charging") == true { charging = .charging }
        else if boolean("Is Charged") == true { charging = .full }
        else if boolean("Is Charging") == false, string("Power Source State") == "Battery Power" { charging = .discharging }
        else { charging = .unknown }
        let group = groupIdentifier.map { opaqueKey("iops-group:" + $0) }
        // Unknown numeric Part Identifier is an opaque part, not a fabricated left/right label.
        let runtimeIdentity = accessory.map { "iops-accessory:" + $0 } ?? groupIdentifier.map { "iops-group:" + $0 } ?? "iops-volatile-power-source:" + sourceID!
        let opaquePart: String
        switch values["Part Identifier"] {
        case let .string(value): opaquePart = value
        case let .number(value): opaquePart = "number:" + String(value)
        case let .boolean(value): opaquePart = "boolean:" + String(value)
        default: opaquePart = "missing"
        }
        let key = opaqueKey(runtimeIdentity + ":part:" + opaquePart)
        let ownIdentity = group ?? accessory.map { opaqueKey("iops-accessory:" + $0) } ?? ""
        return BluetoothAudioPowerRecord(key: key, name: name, groupKey: group, identityKey: ownIdentity,
            identifierKind: accessory.map { UUID(uuidString: $0) != nil ? "UUID" : "opaque-string" } ?? "runtime-only",
            verifiedPreferenceIdentity: !ownIdentity.isEmpty && verifiedAccessoryKeys.contains(ownIdentity) ? "bluetooth-iops:" + ownIdentity : nil, component: component,
            percent: percent, charging: charging, isPresent: present, observedAt: observedAt)
    }
}
