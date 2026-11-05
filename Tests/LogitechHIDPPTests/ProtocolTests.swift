// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import LogitechHIDPP

@Suite("Offline HID++ framing and feature values")
struct HIDPPProtocolTests {
    @Test func observedGPW1GeometryUsesPhysical255ByteSector() throws {
        // Device-observed metadata only: capture 05-onboard-info-observation.json,
        // 2026-11-04T07:06:53Z. Contains no identity, profile or macro payload.
        let info=try HIDPPOnboardInfo.parse([1,3,1,5,1,8,16,0,255,10,4,0,0,0,0,0])
        #expect(info.sectorSize == 255)
        #expect(info.sectorCount == 16)
        #expect(info.profileCount == 5)
        #expect(info.knownLayout)
        #expect(info.knownWritableLayout)
        #expect(info.mechanicalLayout == 10)
        #expect(info.flags == 4)
    }
    @Test func exactNumberedReports() throws {
        for kind in HIDPPReportKind.allCases {
            let request=try HIDPPRequest(deviceIndex:3,featureIndex:7,command:.battery1000,softwareID:9,reportKinds:[kind])
            #expect(request.message.bytes.count == kind.length)
            #expect(try HIDPPMessage.normalize(reportID:kind.rawValue,bytes:request.message.bytes) == request.message)
            #expect(try HIDPPMessage.normalize(reportID:kind.rawValue,bytes:Array(request.message.bytes.dropFirst())) == request.message)
            #expect(throws:HIDPPError.self) { try HIDPPMessage.normalize(reportID:kind.rawValue,bytes:Array(request.message.bytes.dropLast(2))) }
        }
    }
    @Test func strictMatcherAndPingNonce() throws {
        let request=try HIDPPRequest(deviceIndex:4,featureIndex:0,command:.ping(77),softwareID:9)
        var bytes=request.message.bytes; bytes[4]=4; bytes[5]=5
        let good=try HIDPPMessage(bytes:bytes)
        #expect(HIDPPResponseMatcher.match(good,request:request) == .response(good))
        for index in [1,2,3,6] { var wrong=bytes; wrong[index] ^= 1; #expect(HIDPPResponseMatcher.match(try HIDPPMessage(bytes:wrong),request:request) == .unrelated) }
        var notification=bytes; notification[3] &= 0xF0
        #expect(HIDPPResponseMatcher.match(try HIDPPMessage(bytes:notification),request:request) == .unrelated)
        for style: UInt8 in [0x8F,0xFF] {
            let error=try HIDPPMessage(bytes:[0x10,4,style,0,0x19,8,0])
            #expect(HIDPPResponseMatcher.match(error,request:request) == .failure(HIDPPProtocolError(style:style == 0x8F ? .register : .feature,code:8)))
        }
    }
    @Test func batteryUnitsAndSentinels() throws {
        #expect(try HIDPPBattery.parse(featureID:0x1000,payload:[50,20,0]).level == .percentage(50))
        #expect(try HIDPPBattery.parse(featureID:0x1000,payload:[0,0,0]).level == .unknown)
        #expect(try HIDPPBattery.parse(featureID:0x1004,payload:[80,2,1,0],unifiedCapabilities:[15,1]).level == .approximate(2))
        #expect(try HIDPPBattery.parse(featureID:0x1004,payload:[80,2,1,0],unifiedCapabilities:[15,3]).level == .percentage(80))
        #expect(try HIDPPBattery.parse(featureID:0x1004,payload:[0,2,99,0],unifiedCapabilities:[15,3]).level == .unknown)
        #expect(throws:HIDPPError.self) { try HIDPPBattery.parse(featureID:0x1004,payload:[80,2,1,0]) }
        #expect(try HIDPPBattery.parse(featureID:0x1001,payload:[0x0F,0xA0,0x80]).level == .voltage(4000))
        #expect(try HIDPPBattery.parse(featureID:0x1F20,payload:[0x0F,0xA0,3]).level == .voltage(4000))
        #expect(try HIDPPBattery.parse(featureID:0x1F20,payload:[0x0F,0xA0,0]).level == .unknown)
        #expect(throws:HIDPPError.self) { try HIDPPBattery.parse(featureID:0x1000,payload:[101,0,0]) }
    }
    @Test func fourDistinctDPIFields() throws {
        let dpi=try HIDPPDPI.parse([0,0x03,0x20,0x06,0x40,0x09,0x60,0x0C,0x80,2,99],extended:true,supportsY:true,supportsLOD:true)
        #expect(dpi.currentX == 800); #expect(dpi.defaultX == 1600); #expect(dpi.currentY == 2400); #expect(dpi.defaultY == 3200); #expect(dpi.lod == 2)
        #expect(try HIDPPDPICapabilities.decodeList([0,100,0xE0,50,0,200,0,0]) == [100,150,200])
        #expect(throws:HIDPPError.self) { try HIDPPDPICapabilities.decodeList([0,100,0xE0,0,0,200,0,0]) }
    }
    @Test func standardAndExtendedRatesRemainDifferent() throws {
        #expect(try HIDPPReportRate.supportedCodes([0b10000101],extended:false) == [1,3,8])
        #expect(try HIDPPReportRate(code:3,extended:false).hertz == 333)
        #expect(try HIDPPReportRate(code:3,extended:true).hertz == 1000)
        #expect(try HIDPPReportRate(code:6,extended:true).hertz == 8000)
    }
    @Test func patchPreservesAllUneditedSectorBytes() throws {
        #expect(HIDPPCRC.ccitt(Array("123456789".utf8)) == 0x29B1)
        let info=try HIDPPOnboardInfo.parse([1,3,1,1,1,8,4,1,0,0,0])
        var bytes=(0..<256).map { UInt8($0) }; let crc=HIDPPCRC.ccitt(Array(bytes.dropLast(2))); bytes[254]=UInt8(crc >> 8); bytes[255]=UInt8(crc & 255)
        let original=try HIDPPProfileSector(sector:1,bytes:bytes,info:info)
        let updated=try original.patch(dpi:[2:1600])
        for index in bytes.indices where ![7,8,254,255].contains(index) { #expect(updated.bytes[index] == original.bytes[index]) }
        #expect(updated.dpiValues?[2] == 1600)
        #expect(throws:HIDPPError.self) { try HIDPPProfileSector(sector:1,bytes:Array(bytes.dropLast()),info:info) }
        var bad=bytes; bad[70] ^= 1
        #expect(throws:HIDPPError.self) { try HIDPPProfileSector(sector:1,bytes:bad,info:info) }
        #expect(throws:HIDPPError.self) { try HIDPPProfileSector(sector:0x100,bytes:bytes,info:info).patch(dpi:[0:800]) }
        let unknown=try HIDPPOnboardInfo.parse([1,9,1,1,1,8,4,1,0,0,0])
        #expect(throws:HIDPPError.self) { try HIDPPProfileSector(sector:1,bytes:bytes,info:unknown).patch(dpi:[0:800]) }
    }
    @Test(arguments: [16,254,255,256,257,4096]) func boundedPhysicalGeometryDoesNotAuthorizeUnknownLayouts(size: UInt16) throws {
        let info=try HIDPPOnboardInfo.parse([1,3,1,1,1,8,4,UInt8(size >> 8),UInt8(size & 255),10,4])
        #expect(info.sectorSize == size)
        #expect(info.knownLayout == [255,256].contains(size))
        #expect(info.knownWritableLayout == [255,256].contains(size))
        var bytes=[UInt8](repeating:0xA5,count:Int(size)); let crc=HIDPPCRC.ccitt(Array(bytes.dropLast(2)))
        bytes[bytes.count-2]=UInt8(crc >> 8); bytes[bytes.count-1]=UInt8(crc & 255)
        let sector=try HIDPPProfileSector(sector:1,bytes:bytes,info:info)
        if ![255,256].contains(size) {
            #expect(throws:HIDPPError.self) { try sector.patch(dpi:[0:800]) }
            #expect(throws:HIDPPError.self) { try sector.writePlan() }
        }
        #expect((sector.dpiValues != nil) == info.knownLayout)
    }
    @Test func invalidAndTruncatedOnboardInfoRemainRejected() throws {
        for size: UInt16 in [0,15,4097] {
            #expect(throws:HIDPPError.self) { try HIDPPOnboardInfo.parse([1,3,1,1,1,8,4,UInt8(size >> 8),UInt8(size & 255),10,4]) }
        }
        #expect(throws:HIDPPError.self) { try HIDPPOnboardInfo.parse([1,3,1,1,1,8,0,1,0,10,4]) }
        #expect(throws:HIDPPError.self) { try HIDPPOnboardInfo.parse([1,3,1,1,1,8,4,1,0,10]) }
        for field in [0,1,2] {
            var raw: [UInt8]=[1,3,1,1,1,8,4,0,255,10,4]; raw[field]=99
            let info=try HIDPPOnboardInfo.parse(raw)
            #expect(!info.knownLayout); #expect(!info.knownWritableLayout)
            var bytes=[UInt8](repeating:0xA5,count:255); let crc=HIDPPCRC.ccitt(Array(bytes.dropLast(2))); bytes[253]=UInt8(crc >> 8); bytes[254]=UInt8(crc & 255)
            let sector=try HIDPPProfileSector(sector:1,bytes:bytes,info:info)
            #expect(throws:HIDPPError.self) { try sector.writePlan() }
        }
    }
    @Test func writePlanCannotAuthorizeControlOrROMAndCodecRejectsUnknownPartialLengths() throws {
        let info=try HIDPPOnboardInfo.parse([1,3,1,1,1,8,4,0,255,10,4])
        var bytes=[UInt8](repeating:0xA5,count:255); let crc=HIDPPCRC.ccitt(Array(bytes.dropLast(2))); bytes[253]=UInt8(crc >> 8); bytes[254]=UInt8(crc & 255)
        for address: UInt16 in [0,4,0x100,0x101] {
            let sector=try HIDPPProfileSector(sector:address,bytes:bytes,info:info)
            #expect(throws:HIDPPError.self) { try sector.writePlan() }
        }
        for length: UInt16 in [0,15,254,257,4097] {
            #expect(throws:HIDPPError.self) { try HIDPPRequest(deviceIndex:1,featureIndex:9,command:.startSectorWrite(sector:1,length:length),softwareID:1) }
        }
        #expect(throws:HIDPPError.self) { try HIDPPRequest(deviceIndex:1,featureIndex:9,command:.sectorWriteData([UInt8](repeating:0,count:15)),softwareID:1) }
    }
}
