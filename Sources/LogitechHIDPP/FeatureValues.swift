// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct HIDPPFeature: Codable, Equatable, Sendable {
    public let id: UInt16, index: UInt8, flags: UInt8, version: UInt8
    public init(id: UInt16,index: UInt8,flags: UInt8,version: UInt8) { self.id=id; self.index=index; self.flags=flags; self.version=version }
}
public struct HIDPPIdentity: Equatable, Sendable {
    public let name: String?, kind: UInt8?, unitID: [UInt8]?, modelID: [UInt8]?, transportIDs: [String:UInt16]
    public let firmware: [HIDPPFirmwareEntity]
    public let receivedAt: Date?
}
public struct HIDPPFirmwareEntity: Equatable, Sendable {
    public let index: UInt8, kind: UInt8, rawBytes: [UInt8]
}
public enum HIDPPBatteryLevel: Equatable, Sendable { case percentage(Int), approximate(UInt8), voltage(Int), unknown }
public struct HIDPPBattery: Equatable, Sendable {
    public let featureID: UInt16, level: HIDPPBatteryLevel, status: UInt8, rawBytes: [UInt8]
    public static func parse(featureID: UInt16, payload: [UInt8], unifiedCapabilities: [UInt8]? = nil) throws -> Self {
        try require(payload, featureID == 0x1004 ? 4 : 3)
        switch featureID {
        case 0x1000:
            guard payload[0] <= 100, payload[1] <= 100 else { throw HIDPPError.malformed("Battery percentage out of range") }
            return Self(featureID:featureID,level:payload[0] == 0 ? .unknown : .percentage(Int(payload[0])),status:payload[2],rawBytes:payload)
        case 0x1001: return Self(featureID:featureID,level:.voltage(Int(u16(payload,0))),status:payload[2],rawBytes:payload)
        case 0x1F20: return Self(featureID:featureID,level:payload[2] & 1 != 0 ? .voltage(Int(u16(payload,0))) : .unknown,status:payload[2],rawBytes:payload)
        case 0x1004:
            guard payload[0] <= 100 else { throw HIDPPError.malformed("Unified battery percentage out of range") }
            guard let capabilities=unifiedCapabilities else { throw HIDPPError.malformed("Unified battery capabilities must be read first") }; try require(capabilities,2)
            // Zero is the protocol's unavailable percentage sentinel. Preserve coarse flags.
            let hasSOC=capabilities[1] & 2 != 0
            let supportedLevel=capabilities[0] & payload[1] == payload[1] && [1,2,4,8].contains(payload[1])
            let value: HIDPPBatteryLevel = hasSOC ? (payload[0] > 0 ? .percentage(Int(payload[0])) : .unknown) : (supportedLevel ? .approximate(payload[1]) : .unknown)
            return Self(featureID:featureID,level:value,status:payload[2],rawBytes:payload)
        default: throw HIDPPError.unsupportedFeature(featureID)
        }
    }
}

public struct HIDPPDPI: Equatable, Sendable {
    public let sensor: UInt8, currentX: UInt16, defaultX: UInt16, currentY: UInt16?, defaultY: UInt16?, lod: UInt8?
    public let rawBytes: [UInt8]
    public var effectiveX: UInt16 { currentX == 0 ? defaultX : currentX }
    public var effectiveY: UInt16? { guard let currentY else { return nil }; return currentY == 0 ? defaultY : currentY }
    public static func parse(_ payload: [UInt8], extended: Bool, supportsY: Bool = false, supportsLOD: Bool = false) throws -> Self {
        try require(payload,extended ? 10 : 5)
        return Self(sensor:payload[0],currentX:u16(payload,1),defaultX:u16(payload,3),currentY:extended && supportsY ? u16(payload,5) : nil,defaultY:extended && supportsY ? u16(payload,7) : nil,lod:extended && supportsLOD ? payload[9] : nil,rawBytes:payload)
    }
}
public struct HIDPPDPICapabilities: Equatable, Sendable {
    public let sensor: UInt8, extended: Bool, supportsY: Bool, supportsLOD: Bool, xValues: [UInt16], yValues: [UInt16]
    /// Decode discrete values and E000|step range descriptors; bound expansion for untrusted input.
    public static func decodeList(_ bytes: [UInt8], requireTerminator: Bool = true) throws -> [UInt16] {
        var values: [UInt16] = []; var offset=0; var terminated=false
        while offset+1 < bytes.count {
            let value=u16(bytes,offset); offset+=2
            if value == 0 { terminated=true; break }
            if value & 0xE000 == 0xE000 {
                let step=value & 0x1FFF
                guard step > 0, let start=values.last, offset+1 < bytes.count else { throw HIDPPError.malformed("Invalid DPI range") }
                let end=u16(bytes,offset); offset+=2
                guard end > start, (end-start) % step == 0 else { throw HIDPPError.malformed("Invalid DPI range endpoint") }
                var next=UInt32(start)+UInt32(step)
                while next <= UInt32(end) { guard values.count < 8192 else { throw HIDPPError.malformed("Oversized DPI list") }; values.append(UInt16(next)); next+=UInt32(step) }
            } else {
                guard values.last.map({ value > $0 }) ?? true else { throw HIDPPError.malformed("DPI list is not ordered") }
                values.append(value)
            }
        }
        guard !values.isEmpty, !requireTerminator || terminated else { throw HIDPPError.malformed("Incomplete DPI list") }
        return values
    }
}
public struct HIDPPReportRate: Equatable, Sendable {
    public let extended: Bool, code: UInt8
    public var periodMicroseconds: Int { extended ? [8000,4000,2000,1000,500,250,125][Int(code)] : Int(code)*1000 }
    public var hertz: Int { extended ? [125,250,500,1000,2000,4000,8000][Int(code)] : 1000 / Int(code) }
    public init(code: UInt8, extended: Bool) throws {
        guard extended ? code <= 6 : (1...8).contains(code) else { throw HIDPPError.malformed("Invalid rate code") }
        self.code=code; self.extended=extended
    }
    public static func supportedCodes(_ payload: [UInt8], extended: Bool) throws -> [UInt8] {
        try require(payload,extended ? 2 : 1)
        let flags=extended ? u16(payload,0) : UInt16(payload[0])
        return (0..<(extended ? 7 : 8)).filter { flags & (1 << $0) != 0 }.map { UInt8(extended ? $0 : $0+1) }
    }
}

public struct HIDPPOnboardInfo: Equatable, Sendable {
    public let memoryType: UInt8, profileFormat: UInt8, macroFormat: UInt8, profileCount: UInt8, romProfileCount: UInt8, buttonCount: UInt8, sectorCount: UInt8, sectorSize: UInt16, mechanicalLayout: UInt8, flags: UInt8
    public let rawBytes: [UInt8]
    public var knownLayout: Bool { memoryType == 1 && profileFormat == 3 && macroFormat == 1 && [255,256].contains(sectorSize) }
    /// Both explicitly supported physical sizes have a complete write plan. Other
    /// bounded readable geometries do not acquire NVM write permission.
    public var knownWritableLayout: Bool { knownLayout }
    public static func parse(_ bytes: [UInt8]) throws -> Self {
        try require(bytes,11)
        let size=u16(bytes,7)
        // The transfer window is 16 bytes; physical sectors need not be aligned.
        // 8100 getInfo uses a BE size at 7...8, mechanical layout at 9 and
        // various-info flags at 10 (libratbag hidpp20_onboard_profiles_info).
        guard size >= 16, size <= 4096, bytes[6] > 0 else { throw HIDPPError.malformed("Invalid onboard sector geometry") }
        return Self(memoryType:bytes[0],profileFormat:bytes[1],macroFormat:bytes[2],profileCount:bytes[3],romProfileCount:bytes[4],buttonCount:bytes[5],sectorCount:bytes[6],sectorSize:size,mechanicalLayout:bytes[9],flags:bytes[10],rawBytes:bytes)
    }
}

public enum HIDPPCRC {
    /// CRC-16/CCITT-FALSE: poly 1021, init FFFF, no reflection, no xorout.
    public static func ccitt(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16=0xFFFF
        for byte in bytes { crc ^= UInt16(byte) << 8; for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 } }
        return crc
    }
}
public struct HIDPPProfileSector: Equatable, Sendable {
    public let sector: UInt16, bytes: [UInt8], info: HIDPPOnboardInfo
    public init(sector: UInt16,bytes: [UInt8],info: HIDPPOnboardInfo) throws {
        guard bytes.count == Int(info.sectorSize), bytes.count >= 16 else { throw HIDPPError.malformed("Sector size differs from discovered geometry") }
        guard HIDPPCRC.ccitt(Array(bytes.dropLast(2))) == u16(bytes,bytes.count-2) else { throw HIDPPError.malformed("Invalid onboard CRC") }
        self.sector=sector; self.bytes=bytes; self.info=info
    }
    public var dpiValues: [UInt16]? { guard info.knownLayout else { return nil }; return (0..<5).map { UInt16(bytes[3+$0*2]) | UInt16(bytes[4+$0*2]) << 8 } }
    /// Pure exact plan shared by the client and the driver's one-use typed policy.
    /// For 255B, count stays 255 while the final 15B is zero-padded on the wire.
    /// The padding is never part of this sector's original bytes or its CRC.
    public func writePlan() throws -> HIDPPProfileWritePlan {
        guard info.knownWritableLayout, sector > 0, sector < UInt16(info.sectorCount) else { throw HIDPPError.invalidValue("Unknown, ROM or control profile cannot produce a write plan") }
        let chunks=stride(from:0,to:bytes.count,by:16).map { offset in
            let chunk=Array(bytes[offset..<min(offset+16,bytes.count)])
            return chunk+[UInt8](repeating:0,count:16-chunk.count)
        }
        return HIDPPProfileWritePlan(sector:sector,length:info.sectorSize,chunks:chunks)
    }
    public func patch(dpi: [Int:UInt16] = [:], reportRateCode: UInt8? = nil, defaultDPIIndex: UInt8? = nil) throws -> Self {
        guard info.knownWritableLayout else { throw HIDPPError.invalidValue("Profile layout or physical sector write geometry is read-only") }
        guard sector > 0, sector < UInt16(info.sectorCount) else { throw HIDPPError.invalidValue("ROM/control sector is not a writable profile") }
        var updated=bytes
        for (index,value) in dpi { guard (0..<5).contains(index), value > 0 else { throw HIDPPError.invalidValue("Invalid profile DPI field") }; updated[3+index*2]=UInt8(value & 255); updated[4+index*2]=UInt8(value >> 8) }
        if let code=reportRateCode { guard (1...8).contains(code) else { throw HIDPPError.invalidValue("Invalid profile rate") }; updated[0]=code }
        if let index=defaultDPIIndex { guard index < 5 else { throw HIDPPError.invalidValue("Invalid default DPI index") }; updated[1]=index }
        let crc=HIDPPCRC.ccitt(Array(updated.dropLast(2))); updated[updated.count-2]=UInt8(crc >> 8); updated[updated.count-1]=UInt8(crc & 255)
        return try Self(sector:sector,bytes:updated,info:info)
    }
}

/// Contains profile bytes; keep it out of ordinary diagnostic output. Construction
/// is restricted to a complete, CRC-validated sector with an exact known layout.
public struct HIDPPProfileWritePlan: Equatable, Sendable {
    public let sector: UInt16, length: UInt16, chunks: [[UInt8]]
    fileprivate init(sector: UInt16,length: UInt16,chunks: [[UInt8]]) { self.sector=sector; self.length=length; self.chunks=chunks }
    public var commands: [HIDPPCommand] { [.startSectorWrite(sector:sector,length:length)] + chunks.map(HIDPPCommand.sectorWriteData) + [.endSectorWrite] }
}

public struct HIDPPProfileDirectoryEntry: Equatable, Sendable {
    public let sector: UInt16, enabled: Bool
    public static func parse(_ directory: HIDPPProfileSector) throws -> [Self] {
        guard directory.sector == 0 || directory.sector == 0x100 else { throw HIDPPError.invalidValue("Not a profile directory sector") }
        var entries: [Self]=[]
        for offset in stride(from:0,to:directory.bytes.count-5,by:4) {
            let sector=u16(directory.bytes,offset)
            if sector == 0xFFFF { return entries }
            guard directory.bytes[offset+2] <= 1, !entries.contains(where: { $0.sector == sector }) else { throw HIDPPError.malformed("Unknown directory flags or duplicate profile sector") }
            entries.append(Self(sector:sector,enabled:directory.bytes[offset+2] == 1))
            guard entries.count <= Int(directory.info.profileCount) else { throw HIDPPError.malformed("Profile directory exceeds discovered count") }
        }
        throw HIDPPError.malformed("Profile directory is missing its terminator")
    }
}

public struct HIDPPReceiverChild: Equatable, Sendable {
    public let slot: UInt8, wirelessProductID: UInt16, kind: UInt8, unitID: [UInt8]?, online: Bool?
    public static func pairing(_ p: [UInt8], slot: UInt8, variant: HIDPPReceiverVariant) throws -> Self {
        try require(p,8)
        guard (1...6).contains(slot), variant != .unknown else { throw HIDPPError.invalidValue("Unknown receiver variant") }
        return Self(slot:slot,wirelessProductID:variant == .bolt ? UInt16(p[3]) << 8 | UInt16(p[2]) : u16(p,3),kind:variant == .bolt ? p[1] & 15 : p[7] & 15,unitID:variant == .bolt ? Array(p[4..<8]) : nil,online:nil)
    }
    public static func notification(_ m: HIDPPMessage, variant: HIDPPReceiverVariant) throws -> Self {
        guard variant == .unifying || variant == .lightspeed, m.featureIndex == 0x41, m.address != 2, (1...6).contains(m.deviceIndex) else { throw HIDPPError.malformed("Not a supported receiver connection notification") }
        let p=m.parameters; try require(p,3)
        return Self(slot:m.deviceIndex,wirelessProductID:UInt16(p[2]) << 8 | UInt16(p[1]),kind:p[0] & 15,unitID:nil,online:p[0] & 0x40 == 0)
    }
}
