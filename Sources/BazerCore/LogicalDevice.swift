// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct LogicalDeviceID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public static func direct(_ host: PhysicalDeviceID) -> Self { Self(rawValue: host.rawValue + "/direct") }
}
public struct LogicalPeripheralIdentity: Equatable, Hashable, Codable, Sendable {
    public let vendorID: UInt16
    /// WPID is distinct from receiver USB PID and direct-USB PID.
    public let wirelessProductID: UInt16?
    /// A handshake-confirmed unit identifier, never a model name or WPID alone.
    public let unitID: String?
    public let protocolVersion: String?
    public let firmware: String?
    public init(vendorID: UInt16, wirelessProductID: UInt16? = nil, unitID: String? = nil,
                protocolVersion: String? = nil, firmware: String? = nil) {
        self.vendorID = vendorID; self.wirelessProductID = wirelessProductID; self.unitID = unitID
        self.protocolVersion = protocolVersion; self.firmware = firmware
    }
}
public struct DeviceAddress: Equatable, Hashable, Codable, Sendable {
    public enum Target: Equatable, Hashable, Codable, Sendable {
        case direct
        case receiver(index: UInt8, identity: LogicalPeripheralIdentity)
    }
    public let hostSessionID: DeviceSessionID
    public let target: Target
    /// Pairing/discovery epoch; adapters rotate this when an anonymous slot is reused.
    public let pairingGeneration: UUID
    public init(hostSessionID: DeviceSessionID, target: Target, pairingGeneration: UUID) {
        self.hostSessionID = hostSessionID; self.target = target; self.pairingGeneration = pairingGeneration
    }
    public static func direct(_ host: DeviceSessionID) -> Self {
        Self(hostSessionID: host, target: .direct, pairingGeneration: host.generation)
    }
    public var logicalDeviceID: LogicalDeviceID {
        switch target {
        case .direct: .direct(hostSessionID.physicalDeviceID)
        case let .receiver(index, _): LogicalDeviceID(rawValue: hostSessionID.physicalDeviceID.rawValue + "/receiver-slot:\(index)")
        }
    }
}
public struct LogicalDeviceSessionID: Equatable, Hashable, Codable, Sendable {
    public let deviceID: LogicalDeviceID
    public let address: DeviceAddress
    public let generation: UUID
    public init(address: DeviceAddress, generation: UUID = UUID()) {
        self.deviceID = address.logicalDeviceID; self.address = address; self.generation = generation
    }
}
public struct LogicalDeviceDescriptor: Equatable, Codable, Sendable, Identifiable {
    public var id: LogicalDeviceID { address.logicalDeviceID }
    public let address: DeviceAddress
    public let product: String
    public let kind: DeviceKind
    public let capabilities: DeviceCapabilities
    public let controlEndpointRegistryEntryID: UInt64?
    public let preferenceIdentity: DevicePreferenceIdentity?
    public let peripheralIdentity: LogicalPeripheralIdentity?
    public let isIdentityAmbiguous: Bool
    public let peerPresence: PeerPresence
    public init(address: DeviceAddress, product: String, kind: DeviceKind, capabilities: DeviceCapabilities,
                controlEndpointRegistryEntryID: UInt64? = nil, preferenceIdentity: DevicePreferenceIdentity? = nil, derivePreferenceIdentity: Bool = true, peripheralIdentity: LogicalPeripheralIdentity? = nil, isIdentityAmbiguous: Bool = false, peerPresence: PeerPresence = .unknown) {
        self.address = address; self.product = product; self.kind = kind; self.capabilities = capabilities; self.isIdentityAmbiguous = isIdentityAmbiguous; self.peerPresence = peerPresence
        self.controlEndpointRegistryEntryID = controlEndpointRegistryEntryID
        switch address.target {
        case .direct: self.preferenceIdentity = isIdentityAmbiguous ? nil : preferenceIdentity; self.peripheralIdentity = peripheralIdentity
        case let .receiver(_, identity):
            self.peripheralIdentity = identity
            // Reject host-port aliases and WPID-only identities for receiver children.
            let confirmed = DevicePreferenceIdentity.confirmedLogicalUnit(identity)
            self.preferenceIdentity = isIdentityAmbiguous ? nil : (derivePreferenceIdentity && preferenceIdentity == nil ? confirmed : (preferenceIdentity == confirmed ? preferenceIdentity : nil))
        }
    }
}
public struct LogicalDeviceState: Equatable, Sendable, Identifiable {
    public var id: LogicalDeviceID { descriptor.id }
    public internal(set) var descriptor: LogicalDeviceDescriptor
    public internal(set) var sessionID: LogicalDeviceSessionID
    public internal(set) var hostPresence: HostPresence = .present
    public internal(set) var capabilities: DeviceCapabilities
    public internal(set) var access: AccessState = .untested
    public internal(set) var alias: String?
    public internal(set) var lastAttemptedAt: Date?
    public internal(set) var lastFinishedAt: Date?
    public internal(set) var consecutiveFailures = 0
    public internal(set) var isRefreshing = false
    public internal(set) var nextRefreshAt: Date?
    public internal(set) var battery: BatterySample?
    public internal(set) var charging: ChargingSample?
    public internal(set) var batteryFailure: TelemetryFailure?
    public internal(set) var chargingFailure: TelemetryFailure?
    public internal(set) var settings: DeviceSettingsSnapshot?
    public internal(set) var settingsFailure: TelemetryFailure?
    public internal(set) var lastSettingsAttemptedAt: Date?
    public internal(set) var lastSettingsFinishedAt: Date?
    public internal(set) var isReadingSettings = false
    public internal(set) var lastSettingChange: SettingChangeResult?
    public var displayName: String { alias ?? descriptor.product }
    public func historicalSnapshot() -> Self {
        var copy = self; copy.hostPresence = .removed; copy.isRefreshing = false
        copy.isReadingSettings = false; copy.nextRefreshAt = nil
        return copy
    }
    public var peerPresence: PeerPresence { descriptor.peerPresence }
    public var canRefreshTelemetry: Bool {
        hostPresence == .present && peerPresence != .unreachable && descriptor.controlEndpointRegistryEntryID != nil
        && (capabilities.battery != .unsupported || capabilities.permits(.voltageRead) || capabilities.chargingQuery)
    }
    public var canRefreshSettings: Bool {
        hostPresence == .present && peerPresence != .unreachable && descriptor.controlEndpointRegistryEntryID != nil && capabilities.canReadSettings
    }
    public func currentBattery(at date: Date, maximumAge: TimeInterval = 180) -> BatterySample? {
        guard hostPresence == .present, peerPresence != .unreachable, batteryFailure == nil, let battery, !battery.isStale(at: date, maximumAge: maximumAge) else { return nil }
        return battery
    }
}
public struct LogicalDeviceReconciliation: Sendable {
    public let added: [LogicalDeviceSessionID]
    public let invalidated: [LogicalDeviceSessionID]
}
