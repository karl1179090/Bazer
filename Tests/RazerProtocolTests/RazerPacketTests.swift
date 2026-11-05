import Testing
import Foundation
@testable import RazerProtocol

struct RazerPacketTests {
    /// Offline synthetic response, never a device capture or measured battery.
    private func synthetic(_ command: RazerCommand = .battery, raw: UInt8 = 128, status: UInt8 = 2) -> [UInt8] {
        var frame = RazerRequest(command: command).bytes
        frame[0] = status
        frame[9] = raw
        frame[88] = frame[2...87].reduce(0, ^)
        return frame
    }

    private func assertRejected(_ bytes: [UInt8], request: RazerRequest = RazerRequest(command: .battery), as expected: RazerProtocolError, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, sourceLocation: sourceLocation) {
            try RazerResponse.parse(bytes, for: request)
        }
    }

    @Test
    func testReadOnlyRequestGoldenBytesHaveNoWindowsPrefix() {
        for (command, checksum) in [(RazerCommand.battery, UInt8(0x85)), (.charging, 0x81)] {
            let request = RazerRequest(command: command)
            #expect((request.reportID) == (0))
            #expect((request.bytes.count) == (90))
            #expect((Array(request.bytes[0...7])) == ([0, 0x1F, 0, 0, 0, 2, 7, command.rawValue]))
            #expect(request.bytes[8...87].allSatisfy { $0 == 0 })
            #expect((request.bytes[88]) == (checksum))
            #expect((request.bytes[89]) == (0))
        }
        #expect((RazerCommand.allCases.count) == (2))
    }

    @Test
    func testRawZeroMidAndFullAreValidBatteryReadings() throws {
        for (raw, percent) in [(UInt8(0), 0), (128, 50), (255, 100)] {
            let result = try RazerResponse.parse(synthetic(raw: raw), for: RazerRequest(command: .battery))
            #expect((result.battery?.rawValue) == (raw))
            #expect((result.battery?.percent) == (percent))
            #expect((result.charging) == nil)
        }
    }

    @Test
    func testChargingZeroOneAndOtherStayDistinct() throws {
        for (raw, state) in [(UInt8(0), RazerChargingState.notCharging), (1, .charging), (2, .unknown), (255, .unknown)] {
            let result = try RazerResponse.parse(synthetic(.charging, raw: raw), for: RazerRequest(command: .charging))
            #expect((result.charging?.rawValue) == (raw))
            #expect((result.charging?.state) == (state))
            #expect((result.battery) == nil)
        }
    }

    @Test
    func testByteNineIsTheValueAndByteTenIsNot() throws {
        var frame = synthetic(raw: 0)
        frame[10] = 255
        frame[88] = try RazerChecksum.calculate(frame)
        #expect((try RazerResponse.parse(frame, for: RazerRequest(command: .battery)).battery?.percent) == (0))
    }

    @Test
    func testRejectsEveryUnexpectedLengthBeforeIndexing() {
        for length in [0, 1, 8, 9, 88, 89, 91, 256] {
            assertRejected([UInt8](repeating: 0, count: length), as: .invalidLength(expected: 90, actual: length))
        }
        #expect(throws: (any Error).self) { try RazerChecksum.calculate([0]) }
    }

    @Test
    func testRejectsStructuralAndAssociationErrorsEvenWithRecomputedChecksum() throws {
        let cases: [(Int, UInt8, RazerProtocolError)] = [
            (2, 1, .remainingPackets(high: 1, low: 0)),
            (3, 1, .remainingPackets(high: 0, low: 1)),
            (4, 1, .invalidProtocolType(1)),
            (5, 0, .invalidPayloadLength(expected: 2, actual: 0)),
            (5, 1, .invalidPayloadLength(expected: 2, actual: 1)),
            (5, 3, .invalidPayloadLength(expected: 2, actual: 3)),
            (5, 81, .invalidPayloadLength(expected: 2, actual: 81)),
            (6, 4, .wrongCommandClass(expected: 7, actual: 4)),
            (7, 0x84, .wrongCommand(expected: 0x80, actual: 0x84)),
            (1, 0x3F, .wrongTransaction(expected: 0x1F, actual: 0x3F)),
            (89, 1, .invalidReservedByte(1))
        ]
        for (index, byte, expected) in cases {
            var frame = synthetic()
            frame[index] = byte
            frame[88] = try RazerChecksum.calculate(frame)
            assertRejected(frame, as: expected)
        }
    }

    @Test
    func testChecksumCoversExactlyBytesTwoThroughEightySeven() throws {
        let original = synthetic()
        let checksum = try RazerChecksum.calculate(original)
        for index in [0, 1, 88, 89] {
            var frame = original
            frame[index] ^= 0x40
            #expect((try RazerChecksum.calculate(frame)) == (checksum))
        }
        for index in 2...87 {
            var frame = original
            frame[index] ^= 0x40
            #expect((try RazerChecksum.calculate(frame)) != (checksum), "Byte \(index) is protected")
        }
        var broken = original
        broken[9] ^= 1
        assertRejected(broken, as: .checksumMismatch(expected: checksum ^ 1, actual: checksum))
    }

    @Test
    func testBusyAndFailureStatusesNeverProduceBattery() {
        assertRejected(synthetic(status: 1), as: .busy)
        for status in [UInt8(0), 3, 4, 5, 255] {
            assertRejected(synthetic(status: status), as: .deviceStatus(status))
        }
        var malformedBusy = synthetic(status: 1)
        malformedBusy[88] ^= 1
        assertRejected(malformedBusy, as: .checksumMismatch(expected: synthetic(status: 1)[88], actual: malformedBusy[88]))
    }

    @Test
    func testStaleResponseFromDifferentCommandOrTransactionIsRejected() {
        assertRejected(synthetic(.charging), as: .wrongCommand(expected: 0x80, actual: 0x84))
        assertRejected(synthetic(), request: RazerRequest(command: .battery, transactionID: 0x20), as: .wrongTransaction(expected: 0x20, actual: 0x1F))
    }

    @Test
    func testFixturesAreExplicitlySyntheticAndParse() throws {
        struct Fixture: Decodable {
            struct Frame: Decodable { let name: String; let command: UInt8; let rawValue: UInt8; let hex: String }
            let synthetic: Bool
            let frames: [Frame]
        }
        let url = try #require(Bundle.module.url(forResource: "synthetic-responses", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.synthetic)
        #expect((fixture.frames.count) == (6))
        for frame in fixture.frames {
            let characters = Array(frame.hex)
            let bytes = stride(from: 0, to: characters.count, by: 2).map { UInt8(String(characters[$0...($0 + 1)]), radix: 16)! }
            let command = try #require(RazerCommand(rawValue: frame.command))
            #expect((try RazerResponse.parse(bytes, for: RazerRequest(command: command)).rawValue) == (frame.rawValue), "\(frame.name)")
        }
    }
}
