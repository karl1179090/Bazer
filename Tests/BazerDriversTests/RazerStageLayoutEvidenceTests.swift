// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import Foundation
import RazerProtocol
import Testing

/// These records model future human-confirmed hardware documents using offline protocol fixtures.
/// They are generated only in temporary test directories and are not real hardware evidence.
enum StageEvidenceTestFixtures {
    static let payload: [UInt8] = [1,3,2,3,3,32,4,176,0xAA,0xBB,7,6,64,7,208,0xCC,0xDD] + Array(repeating: 0xE9, count: 63)
    static let identity = ProfileBackupIdentity(vendorID: 0x1532, productID: 0x00C5,
        unitID: "razer-serial-sha256:" + String(repeating: "1", count: 64), firmware: "1.2",
        formatID: "razer.00c5.dpi-stage-payload", formatVersion: 0, descriptorSHA256: String(repeating: "2", count: 64))
    static func stageFrame(_ payload: [UInt8]) -> [UInt8] {
        var frame = RazerSettingRequest.readStages().bytes
        frame[0] = 2; frame[8...87] = payload[...]; frame[88] = frame[2...87].reduce(0, ^); return frame
    }
    static func dpiFrame(_ x: UInt16, _ y: UInt16) -> [UInt8] {
        var frame = RazerSettingRequest.readDPI().bytes
        frame[0] = 2; frame[9] = UInt8(x >> 8); frame[10] = UInt8(x & 255); frame[11] = UInt8(y >> 8); frame[12] = UInt8(y & 255)
        frame[88] = frame[2...87].reduce(0, ^); return frame
    }
    static func confirmed(identity: ProfileBackupIdentity = identity, payload: [UInt8] = payload) -> RazerStageLayoutEvidence {
        let ids = (0..<Int(payload[2])).map { payload[3 + $0 * 7] }
        let observations = ids.enumerated().map { index, id in
            let offset = 3 + index * 7, x = UInt16(payload[offset + 1]) << 8 | UInt16(payload[offset + 2]), y = UInt16(payload[offset + 3]) << 8 | UInt16(payload[offset + 4])
            var observed = payload; observed[1] = id
            return RazerStageLayoutObservation(selectedStageID: id, observedAt: Date(timeIntervalSince1970: 1001 + Double(index)),
                reportedActiveField: id, observedCurrentDPI: DPISetting(x: x, y: y), stagesResponse: stageFrame(observed), dpiResponse: dpiFrame(x, y))
        }
        return RazerStageLayoutEvidence(source: .hardwareCapture, captureTool: "Offline test model of explicit hardware attestation",
            capturedAt: Date(timeIntervalSince1970: 1000), identity: identity, layout: .sevenByteRecords,
            capturedPayload: payload, stageCount: ids.count, stageIDs: ids, activeSemantics: .protocolStageIdentifier,
            observations: observations, confirmation: RazerStageHardwareConfirmation(confirmedOnHardware: true,
                confirmedBy: "Simulated human confirmation in offline unit test", confirmedAt: Date(timeIntervalSince1970: 1010)))
    }
    static func encode(_ document: RazerStageLayoutEvidence) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
    static func mutated(_ transform: (inout [String: Any]) -> Void) throws -> RazerStageLayoutEvidence {
        var json = try #require(JSONSerialization.jsonObject(with: encode(confirmed())) as? [String: Any]); transform(&json)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RazerStageLayoutEvidence.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@Suite("Structured Razer stage-layout evidence gates — offline fixtures only")
struct RazerStageLayoutEvidenceTests {
    @Test func confirmedCapturedDocumentAcceptsOnlyEditableCurrentDifferencesForRestore() throws {
        let evidence = StageEvidenceTestFixtures.confirmed()
        try evidence.validate(currentIdentity: StageEvidenceTestFixtures.identity, currentPayload: StageEvidenceTestFixtures.payload)
        var edited = StageEvidenceTestFixtures.payload
        edited[1] = 7; edited[4] = 3; edited[5] = 232; edited[6] = 5; edited[7] = 120 // 1000 / 1400
        try evidence.validate(currentIdentity: StageEvidenceTestFixtures.identity, currentPayload: edited)
        // Restoring the original read image remains legal after the first write.
        try evidence.validate(currentIdentity: StageEvidenceTestFixtures.identity, currentPayload: StageEvidenceTestFixtures.payload)
        for index in [0,2,3,8,9,10,15,16,79] {
            var incompatible = edited; incompatible[index] ^= 1
            #expect(throws: (any Error).self) { try evidence.validate(currentIdentity: StageEvidenceTestFixtures.identity, currentPayload: incompatible) }
        }
        var illegalDPI = edited; illegalDPI[4] = 0; illegalDPI[5] = 0
        #expect(throws: (any Error).self) { try evidence.validate(currentIdentity: StageEvidenceTestFixtures.identity, currentPayload: illegalDPI) }
    }
    @Test func syntheticUnconfirmedMalformedIdentityAndDeclarationsCannotAuthorize() throws {
        let invalid: [([String: Any]) -> [String: Any]] = [
            { var j=$0; j["source"]="synthetic"; return j },
            { var j=$0; j["source"]="unconfirmedTemplate"; return j },
            { var j=$0; j["schemaVersion"]=2; return j },
            { var j=$0; j["stageCount"]=1; return j },
            { var j=$0; j["stageIDs"]=[3,8]; return j },
            { var j=$0; j["activeSemantics"]="unknown"; return j },
            { var j=$0; j["capturedPayloadSHA256"]=String(repeating:"0",count:64); return j },
            { var j=$0; var i=j["identity"] as! [String:Any]; i.removeValue(forKey:"unitID"); j["identity"]=i; return j },
            { var j=$0; var i=j["identity"] as! [String:Any]; i["productID"]=0x00C4; j["identity"]=i; return j },
            { var j=$0; var c=j["confirmation"] as! [String:Any]; c["confirmedOnHardware"]=false; j["confirmation"]=c; return j },
            { var j=$0; var c=j["confirmation"] as! [String:Any]; c["confirmedBy"]="  "; j["confirmation"]=c; return j },
            { var j=$0; j["capturedPayload"]=[UInt8](repeating:0,count:80); j["capturedPayloadSHA256"]=RazerStageLayoutEvidence.sha256([UInt8](repeating:0,count:80)); return j }
        ]
        for transform in invalid {
            let document = try StageEvidenceTestFixtures.mutated { $0 = transform($0) }
            #expect(throws: (any Error).self) { try document.validate(currentIdentity: StageEvidenceTestFixtures.identity, currentPayload: StageEvidenceTestFixtures.payload) }
        }
    }
    @Test func independentRawObservationsAndCurrentStrongIdentityAreMandatory() throws {
        for change in [0,1,2,3] {
            let bad = try StageEvidenceTestFixtures.mutated { json in
                var observations = json["observations"] as! [[String:Any]]
                switch change {
                case 0: observations.removeLast()
                case 1: observations[1].removeValue(forKey:"selectedStageID")
                case 2: var frame=observations[0]["stagesResponse"] as! [Int]; frame[88] ^= 1; observations[0]["stagesResponse"]=frame
                default: observations[0]["reportedActiveField"]=7
                }
                json["observations"]=observations
            }
            #expect(throws: (any Error).self) { try bad.validateCapturedEvidence() }
        }
        let document = StageEvidenceTestFixtures.confirmed()
        for unit in [String?.none, "razer-serial-sha256:" + String(repeating:"3",count:64)] {
            let identity = ProfileBackupIdentity(vendorID:0x1532,productID:0x00C5,unitID:unit,firmware:"1.2",formatID:"razer.00c5.dpi-stage-payload",formatVersion:0,descriptorSHA256:StageEvidenceTestFixtures.identity.descriptorSHA256)
            #expect(throws: (any Error).self) { try document.validate(currentIdentity:identity,currentPayload:StageEvidenceTestFixtures.payload) }
        }
        for (fw, descriptor) in [("9.9",StageEvidenceTestFixtures.identity.descriptorSHA256),("1.2",String(repeating:"4",count:64))] {
            let identity = ProfileBackupIdentity(vendorID:0x1532,productID:0x00C5,unitID:StageEvidenceTestFixtures.identity.unitID,firmware:fw,formatID:"razer.00c5.dpi-stage-payload",formatVersion:0,descriptorSHA256:descriptor)
            #expect(throws: (any Error).self) { try document.validate(currentIdentity:identity,currentPayload:StageEvidenceTestFixtures.payload) }
        }
    }
    @Test func fileLoaderRequiresRealRegularLocalFileAndRejectsUnconfirmedCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let path = directory.appendingPathComponent("confirmed-model.json")
        try LocalPrivateFile(url:path).writeNew(StageEvidenceTestFixtures.encode(StageEvidenceTestFixtures.confirmed()))
        let loaded = try RazerStageLayoutEvidenceFile.load(reference:path.path)
        #expect(loaded.document.source == .hardwareCapture)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:path.path)
        for reference in ["arbitrary text",directory.path,link.path,directory.appendingPathComponent("does-not-exist.json").path] {
            #expect(throws: (any Error).self) { _ = try RazerStageLayoutEvidenceFile.load(reference:reference) }
        }
        let template = RazerStageLayoutEvidence.unconfirmed(capturedAt:Date(timeIntervalSince1970:1000),identity:StageEvidenceTestFixtures.identity,payload:StageEvidenceTestFixtures.payload,observations:[])
        let templatePath = directory.appendingPathComponent("unconfirmed.json")
        try RazerStageLayoutEvidenceFile.saveUnconfirmed(template,to:templatePath)
        #expect(throws: RazerStageEvidenceError.notHardwareConfirmed) { _ = try RazerStageLayoutEvidenceFile.load(reference:templatePath.path) }
        let attributes = try FileManager.default.attributesOfItem(atPath:templatePath.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
