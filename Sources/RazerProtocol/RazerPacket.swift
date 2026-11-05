// SPDX-License-Identifier: GPL-3.0-or-later
// Protocol layout adapted from FerrisPulse; see THIRD_PARTY_NOTICES.md.
import Foundation

/// Legacy telemetry commands. Settings use the separate typed setting codec.
public enum RazerCommand: UInt8, Codable, Sendable, CaseIterable {
    case battery = 0x80
    case charging = 0x84
    public var commandClass: UInt8 { 0x07 }
    public var dataSize: UInt8 { 2 }
}

public struct RazerRequest: Equatable, Codable, Sendable {
    public static let frameLength = 90
    public let command: RazerCommand
    public let transactionID: UInt8
    public var reportID: UInt8 { 0 }

    public init(command: RazerCommand, transactionID: UInt8 = 0x1F) {
        self.command = command
        self.transactionID = transactionID
    }

    /// No Windows leading placeholder and no extra Report ID byte.
    public var bytes: [UInt8] {
        var frame = [UInt8](repeating: 0, count: Self.frameLength)
        frame[1] = transactionID
        frame[5] = command.dataSize
        frame[6] = command.commandClass
        frame[7] = command.rawValue
        frame[88] = frame[2...87].reduce(0, ^)
        return frame
    }
}

public enum RazerProtocolError: Error, Equatable, Codable, Sendable {
    case invalidLength(expected: Int, actual: Int)
    case remainingPackets(high: UInt8, low: UInt8)
    case invalidProtocolType(UInt8)
    case invalidPayloadLength(expected: UInt8, actual: UInt8)
    case wrongCommandClass(expected: UInt8, actual: UInt8)
    case wrongCommand(expected: UInt8, actual: UInt8)
    case wrongTransaction(expected: UInt8, actual: UInt8)
    case invalidReservedByte(UInt8)
    case checksumMismatch(expected: UInt8, actual: UInt8)
    case busy
    case deviceStatus(UInt8)
}

public enum RazerChecksum {
    public static func calculate(_ bytes: [UInt8]) throws -> UInt8 {
        guard bytes.count == RazerRequest.frameLength else {
            throw RazerProtocolError.invalidLength(expected: RazerRequest.frameLength, actual: bytes.count)
        }
        return bytes[2...87].reduce(0, ^)
    }
}

public struct RazerBatteryReading: Equatable, Codable, Sendable {
    public let rawValue: UInt8
    public var percent: Int { Int((Double(rawValue) * 100 / 255).rounded()) }
}

public enum RazerChargingState: String, Codable, Sendable { case charging, notCharging, unknown }

public struct RazerChargingReading: Equatable, Codable, Sendable {
    public let rawValue: UInt8
    public var state: RazerChargingState {
        switch rawValue {
        case 0: .notCharging
        case 1: .charging
        default: .unknown
        }
    }
}

/// Constructible only after validating a response against the request.
public struct RazerResponse: Equatable, Sendable {
    public let command: RazerCommand
    public let transactionID: UInt8
    public let rawValue: UInt8
    public let bytes: [UInt8]

    public var battery: RazerBatteryReading? {
        command == .battery ? RazerBatteryReading(rawValue: rawValue) : nil
    }
    public var charging: RazerChargingReading? {
        command == .charging ? RazerChargingReading(rawValue: rawValue) : nil
    }

    public static func parse(_ bytes: [UInt8], for request: RazerRequest) throws -> Self {
        guard bytes.count == RazerRequest.frameLength else {
            throw RazerProtocolError.invalidLength(expected: RazerRequest.frameLength, actual: bytes.count)
        }
        guard bytes[2] == 0 && bytes[3] == 0 else {
            throw RazerProtocolError.remainingPackets(high: bytes[2], low: bytes[3])
        }
        guard bytes[4] == 0 else { throw RazerProtocolError.invalidProtocolType(bytes[4]) }
        guard bytes[5] == request.command.dataSize else {
            throw RazerProtocolError.invalidPayloadLength(expected: request.command.dataSize, actual: bytes[5])
        }
        guard bytes[6] == request.command.commandClass else {
            throw RazerProtocolError.wrongCommandClass(expected: request.command.commandClass, actual: bytes[6])
        }
        guard bytes[7] == request.command.rawValue else {
            throw RazerProtocolError.wrongCommand(expected: request.command.rawValue, actual: bytes[7])
        }
        guard bytes[1] == request.transactionID else {
            throw RazerProtocolError.wrongTransaction(expected: request.transactionID, actual: bytes[1])
        }
        guard bytes[89] == 0 else { throw RazerProtocolError.invalidReservedByte(bytes[89]) }
        let checksum = try RazerChecksum.calculate(bytes)
        guard bytes[88] == checksum else {
            throw RazerProtocolError.checksumMismatch(expected: checksum, actual: bytes[88])
        }
        // Status is trusted only after validating both structure and association.
        if bytes[0] == 0x01 { throw RazerProtocolError.busy }
        guard bytes[0] == 0x02 else { throw RazerProtocolError.deviceStatus(bytes[0]) }
        return Self(command: request.command, transactionID: request.transactionID, rawValue: bytes[9], bytes: bytes)
    }
}
