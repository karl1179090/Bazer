// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Namespaced preference identity. Legacy USB topology keys identify a port;
/// confirmed logical units and verified Bluetooth audio keys identify a unit.
public struct DevicePreferenceIdentity: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case portTopology, confirmedLogicalUnit, verifiedBluetoothAudio }
    public let kind: Kind
    public let rawValue: String

    public init(kind: Kind, rawValue: String) { self.kind = kind; self.rawValue = rawValue }

    public static func confirmedLogicalUnit(_ identity: LogicalPeripheralIdentity) -> Self? {
        guard let unit = identity.unitID?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty else { return nil }
        // Unit ID is handshake evidence; WPID alone only identifies a model.
        let encoded = Data(unit.utf8).base64EncodedString()
        return Self(kind: .confirmedLogicalUnit, rawValue: String(format: "logical-unit:%04X:", identity.vendorID) + encoded)
    }

    public static func derive(from device: PhysicalDeviceDescriptor) -> Self? {
        guard device.isExternalUSB, let first = device.interfaces.first,
              device.interfaces.allSatisfy({ $0.vendorID == first.vendorID && $0.productID == first.productID }) else { return nil }
        // Never include RegistryEntryID, PhysicalDeviceID, product names or aliases.
        let locations = Set(device.interfaces.compactMap(\.locationID))
        if locations.count == 1, let location = locations.first, location != 0,
           device.interfaces.allSatisfy({ $0.locationID == location }) {
            return Self(kind: .portTopology, rawValue: String(format: "usb-port:%04X:%04X:%08X", first.vendorID, first.productID, location))
        }
        let paths = Set(device.interfaces.compactMap(\.usbParentPath).filter { !$0.isEmpty })
        guard paths.count == 1, let path = paths.first,
              device.interfaces.allSatisfy({ $0.usbParentPath == path }) else { return nil }
        return Self(kind: .portTopology, rawValue: String(format: "usb-path:%04X:%04X:", first.vendorID, first.productID) + path)
    }
}

/// User-selectable color appearance mode for the Bazer panel.
public enum BazerAppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// User-configured quick-select options for a specific confirmed device identity.
/// Quick presets are UI shortcuts only and never map to protocol stage IDs.
public struct DeviceQuickPresets: Equatable, Codable, Sendable {
    public var dpiPresets: [DPISetting]?
    public var pollingRatePresets: [Int]?

    public init(dpiPresets: [DPISetting]? = nil, pollingRatePresets: [Int]? = nil) {
        self.dpiPresets = dpiPresets
        self.pollingRatePresets = pollingRatePresets
    }

    public var isEmpty: Bool {
        (dpiPresets == nil || dpiPresets?.isEmpty == true)
            && (pollingRatePresets == nil || pollingRatePresets?.isEmpty == true)
    }
}

/// Deliberately excludes samples, timestamps, runtime sessions and registry IDs.
public struct DevicePreferences: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 2
    public private(set) var schemaVersion: Int
    public var aliases: [String: String]
    public var primaryIdentity: String?
    public var ambiguousIdentityKeys: Set<String>
    public var foldedIdentities: Set<String>
    public var rememberFoldedDevices: Bool
    public var quickPresets: [String: DeviceQuickPresets]
    public var showMenuBarPercentage: Bool
    public var appearanceMode: BazerAppearanceMode

    public init(
        aliases: [String: String] = [:],
        primaryIdentity: String? = nil,
        ambiguousIdentityKeys: Set<String> = [],
        foldedIdentities: Set<String> = [],
        rememberFoldedDevices: Bool = false,
        quickPresets: [String: DeviceQuickPresets] = [:],
        showMenuBarPercentage: Bool = true,
        appearanceMode: BazerAppearanceMode = .light
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.aliases = aliases
        self.primaryIdentity = primaryIdentity
        self.ambiguousIdentityKeys = ambiguousIdentityKeys
        self.foldedIdentities = foldedIdentities
        self.rememberFoldedDevices = rememberFoldedDevices
        self.quickPresets = quickPresets
        self.showMenuBarPercentage = showMenuBarPercentage
        self.appearanceMode = appearanceMode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case aliases
        case primaryIdentity
        case ambiguousIdentityKeys
        case foldedIdentities
        case rememberFoldedDevices
        case quickPresets
        case showMenuBarPercentage
        case appearanceMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported preferences schema.")
        }
        schemaVersion = version
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        primaryIdentity = try c.decodeIfPresent(String.self, forKey: .primaryIdentity)
        ambiguousIdentityKeys = try c.decodeIfPresent(Set<String>.self, forKey: .ambiguousIdentityKeys) ?? []
        foldedIdentities = try c.decodeIfPresent(Set<String>.self, forKey: .foldedIdentities) ?? []
        rememberFoldedDevices = try c.decodeIfPresent(Bool.self, forKey: .rememberFoldedDevices) ?? false
        quickPresets = try c.decodeIfPresent([String: DeviceQuickPresets].self, forKey: .quickPresets) ?? [:]
        showMenuBarPercentage = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarPercentage) ?? true
        appearanceMode = try c.decodeIfPresent(BazerAppearanceMode.self, forKey: .appearanceMode) ?? .light
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(aliases, forKey: .aliases)
        try c.encodeIfPresent(primaryIdentity, forKey: .primaryIdentity)
        try c.encode(ambiguousIdentityKeys, forKey: .ambiguousIdentityKeys)
        if !foldedIdentities.isEmpty {
            try c.encode(foldedIdentities, forKey: .foldedIdentities)
        }
        if rememberFoldedDevices {
            try c.encode(rememberFoldedDevices, forKey: .rememberFoldedDevices)
        }
        let nonEmptyPresets = quickPresets.filter { !$0.value.isEmpty }
        if !nonEmptyPresets.isEmpty {
            try c.encode(nonEmptyPresets, forKey: .quickPresets)
        }
        if !showMenuBarPercentage {
            try c.encode(showMenuBarPercentage, forKey: .showMenuBarPercentage)
        }
        if appearanceMode != .light {
            try c.encode(appearanceMode, forKey: .appearanceMode)
        }
    }

    public mutating func upgradeSchema() { schemaVersion = Self.currentSchemaVersion }
    /// Only a proven single direct child can inherit a legacy host preference.
    /// Shared receivers cannot fan one host alias or primary selection out to children.
    @discardableResult
    public mutating func migrateLegacyHost(_ host: DevicePreferenceIdentity, to children: [DevicePreferenceIdentity],
                                          isDirectPeripheral: Bool) -> Bool {
        guard isDirectPeripheral, children.count == 1, let child = children.first else { return false }
        if let alias = aliases[host.rawValue], aliases[child.rawValue] == nil { aliases[child.rawValue] = alias }
        if primaryIdentity == host.rawValue { primaryIdentity = child.rawValue }
        if foldedIdentities.contains(host.rawValue) {
            foldedIdentities.insert(child.rawValue)
            if host != child { foldedIdentities.remove(host.rawValue) }
        }
        if let presets = quickPresets[host.rawValue], quickPresets[child.rawValue] == nil {
            quickPresets[child.rawValue] = presets
            if host != child { quickPresets.removeValue(forKey: host.rawValue) }
        }
        if host != child { aliases.removeValue(forKey: host.rawValue) }
        return true
    }
}

public protocol DevicePreferencesPersisting: Sendable {
    func load() throws -> DevicePreferences
    func save(_ preferences: DevicePreferences) throws
}

public struct FileDevicePreferences: DevicePreferencesPersisting, Sendable {
    public let url: URL
    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Bazer/device-preferences.json")) { self.url = url }

    public func load() throws -> DevicePreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return DevicePreferences() }
        let original = try Data(contentsOf: url)
        var preferences = try JSONDecoder().decode(DevicePreferences.self, from: original)
        if preferences.schemaVersion < DevicePreferences.currentSchemaVersion {
            // Preserve exact old bytes before any migration. Existing backups are never overwritten.
            let backup = url.appendingPathExtension("schema-v1.backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try original.write(to: backup, options: .withoutOverwriting)
            }
            preferences.upgradeSchema()
            try save(preferences)
        }
        return preferences
    }
    public func save(_ preferences: DevicePreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var current = preferences; current.upgradeSchema()
        try JSONEncoder().encode(current).write(to: url, options: .atomic)
    }
}
