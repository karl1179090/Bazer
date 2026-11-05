// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
@testable import BazerDrivers
import Foundation
import LogitechHIDPP
import Testing

@Suite("Built-in Logitech evidence matching — pure values only")
struct LogitechVerifiedHardwareProfileTests {
    private func info(memory: UInt8 = 1,format: UInt8 = 3,macro: UInt8 = 1,size: UInt16 = 255) throws -> HIDPPOnboardInfo {
        try HIDPPOnboardInfo.parse([memory,format,macro,5,1,8,16,UInt8(size >> 8),UInt8(size & 255),10,4]+[UInt8](repeating:0,count:5))
    }
    private func sector(_ id: UInt16,bytes: [UInt8],info: HIDPPOnboardInfo) throws -> HIDPPProfileSector {
        var copy=bytes; let crc=HIDPPCRC.ccitt(Array(copy.dropLast(2)))
        copy[copy.count-2]=UInt8(crc >> 8); copy[copy.count-1]=UInt8(crc & 255)
        return try HIDPPProfileSector(sector:id,bytes:copy,info:info)
    }
    private func observation(size: UInt16 = 255) throws -> LogitechHardwareObservation {
        let info=try info(size:size)
        var profile=[UInt8](repeating:0xA7,count:Int(size)); profile[0]=1; profile[1]=1
        for (index,value) in [UInt16(400),800,1600,3200,6400].enumerated() {
            profile[3+index*2]=UInt8(value & 255); profile[4+index*2]=UInt8(value >> 8)
        }
        var directory=[UInt8](repeating:255,count:Int(size)); directory.replaceSubrange(0..<8,with:[0,1,1,0,255,255,0,0])
        let tuples: [(UInt16,UInt8,UInt8)]=[
            (0,0,1),(1,0,1),(3,0,2),(5,0,0),(0x1D4B,0,0),(0x0020,0,0),(0x1001,0,2),
            (0x8070,0,4),(0x1300,0,0),(0x8100,0,0),(0x8110,0,0),(0x8060,0,0),(0x2201,0,1),
            (0x1802,0x60,0),(0x1803,0x60,0),(0x1805,0x60,0),(0x1806,0x60,4),(0x1811,0x60,0),
            (0x1830,0x60,0),(0x1890,0x60,2),(0x1891,0x60,2),(0x18A1,0x60,0),(0x1801,0x60,0),
            (0x18B1,0x60,0),(0x1DF3,0x60,0),(0x1E00,0x40,0),(0x1EB0,0x60,0),(0x1863,0x60,0),(0x1E22,0x60,0)
        ]
        return LogitechHardwareObservation(hostVendorID:0x046D,hostProductID:0xC539,
            controlDescriptorSHA256:LogitechVerifiedHardwareProfile.expectedDescriptorSHA256,
            peripheralVendorID:0x046D,wirelessProductID:0x4079,protocolVersion:"4.2",
            firmwareSHA256:LogitechVerifiedHardwareProfile.expectedFirmwareSHA256,isReceiver:true,identityIsReliable:true,
            features:tuples.enumerated().map { HIDPPFeature(id:$0.element.0,index:UInt8($0.offset),flags:$0.element.1,version:$0.element.2) },
            dpiValues:Array(stride(from:UInt16(100),through:25600,by:50)),supportsIndependentXY:false,currentDPI:DPISetting(1600),
            rateValues:[125,250,500,1000],currentRate:try HIDPPReportRate(code:1,extended:false),
            onboardInfo:info,onboardMode:1,directory:try sector(0,bytes:directory,info:info),
            profile:try sector(1,bytes:profile,info:info),currentStageID:2)
    }
    private func capabilities() -> DeviceCapabilities {
        let dpi=CapabilityConstraints(allowedValues:Array(stride(from:100,through:25600,by:50)),persistenceScopes:[.runtime])
        return DeviceCapabilities(operations:[
            .dpiRead:OperationCapability(evidence:.discovered,constraints:dpi),
            .dpiWrite:OperationCapability(evidence:.discovered,constraints:dpi),
            .pollingRateRead:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(allowedValues:[125,250,500,1000],persistenceScopes:[.runtime])),
            .pollingRateWrite:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(allowedValues:[125,250,500,1000],persistenceScopes:[.runtime])),
            .stageSelect:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(allowedValues:[0,1,2,3,4],persistenceScopes:[.runtime])),
            .stagesWrite:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(allowedValues:Array(stride(from:100,through:25600,by:50)),maximumStages:5,persistenceScopes:[.onboard])),
            .onboardWrite:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(allowedValues:[1,2,3],persistenceScopes:[.runtime])),
            .onboardPersist:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(persistenceScopes:[.onboard]))
        ])
    }
    private func observation(rawInfo: [UInt8]) throws -> LogitechHardwareObservation {
        let decoded=try HIDPPOnboardInfo.parse(rawInfo)
        var value=try observation(size:decoded.sectorSize)
        value.onboardInfo=decoded
        value.directory=try sector(0,bytes:value.directory.bytes,info:decoded)
        value.profile=try sector(1,bytes:value.profile.bytes,info:decoded)
        return value
    }
    @Test(arguments:Array(0..<16)) func everyCapturedOnboardInfoByteMustMatchBeforeOrdinaryPromotion(offset: Int) throws {
        var raw=try info().rawBytes; raw[offset] ^= 1
        let value=try observation(rawInfo:raw)
        let matches=LogitechVerifiedHardwareProfile.matches(value)
        let unchanged=LogitechVerifiedHardwareProfile.promoting(capabilities(),observation:value) == capabilities()
        #expect(!matches); #expect(unchanged)
    }
    @Test(arguments:[11,12,13,14,15,17,20]) func nonExactOnboardInfoLengthCannotPromote(length: Int) throws {
        let original=try info().rawBytes
        let raw=length < original.count ? Array(original.prefix(length)) : original+[UInt8](repeating:0,count:length-original.count)
        let value=try observation(rawInfo:raw)
        let matches=LogitechVerifiedHardwareProfile.matches(value)
        let unchanged=LogitechVerifiedHardwareProfile.promoting(capabilities(),observation:value) == capabilities()
        #expect(!matches); #expect(unchanged)
    }
    @Test(arguments:[0,1,10]) func truncatedInfoCannotBecomeTypedObservationInput(length: Int) throws {
        let raw=Array(try info().rawBytes.prefix(length))
        #expect(throws:HIDPPError.self) { try observation(rawInfo:raw) }
    }
    @Test func exactMetadataOnlyPromotesReviewedOperationsAndTheirSpecificScopes() throws {
        let observation=try observation(), capabilities=capabilities()
        #expect(LogitechVerifiedHardwareProfile.matches(observation))
        let promoted=LogitechVerifiedHardwareProfile.promoting(capabilities,observation:observation)
        let permitted: Set<DeviceOperation>=[.stageSelect,.stagesWrite,.pollingRateWrite,.onboardPersist]
        for operation in DeviceOperation.allCases where operation.isWrite { #expect(promoted.permits(operation) == permitted.contains(operation)) }
        #expect(promoted[.stageSelect].evidence == .writeVerified)
        #expect(promoted[.stageSelect].constraints.persistenceScopes == [.runtime])
        #expect(promoted[.stageSelect].constraints.allowedValues == [0,1,2,3,4])
        #expect(promoted[.stagesWrite].evidence == .writeVerified)
        #expect(promoted[.stagesWrite].constraints.persistenceScopes == [.onboard])
        #expect(promoted[.stagesWrite].constraints.allowedValues == observation.dpiValues.map(Int.init))
        #expect(promoted[.pollingRateWrite].evidence == .writeVerified)
        #expect(promoted[.pollingRateWrite].constraints.persistenceScopes == [.onboard])
        #expect(promoted[.onboardPersist].evidence == .persistenceVerified)
        #expect(!DeviceSettingsChange(pollingRateHz:500,persistence:.runtime).validate(capabilities:promoted).isEmpty)
        #expect(observation.currentStageID != observation.profile.bytes[1],"Current selection and stored default are separate observations")
    }
    @Test func firmwareFingerprintHashesExactCompleteUTF8WithoutNormalization() {
        #expect(LogitechVerifiedHardwareProfile.firmwareEncoding == "hidpp-identity-firmware-utf8-v1")
        #expect(LogitechVerifiedHardwareProfile.firmwareSHA256(nil) == nil)
        #expect(LogitechVerifiedHardwareProfile.firmwareSHA256("") == nil)
        #expect(LogitechVerifiedHardwareProfile.firmwareSHA256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(LogitechVerifiedHardwareProfile.firmwareSHA256("0:ABC;1:DEF") != LogitechVerifiedHardwareProfile.firmwareSHA256("0:abc;1:def"))
        #expect(LogitechVerifiedHardwareProfile.firmwareSHA256("0:ABC;1:DEF") != LogitechVerifiedHardwareProfile.firmwareSHA256("0:ABC"))
    }
    @Test func featureIndicesAndDirectoryOrderRemainDynamic() throws {
        var observation=try observation()
        observation.features=observation.features.reversed().enumerated().map { HIDPPFeature(id:$0.element.id,index:$0.element.id == 0 ? 0 : UInt8($0.offset+40),flags:$0.element.flags,version:$0.element.version) }
        #expect(LogitechVerifiedHardwareProfile.matches(observation))
    }
    @Test(arguments:Array(0..<33)) func everyUnprovenMatchDimensionFailsClosed(change: Int) throws {
        var value=try observation()
        switch change {
        case 0: value.hostVendorID=0x1532
        case 1: value.hostProductID=0xC537
        case 2: value.controlDescriptorSHA256=String(repeating:"0",count:64)
        case 3: value.peripheralVendorID=0
        case 4: value.wirelessProductID=0x4093
        case 5: value.protocolVersion="4.3"
        case 6: value.firmwareSHA256=String(repeating:"0",count:64)
        case 7: value.firmwareSHA256=nil
        case 8: value.isReceiver=false
        case 9: value.identityIsReliable=false
        case 10: value.features.removeLast()
        case 11:
            let f=value.features[6]; value.features[6]=HIDPPFeature(id:f.id,index:f.index,flags:f.flags,version:f.version+1)
        case 12:
            let f=value.features[6]; value.features[6]=HIDPPFeature(id:f.id,index:f.index,flags:1,version:f.version)
        case 13: value.features.append(HIDPPFeature(id:0x8061,index:40,flags:0,version:0))
        case 14: value.dpiValues.removeFirst()
        case 15: value.supportsIndependentXY=true
        case 16: value.rateValues.append(2000)
        case 17: value.currentRate=try HIDPPReportRate(code:3,extended:true)
        case 18: value.onboardMode=2
        case 19: value.onboardInfo=try info(memory:2)
        case 20: value.onboardInfo=try info(format:4)
        case 21: value.onboardInfo=try info(macro:2)
        case 22: value=try observation(size:256)
        case 23: value.currentStageID=5
        case 24:
            var bytes=value.profile.bytes; bytes[1]=5; value.profile=try sector(1,bytes:bytes,info:value.onboardInfo)
        case 25: value.currentDPI=DPISetting(800)
        case 26:
            var bytes=value.profile.bytes; bytes[0]=2; value.profile=try sector(1,bytes:bytes,info:value.onboardInfo)
        case 27:
            var bytes=value.directory.bytes; bytes[2]=0; value.directory=try sector(0,bytes:bytes,info:value.onboardInfo)
        case 28: value.directory=try sector(1,bytes:value.directory.bytes,info:value.onboardInfo)
        case 29: value.profile=try sector(0x101,bytes:value.profile.bytes,info:value.onboardInfo)
        case 30: value.directory=try observation(size:256).directory
        case 31:
            var bytes=value.profile.bytes; bytes[3]=0x91; bytes[4]=1; value.profile=try sector(1,bytes:bytes,info:value.onboardInfo)
        default: value.features[value.features.count-1]=value.features[0]
        }
        #expect(!LogitechVerifiedHardwareProfile.matches(value))
        #expect(LogitechVerifiedHardwareProfile.promoting(capabilities(),observation:value) == capabilities())
    }
    @Test func corruptOrIncompleteImagesCannotBecomeTypedObservationInputs() throws {
        let observation=try observation()
        var corrupt=observation.profile.bytes; corrupt[20] ^= 1
        #expect(throws:HIDPPError.self) { try HIDPPProfileSector(sector:1,bytes:corrupt,info:observation.onboardInfo) }
        #expect(throws:HIDPPError.self) { try HIDPPProfileSector(sector:1,bytes:Array(observation.profile.bytes.dropLast()),info:observation.onboardInfo) }
    }
}
