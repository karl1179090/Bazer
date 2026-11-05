// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import LogitechHIDPP

private actor OfflineFeatureDevice: HIDPPTransport, HIDPPTransaction {
    let extended: Bool
    var features: [UInt16:UInt8]
    var calls: [HIDPPCommand]=[]
    var leases=0, finishes=0
    var x: UInt16=800, y: UInt16=2400, lod: UInt8=1, rate: UInt8=3
    var hostMode: UInt8=2
    var ignoreWrites=false
    var failWriteStep: Int?, writeStep=0
    var profile: [UInt8], directory: [UInt8], staging: [UInt8]=[]
    var writingSector: UInt16=0, writingLength=0
    var wireRequests: [HIDPPMessage]=[]
    let sectorSize: UInt16
    var profileFormat: UInt8=3, readbackFault=0
    init(extended: Bool = true,failWriteStep: Int? = nil,sectorSize: UInt16 = 256) {
        self.extended=extended; self.failWriteStep=failWriteStep
        self.sectorSize=sectorSize
        rate=extended ? 3 : 1
        features=[0:0,1:1,3:9,5:10,0x1004:11,extended ? 0x2202 : 0x2201:12,extended ? 0x8061 : 0x8060:13,0x8100:14]
        // Profile format 3 with nontrivial opaque button/lighting bytes.
        let size=Int(sectorSize)
        var raw=(0..<size).map { UInt8(($0*37+19) & 255) }; raw[0]=1; raw[1]=0; raw[2]=1
        for (index,dpi): (Int,UInt16) in [UInt16(400),800,1200,2400,3200].enumerated() { raw[3+index*2]=UInt8(dpi & 255); raw[4+index*2]=UInt8(dpi >> 8) }
        let crc=HIDPPCRC.ccitt(Array(raw.dropLast(2))); raw[size-2]=UInt8(crc >> 8); raw[size-1]=UInt8(crc & 255); profile=raw
        var dir=[UInt8](repeating:255,count:size); dir.replaceSubrange(0..<8,with:[0,1,1,0,255,255,0,0]); let dc=HIDPPCRC.ccitt(Array(dir.dropLast(2))); dir[size-2]=UInt8(dc >> 8); dir[size-1]=UInt8(dc & 255); directory=dir
    }
    func acquireTransaction() throws -> any HIDPPTransaction { leases+=1; return self }
    func finish() { finishes+=1 }
    func setIgnoreWrites() { ignoreWrites=true }
    func setReadbackFault(_ value: Int) { readbackFault=value }
    func setProfileFormat(_ value: UInt8) { profileFormat=value }
    func corruptProfileCRC() { profile[40] ^= 1 }
    func changeOpaqueProfile() { profile[40] ^= 1; let crc=HIDPPCRC.ccitt(Array(profile.dropLast(2))); profile[profile.count-2]=UInt8(crc >> 8); profile[profile.count-1]=UInt8(crc & 255) }
    func disableDirectoryProfile() { directory[2]=0; let crc=HIDPPCRC.ccitt(Array(directory.dropLast(2))); directory[directory.count-2]=UInt8(crc >> 8); directory[directory.count-1]=UInt8(crc & 255) }
    func setOnboardMode() { hostMode=1 }
    func compactFeatureIndices() { for (index,id) in features.keys.sorted().enumerated() { features[id]=UInt8(index) } }
    func exchange(_ request: HIDPPRequest) throws -> HIDPPMessage {
        calls.append(request.command); wireRequests.append(request.message)
        if request.command.isWrite {
            let step=writeStep; writeStep+=1
            if step == failWriteStep { throw HIDPPError.transport("Synthetic interruption at write step \(step)") }
        }
        func be(_ n: UInt16) -> [UInt8] { [UInt8(n >> 8),UInt8(n & 255)] }
        var p: [UInt8]
        switch request.command {
        case .lookupFeature(let id): p=[features[id] ?? 0,0,0]
        case .ping(let nonce): p=[4,5,nonce]
        case .featureCount: p=[UInt8(features.count-1)]
        case .featureAt(let index): guard let id=features.first(where: { $0.value == index })?.key else { throw HIDPPError.invalidValue("Synthetic sparse directory is not enumerated in this fixture") }; p=be(id)+[0,0]
        case .firmwareInfo: p=[0,1,2,3,4,0,12,0x40,0x79,0xC0,0x88,0,0]
        case .nameLength: p=[4]
        case .nameChunk: p=Array("Test".utf8)
        case .deviceKind: p=[3]
        case .battery1004Capabilities: p=[15,3]
        case .battery1004: p=[50,4,0,0]
        case .sensorCount: p=[1]
        case .sensorInfo(let sensor): p=[sensor,0,3]
        case .dpiList(let sensor,let direction,let page,let ext): p=(ext ? [sensor,direction,page] : [sensor])+[0,100,0xE0,100,0x0C,0x80,0,0]
        case .dpi(let sensor,let ext): p=[sensor]+be(x)+be(1600)+(ext ? be(y)+be(3200)+[lod] : [])
        case .setDPI(_,let newX,let newY,let newLOD,_): if !ignoreWrites { x=newX; y=newY ?? y; lod=newLOD ?? lod }; p=[]
        case .rateCapabilities(let ext): p=ext ? [0,127] : [0b10001011]
        case .rate: p=[rate]
        case .setRate(let code,_): if !ignoreWrites { rate=code }; p=[]
        case .onboardInfo: p=[1,profileFormat,1,1,1,8,4]+be(sectorSize)+[10,4]
        case .onboardMode: p=[hostMode]
        case .activeProfile: p=[0,1]
        case .readSector(let sector,let offset):
            if readbackFault == 3, writeStep == 18 { throw HIDPPError.timeout }
            let bytes=sector == 0 ? directory : profile
            guard Int(offset)+16 <= bytes.count else { throw HIDPPError.invalidValue("Synthetic firmware rejects read beyond physical sector") }
            p=Array(bytes[Int(offset)..<Int(offset)+16])
        case .startSectorWrite(let sector,let length):
            guard length == sectorSize else { throw HIDPPError.invalidValue("Synthetic start count differs from physical size") }
            writingSector=sector; writingLength=Int(length); staging=[]; p=[]
        case .sectorWriteData: staging+=request.message.parameters; p=[]
        case .endSectorWrite:
            guard staging.count == ((writingLength+15)/16)*16,
                  staging.dropFirst(writingLength).allSatisfy({ $0 == 0 }) else { throw HIDPPError.invalidValue("Synthetic firmware rejects incomplete data or nonzero final padding") }
            if !ignoreWrites { let actual=Array(staging.prefix(writingLength)); if writingSector == 0 { directory=actual } else { profile=actual } }
            if readbackFault == 1 { corruptProfileCRC() }; if readbackFault == 2 { changeOpaqueProfile() }; p=[]
        default: throw HIDPPError.invalidValue("Unsupported synthetic command")
        }
        let header=Array(request.message.bytes.prefix(4)); return try HIDPPMessage(bytes:[0x11]+header.dropFirst()+p+[UInt8](repeating:0,count:16-p.count))
    }
}

@Suite("Offline HID++ client transactions")
struct HIDPPClientTests {
    @Test(arguments: [16,31,254,255,256,257,4096]) func physicalSectorReadOverlapsTailWithoutOverrun(size: UInt16) async throws {
        let device=OfflineFeatureDevice(extended:false,sectorSize:size); let client=HIDPPClient(transport:device,deviceIndex:5)
        let profile=try await client.readProfileSector(1)
        let originalProfile=await device.profile
        #expect(profile.bytes == originalProfile)
        #expect(profile.bytes.count == Int(size))
        let directory=try await client.readProfileSector(0)
        let originalDirectory=await device.directory
        #expect(directory.bytes == originalDirectory)
        #expect(try HIDPPProfileDirectoryEntry.parse(directory).map(\.sector) == [1])
        let calls=await device.calls
        let offsets=calls.compactMap { command -> UInt16? in if case .readSector(1,let offset)=command { return offset }; return nil }
        #expect(offsets.last == size-16)
        #expect(offsets.allSatisfy { Int($0)+16 <= Int(size) })
        if size == 255 { #expect(offsets == Array(stride(from:0,through:224,by:16)).map(UInt16.init)+[239]) }
        if size == 256 { #expect(offsets == Array(stride(from:0,through:240,by:16)).map(UInt16.init)) }
        #expect(calls.allSatisfy { !$0.isWrite })
        #expect(await device.leases == device.finishes)
    }
    @Test func physical255ByteProfileWritesExactTailAndRestoresOriginal() async throws {
        let device=OfflineFeatureDevice(extended:false,sectorSize:255); let client=HIDPPClient(transport:device,deviceIndex:5)
        let profile=try await client.readProfileSector(1)
        let updated=try await client.patchProfileSector(1,expected:profile,dpi:[2:1600],reportRateCode:2,defaultDPIIndex:1)
        #expect(updated.bytes.count == 255); #expect(updated.dpiValues?[2] == 1600)
        for index in profile.bytes.indices where ![0,1,7,8,253,254].contains(index) { #expect(updated.bytes[index] == profile.bytes[index]) }
        let wire=await device.wireRequests.filter { [0x60,0x70,0x80].contains($0.address & 0xF0) }
        #expect(wire.count == 18)
        #expect(wire[0].parameters.prefix(6) == [0,1,0,0,0,255])
        let data=wire.filter { $0.address & 0xF0 == 0x70 }
        #expect(data.count == 16); #expect(data.allSatisfy { $0.bytes.count == 20 && $0.parameters.count == 16 })
        let transmitted=data.flatMap(\.parameters)
        #expect(Array(transmitted.prefix(255)) == updated.bytes)
        #expect(transmitted.count == 256); #expect(transmitted[255] == 0)
        #expect(data.last?.parameters == Array(updated.bytes[240..<255])+[0])
        #expect(HIDPPCRC.ccitt(Array(updated.bytes.prefix(253))) == UInt16(updated.bytes[253]) << 8 | UInt16(updated.bytes[254]))
        let restored=try await client.patchProfileSector(1,expected:updated,dpi:[2:1200],reportRateCode:profile.bytes[0],defaultDPIIndex:profile.bytes[1])
        #expect(restored.bytes == profile.bytes)
        #expect(await device.leases == device.finishes)
    }
    @Test func featureDirectoryUsesRuntimeIndicesAndVersions() async throws {
        let device=OfflineFeatureDevice(); await device.compactFeatureIndices(); let client=HIDPPClient(transport:device,deviceIndex:6)
        let features=try await client.discoverFeatures()
        #expect(features.count == 8); #expect(features.first?.id == 0); #expect(features.first?.index == 0)
        #expect(features.first(where:{ $0.id == 0x1004 })?.index == 4)
        #expect(try await client.readBattery().level == .percentage(50)); #expect(await device.calls.allSatisfy { !$0.isWrite })
    }
    @Test func identitySeparatesWirelessAndUSBAndReadsNativePercentage() async throws {
        let device=OfflineFeatureDevice(); let client=HIDPPClient(transport:device,deviceIndex:4)
        #expect(try await client.ping(nonce:99) == "4.5")
        let identity=try await client.readIdentity()
        #expect(identity.transportIDs["wireless"] == 0x4079); #expect(identity.transportIDs["usb"] == 0xC088); #expect(identity.unitID == [1,2,3,4])
        #expect(try await client.readBattery().level == .percentage(50))
        #expect(await device.calls.allSatisfy { !$0.isWrite })
        #expect(await device.leases == device.finishes)
    }
    @Test func extendedWritePreservesUneditedLODAndReadsBackBothAxes() async throws {
        let device=OfflineFeatureDevice(); let client=HIDPPClient(transport:device,deviceIndex:3)
        let (_,before)=try await client.readDPI(); #expect(before.currentX == 800); #expect(before.defaultX == 1600); #expect(before.currentY == 2400); #expect(before.defaultY == 3200)
        let after=try await client.setDPI(x:1000,y:1500)
        #expect(after.effectiveX == 1000); #expect(after.effectiveY == 1500); #expect(after.lod == 1)
        #expect(await device.leases == 2); #expect(await device.finishes == 2)
    }
    @Test func rejectsUnsupportedXYAnd8KBeforeWriting() async throws {
        let device=OfflineFeatureDevice(extended:false); let client=HIDPPClient(transport:device,deviceIndex:2)
        do { _=try await client.setDPI(x:800,y:1200); Issue.record("Standard DPI accepted unequal X/Y") } catch HIDPPError.invalidValue {} catch { Issue.record("Unexpected \(error)") }
        do { _=try await client.setReportRate(hertz:8000); Issue.record("Standard rate accepted 8K") } catch HIDPPError.invalidValue {} catch { Issue.record("Unexpected \(error)") }
        #expect(await device.calls.allSatisfy { !$0.isWrite })
    }
    @Test func onboardModeIsNotSilentlyChangedAndAckIsNotSuccess() async throws {
        let onboard=OfflineFeatureDevice(); await onboard.setOnboardMode(); let client=HIDPPClient(transport:onboard,deviceIndex:1)
        do { _=try await client.setDPI(x:800); Issue.record("Onboard mode allowed runtime mutation") } catch HIDPPError.invalidValue {} catch { Issue.record("Unexpected \(error)") }
        #expect(await onboard.calls.allSatisfy { !$0.isWrite })
        let device=OfflineFeatureDevice(); await device.setIgnoreWrites(); let other=HIDPPClient(transport:device,deviceIndex:1)
        do { _=try await other.setDPI(x:1000,y:1500); Issue.record("ACK without readback became success") } catch HIDPPError.readbackMismatch {} catch { Issue.record("Unexpected \(error)") }
    }
    @Test func profilePatchRetainsCompleteOpaqueSectorAndSingleLease() async throws {
        let device=OfflineFeatureDevice(extended:false); let client=HIDPPClient(transport:device,deviceIndex:5)
        let original=try await client.readProfileSector(1)
        let updated=try await client.patchProfileSector(1,expected:original,dpi:[2:1600],reportRateCode:2)
        #expect(updated.dpiValues?[2] == 1600); #expect(updated.bytes[0] == 2)
        for index in 0..<254 where ![0,7,8].contains(index) { #expect(updated.bytes[index] == original.bytes[index]) }
        #expect(await device.leases == 2); #expect(await device.finishes == 2)
    }
    @Test(arguments:[UInt16(255),256],Array(0..<18)) func everyWriteInterruptionStopsWithoutRetry(size: UInt16,step: Int) async throws {
        let device=OfflineFeatureDevice(extended:false,failWriteStep:step,sectorSize:size); let client=HIDPPClient(transport:device,deviceIndex:2)
        let original=try await client.readProfileSector(1)
        do { _=try await client.patchProfileSector(1,expected:original,dpi:[0:800]); Issue.record("Interrupted write succeeded") }
        catch HIDPPError.interruptedWrite(let chunks,let stage,_) {
            #expect(chunks == min(16,max(0,step-1))); #expect(stage == (step == 0 ? "start" : (step == 17 ? "end" : "data")))
        } catch { Issue.record("Unexpected interruption error: \(error)") }
        #expect(await device.writeStep == step+1); #expect(await device.leases == device.finishes)
    }
    @Test(arguments:Array(0..<4)) func physical255ReadbackFailureIsUnknownAndNeverRetried(fault: Int) async throws {
        let device=OfflineFeatureDevice(extended:false,sectorSize:255); let client=HIDPPClient(transport:device,deviceIndex:2)
        let original=try await client.readProfileSector(1)
        if fault == 0 { await device.setIgnoreWrites() } else { await device.setReadbackFault(fault) }
        do { _=try await client.patchProfileSector(1,expected:original,dpi:[0:800]); Issue.record("Readback failure became a verified write") }
        catch HIDPPError.interruptedWrite(let chunks,let stage,_) { #expect(chunks == 16); #expect(stage == "readback") }
        catch { Issue.record("Unexpected failure: \(error)") }
        #expect(await device.writeStep == 18)
        #expect(await device.leases == device.finishes)
    }
    @Test(arguments:Array(0..<6)) func physical255UnsafeInputsNeverSendSettingFrames(fault: Int) async throws {
        let device=OfflineFeatureDevice(extended:false,sectorSize:255); let client=HIDPPClient(transport:device,deviceIndex:2)
        if fault == 3 { await device.setProfileFormat(99) }
        let sector: UInt16=fault == 4 ? 0x101 : (fault == 5 ? 0 : 1)
        let original=try await client.readProfileSector(sector)
        switch fault {
        case 0: await device.corruptProfileCRC()
        case 1: await device.changeOpaqueProfile()
        case 2: await device.disableDirectoryProfile()
        default: break
        }
        do { _=try await client.patchProfileSector(sector,expected:original,dpi:[0:800]); Issue.record("Unsafe profile input produced a write") } catch {}
        #expect(await device.calls.allSatisfy { !$0.isWrite })
    }
}
