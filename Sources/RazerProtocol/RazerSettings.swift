// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol fields independently implemented from the OpenRazer source snapshots
// recorded in docs/evidence/expansion-planning-baseline-2026-11-04.json.
import Foundation
import CryptoKit

/// A protocol selector, not a promise that a setting survives power removal.
public enum RazerStorage: UInt8, Codable, Sendable { case volatile = 0, device = 1 }

public enum RazerSettingsError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case unknownLayout
    case unknownRateCode(UInt8)
    case unexpectedStorage(expected: UInt8, actual: UInt8)
}

public enum RazerTraditionalPollingRate: UInt16, Codable, CaseIterable, Sendable {
    case hz125 = 125, hz500 = 500, hz1000 = 1000
    public var code: UInt8 { switch self { case .hz125: 8; case .hz500: 2; case .hz1000: 1 } }
    public init(code: UInt8) throws {
        guard let value = Self.allCases.first(where: { $0.code == code }) else { throw RazerSettingsError.unknownRateCode(code) }
        self = value
    }
}

/// Independent candidate codec. These codes are never traditional rate codes.
public enum RazerExtendedPollingRate: UInt16, Codable, CaseIterable, Sendable {
    case hz125 = 125, hz250 = 250, hz500 = 500, hz1000 = 1000, hz2000 = 2000, hz4000 = 4000, hz8000 = 8000
    public var code: UInt8 {
        switch self { case .hz125: 0x40; case .hz250: 0x20; case .hz500: 0x10; case .hz1000: 8; case .hz2000: 4; case .hz4000: 2; case .hz8000: 1 }
    }
    public init(code: UInt8) throws {
        guard let value = Self.allCases.first(where: { $0.code == code }) else { throw RazerSettingsError.unknownRateCode(code) }
        self = value
    }
}

public struct RazerDPIConstraints: Equatable, Sendable {
    public let minimum: UInt16
    public let maximum: UInt16
    public let step: UInt16
    public init(minimum: UInt16, maximum: UInt16, step: UInt16) throws {
        guard minimum > 0, maximum >= minimum, step > 0 else { throw RazerSettingsError.invalidArgument("invalid DPI bounds or step") }
        self.minimum = minimum; self.maximum = maximum; self.step = step
    }
    func validate(_ value: UInt16) throws {
        guard value >= minimum, value <= maximum, (value - minimum) % step == 0 else { throw RazerSettingsError.invalidArgument("DPI is outside the explicit range or step") }
    }
}

public struct RazerDPISnapshot: Equatable, Sendable {
    public let storage: RazerStorage
    public let x: UInt16
    public let y: UInt16
    /// All 80 argument bytes are retained, including bytes outside data_size.
    public let payload: [UInt8]
}

public enum RazerStageLayout: Equatable, Sendable {
    case unknown
    /// Source-backed candidate layout. IDs remain opaque; no 0/1 base is inferred.
    case sevenByteRecords
}

public struct RazerDPIStage: Equatable, Sendable {
    public let id: UInt8
    public let x: UInt16
    public let y: UInt16
    public let reserved: [UInt8]
}

/// A complete read image plus local edits, with no public blank-table constructor.
public struct RazerStageTable: Equatable, Sendable {
    public let storage: RazerStorage
    public let layout: RazerStageLayout
    public let originalPayload: [UInt8]
    public let payload: [UInt8]
    public let stages: [RazerDPIStage]
    public var rawActiveStage: UInt8 { payload[1] }

    static func decode(_ payload: [UInt8], storage: RazerStorage, layout: RazerStageLayout, original: [UInt8]? = nil) throws -> Self {
        guard payload.count == 80 else { throw RazerSettingsError.invalidArgument("a stage image must retain all 80 argument bytes") }
        guard payload[0] == storage.rawValue else { throw RazerSettingsError.unexpectedStorage(expected: storage.rawValue, actual: payload[0]) }
        var stages: [RazerDPIStage] = []
        if layout == .sevenByteRecords {
            let count = Int(payload[2])
            guard (1...5).contains(count), 3 + count * 7 <= 38 else { throw RazerSettingsError.invalidArgument("invalid stage count for the 38-byte layout") }
            for index in 0..<count {
                let offset = 3 + index * 7
                stages.append(RazerDPIStage(id: payload[offset], x: u16(payload, offset + 1), y: u16(payload, offset + 3), reserved: Array(payload[(offset + 5)...(offset + 6)])))
            }
            guard Set(stages.map(\.id)).count == count else { throw RazerSettingsError.invalidArgument("duplicate stage IDs") }
        }
        return Self(storage: storage, layout: layout, originalPayload: original ?? payload, payload: payload, stages: stages)
    }

    public func updating(stageID: UInt8, x: UInt16? = nil, y: UInt16? = nil, constraints: RazerDPIConstraints) throws -> Self {
        guard layout == .sevenByteRecords else { throw RazerSettingsError.unknownLayout }
        guard let index = stages.firstIndex(where: { $0.id == stageID }), x != nil || y != nil else { throw RazerSettingsError.invalidArgument("edit must name an existing exact stage ID and a changed axis") }
        let newX = x ?? stages[index].x, newY = y ?? stages[index].y
        try constraints.validate(newX); try constraints.validate(newY)
        var updated = payload
        let offset = 3 + index * 7
        put16(newX, in: &updated, at: offset + 1); put16(newY, in: &updated, at: offset + 3)
        return try Self.decode(updated, storage: storage, layout: layout, original: originalPayload)
    }

    /// Caller must already know that the device's active field uses exact IDs.
    /// This pure codec cannot grant hardware permission for that interpretation.
    public func selecting(activeStageID: UInt8) throws -> Self {
        guard layout == .sevenByteRecords else { throw RazerSettingsError.unknownLayout }
        guard stages.contains(where: { $0.id == activeStageID }) else { throw RazerSettingsError.invalidArgument("unknown active stage ID") }
        var updated = payload; updated[1] = activeStageID
        return try Self.decode(updated, storage: storage, layout: layout, original: originalPayload)
    }
}

public enum RazerSettingCommand: Equatable, Sendable {
    case readBackupIdentity, readFirmware, readDPI, writeDPI, readStages, writeStages, readPollingRate, writePollingRate, readExtendedPollingRate, writeExtendedPollingRate
    public var commandClass: UInt8 { switch self { case .readDPI, .writeDPI, .readStages, .writeStages: 4; default: 0 } }
    public var commandID: UInt8 {
        switch self { case .readBackupIdentity: 0x82; case .readFirmware: 0x81; case .readDPI, .readPollingRate: 0x85; case .writeDPI, .writePollingRate: 5; case .readStages: 0x86; case .writeStages: 6; case .readExtendedPollingRate: 0xC0; case .writeExtendedPollingRate: 0x40 }
    }
    public var dataSize: UInt8 {
        switch self { case .readBackupIdentity: 0x16; case .readFirmware: 2; case .readDPI, .writeDPI: 7; case .readStages, .writeStages: 0x26; case .writeExtendedPollingRate: 2; default: 1 }
    }
    public var isWrite: Bool { switch self { case .writeDPI, .writeStages, .writePollingRate, .writeExtendedPollingRate: true; default: false } }
}

public struct RazerSettingRequest: Equatable, Sendable {
    public let command: RazerSettingCommand
    public let transactionID: UInt8
    public let storage: RazerStorage?
    public let payload: [UInt8]
    public var reportID: UInt8 { 0 }

    private init(command: RazerSettingCommand, transactionID: UInt8, storage: RazerStorage? = nil, payload: [UInt8]) {
        self.command = command; self.transactionID = transactionID; self.storage = storage; self.payload = payload
    }
    private static func arguments(_ prefix: [UInt8]) -> [UInt8] { prefix + Array(repeating: 0, count: 80 - prefix.count) }

    /// Backup/restore actions only. The response parser returns a hash, never serial text.
    public static func readBackupIdentity(transactionID: UInt8 = 0x1F) -> Self {
        Self(command: .readBackupIdentity, transactionID: transactionID, payload: arguments([]))
    }

    public static func readFirmware(transactionID: UInt8 = 0x1F) -> Self {
        Self(command: .readFirmware, transactionID: transactionID, payload: arguments([]))
    }

    public static func readDPI(storage: RazerStorage = .device, transactionID: UInt8 = 0x1F) -> Self {
        Self(command: .readDPI, transactionID: transactionID, storage: storage, payload: arguments([storage.rawValue]))
    }
    public static func writeDPI(from snapshot: RazerDPISnapshot, x: UInt16? = nil, y: UInt16? = nil, constraints: RazerDPIConstraints, transactionID: UInt8 = 0x1F) throws -> Self {
        guard x != nil || y != nil else { throw RazerSettingsError.invalidArgument("DPI write needs an explicit changed axis") }
        let newX = x ?? snapshot.x, newY = y ?? snapshot.y
        try constraints.validate(newX); try constraints.validate(newY)
        var payload = snapshot.payload
        put16(newX, in: &payload, at: 1); put16(newY, in: &payload, at: 3)
        return Self(command: .writeDPI, transactionID: transactionID, storage: snapshot.storage, payload: payload)
    }
    public static func readStages(storage: RazerStorage = .device, transactionID: UInt8 = 0x1F) -> Self {
        Self(command: .readStages, transactionID: transactionID, storage: storage, payload: arguments([storage.rawValue]))
    }
    public static func writeStages(from table: RazerStageTable, transactionID: UInt8 = 0x1F) throws -> Self {
        guard table.layout == .sevenByteRecords else { throw RazerSettingsError.unknownLayout }
        return Self(command: .writeStages, transactionID: transactionID, storage: table.storage, payload: table.payload)
    }
    public static func readPollingRate(transactionID: UInt8 = 0x1F) -> Self {
        Self(command: .readPollingRate, transactionID: transactionID, payload: arguments([]))
    }
    public static func writePollingRate(_ rate: RazerTraditionalPollingRate, transactionID: UInt8 = 0x1F) -> Self {
        Self(command: .writePollingRate, transactionID: transactionID, payload: arguments([rate.code]))
    }
    public static func readExtendedPollingRate(transactionID: UInt8 = 0x1F) -> Self {
        Self(command: .readExtendedPollingRate, transactionID: transactionID, payload: arguments([]))
    }
    public static func writeExtendedPollingRate(_ rate: RazerExtendedPollingRate, selector: UInt8, transactionID: UInt8 = 0x1F) throws -> Self {
        guard selector <= 1 else { throw RazerSettingsError.invalidArgument("extended selector must be explicitly 0 or 1") }
        return Self(command: .writeExtendedPollingRate, transactionID: transactionID, payload: arguments([selector, rate.code]))
    }
    public var bytes: [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: 90)
        bytes[1] = transactionID; bytes[5] = command.dataSize; bytes[6] = command.commandClass; bytes[7] = command.commandID
        bytes[8...87] = payload[...]; bytes[88] = bytes[2...87].reduce(0, ^)
        return bytes
    }
}

public enum RazerSettingResponse: Equatable, Sendable {
    case backupIdentity(sha256: String)
    case firmware(major: UInt8, minor: UInt8)
    case dpi(RazerDPISnapshot)
    case stages(RazerStageTable)
    case pollingRate(RazerTraditionalPollingRate)
    case extendedPollingRate(RazerExtendedPollingRate)
    /// This is an ACK only. It is never a readback or persistence result.
    case acknowledgement(RazerSettingCommand)

    public static func parse(_ bytes: [UInt8], for request: RazerSettingRequest, stageLayout: RazerStageLayout = .unknown) throws -> Self {
        guard bytes.count == 90 else { throw RazerProtocolError.invalidLength(expected: 90, actual: bytes.count) }
        guard bytes[2] == 0, bytes[3] == 0 else { throw RazerProtocolError.remainingPackets(high: bytes[2], low: bytes[3]) }
        guard bytes[4] == 0 else { throw RazerProtocolError.invalidProtocolType(bytes[4]) }
        guard bytes[5] == request.command.dataSize else { throw RazerProtocolError.invalidPayloadLength(expected: request.command.dataSize, actual: bytes[5]) }
        guard bytes[6] == request.command.commandClass else { throw RazerProtocolError.wrongCommandClass(expected: request.command.commandClass, actual: bytes[6]) }
        guard bytes[7] == request.command.commandID else { throw RazerProtocolError.wrongCommand(expected: request.command.commandID, actual: bytes[7]) }
        guard bytes[1] == request.transactionID else { throw RazerProtocolError.wrongTransaction(expected: request.transactionID, actual: bytes[1]) }
        guard bytes[89] == 0 else { throw RazerProtocolError.invalidReservedByte(bytes[89]) }
        let checksum = try RazerChecksum.calculate(bytes)
        guard bytes[88] == checksum else { throw RazerProtocolError.checksumMismatch(expected: checksum, actual: bytes[88]) }
        if bytes[0] == 1 { throw RazerProtocolError.busy }
        guard bytes[0] == 2 else { throw RazerProtocolError.deviceStatus(bytes[0]) }
        if request.command.isWrite { return .acknowledgement(request.command) }
        let payload = Array(bytes[8...87])
        switch request.command {
        case .readBackupIdentity:
            // Hash a domain tag + exact supported USB identity + normalized
            // printable serial, without ever constructing serial text for logs.
            let raw = Array(payload.prefix(22))
            let terminated = Array(raw.prefix(while: { $0 != 0 }))
            let serial = Array(terminated.drop(while: { $0 == 32 }).reversed().drop(while: { $0 == 32 }).reversed())
            guard serial.count >= 4, serial.allSatisfy({ (0x21...0x7E).contains($0) }),
                  Set(serial).count > 1,
                  ![Array("UNKNOWN".utf8), Array("DEFAULT".utf8)].contains(serial.map { (0x61...0x7A).contains($0) ? $0 - 32 : $0 }) else {
                throw RazerSettingsError.invalidArgument("device did not return a usable unique backup identity")
            }
            let digest = SHA256.hash(data: Data(Array("Bazer/RazerBackupIdentity/v1".utf8) + [0x15, 0x32, 0x00, 0xC5] + serial)).map { String(format: "%02x", $0) }.joined()
            return .backupIdentity(sha256: digest)
        case .readFirmware: return .firmware(major: payload[0], minor: payload[1])
        case .readDPI:
            let storage = request.storage!
            guard payload[0] == storage.rawValue else { throw RazerSettingsError.unexpectedStorage(expected: storage.rawValue, actual: payload[0]) }
            return .dpi(RazerDPISnapshot(storage: storage, x: u16(payload, 1), y: u16(payload, 3), payload: payload))
        case .readStages: return .stages(try RazerStageTable.decode(payload, storage: request.storage!, layout: stageLayout))
        case .readPollingRate: return .pollingRate(try RazerTraditionalPollingRate(code: payload[0]))
        case .readExtendedPollingRate: return .extendedPollingRate(try RazerExtendedPollingRate(code: payload[1]))
        default: preconditionFailure("write acknowledgements handled above")
        }
    }
}

private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
private func put16(_ value: UInt16, in bytes: inout [UInt8], at offset: Int) { bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255) }
