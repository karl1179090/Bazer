// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

public struct ProfileBackupIdentity: Equatable, Codable, Sendable {
    public let vendorID: UInt16
    public let productID: UInt16?
    public let wirelessProductID: UInt16?
    public let unitID: String?
    public let firmware: String?
    public let formatID: String
    public let formatVersion: Int
    public let descriptorSHA256: String
    public init(vendorID: UInt16, productID: UInt16? = nil, wirelessProductID: UInt16? = nil, unitID: String? = nil,
                firmware: String? = nil, formatID: String, formatVersion: Int, descriptorSHA256: String) {
        self.vendorID = vendorID; self.productID = productID; self.wirelessProductID = wirelessProductID
        self.unitID = unitID; self.firmware = firmware; self.formatID = formatID; self.formatVersion = formatVersion
        self.descriptorSHA256 = descriptorSHA256
    }
}
public struct ProfileBackupRegion: Equatable, Codable, Sendable {
    public let id: String
    public let bytes: [UInt8]
    public let sha256: String
    public init(id: String, bytes: [UInt8]) { self.id = id; self.bytes = bytes; sha256 = Self.digest(bytes) }
    public var checksumIsValid: Bool { sha256 == Self.digest(bytes) }
    private static func digest(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
}
public enum ProfileBackupError: Error, Equatable, Sendable {
    case unsupportedSchema, invalidIdentity, duplicateRegion, emptyRegion, checksumMismatch(String)
    case wrongDevice, staleAnonymousSession, regionLayoutMismatch, unknownFormat
}

/// Local recovery data may contain key/macro bytes. Never include it in ordinary diagnostic logs.
public struct ProfileBackup: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let capturedAt: Date
    public let identity: ProfileBackupIdentity
    public let session: LogicalDeviceSessionID
    public let activeProfileID: Int?
    public let hardwareEvidenceReference: String?
    public let regions: [ProfileBackupRegion]
    public init(capturedAt: Date, identity: ProfileBackupIdentity, session: LogicalDeviceSessionID,
                activeProfileID: Int? = nil, regions: [ProfileBackupRegion], hardwareEvidenceReference: String? = nil) {
        schemaVersion = Self.currentSchemaVersion; self.capturedAt = capturedAt; self.identity = identity
        self.session = session; self.activeProfileID = activeProfileID; self.regions = regions; self.hardwareEvidenceReference = hardwareEvidenceReference
    }
    public func validateIntegrity() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw ProfileBackupError.unsupportedSchema }
        guard !identity.formatID.isEmpty, identity.formatVersion >= 0, !identity.descriptorSHA256.isEmpty else { throw ProfileBackupError.invalidIdentity }
        guard !regions.isEmpty, Set(regions.map(\.id)).count == regions.count else { throw ProfileBackupError.duplicateRegion }
        for region in regions {
            guard !region.id.isEmpty, !region.bytes.isEmpty else { throw ProfileBackupError.emptyRegion }
            guard region.checksumIsValid else { throw ProfileBackupError.checksumMismatch(region.id) }
        }
    }
    /// This validates an existing exact format; it does not authorize a generic raw write.
    public func validateRestore(to current: ProfileBackupIdentity, session currentSession: LogicalDeviceSessionID,
                                expectedRegionLengths: [String: Int]) throws {
        try validateIntegrity()
        guard current == identity else { throw ProfileBackupError.wrongDevice }
        guard current.formatVersion > 0, !expectedRegionLengths.isEmpty else { throw ProfileBackupError.unknownFormat }
        if current.unitID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            guard currentSession == session else { throw ProfileBackupError.staleAnonymousSession }
        }
        let lengths = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0.bytes.count) })
        guard lengths == expectedRegionLengths else { throw ProfileBackupError.regionLayoutMismatch }
    }
}
public struct FileProfileBackup: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    /// Exclusive private creation; final symlinks and existing files are rejected.
    public func save(_ backup: ProfileBackup) throws {
        try backup.validateIntegrity()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalPrivateFile(url: url).writeNew(encoder.encode(backup))
    }
    public func load() throws -> ProfileBackup {
        let backup = try JSONDecoder().decode(ProfileBackup.self, from: LocalPrivateFile(url: url).read(maximumBytes: 8 * 1_048_576))
        try backup.validateIntegrity(); return backup
    }
}
