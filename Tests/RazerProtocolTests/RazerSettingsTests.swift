import Foundation
import Testing
@testable import RazerProtocol

struct RazerSettingsTests {
    private let constraints = try! RazerDPIConstraints(minimum: 100, maximum: 26000, step: 50)
    private func response(_ request: RazerSettingRequest, payload: [UInt8]? = nil, status: UInt8 = 2) -> [UInt8] {
        var bytes = request.bytes; bytes[0] = status
        if let payload { bytes[8..<(8 + payload.count)] = payload[...] }
        bytes[88] = bytes[2...87].reduce(0, ^)
        return bytes
    }
    private func dpiSnapshot() throws -> RazerDPISnapshot {
        let request = RazerSettingRequest.readDPI()
        guard case .dpi(let snapshot) = try RazerSettingResponse.parse(response(request, payload: [1, 3, 32, 6, 64, 0xA5, 0x5A]), for: request) else { throw RazerSettingsError.unknownLayout }
        return snapshot
    }
    private func stageFrame(ids: [UInt8] = [0, 1, 2]) -> [UInt8] {
        let request = RazerSettingRequest.readStages()
        var bytes = response(request)
        bytes[9] = ids[0]; bytes[10] = UInt8(ids.count)
        for (index, id) in ids.enumerated() {
            let offset = 11 + index * 7, x = UInt16(400 + index * 400), y = UInt16(800 + index * 400)
            bytes[offset..<(offset + 7)] = [id, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255), UInt8(0xA0 + index), UInt8(0xB0 + index)][...]
        }
        // Nonzero unused and trailing bytes expose accidental table reconstruction.
        bytes[45] = 0xC7; bytes[87] = 0xD9
        bytes[88] = bytes[2...87].reduce(0, ^)
        return bytes
    }

    @Test func exactReadGoldenHeadersUseSeparateClassesAndLengths() {
        let cases: [(RazerSettingRequest, [UInt8])] = [
            (.readFirmware(), [0, 0x1F, 0, 0, 0, 2, 0, 0x81, 0]),
            (.readDPI(), [0, 0x1F, 0, 0, 0, 7, 4, 0x85, 1]),
            (.readStages(), [0, 0x1F, 0, 0, 0, 0x26, 4, 0x86, 1]),
            (.readPollingRate(), [0, 0x1F, 0, 0, 0, 1, 0, 0x85, 0]),
            (.readExtendedPollingRate(), [0, 0x1F, 0, 0, 0, 1, 0, 0xC0, 0])
        ]
        for (request, prefix) in cases {
            #expect(request.bytes.count == 90); #expect(request.reportID == 0)
            #expect(Array(request.bytes.prefix(9)) == prefix)
            #expect(request.bytes[88] == request.bytes[2...87].reduce(0, ^))
            #expect(request.bytes[89] == 0)
        }
    }

    @Test func dpiReadUsesDistinctAxesAndWritePreservesOtherAxisAndAllTailBytes() throws {
        let snapshot = try dpiSnapshot()
        #expect(snapshot.x == 800); #expect(snapshot.y == 1600)
        let write = try RazerSettingRequest.writeDPI(from: snapshot, x: 1200, constraints: constraints)
        #expect(write.command == .writeDPI)
        #expect(Array(write.bytes[8...14]) == [1, 4, 176, 6, 64, 0xA5, 0x5A])
        #expect(Array(write.payload[5...79]) == Array(snapshot.payload[5...79]))
        #expect(throws: (any Error).self) { try RazerSettingRequest.writeDPI(from: snapshot, x: 0, constraints: constraints) }
        #expect(throws: (any Error).self) { try RazerSettingRequest.writeDPI(from: snapshot, x: 26050, constraints: constraints) }
        #expect(throws: (any Error).self) { try RazerSettingRequest.writeDPI(from: snapshot, x: 801, constraints: constraints) }
        #expect(throws: (any Error).self) { try RazerSettingRequest.writeDPI(from: snapshot, constraints: constraints) }
    }

    @Test func stageEditsPreserveIDsReservedUnusedAndUneditedFieldsForBothNumberingBases() throws {
        let request = RazerSettingRequest.readStages()
        for ids: [UInt8] in [[0, 1, 2], [1, 2, 3]] {
            let bytes = stageFrame(ids: ids)
            guard case .stages(let table) = try RazerSettingResponse.parse(bytes, for: request, stageLayout: .sevenByteRecords) else { Issue.record("wrong response"); return }
            #expect(table.stages.map(\.id) == ids)
            let updated = try table.updating(stageID: ids[1], y: 1800, constraints: constraints)
            let write = try RazerSettingRequest.writeStages(from: updated)
            #expect(write.bytes[7] == 6); #expect(write.bytes[5] == 0x26)
            #expect(updated.originalPayload == table.payload)
            for index in 0..<80 where index != 13 && index != 14 { #expect(updated.payload[index] == table.payload[index], "preserved argument \(index)") }
            #expect(updated.stages[1].x == table.stages[1].x)
            #expect(updated.stages[1].y == 1800)
            #expect(updated.rawActiveStage == table.rawActiveStage)
        }
    }

    @Test func unknownStageLayoutRemainsReadableButCannotBecomeAWriteTemplate() throws {
        let request = RazerSettingRequest.readStages()
        guard case .stages(let table) = try RazerSettingResponse.parse(stageFrame(), for: request) else { Issue.record("wrong response"); return }
        #expect(table.layout == .unknown); #expect(table.payload.count == 80); #expect(table.stages.isEmpty)
        #expect(throws: RazerSettingsError.unknownLayout) { try RazerSettingRequest.writeStages(from: table) }
        #expect(throws: RazerSettingsError.unknownLayout) { try table.updating(stageID: 1, x: 800, constraints: constraints) }
    }

    @Test func invalidStageCountDuplicateIDsAndStorageAreRejected() throws {
        let request = RazerSettingRequest.readStages()
        for (index, value) in [(10, UInt8(0)), (10, 6), (18, 0), (8, 0)] {
            var bytes = stageFrame(); bytes[index] = value; bytes[88] = bytes[2...87].reduce(0, ^)
            #expect(throws: (any Error).self) { try RazerSettingResponse.parse(bytes, for: request, stageLayout: .sevenByteRecords) }
        }
    }

    @Test func traditionalAndExtendedRateCodesNeverShareSemantics() throws {
        #expect(try RazerTraditionalPollingRate(code: 1) == .hz1000)
        #expect(try RazerExtendedPollingRate(code: 1) == .hz8000)
        for rate in RazerTraditionalPollingRate.allCases {
            let request = RazerSettingRequest.writePollingRate(rate)
            #expect(request.bytes[5] == 1); #expect(request.bytes[7] == 5); #expect(request.bytes[8] == rate.code)
            let read = RazerSettingRequest.readPollingRate()
            #expect(try RazerSettingResponse.parse(response(read, payload: [rate.code]), for: read) == .pollingRate(rate))
        }
        for rate in RazerExtendedPollingRate.allCases {
            let request = try RazerSettingRequest.writeExtendedPollingRate(rate, selector: 1)
            #expect(Array(request.bytes[5...9]) == [2, 0, 0x40, 1, rate.code])
            let read = RazerSettingRequest.readExtendedPollingRate()
            #expect(try RazerSettingResponse.parse(response(read, payload: [0xEE, rate.code]), for: read) == .extendedPollingRate(rate))
        }
        for code: UInt8 in [0, 3, 4, 0xFF] { #expect(throws: (any Error).self) { try RazerTraditionalPollingRate(code: code) } }
        for code: UInt8 in [0, 3, 0x80, 0xFF] { #expect(throws: (any Error).self) { try RazerExtendedPollingRate(code: code) } }
        #expect(throws: (any Error).self) { try RazerSettingRequest.writeExtendedPollingRate(.hz8000, selector: 2) }
    }

    @Test func everyStructuralAssociationAndChecksumErrorFailsBeforeSuccessOrBusy() throws {
        let request = RazerSettingRequest.readDPI()
        let good = response(request, payload: [1, 3, 32, 6, 64, 0, 0])
        for length in [0, 1, 8, 89, 91] { #expect(throws: (any Error).self) { try RazerSettingResponse.parse(Array(repeating: 0, count: length), for: request) } }
        for index in [1, 2, 3, 4, 5, 6, 7, 8, 89] {
            var bytes = good; bytes[index] ^= 1; bytes[88] = bytes[2...87].reduce(0, ^)
            #expect(throws: (any Error).self) { try RazerSettingResponse.parse(bytes, for: request) }
        }
        var badChecksum = good; badChecksum[88] ^= 1
        #expect(throws: (any Error).self) { try RazerSettingResponse.parse(badChecksum, for: request) }
        #expect(throws: RazerProtocolError.busy) { try RazerSettingResponse.parse(response(request, status: 1), for: request) }
        #expect(throws: RazerProtocolError.deviceStatus(3)) { try RazerSettingResponse.parse(response(request, status: 3), for: request) }
    }

    @Test func aSuccessfulWriteResponseIsOnlyAnAcknowledgement() throws {
        let request = RazerSettingRequest.writePollingRate(.hz500)
        #expect(try RazerSettingResponse.parse(response(request), for: request) == .acknowledgement(.writePollingRate))
        let read = RazerSettingRequest.readPollingRate()
        #expect(throws: (any Error).self) { try RazerSettingResponse.parse(response(request), for: read) }
    }

    @Test func firmwareUsesOnlyTwoVersionBytesAndNeverRequestsSerial() throws {
        let request = RazerSettingRequest.readFirmware()
        #expect(try RazerSettingResponse.parse(response(request, payload: [3, 17]), for: request) == .firmware(major: 3, minor: 17))
        #expect(request.command.commandID == 0x81)
    }

    @Test func backupIdentityReturnsOnlyStableHashAndRejectsPlaceholders() throws {
        let request = RazerSettingRequest.readBackupIdentity()
        let first = try RazerSettingResponse.parse(response(request, payload: Array("SYNTHETIC-UNIT-42".utf8)), for: request)
        let second = try RazerSettingResponse.parse(response(request, payload: Array("SYNTHETIC-UNIT-42".utf8)), for: request)
        let other = try RazerSettingResponse.parse(response(request, payload: Array("SYNTHETIC-UNIT-43".utf8)), for: request)
        #expect(first == second); #expect(first != other)
        guard case .backupIdentity(let digest) = first else { Issue.record("identity must be a hash"); return }
        #expect(digest.count == 64); #expect(!digest.contains("SYNTHETIC"))
        for payload in [[], Array("0000000000".utf8), Array("UNKNOWN".utf8), [1, 2, 3, 4], Array("   ".utf8)] {
            #expect(throws: (any Error).self) { try RazerSettingResponse.parse(response(request, payload: payload), for: request) }
        }
    }
}
