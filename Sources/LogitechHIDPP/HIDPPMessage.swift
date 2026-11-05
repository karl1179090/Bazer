// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

public enum HIDPPError: Error, Equatable, Sendable {
    case malformed(String), invalidValue(String), unsupportedFeature(UInt16)
    case protocolError(HIDPPProtocolError)
    case transport(String), timeout, cancelled, closed, busy, staleRequest
    case sessionRebuildRequired(String)
    case readbackMismatch(String)
    case interruptedWrite(completedChunks: Int, stage: String, reason: String)
    case ioFailure(HIDPPIODiagnostic)
}

public struct HIDPPIODiagnostic: Codable, Equatable, Sendable {
    public let phase: String, rawIOReturn: Int32, endpointRegistryEntryID: UInt64?
    public init(phase: String,rawIOReturn: Int32,endpointRegistryEntryID: UInt64?) { self.phase=phase; self.rawIOReturn=rawIOReturn; self.endpointRegistryEntryID=endpointRegistryEntryID }
}
public struct HIDPPControlTrace: Codable, Equatable, Sendable {
    public let startedAt: Date, receivedAt: Date?, elapsedMilliseconds: Double
    public let command: String, deviceIndex: UInt8, featureID: UInt16, featureIndex: UInt8, softwareID: UInt8
    public let tx: [UInt8], rx: [UInt8]?, transmittedLength: Int, actualInputLength: Int?
    public let redacted: Bool, outcome: String, io: HIDPPIODiagnostic?
    public let txSHA256: String, rxSHA256: String?, maskDescription: String?
    public init(startedAt: Date,receivedAt: Date?,elapsedMilliseconds: Double,request: HIDPPRequest,response: HIDPPMessage?,actualInputLength: Int?,error: (any Error)?) {
        self.startedAt=startedAt; self.receivedAt=receivedAt; self.elapsedMilliseconds=elapsedMilliseconds
        command=request.command.traceName; deviceIndex=request.message.deviceIndex; featureID=request.command.featureID; featureIndex=request.message.featureIndex; softwareID=request.message.softwareID
        let shouldRedact=request.command.featureID == 0x8100 || request.command.featureID == 3 || request.command.isRegister
        redacted=shouldRedact
        tx=shouldRedact ? Array(request.message.bytes.prefix(4)) : request.message.bytes
        rx=response.map { shouldRedact ? Array($0.bytes.prefix(4)) : $0.bytes }
        transmittedLength=request.message.bytes.count; self.actualInputLength=actualInputLength
        func digest(_ bytes: [UInt8]) -> String { SHA256.hash(data:Data(bytes)).map { String(format:"%02x",$0) }.joined() }
        txSHA256=digest(request.message.bytes); rxSHA256=response.map { digest($0.bytes) }
        maskDescription=shouldRedact ? "Only the 4-byte control header is retained; full canonical frame SHA256 and actual lengths are recorded. Profile/identity/register parameters are withheld." : nil
        if let typed=error as? HIDPPError, case .ioFailure(let diagnostic)=typed { io=diagnostic } else { io=nil }
        outcome=error.map { String(describing:$0) } ?? "response"
    }
}
public struct HIDPPControlTraceSnapshot: Codable, Equatable, Sendable {
    public let entries: [HIDPPControlTrace], capacity: Int, droppedCount: Int
    public var truncated: Bool { droppedCount > 0 }
    public init(entries: [HIDPPControlTrace],capacity: Int,droppedCount: Int) { self.entries=entries; self.capacity=capacity; self.droppedCount=droppedCount }
    private enum CodingKeys: String,CodingKey { case entries,capacity,droppedCount,truncated }
    public init(from decoder: Decoder) throws { let c=try decoder.container(keyedBy:CodingKeys.self); entries=try c.decode([HIDPPControlTrace].self,forKey:.entries); capacity=try c.decode(Int.self,forKey:.capacity); droppedCount=try c.decode(Int.self,forKey:.droppedCount) }
    public func encode(to encoder: Encoder) throws { var c=encoder.container(keyedBy:CodingKeys.self); try c.encode(entries,forKey:.entries); try c.encode(capacity,forKey:.capacity); try c.encode(droppedCount,forKey:.droppedCount); try c.encode(truncated,forKey:.truncated) }
}

public struct HIDPPProtocolError: Error, Equatable, Sendable {
    public enum Style: String, Sendable { case register, feature }
    public let style: Style
    public let code: UInt8
    public var meaning: String {
        if style == .feature {
            return [1:"unknown", 2:"invalidArgument", 3:"outOfRange", 4:"hardwareError", 5:"internalError", 6:"invalidFeature", 7:"invalidFunction", 8:"busy", 9:"unsupported"][Int(code)] ?? "unknownStatus"
        }
        return [1:"invalidSubID", 2:"invalidAddress", 3:"invalidValue", 4:"connectionFailed", 5:"tooManyDevices", 6:"alreadyExists", 7:"busy", 8:"unknownDevice", 9:"resourceError", 10:"requestUnavailable", 11:"invalidParameter", 12:"wrongPIN"][Int(code)] ?? "unknownStatus"
    }
}

public enum HIDPPReportKind: UInt8, CaseIterable, Sendable {
    case short = 0x10, long = 0x11
    public var length: Int { self == .short ? 7 : 20 }
    public var parameterCapacity: Int { length - 4 }
}

/// Canonical packets include their Report ID exactly once. Normalization is explicit,
/// based on callback length and Report ID; it never guesses by inspecting a payload byte.
public struct HIDPPMessage: Equatable, Sendable {
    public let kind: HIDPPReportKind
    public let bytes: [UInt8]
    public let receivedAt: Date?
    public var deviceIndex: UInt8 { bytes[1] }
    public var featureIndex: UInt8 { bytes[2] }
    public var address: UInt8 { bytes[3] }
    public var function: UInt8 { address >> 4 }
    public var softwareID: UInt8 { address & 15 }
    public var parameters: [UInt8] { Array(bytes.dropFirst(4)) }
    public init(bytes: [UInt8],receivedAt: Date? = nil) throws {
        guard let id = bytes.first, let kind = HIDPPReportKind(rawValue: id), bytes.count == kind.length else { throw HIDPPError.malformed("HID++ requires an exact 7- or 20-byte numbered report") }
        self.kind = kind; self.bytes = bytes; self.receivedAt=receivedAt
    }
    public static func normalize(reportID: UInt8, bytes: [UInt8],receivedAt: Date? = nil) throws -> HIDPPMessage {
        guard let kind = HIDPPReportKind(rawValue: reportID) else { throw HIDPPError.malformed("Unrelated report ID") }
        if bytes.count == kind.length { guard bytes.first == reportID else { throw HIDPPError.malformed("Conflicting Report ID") }; return try Self(bytes: bytes,receivedAt:receivedAt) }
        guard bytes.count == kind.length - 1 else { throw HIDPPError.malformed("Invalid callback report length") }
        return try Self(bytes: [reportID] + bytes,receivedAt:receivedAt)
    }
}

public enum HIDPPReceiverVariant: String, Sendable { case unifying, lightspeed, bolt, unknown }

/// Only named protocol operations can become output packets. No arbitrary report entry point.
public enum HIDPPCommand: Equatable, Sendable {
    case ping(UInt8), lookupFeature(UInt16), featureCount, featureAt(UInt8)
    case firmwareInfo, firmwareEntity(UInt8), nameLength, nameChunk(UInt8), deviceKind
    case battery1000, battery1001, battery1004Capabilities, battery1004, adcMeasurement
    case sensorCount(extended: Bool), sensorInfo(UInt8), dpiList(sensor: UInt8, direction: UInt8, page: UInt8, extended: Bool)
    case dpi(sensor: UInt8, extended: Bool), setDPI(sensor: UInt8, x: UInt16, y: UInt16?, lod: UInt8?, extended: Bool)
    case rateCapabilities(extended: Bool), rate(extended: Bool), setRate(code: UInt8, extended: Bool)
    case onboardInfo, onboardMode, activeProfile, activeDPIIndex
    case setOnboardMode(UInt8), setActiveProfile(UInt16), setActiveDPIIndex(UInt8)
    case readSector(sector: UInt16, offset: UInt16)
    case startSectorWrite(sector: UInt16, length: UInt16), sectorWriteData([UInt8]), endSectorWrite
    case receiverInformation, receiverConnection, pairing(slot: UInt8, variant: HIDPPReceiverVariant), extendedPairing(slot: UInt8)

    public var isWrite: Bool {
        switch self {
        case .setDPI, .setRate, .setOnboardMode, .setActiveProfile, .setActiveDPIIndex, .startSectorWrite, .sectorWriteData, .endSectorWrite: true
        default: false
        }
    }
    public var traceName: String {
        switch self {
        case .ping: "root.ping"; case .lookupFeature: "root.getFeature"; case .featureCount: "featureSet.count"; case .featureAt: "featureSet.featureAt"
        case .firmwareInfo: "identity.info"; case .firmwareEntity: "identity.firmwareEntity"; case .nameLength: "identity.nameLength"; case .nameChunk: "identity.nameChunk"; case .deviceKind: "identity.kind"
        case .battery1000: "battery1000.status"; case .battery1001: "battery1001.voltage"; case .battery1004Capabilities: "battery1004.capabilities"; case .battery1004: "battery1004.status"; case .adcMeasurement: "adc1F20.measurement"
        case .sensorCount: "dpi.sensorCount"; case .sensorInfo: "dpi.sensorInfo"; case .dpiList: "dpi.list"; case .dpi: "dpi.current"; case .setDPI: "dpi.set"
        case .rateCapabilities: "rate.capabilities"; case .rate: "rate.current"; case .setRate: "rate.set"
        case .onboardInfo: "onboard.info"; case .onboardMode: "onboard.mode"; case .activeProfile: "onboard.activeProfile"; case .activeDPIIndex: "onboard.activeDPIIndex"
        case .setOnboardMode: "onboard.setMode"; case .setActiveProfile: "onboard.setActiveProfile"; case .setActiveDPIIndex: "onboard.setActiveDPIIndex"
        case .readSector: "onboard.readSector"; case .startSectorWrite: "onboard.startWrite"; case .sectorWriteData: "onboard.writeChunk"; case .endSectorWrite: "onboard.endWrite"
        case .receiverInformation: "receiver.info"; case .receiverConnection: "receiver.connections"; case .pairing: "receiver.pairing"; case .extendedPairing: "receiver.extendedPairing"
        }
    }
    public var isRegister: Bool {
        switch self { case .receiverInformation, .receiverConnection, .pairing, .extendedPairing: true; default: false }
    }
    public var featureID: UInt16 {
        switch self {
        case .ping, .lookupFeature: 0
        case .featureCount, .featureAt: 1
        case .firmwareInfo, .firmwareEntity: 3
        case .nameLength, .nameChunk, .deviceKind: 5
        case .battery1000: 0x1000
        case .battery1001: 0x1001
        case .battery1004, .battery1004Capabilities: 0x1004
        case .adcMeasurement: 0x1F20
        case .sensorCount(let ext), .dpiList(_,_,_,let ext), .dpi(_,let ext), .setDPI(_,_,_,_,let ext): ext ? 0x2202 : 0x2201
        case .sensorInfo: 0x2202
        case .rateCapabilities(let ext), .rate(let ext), .setRate(_,let ext): ext ? 0x8061 : 0x8060
        case .receiverInformation, .receiverConnection, .pairing, .extendedPairing: 0xFFFF
        default: 0x8100
        }
    }
    fileprivate func fields() throws -> (UInt8, [UInt8]) {
        func be(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 255)] }
        switch self {
        case .ping(let nonce): return (0x10, [0, 0, nonce])
        case .lookupFeature(let id): return (0, be(id))
        case .featureCount, .firmwareInfo, .nameLength, .battery1000, .battery1001, .battery1004Capabilities, .adcMeasurement, .onboardInfo: return (0, [])
        case .featureAt(let index), .firmwareEntity(let index), .nameChunk(let index): return (0x10, [index])
        case .deviceKind, .onboardMode: return (0x20, [])
        case .battery1004: return (0x10, [])
        case .sensorCount: return (0, [])
        case .sensorInfo(let sensor): return (0x10, [sensor])
        case .dpiList(let sensor, let direction, let page, let extended):
            guard extended || (direction == 0 && page == 0) else { throw HIDPPError.invalidValue("2201 has one non-paginated DPI list") }
            return (extended ? 0x20 : 0x10, extended ? [sensor,direction,page] : [sensor])
        case .dpi(let sensor, let extended): return (extended ? 0x50 : 0x20, [sensor])
        case .setDPI(let sensor, let x, let y, let lod, let extended):
            guard x > 0, extended || (y == nil && lod == nil) else { throw HIDPPError.invalidValue("2201 cannot write independent Y or LOD") }
            if extended { return (0x60, [sensor] + be(x) + be(y ?? 0) + [lod ?? 0]) }
            return (0x30, [sensor] + be(x))
        case .rateCapabilities(let ext): return (ext ? 0x10 : 0, [])
        case .rate(let ext): return (ext ? 0x20 : 0x10, [])
        case .setRate(let code, let ext):
            guard ext ? code <= 6 : (1...8).contains(code) else { throw HIDPPError.invalidValue("Invalid report rate code") }
            return (ext ? 0x30 : 0x20, [code])
        case .activeProfile: return (0x40, [])
        case .activeDPIIndex: return (0xB0, [])
        case .setOnboardMode(let mode): guard mode == 1 || mode == 2 else { throw HIDPPError.invalidValue("Invalid onboard mode") }; return (0x10, [mode])
        case .setActiveProfile(let sector): return (0x30, be(sector))
        case .setActiveDPIIndex(let index): guard index < 5 else { throw HIDPPError.invalidValue("Invalid DPI index") }; return (0xC0,[index])
        case .readSector(let sector, let offset): return (0x50, be(sector) + be(offset))
        case .startSectorWrite(let sector, let length): guard length == 255 || (length >= 16 && length <= 4096 && length % 16 == 0) else { throw HIDPPError.invalidValue("Unsupported physical sector write length") }; return (0x60,be(sector) + [0,0] + be(length))
        case .sectorWriteData(let bytes): guard bytes.count == 16 else { throw HIDPPError.invalidValue("Sector write chunk must have 16 bytes") }; return (0x70,bytes)
        case .endSectorWrite: return (0x80,[])
        case .receiverInformation: return (0xB5,[3])
        case .receiverConnection: return (2,[])
        case .pairing(let slot,let variant):
            guard (1...6).contains(slot), variant != .unknown else { throw HIDPPError.invalidValue("An identified receiver variant and bounded slot are required") }
            return (0xB5,[variant == .bolt ? 0x50 + slot : 0x20 + slot - 1])
        case .extendedPairing(let slot): guard (1...6).contains(slot) else { throw HIDPPError.invalidValue("Invalid receiver slot") }; return (0xB5,[0x30 + slot - 1])
        }
    }
}

public struct HIDPPRequest: Equatable, Sendable {
    public let command: HIDPPCommand
    public let message: HIDPPMessage
    public var correlationKey: String { "\(message.deviceIndex):\(message.featureIndex):\(message.address)" }
    public init(deviceIndex: UInt8, featureIndex: UInt8, command: HIDPPCommand, softwareID: UInt8, reportKinds: Set<HIDPPReportKind> = [.short,.long]) throws {
        let (function,parameters) = try command.fields()
        guard command.isRegister || (1...15).contains(softwareID) else { throw HIDPPError.invalidValue("Software ID must be nonzero and fit four bits") }
        guard command.featureID != 0 || featureIndex == 0 else { throw HIDPPError.invalidValue("Root index must be zero") }
        guard command.featureID == 0 || command.isRegister || featureIndex != 0 else { throw HIDPPError.invalidValue("Missing discovered feature index") }
        let index: UInt8 = command.isRegister ? (command == .receiverConnection ? 0x81 : 0x83) : featureIndex
        let address = command.isRegister ? function : function | softwareID
        let kind: HIDPPReportKind
        if parameters.count <= 3 && reportKinds.contains(.short) { kind = .short }
        else if parameters.count <= 16 && reportKinds.contains(.long) { kind = .long }
        else { throw HIDPPError.invalidValue("Endpoint lacks required output report") }
        self.command = command
        message = try HIDPPMessage(bytes: [kind.rawValue,deviceIndex,index,address] + parameters + [UInt8](repeating: 0,count: kind.parameterCapacity-parameters.count))
    }
}

public enum HIDPPMatch: Equatable, Sendable { case unrelated, response(HIDPPMessage), failure(HIDPPProtocolError) }
public enum HIDPPResponseMatcher {
    public static func match(_ response: HIDPPMessage, request: HIDPPRequest) -> HIDPPMatch {
        let expected = request.message
        guard response.deviceIndex == expected.deviceIndex else { return .unrelated }
        if response.featureIndex == 0x8F || response.featureIndex == 0xFF {
            let p = response.parameters
            // Error packets shift the echoed feature/sub-ID into byte 3 and address into byte 4.
            guard response.address == expected.featureIndex, p.count >= 2, p[0] == expected.address else { return .unrelated }
            return .failure(HIDPPProtocolError(style: response.featureIndex == 0x8F ? .register : .feature,code: p[1]))
        }
        guard response.featureIndex == expected.featureIndex, response.address == expected.address else { return .unrelated }
        if case .ping(let nonce) = request.command { guard response.parameters[2] == nonce else { return .unrelated } }
        if request.command.isRegister, let selector = expected.parameters.first, request.command != .receiverConnection {
            guard response.parameters.first == selector else { return .unrelated }
        }
        return .response(response)
    }
}

public protocol HIDPPExchange: Sendable { func exchange(_ request: HIDPPRequest) async throws -> HIDPPMessage }
public protocol HIDPPTransaction: HIDPPExchange { func finish() async }
public protocol HIDPPTransport: HIDPPExchange { func acquireTransaction() async throws -> any HIDPPTransaction }

func require(_ bytes: [UInt8], _ count: Int) throws { guard bytes.count >= count else { throw HIDPPError.malformed("Truncated feature payload: need \(count), got \(bytes.count)") } }
func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset+1]) }
