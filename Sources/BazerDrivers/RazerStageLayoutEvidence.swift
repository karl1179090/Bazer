// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import CryptoKit
import Foundation
import RazerProtocol

public enum RazerStageEvidenceSource: String, Codable, Sendable { case unconfirmedTemplate, synthetic, hardwareCapture }
public enum RazerStageEvidenceLayout: String, Codable, Sendable { case unknown, sevenByteRecords }
public enum RazerStageActiveSemantics: String, Codable, Sendable { case unknown, protocolStageIdentifier }
public enum RazerStageConfirmationMethod: String, Codable, Sendable { case manualStageSelectionWithIndependentDPIReadback }
public struct RazerStageLayoutObservation: Equatable, Codable, Sendable {
    /// Filled only after a human has identified the physically selected protocol stage ID.
    public let selectedStageID: UInt8?
    public let observedAt: Date
    public let reportedActiveField: UInt8
    public let observedCurrentDPI: DPISetting
    public let stagesResponse: [UInt8]
    public let dpiResponse: [UInt8]
    public init(selectedStageID: UInt8?, observedAt: Date, reportedActiveField: UInt8, observedCurrentDPI: DPISetting,
                stagesResponse: [UInt8], dpiResponse: [UInt8]) {
        self.selectedStageID = selectedStageID; self.observedAt = observedAt; self.reportedActiveField = reportedActiveField
        self.observedCurrentDPI = observedCurrentDPI; self.stagesResponse = stagesResponse; self.dpiResponse = dpiResponse
    }
}
public struct RazerStageHardwareConfirmation: Equatable, Codable, Sendable {
    public let confirmedOnHardware: Bool
    public let confirmedBy: String
    public let confirmedAt: Date
    public let method: RazerStageConfirmationMethod
    public init(confirmedOnHardware: Bool, confirmedBy: String, confirmedAt: Date,
                method: RazerStageConfirmationMethod = .manualStageSelectionWithIndependentDPIReadback) {
        self.confirmedOnHardware = confirmedOnHardware; self.confirmedBy = confirmedBy; self.confirmedAt = confirmedAt; self.method = method
    }
}
public enum RazerStageEvidenceError: Error, Equatable, Sendable, DeviceSettingsPreflightRejecting {
    case invalidReference, unsupportedSchema, notHardwareConfirmed, invalidIdentity, wrongIdentity
    case invalidCapturedHash, invalidStageDeclaration, invalidObservation, insufficientObservations, incompatibleCurrentImage
    public var rejectionMessage: String { "Stage-layout evidence rejected (\(String(describing: self))). No settings were sent." }
}

/// A local human hardware attestation with replayable protocol captures. It is not a product-support promotion.
/// Synthetic or unconfirmed documents can be exported and inspected but never authorize known-layout writes.
public struct RazerStageLayoutEvidence: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let evidenceID: UUID
    public let source: RazerStageEvidenceSource
    public let captureTool: String
    public let capturedAt: Date
    public let identity: ProfileBackupIdentity
    public let layout: RazerStageEvidenceLayout
    public let capturedPayload: [UInt8]
    public let capturedPayloadSHA256: String
    public let stageCount: Int?
    public let stageIDs: [UInt8]
    public let activeSemantics: RazerStageActiveSemantics
    public let observations: [RazerStageLayoutObservation]
    public let confirmation: RazerStageHardwareConfirmation?
    public init(schemaVersion: Int = 1, evidenceID: UUID = UUID(), source: RazerStageEvidenceSource, captureTool: String,
                capturedAt: Date, identity: ProfileBackupIdentity, layout: RazerStageEvidenceLayout,
                capturedPayload: [UInt8], capturedPayloadSHA256: String? = nil, stageCount: Int?, stageIDs: [UInt8],
                activeSemantics: RazerStageActiveSemantics, observations: [RazerStageLayoutObservation],
                confirmation: RazerStageHardwareConfirmation?) {
        self.schemaVersion = schemaVersion; self.evidenceID = evidenceID; self.source = source; self.captureTool = captureTool
        self.capturedAt = capturedAt; self.identity = identity; self.layout = layout; self.capturedPayload = capturedPayload
        self.capturedPayloadSHA256 = capturedPayloadSHA256 ?? Self.sha256(capturedPayload)
        self.stageCount = stageCount; self.stageIDs = stageIDs; self.activeSemantics = activeSemantics
        self.observations = observations; self.confirmation = confirmation
    }
    public static func unconfirmed(capturedAt: Date, identity: ProfileBackupIdentity, payload: [UInt8],
                                   observations: [RazerStageLayoutObservation]) -> Self {
        Self(source: .unconfirmedTemplate, captureTool: "Bazer HIDProbe read-only capture-layout", capturedAt: capturedAt,
            identity: identity, layout: .unknown, capturedPayload: payload, stageCount: nil, stageIDs: [],
            activeSemantics: .unknown, observations: observations, confirmation: nil)
    }
    public static func sha256(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }

    public func validateCapturedEvidence(at now: Date = Date()) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw RazerStageEvidenceError.unsupportedSchema }
        guard source == .hardwareCapture, layout == .sevenByteRecords, activeSemantics == .protocolStageIdentifier,
              let confirmation, confirmation.confirmedOnHardware,
              !confirmation.confirmedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !captureTool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              confirmation.confirmedAt >= capturedAt, confirmation.confirmedAt <= now else { throw RazerStageEvidenceError.notHardwareConfirmed }
        try Self.validateIdentity(identity)
        guard capturedPayload.count == 80, Self.isHash(capturedPayloadSHA256), Self.sha256(capturedPayload) == capturedPayloadSHA256.lowercased() else {
            throw RazerStageEvidenceError.invalidCapturedHash
        }
        let original = try Self.table(capturedPayload)
        guard stageCount == original.stages.count, stageIDs == original.stages.map(\.id), stageIDs.contains(original.rawActiveStage) else {
            throw RazerStageEvidenceError.invalidStageDeclaration
        }
        var selected: Set<UInt8> = []
        for observation in observations {
            guard let id = observation.selectedStageID, observation.observedAt >= capturedAt,
                  observation.observedAt <= confirmation.confirmedAt, observation.reportedActiveField == id,
                  let expected = original.stages.first(where: { $0.id == id }),
                  case let .stages(table) = try RazerSettingResponse.parse(observation.stagesResponse, for: .readStages(), stageLayout: .sevenByteRecords),
                  case let .dpi(dpi) = try RazerSettingResponse.parse(observation.dpiResponse, for: .readDPI()),
                  table.rawActiveStage == id, dpi.x == expected.x, dpi.y == expected.y,
                  observation.observedCurrentDPI == DPISetting(x: dpi.x, y: dpi.y) else { throw RazerStageEvidenceError.invalidObservation }
            var exactRead = capturedPayload; exactRead[1] = id
            guard table.payload == exactRead else { throw RazerStageEvidenceError.invalidObservation }
            selected.insert(id)
        }
        guard selected.count >= min(2, original.stages.count) else { throw RazerStageEvidenceError.insufficientObservations }
    }
    /// Reuses the original layout evidence after a legal first write: only stage DPI and known active ID may differ.
    public func validate(currentIdentity: ProfileBackupIdentity, currentPayload: [UInt8], at now: Date = Date()) throws {
        try validateCapturedEvidence(at: now)
        try Self.validateIdentity(currentIdentity)
        guard identity.vendorID == currentIdentity.vendorID, identity.productID == currentIdentity.productID,
              identity.unitID == currentIdentity.unitID, identity.firmware == currentIdentity.firmware,
              identity.descriptorSHA256.lowercased() == currentIdentity.descriptorSHA256.lowercased(),
              identity.formatID == currentIdentity.formatID else { throw RazerStageEvidenceError.wrongIdentity }
        let original = try Self.table(capturedPayload), actual = try Self.table(currentPayload)
        guard actual.stages.map(\.id) == original.stages.map(\.id), actual.stages.count == original.stages.count,
              stageIDs.contains(actual.rawActiveStage) else { throw RazerStageEvidenceError.incompatibleCurrentImage }
        var allowed: Set<Int> = [1]
        for index in original.stages.indices { allowed.formUnion((4 + index * 7)...(7 + index * 7)) }
        guard capturedPayload.indices.allSatisfy({ allowed.contains($0) || currentPayload[$0] == capturedPayload[$0] }) else {
            throw RazerStageEvidenceError.incompatibleCurrentImage
        }
    }
    private static func validateIdentity(_ value: ProfileBackupIdentity) throws {
        guard value.vendorID == 0x1532, value.productID == 0x00C5, value.wirelessProductID == nil,
              value.formatID == "razer.00c5.dpi-stage-payload", (0...1).contains(value.formatVersion),
              let unit = value.unitID, unit.hasPrefix("razer-serial-sha256:"), isHash(String(unit.dropFirst("razer-serial-sha256:".count))),
              let firmware = value.firmware, !firmware.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isHash(value.descriptorSHA256) else { throw RazerStageEvidenceError.invalidIdentity }
    }
    private static func isHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
    private static func table(_ payload: [UInt8]) throws -> RazerStageTable {
        guard payload.count == 80, payload[0] == 1 else { throw RazerStageEvidenceError.invalidStageDeclaration }
        let request = RazerSettingRequest.readStages()
        var response = request.bytes; response[0] = 2; response[8...87] = payload[...]; response[88] = response[2...87].reduce(0, ^)
        guard case let .stages(table) = try RazerSettingResponse.parse(response, for: request, stageLayout: .sevenByteRecords),
              table.stages.contains(where: { $0.id == table.rawActiveStage }),
              table.stages.allSatisfy({ (100...26000).contains($0.x) && (100...26000).contains($0.y) && $0.x % 50 == 0 && $0.y % 50 == 0 }) else {
            throw RazerStageEvidenceError.invalidStageDeclaration
        }
        return table
    }
}
public struct LoadedRazerStageLayoutEvidence: Sendable {
    public let document: RazerStageLayoutEvidence
    public let reference: String
    public let documentSHA256: String
}
public enum RazerStageLayoutEvidenceFile {
    public static func load(reference: String) throws -> LoadedRazerStageLayoutEvidence {
        guard reference.hasPrefix("/"), !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RazerStageEvidenceError.invalidReference }
        do {
            let data = try LocalPrivateFile(url: URL(fileURLWithPath: reference)).read(maximumBytes: 262_144)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(RazerStageLayoutEvidence.self, from: data)
            try document.validateCapturedEvidence()
            return LoadedRazerStageLayoutEvidence(document: document, reference: reference, documentSHA256: RazerStageLayoutEvidence.sha256(Array(data)))
        } catch let rejection as RazerStageEvidenceError { throw rejection }
        catch { throw RazerStageEvidenceError.invalidReference }
    }
    /// Capture-only API cannot mark a document confirmed, even if its caller supplies other metadata.
    public static func saveUnconfirmed(_ document: RazerStageLayoutEvidence, to url: URL) throws {
        guard document.source == .unconfirmedTemplate, document.layout == .unknown, document.activeSemantics == .unknown,
              document.confirmation == nil, document.stageCount == nil, document.stageIDs.isEmpty else { throw RazerStageEvidenceError.notHardwareConfirmed }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalPrivateFile(url: url).writeNew(encoder.encode(document))
    }
}
