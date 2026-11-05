// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Local, explicitly reviewed evidence. A repeat observation or unique name cannot create it.
/// No addresses, names, battery values or transport sessions are persisted here.
public struct BluetoothAudioIdentityEvidence: Codable, Equatable, Sendable {
    public let identifierKey: String
    public let identifierNamespace: String
    public let semanticReference: String
    public let reconnectVerified: Bool
    public let processRestartVerified: Bool
    public let nameIndependentIdentityVerified: Bool
    public let collisionIsolationVerified: Bool
    public let evidenceReference: String
    public let approvedAt: Date
    public init(identifierKey: String, identifierNamespace: String, semanticReference: String,
                reconnectVerified: Bool, processRestartVerified: Bool, nameIndependentIdentityVerified: Bool,
                collisionIsolationVerified: Bool, evidenceReference: String, approvedAt: Date) {
        self.identifierKey = identifierKey; self.identifierNamespace = identifierNamespace; self.semanticReference = semanticReference
        self.reconnectVerified = reconnectVerified; self.processRestartVerified = processRestartVerified
        self.nameIndependentIdentityVerified = nameIndependentIdentityVerified; self.collisionIsolationVerified = collisionIsolationVerified
        self.evidenceReference = evidenceReference; self.approvedAt = approvedAt
    }
    public var isVerified: Bool {
        identifierKey.hasPrefix("sha256:") && identifierKey.count == 71
            && identifierKey.dropFirst(7).allSatisfy { $0.isHexDigit }
            && ["iops-accessory", "iops-group"].contains(identifierNamespace)
            && semanticReference == "https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeysPrivate.h"
            && reconnectVerified && processRestartVerified && nameIndependentIdentityVerified && collisionIsolationVerified
            && !evidenceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && approvedAt <= Date()
    }
}

public struct BluetoothAudioIdentityEvidenceRegistry: Sendable {
    public struct Document: Codable, Sendable {
        public let schemaVersion: Int
        public let entries: [BluetoothAudioIdentityEvidence]
        public init(entries: [BluetoothAudioIdentityEvidence]) { schemaVersion = 1; self.entries = entries }
    }
    public let url: URL
    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Bazer/bluetooth-identity-evidence.json")) { self.url = url }
    public func loadVerifiedKeys() -> Set<String> {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data), document.schemaVersion == 1 else { return [] }
        let groups = Dictionary(grouping: document.entries, by: \.identifierKey)
        return Set(groups.compactMap { key, entries in entries.count == 1 && entries[0].isVerified ? key : nil })
    }
    /// Called only after explicit review, never by discovery, matching or the probe.
    public func saveReviewed(_ entries: [BluetoothAudioIdentityEvidence]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Document(entries: entries)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
