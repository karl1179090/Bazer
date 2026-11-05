// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
@testable import BazerHID
import Foundation
import LogitechHIDPP
import Testing
@testable import HIDProbe

private func recordedHexBytes(_ text: String) -> [UInt8] {
    var iterator=text.makeIterator(), result: [UInt8]=[]
    while let high=iterator.next(), let low=iterator.next() { result.append(UInt8(String([high,low]),radix:16)!) }
    return result
}

private final class RateOnlyAuthorizer: @unchecked Sendable {
    private let lock=NSLock()
    private var authorize: (@Sendable (HIDPPRequest) throws -> Void)?
    func install(_ value: @escaping @Sendable (HIDPPRequest) throws -> Void) { lock.withLock { authorize=value } }
    func check(_ request: HIDPPRequest) throws { try lock.withLock { try authorize?(request) } }
}

/// The production CLI, controller, driver, codec and typed policy run unchanged;
/// only value packets and discovery are supplied by this in-memory receiver.
private actor RateOnlyReceiver: LogitechSessionTransport, HIDPPTransaction {
    enum Fault: CaseIterable, Sendable {
        case none, profileRead, hostMode, unknownLayout, corruptAfterWrite, disabledProfile
        case lateObservedDrift, lateProfileSwitch, lateReadFailure, lateCRCFailure, unknownFirmware, unknownOnboardInfo
    }
    nonisolated let authorizer=RateOnlyAuthorizer()
    private let stream=AsyncStream<HIDPPMessage>.makeStream()
    private let ids: [UInt16]
    private let fault: Fault
    private let verifiedConfiguration: Bool
    private static let verifiedFeatures: [(UInt16,UInt8,UInt8)]=[
        (0,0,1),(1,0,1),(3,0,2),(5,0,0),(0x1D4B,0,0),(0x0020,0,0),(0x1001,0,2),
        (0x8070,0,4),(0x1300,0,0),(0x8100,0,0),(0x8110,0,0),(0x8060,0,0),(0x2201,0,1),
        (0x1802,0x60,0),(0x1803,0x60,0),(0x1805,0x60,0),(0x1806,0x60,4),(0x1811,0x60,0),
        (0x1830,0x60,0),(0x1890,0x60,2),(0x1891,0x60,2),(0x18A1,0x60,0),(0x1801,0x60,0),
        (0x18B1,0x60,0),(0x1DF3,0x60,0),(0x1E00,0x40,0),(0x1EB0,0x60,0),(0x1863,0x60,0),(0x1E22,0x60,0)
    ]
    private(set) var commands: [HIDPPCommand]=[]
    private(set) var profile: [UInt8]
    private(set) var directory: [UInt8]
    private var staged: [UInt8]=[]
    private var writingLength=0
    private var completedWrites=0, profileReadsAfterWrite=0
    private var liveInfo: [UInt8]=[1,3,1,5,1,8,16,0,255,10,4,0,0,0,0,0]
    private var infoReads=0, mutateAtInfoRead: Int?
    private var activeDPI: UInt8=2
    private(set) var closes=0
    init(fault: Fault = .none, verifiedConfiguration: Bool = false) {
        self.fault=fault; self.verifiedConfiguration=verifiedConfiguration
        // Reorder non-root features to exercise actual dynamic index resolution.
        ids=verifiedConfiguration ? [0,1]+Self.verifiedFeatures.dropFirst(2).reversed().map { $0.0 } : [0,1,3,5,0x2201,0x8060,0x8100]
        var p=[UInt8](repeating:0xA7,count:255)
        p[0]=1; p[1]=1; p[2]=0
        for (index,dpi) in [UInt16(400),800,1600,3200,6400].enumerated() {
            p[3+index*2]=UInt8(dpi & 255); p[4+index*2]=UInt8(dpi >> 8)
        }
        profile=Self.withCRC(p)
        var d=[UInt8](repeating:255,count:255)
        d.replaceSubrange(0..<8,with:[0,1,fault == .disabledProfile ? 0 : 1,0,255,255,0,0])
        directory=Self.withCRC(d)
    }
    private static func withCRC(_ source: [UInt8]) -> [UInt8] {
        var bytes=source; let crc=HIDPPCRC.ccitt(Array(bytes.dropLast(2)))
        bytes[bytes.count-2]=UInt8(crc >> 8); bytes[bytes.count-1]=UInt8(crc & 255); return bytes
    }
    func notifications() -> AsyncStream<HIDPPMessage> { stream.stream }
    func acquireTransaction() -> any HIDPPTransaction { self }
    func finish() {}
    func close() { closes+=1; stream.continuation.finish() }
    func changeOnboardInfo() { liveInfo[3] ^= 1 }
    func changeInfoOnRead(_ ordinal: Int) { infoReads=0; mutateAtInfoRead=ordinal }
    func exchange(_ request: HIDPPRequest) throws -> HIDPPMessage {
        try authorizer.check(request); commands.append(request.command)
        func be(_ number: UInt16) -> [UInt8] { [UInt8(number >> 8),UInt8(number & 255)] }
        let payload: [UInt8]
        switch request.command {
        case .receiverInformation: payload=[3,1,2,3,4,0,1]
        case .pairing: payload=verifiedConfiguration ? [0x20,0,0,0x40,0x79,0,0,2] : [0x20,0,0,0xAA,0xBB,0,0,2]
        case .ping(let nonce): payload=[4,2,nonce]
        case .lookupFeature(let id):
            let metadata=verifiedConfiguration ? Self.verifiedFeatures.first(where:{ $0.0 == id }) : nil
            payload=[ids.firstIndex(of:id).map(UInt8.init) ?? 0,metadata?.1 ?? 0,metadata?.2 ?? 0]
        case .featureCount: payload=[UInt8(ids.count-1)]
        case .featureAt(let index):
            let id=ids[Int(index)], metadata=verifiedConfiguration ? Self.verifiedFeatures.first(where:{ $0.0 == id }) : nil
            payload=be(id)+[metadata?.1 ?? 0,metadata?.2 ?? 0]
        case .firmwareInfo: payload=verifiedConfiguration ? [3,1,2,3,4,0,4,0x40,0x79,0,0,0,0] : [1,1,2,3,4,0,12,0xAA,0xBB,0x12,0x34,0,0]
        case .firmwareEntity(let index):
            if verifiedConfiguration {
                // Public firmware records, not private profile or raw unit bytes.
                let entities=["01424F547402002600AADF85EE714A00","004D504D1502002601407985EE714A00","05000000000000A90000000000000000"]
                var bytes=recordedHexBytes(entities[Int(index)])
                if fault == .unknownFirmware, index == 0 { bytes[5] ^= 1 }
                payload=bytes
            } else { payload=[0,70,87,82,1,2,0,3,0] }
        case .nameLength: payload=[19]
        case .nameChunk(let offset): payload=Array("Synthetic Rate Only".utf8.dropFirst(Int(offset)).prefix(16))
        case .deviceKind: payload=[3]
        case .sensorCount: payload=[1]
        case .dpiList: payload=verifiedConfiguration ? [0]+be(100)+be(0xE032)+be(25600)+[0,0] : [0]+be(400)+be(800)+be(1600)+be(3200)+be(6400)+[0,0]
        case .dpi: payload=[0]+be(UInt16(profile[3+Int(activeDPI)*2]) | UInt16(profile[4+Int(activeDPI)*2]) << 8)+be(800)
        case .rateCapabilities: payload=[0b10001011]
        case .rate: payload=[profile[0]]
        case .onboardInfo:
            if verifiedConfiguration {
                infoReads+=1
                if infoReads == mutateAtInfoRead { liveInfo[3] ^= 1 }
                var info=liveInfo
                if fault == .unknownLayout { info[0]=2 }
                if fault == .unknownOnboardInfo { info[3]=4 }
                payload=info
            } else { payload=[fault == .unknownLayout ? 2 : 1,3,1,1,1,8,4]+be(255)+[10,4] }
        case .onboardMode: payload=[fault == .hostMode ? 2 : 1]
        case .activeProfile: payload=be(fault == .lateProfileSwitch && completedWrites > 0 && profileReadsAfterWrite > 0 ? 2 : 1)
        case .activeDPIIndex: payload=[activeDPI]
        case .setActiveDPIIndex(let index): activeDPI=index; payload=[]
        case .readSector(let sector,let offset):
            if fault == .profileRead, sector == 1 { throw HIDPPError.invalidValue("Synthetic profile read failed") }
            if sector > 0, offset == 0, completedWrites > 0 {
                profileReadsAfterWrite+=1
                if profileReadsAfterWrite == 2 {
                    switch fault {
                    case .lateObservedDrift: profile[40] ^= 1; profile=Self.withCRC(profile)
                    case .lateReadFailure: throw HIDPPError.invalidValue("Synthetic final profile read failed once")
                    case .lateCRCFailure: profile[40] ^= 1
                    default: break
                    }
                }
            }
            let bytes=sector == 0 ? directory : profile
            guard Int(offset)+16 <= bytes.count else { throw HIDPPError.invalidValue("Read exceeds physical sector") }
            payload=Array(bytes[Int(offset)..<Int(offset)+16])
        case .startSectorWrite(let sector,let length):
            guard sector == 1, length == 255 else { throw HIDPPError.invalidValue("Unexpected profile write geometry") }
            staged=[]; writingLength=Int(length); payload=[]
        case .sectorWriteData(let bytes): staged+=bytes; payload=[]
        case .endSectorWrite:
            guard staged.count == 256, writingLength == 255, staged[255] == 0 else { throw HIDPPError.invalidValue("Unexpected final padding") }
            profile=Array(staged.prefix(writingLength))
            if fault == .corruptAfterWrite { profile[20] ^= 1; profile=Self.withCRC(profile) }
            completedWrites+=1; profileReadsAfterWrite=0
            payload=[]
        default: throw HIDPPError.invalidValue("Unexpected command in rate-only fixture")
        }
        return try HIDPPMessage(bytes:[0x11]+request.message.bytes[1..<4]+payload+[UInt8](repeating:0,count:16-payload.count),receivedAt:Date())
    }
}

private struct RateOnlyPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}

private final class RateOnlyDiscovery: HIDDiscoveryBackend, @unchecked Sendable {
    private let verifiedConfiguration: Bool
    init(verifiedConfiguration: Bool = false) { self.verifiedConfiguration=verifiedConfiguration }
    static var descriptor: HIDInterfaceDescriptor {
        let bytes: [UInt8]=[0x06,0,0xFF,9,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0]
        return HIDInterfaceDescriptor(registryEntryID:101,usbParentRegistryEntryID:10,vendorID:0x046D,productID:0xDEAD,
            product:"Synthetic rate-only receiver",transport:"USB",maxInputReportSize:20,maxOutputReportSize:20,reportDescriptor:bytes)
    }
    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) {}
    static var verifiedDescriptor: HIDInterfaceDescriptor {
        // Public report descriptor from 01-passive-list.json; no peripheral input.
        let bytes=recordedHexBytes("0600ff0901a101851075089506150026ff000901810009019100c00600ff0902a101851175089513150026ff000902810009029100c00600ff0904a10185207508950e150026ff0009418100094191008521951f150026ff000942810009429100c0")
        return HIDInterfaceDescriptor(registryEntryID:101,usbParentRegistryEntryID:10,vendorID:0x046D,productID:0xC539,
            product:"Synthetic verified receiver",transport:"USB",maxInputReportSize:32,maxOutputReportSize:32,reportDescriptor:bytes)
    }
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt:Date(),interfaces:[verifiedConfiguration ? Self.verifiedDescriptor : Self.descriptor]) }
    func inspectInterface(registryEntryID: UInt64) -> HIDInspectionResult { HIDInspectionResult(registryEntryID:registryEntryID,operations:[]) }
    func stop() {}
}

@Suite("Logitech rate-only CLI pipeline — synthetic packets only", .serialized)
struct LogitechRateOnlyExecutionTests {
    private func run(_ receiver: RateOnlyReceiver, backup: URL, ordinary: Bool = false) async throws {
        let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in receiver.authorizer.install(authorize); return receiver })
        let registry=DriverRegistry(registrations:[DeviceDriverRegistration(id:"offline.rate-only",identify:LogitechReceiverDriver.identify,logicalDriver:driver,settingsAdapter:driver)])
        let discovery=HIDDiscovery(backendFactory:{ RateOnlyDiscovery(verifiedConfiguration:ordinary) },processLockFactory:{ _ in nil })
        var arguments=["settings","apply","--device","usb-parent:10/receiver-slot:1","--rate","500","--scope","onboard","--backup-output",backup.path,"--restore-original"]
        if !ordinary { arguments += ["--validation-operation","logitechHIDPP8100Profile"] }
        let options=try ExpansionProbeOptions.parse(arguments)
        #expect(options.dpiStages == nil); #expect(options.defaultStage == nil)
        #expect(try await ExpansionProbe.run(options,discovery:discovery,registry:registry))
    }
    @Test func ordinaryCLIUsesReviewedLiveProfileWithoutCandidateFlagsAndUnknownFirmwareDoesNotInheritIt() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-ordinary-cli-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let receiver=RateOnlyReceiver(verifiedConfiguration:true), original=await receiver.profile
        try await run(receiver,backup:folder.appendingPathComponent("before.json"),ordinary:true)
        #expect(await receiver.profile == original)
        #expect(await receiver.commands.filter(\.isWrite).count == 36)
        let unknown=RateOnlyReceiver(fault:.unknownFirmware,verifiedConfiguration:true)
        var rejected=false
        do { try await run(unknown,backup:folder.appendingPathComponent("unknown-before.json"),ordinary:true) }
        catch { rejected=true }
        #expect(rejected); #expect(await unknown.commands.allSatisfy { !$0.isWrite })
        #expect(throws:ProbeCLIError.self) {
            try ExpansionProbeOptions.parse(["settings","apply","--device","usb-parent:10/receiver-slot:1","--rate","500","--scope","onboard"])
        }
    }
    @Test func ordinaryCLIDoesNotPromoteChangedFullOnboardMetadataOrSendSettingsWrites() async throws {
        let receiver=RateOnlyReceiver(fault:.unknownOnboardInfo,verifiedConfiguration:true)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-ordinary-info-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        var rejected=false
        do { try await run(receiver,backup:folder.appendingPathComponent("before.json"),ordinary:true) }
        catch { rejected=true }
        #expect(rejected); #expect(await receiver.commands.allSatisfy { !$0.isWrite })
    }
    @Test func ordinaryControllerRequiresCurrentBackupPreparationAndRestoresTableDefaultAndRate() async throws {
        let receiver=RateOnlyReceiver(verifiedConfiguration:true), original=await receiver.profile
        let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in receiver.authorizer.install(authorize); return receiver })
        let registry=DriverRegistry(registrations:[DeviceDriverRegistration(id:"offline.ordinary-controller",identify:LogitechReceiverDriver.identify,logicalDriver:driver,settingsAdapter:driver)])
        let discovery=HIDDiscovery(backendFactory:{ RateOnlyDiscovery(verifiedConfiguration:true) },processLockFactory:{ _ in nil })
        let monitor=BatteryMonitor(discovery:discovery,reader:registry,preferences:RateOnlyPreferences(),registry:registry,automaticallyRefreshTelemetry:false)
        await monitor.start(); let initial=await monitor.initialDiscoveryReady()
        let target=try #require(initial.logicalDevices.first), controller=DeviceController(monitor:monitor,registry:registry)
        #expect(target.capabilities[.onboardPersist].evidence == .persistenceVerified)
        #expect(target.capabilities[.pollingRateWrite].constraints.persistenceScopes == [.onboard])
        #expect(!target.capabilities.permits(.dpiWrite)); #expect(!target.capabilities.permits(.independentXY)); #expect(!target.capabilities.permits(.onboardWrite))
        #expect(await receiver.commands.allSatisfy { !$0.isWrite },"Discovery must never replay a setting")
        let before=try await controller.readSettings(logicalDeviceID:target.id), table=try #require(before.settings.stages)
        let edited=DPIStageTable(stages:table.stages,activeStageID:table.activeStageID,opaqueBytes:table.opaqueBytes,defaultStageID:2)
        let request=SettingChangeRequest(target:before.session,expectedRevision:before.revision,change:DeviceSettingsChange(pollingRateHz:500,stages:edited,persistence:.onboard))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-ordinary-controller-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let backup=folder.appendingPathComponent("before.json")
        let prepared=try await controller.prepareOnboardChange(request,saveBackupTo:backup)
        #expect(FileManager.default.fileExists(atPath:backup.path))
        #expect(await receiver.commands.allSatisfy { !$0.isWrite },"Saving a recovery image must not apply its draft")
        let result=await controller.apply(prepared)
        #expect(result.status == .verified); #expect(result.observed?.settings.pollingRateHz == 500)
        #expect(result.observed?.settings.stages?.defaultStageID == 2); #expect(result.observed?.settings.currentStageID == 2)
        let restore=try await controller.prepareProfileRestore(backupURL:backup,rollbackBackupURL:folder.appendingPathComponent("rollback.json"),logicalDeviceID:target.id)
        #expect(await controller.apply(restore).status == .verified)
        #expect(await receiver.profile == original)
        let oldRequest=prepared
        await monitor.stop()
        #expect(await controller.apply(oldRequest).status == .superseded)
        #expect(await receiver.commands.filter(\.isWrite).count == 36)
    }
    @Test(arguments:["before-backup","after-backup","revalidation","actual-before","final-metadata","original-image","client-before"],[false,true])
    func ordinaryWritesRetireStaleMetadataBeforeAnySettingAndNeverResumeOldDraft(phase: String,runtime: Bool) async throws {
        if runtime, ["original-image","client-before"].contains(phase) { return }
        let receiver=RateOnlyReceiver(verifiedConfiguration:true)
        let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in receiver.authorizer.install(authorize); return receiver })
        let registry=DriverRegistry(registrations:[DeviceDriverRegistration(id:"offline.ordinary-metadata",identify:LogitechReceiverDriver.identify,logicalDriver:driver,settingsAdapter:driver)])
        let discovery=HIDDiscovery(backendFactory:{ RateOnlyDiscovery(verifiedConfiguration:true) },processLockFactory:{ _ in nil })
        let monitor=BatteryMonitor(discovery:discovery,reader:registry,preferences:RateOnlyPreferences(),registry:registry,automaticallyRefreshTelemetry:false)
        await monitor.start(); let initial=await monitor.initialDiscoveryReady()
        let target=try #require(initial.logicalDevices.first), controller=DeviceController(monitor:monitor,registry:registry)
        let before=try await controller.readSettings(logicalDeviceID:target.id)
        let request=SettingChangeRequest(target:before.session,expectedRevision:before.revision,
            change:runtime ? DeviceSettingsChange(persistence:.runtime,currentStageID:3) : DeviceSettingsChange(pollingRateHz:500,persistence:.onboard))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-stale-info-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        if phase == "before-backup" { await receiver.changeOnboardInfo() }
        let prepared=runtime ? request : try await controller.prepareOnboardChange(request,saveBackupTo:folder.appendingPathComponent("before.json"))
        if phase == "after-backup" { await receiver.changeOnboardInfo() }
        let ordinal=["revalidation":1,"actual-before":4,"final-metadata":6,"original-image":7,"client-before":8][phase]
        if let ordinal { await receiver.changeInfoOnRead(ordinal) }
        let result=await controller.apply(prepared)
        #expect(result.status != .verified)
        #expect(await receiver.commands.allSatisfy { !$0.isWrite })
        #expect(await receiver.closes > 0,"The failed ordinary configuration must retire its cached session")
        #expect(await controller.apply(prepared).status != .verified)
        #expect(await receiver.commands.allSatisfy { !$0.isWrite },"A stale draft must not replay after read-only rediscovery")
        await monitor.stop()
    }
    @Test func rateOnlyCLIBacksUpPreflightsReadsWritesRestoresAndPreservesEveryOtherByte() async throws {
        let receiver=RateOnlyReceiver(), original=await receiver.profile, directory=await receiver.directory
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-rate-only-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let backup=folder.appendingPathComponent("before.json")
        try await run(receiver,backup:backup)
        let saved=try FileProfileBackup(url:backup).load()
        #expect(saved.regions.first(where:{ $0.id == "profile:1" })?.bytes == original)
        #expect(saved.regions.first(where:{ $0.id == "directory:0" })?.bytes == directory)
        #expect(await receiver.profile == original); #expect(await receiver.directory == directory)
        let writes=await receiver.commands.filter(\.isWrite)
        #expect(writes.count == 36)
        #expect(writes.filter { if case .startSectorWrite = $0 { true } else { false } }.count == 2)
        #expect(writes.allSatisfy { switch $0 { case .startSectorWrite,.sectorWriteData,.endSectorWrite: true; default: false } })
        let plans=writes.split { if case .endSectorWrite = $0 { true } else { false } }
        let first=plans[0].compactMap { command -> [UInt8]? in if case .sectorWriteData(let bytes)=command { bytes } else { nil } }.flatMap { $0 }
        #expect(first.count == 256); #expect(first[0] == 2); #expect(first[255] == 0)
        for index in 1..<253 { #expect(first[index] == original[index]) }
        #expect(HIDPPCRC.ccitt(Array(first.prefix(253))) == UInt16(first[253]) << 8 | UInt16(first[254]))
    }
    @Test(arguments:[RateOnlyReceiver.Fault.profileRead,.hostMode,.unknownLayout,.disabledProfile])
    fileprivate func unsupportedOrUnreadableRateOnlyProfileCannotWrite(fault: RateOnlyReceiver.Fault) async throws {
        let receiver=RateOnlyReceiver(fault:fault), original=await receiver.profile
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-rate-refusal-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        var rejected=false
        do { try await run(receiver,backup:folder.appendingPathComponent("before.json")) }
        catch { rejected=true }
        #expect(rejected); #expect(await receiver.commands.allSatisfy { !$0.isWrite }); #expect(await receiver.profile == original)
    }
    @Test(arguments:[RateOnlyReceiver.Fault.corruptAfterWrite,.lateObservedDrift,.lateProfileSwitch,.lateReadFailure,.lateCRCFailure])
    fileprivate func completeImageMismatchCannotBecomeVerifiedFromMatchingRateOrTriggerAutomaticRestore(fault: RateOnlyReceiver.Fault) async throws {
        let receiver=RateOnlyReceiver(fault:fault)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-rate-unknown-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        var rejected=false
        do { try await run(receiver,backup:folder.appendingPathComponent("before.json")) }
        catch { rejected=true }
        #expect(rejected); #expect(await receiver.profile[0] == 2)
        #expect(await receiver.commands.filter { if case .startSectorWrite = $0 { true } else { false } }.count == 1)
        #expect(FileManager.default.fileExists(atPath:folder.appendingPathComponent("before.json").path))
    }
    @Test(arguments:[RateOnlyReceiver.Fault.lateObservedDrift,.lateProfileSwitch,.lateReadFailure,.lateCRCFailure],[false,true])
    fileprivate func finalActualObservationMustStillMatchCompleteWrittenProfileAndSector(fault: RateOnlyReceiver.Fault, tableIntent: Bool) async throws {
        let receiver=RateOnlyReceiver(fault:fault)
        let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in receiver.authorizer.install(authorize); return receiver })
        let registry=DriverRegistry(registrations:[DeviceDriverRegistration(id:"offline.rate-only-final",identify:LogitechReceiverDriver.identify,logicalDriver:driver,settingsAdapter:driver)])
        let discovery=HIDDiscovery(backendFactory:{ RateOnlyDiscovery() },processLockFactory:{ _ in nil })
        let monitor=BatteryMonitor(discovery:discovery,reader:registry,preferences:RateOnlyPreferences(),registry:registry,automaticallyRefreshTelemetry:false)
        await monitor.start(); let initial=await monitor.initialDiscoveryReady()
        let target=try #require(initial.logicalDevices.first), controller=DeviceController(monitor:monitor,registry:registry)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("bazer-logitech-rate-final-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let backup=folder.appendingPathComponent("before.json")
        _=try await controller.exportProfile(logicalDeviceID:target.id,saveTo:backup)
        let before=try await controller.readSettings(logicalDeviceID:target.id)
        let change: DeviceSettingsChange
        if tableIntent {
            let table=try #require(before.settings.stages)
            let requested=DPIStageTable(stages:table.stages,activeStageID:table.activeStageID,opaqueBytes:table.opaqueBytes,defaultStageID:2)
            change=DeviceSettingsChange(stages:requested,persistence:.onboard)
        } else { change=DeviceSettingsChange(pollingRateHz:500,persistence:.onboard) }
        let request=SettingChangeRequest(target:before.session,expectedRevision:before.revision,change:change)
        let authorization=try await controller.authorizeValidation(request,operation:.logitechHIDPP8100Profile)
        let result=await controller.applyValidation(request,authorization:authorization)
        #expect(result.status == .outcomeUnknown)
        if fault == .lateCRCFailure {
            #expect(result.observed == nil)
            #expect(result.fields.allSatisfy { $0.status != .verified })
        } else { #expect(result.fields.first?.status == .outcomeUnknown) }
        #expect(result.message != nil)
        #expect(await receiver.profile[0] == (tableIntent ? 1 : 2))
        #expect(await receiver.commands.filter(\.isWrite).count == 18)
        if fault != .lateCRCFailure {
            let observed=try #require(result.observed?.settings)
            #expect(observed.pollingRateHz == (tableIntent ? 1000 : 500))
            #expect(observed.stages?.opaqueBytes == (await receiver.profile))
            #expect(observed.activeProfileID == (fault == .lateProfileSwitch ? 2 : 1))
        }
        #expect(FileManager.default.fileExists(atPath:backup.path))
        await monitor.stop()
    }
}
