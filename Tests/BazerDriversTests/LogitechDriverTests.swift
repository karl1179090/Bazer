// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
@testable import BazerHID
import Foundation
import LogitechHIDPP
import Testing

private final class OfflineAuthorizer: @unchecked Sendable {
    private let lock=NSLock()
    private var closure: (@Sendable (HIDPPRequest) throws -> Void)?
    func install(_ value: @escaping @Sendable (HIDPPRequest) throws -> Void) { lock.withLock { closure=value } }
    func check(_ request: HIDPPRequest) throws { try lock.withLock { try closure?(request) } }
}
private actor OfflineLogitechReceiver: LogitechSessionTransport, HIDPPTransaction {
    nonisolated let authorizer=OfflineAuthorizer()
    let stream=AsyncStream<HIDPPMessage>.makeStream()
    var ids: [UInt16]=[0,1,3,5,0x1004,0x2201,0x8060,0x8100]
    var commands: [HIDPPCommand]=[]
    var closed=0, leases=0, finishes=0, mode: UInt8=2, activeDPI: UInt8=0
    var x: UInt16=400, rate: UInt8=1
    var ignoreDPI=false
    var unitByte: UInt8=1, deviceKind: UInt8=3, failDPI=false
    var activeProfile: UInt16=1
    var slotOneTimesOut=false
    var profileCount: UInt8=1
    var isDirect=false, adcFlags: UInt8=3
    var profile: [UInt8], directory: [UInt8], staging: [UInt8]=[]
    var writingLength=0, ignoreProfileWrites=false, tamperFinalPad=false
    init() {
        var p=[UInt8](repeating:0xA5,count:256); p[0]=1; p[1]=0; p[2]=1
        for (index,dpi): (Int,UInt16) in [UInt16(400),800,1600,3200,0].enumerated() { p[3+index*2]=UInt8(dpi & 255); p[4+index*2]=UInt8(dpi >> 8) }
        let crc=HIDPPCRC.ccitt(Array(p.dropLast(2))); p[254]=UInt8(crc >> 8); p[255]=UInt8(crc & 255); profile=p
        var d=[UInt8](repeating:255,count:256); d.replaceSubrange(0..<8,with:[0,1,1,0,255,255,0,0]); let dc=HIDPPCRC.ccitt(Array(d.dropLast(2))); d[254]=UInt8(dc >> 8); d[255]=UInt8(dc & 255); directory=d
    }
    func notifications() -> AsyncStream<HIDPPMessage> { stream.stream }
    func acquireTransaction() -> any HIDPPTransaction { leases+=1; return self }
    func finish() { finishes+=1 }
    func close() { closed+=1; stream.continuation.finish() }
    func setIgnoreDPI() { ignoreDPI=true }
    func setModeOnboard() { mode=1 }
    func selectSyntheticStage(_ index: UInt8) { activeDPI=index }
    func setIgnoreProfileWrites() { ignoreProfileWrites=true }
    func setTamperFinalPad() { tamperFinalPad=true }
    func configure255ByteSectors() {
        profile=Array(profile.prefix(255)); directory=Array(directory.prefix(255))
        for isDirectory in [false,true] {
            var bytes=isDirectory ? directory : profile
            let crc=HIDPPCRC.ccitt(Array(bytes.dropLast(2))); bytes[253]=UInt8(crc >> 8); bytes[254]=UInt8(crc & 255)
            if isDirectory { directory=bytes } else { profile=bytes }
        }
    }
    func setKind(_ kind: UInt8) { deviceKind=kind }
    func setDPIFailure() { failDPI=true }
    func replaceUnitSilently() { unitByte=9 }
    func addUnresponsiveSlotOne() { slotOneTimesOut=true }
    func addSecondProfile() {
        profileCount=2; directory.replaceSubrange(0..<12,with:[0,1,1,0,0,2,1,0,255,255,0,0])
        let crc=HIDPPCRC.ccitt(Array(directory.dropLast(2))); directory[254]=UInt8(crc >> 8); directory[255]=UInt8(crc & 255)
    }
    func configureHeadset(hasADC: Bool = true) { isDirect=true; deviceKind=0xFE; ids=[0,1,3,5] + (hasADC ? [0x1F20] : []) }
    func configureWiredMouse() { isDirect=true; ids.removeAll { $0 == 0x1004 } }
    func setADCFlags(_ flags: UInt8) { adcFlags=flags }
    func disconnect() throws { stream.continuation.yield(try HIDPPMessage(bytes:[0x10,2,0x41,4,0x42,0xBB,0xAA])) }
    func exchange(_ request: HIDPPRequest) throws -> HIDPPMessage {
        var authorizedRequest=request
        if tamperFinalPad, writingLength == 255, staging.count == 240, case .sectorWriteData(let bytes)=request.command {
            var changed=bytes; changed[15]=0x7F
            authorizedRequest=try HIDPPRequest(deviceIndex:request.message.deviceIndex,featureIndex:request.message.featureIndex,command:.sectorWriteData(changed),softwareID:request.message.softwareID)
        }
        try authorizer.check(authorizedRequest); commands.append(request.command)
        func be(_ n: UInt16) -> [UInt8] { [UInt8(n >> 8),UInt8(n & 255)] }
        var p: [UInt8]
        switch request.command {
        case .receiverInformation: if isDirect { return try HIDPPMessage(bytes:[0x10,255,0x8F,0x83,0xB5,1,0]) }; p=[3,1,2,3,4,0,2]
        case .pairing(let slot,_):
            if slot == 1 { if slotOneTimesOut { p=[0x20,0,0,0x11,0x11,0,0,1] } else { return try HIDPPMessage(bytes:[0x10,255,0x8F,0x83,0xB5,8,0]) } }
            else { p=[0x21,0,0,0xAA,0xBB,0,0,2] }
        case .ping(let nonce): if request.message.deviceIndex == 1 && slotOneTimesOut { throw HIDPPError.timeout }; p=[4,5,nonce]
        case .lookupFeature(let id): p=[ids.firstIndex(of:id).map(UInt8.init) ?? 0,0,0]
        case .featureCount: p=[UInt8(ids.count-1)]
        case .featureAt(let index): p=be(ids[Int(index)])+[0,0]
        case .firmwareInfo: p=[1,unitByte,2,3,4,0,12,0xAA,0xBB,0x12,0x34,0,0]
        case .firmwareEntity: p=[0,70,87,82,1,2,0,3,0]
        case .nameLength: p=[15]
        case .nameChunk(let offset): p=Array("Synthetic Mouse".utf8.dropFirst(Int(offset)))
        case .deviceKind: p=[deviceKind]
        case .battery1004Capabilities: p=[15,3]
        case .battery1004: p=[50,4,0,0]
        case .adcMeasurement: p=[0x0F,0xA0,adcFlags]
        case .sensorCount: if failDPI { throw HIDPPError.unsupportedFeature(0x2201) }; p=[1]
        case .dpiList: p=[0]+be(400)+be(800)+be(1600)+be(3200)+[0,0]
        case .dpi: p=[0]+be(mode == 1 ? UInt16(profile[3+Int(activeDPI)*2]) | UInt16(profile[4+Int(activeDPI)*2]) << 8 : x)+be(800)
        case .setDPI(_,let value,_,_,_): if !ignoreDPI { x=value }; p=[]
        case .rateCapabilities: p=[0b10001011]
        case .rate: p=[mode == 1 ? profile[0] : rate]
        case .setRate(let code,_): rate=code; p=[]
        case .onboardInfo: p=[1,3,1,profileCount,1,8,4]+be(UInt16(profile.count))+[10,4]
        case .onboardMode: p=[mode]
        case .activeProfile: p=be(activeProfile)
        case .setActiveProfile(let number): activeProfile=number; p=[]
        case .activeDPIIndex: p=[activeDPI]
        case .setActiveDPIIndex(let index): activeDPI=index; p=[]
        case .readSector(let sector,let offset):
            let b=sector == 0 ? directory : profile
            guard Int(offset)+16 <= b.count else { throw HIDPPError.invalidValue("Synthetic firmware rejects read beyond physical sector") }
            p=Array(b[Int(offset)..<Int(offset)+16])
        case .startSectorWrite(_,let length):
            guard Int(length) == profile.count else { throw HIDPPError.invalidValue("Synthetic write count differs from physical size") }
            writingLength=Int(length); staging=[]; p=[]
        case .sectorWriteData: staging+=request.message.parameters; p=[]
        case .endSectorWrite:
            guard staging.count == ((writingLength+15)/16)*16, staging.dropFirst(writingLength).allSatisfy({ $0 == 0 }) else { throw HIDPPError.invalidValue("Invalid synthetic write data or final padding") }
            if !ignoreProfileWrites { profile=Array(staging.prefix(writingLength)) }; p=[]
        default: throw HIDPPError.invalidValue("Unimplemented synthetic receiver command")
        }
        return try HIDPPMessage(bytes:[0x11]+request.message.bytes[1..<4]+p+[UInt8](repeating:0,count:16-p.count))
    }
}
private actor OfflineTraceBackend: HIDInputOutputBackend {
    var input: (@Sendable (UInt8,[UInt8]) -> Void)?
    func open(endpoint: HIDInputOutputEndpoint,onReport: @escaping @Sendable (UInt8,[UInt8]) -> Void,onRemoval: @escaping @Sendable () -> Void) { input=onReport }
    func send(_ message: HIDPPMessage) { input?(message.kind.rawValue,message.bytes) }
    func close() {}
}

/// Runs the production matcher, correlation quarantine and lifecycle with value-only I/O.
private final class RecoveryRequestRecorder: @unchecked Sendable {
    private let lock=NSLock()
    private var request: HIDPPRequest?
    func record(_ request: HIDPPRequest) { lock.withLock { self.request=request } }
    func matching(_ message: HIDPPMessage) -> HIDPPRequest? { lock.withLock { request?.message.bytes == message.bytes ? request : nil } }
}
private actor RecoveryFaults {
    var remainingPingDrops=0, alwaysDropPings=false
    var nextCommand: HIDPPCommand?
    func dropPings(_ count: Int,always: Bool = false) { remainingPingDrops=count; alwaysDropPings=always }
    func dropNext(_ command: HIDPPCommand) { nextCommand=command }
    func drops(_ request: HIDPPRequest) -> Bool {
        if nextCommand == request.command { nextCommand=nil; return true }
        if case .ping=request.command, request.message.deviceIndex != 255 {
            if alwaysDropPings { return true }
            if remainingPingDrops > 0 { remainingPingDrops-=1; return true }
        }
        return false
    }
}
private actor RecoveryIOBackend: HIDInputOutputBackend {
    let receiver: OfflineLogitechReceiver, recorder: RecoveryRequestRecorder, faults: RecoveryFaults
    var input: (@Sendable (UInt8,[UInt8]) -> Void)?
    var opens=0, closes=0
    var sent: [HIDPPRequest]=[]
    private var holdsClose=false, closeGate: CheckedContinuation<Void,Never>?
    private var closeWaiters: [CheckedContinuation<Void,Never>]=[]
    init(receiver: OfflineLogitechReceiver,recorder: RecoveryRequestRecorder,faults: RecoveryFaults) { self.receiver=receiver; self.recorder=recorder; self.faults=faults }
    func open(endpoint: HIDInputOutputEndpoint,onReport: @escaping @Sendable (UInt8,[UInt8]) -> Void,onRemoval: @escaping @Sendable () -> Void) { opens+=1; input=onReport }
    func send(_ message: HIDPPMessage) async throws {
        guard let request=recorder.matching(message) else { throw HIDPPError.invalidValue("Synthetic backend received an unrecorded request") }
        sent.append(request)
        if await faults.drops(request) { return }
        let response=try await receiver.exchange(request)
        input?(response.kind.rawValue,response.bytes)
    }
    func emitOnline() { input?(0x10,[0x10,2,0x41,4,2,0xBB,0xAA]) }
    func emit(_ message: HIDPPMessage) { input?(message.kind.rawValue,message.bytes) }
    func holdClose() { holdsClose=true }
    func waitForClose() async { if closes > 0 { return }; await withCheckedContinuation { closeWaiters.append($0) } }
    func releaseClose() { holdsClose=false; let gate=closeGate; closeGate=nil; gate?.resume() }
    func close() async {
        closes+=1; let waiters=closeWaiters; closeWaiters=[]; waiters.forEach { $0.resume() }
        if holdsClose { await withCheckedContinuation { closeGate=$0 } }
    }
}
private final class RecoverySessionFactory: @unchecked Sendable {
    let receiver=OfflineLogitechReceiver(), faults=RecoveryFaults()
    private let lock=NSLock()
    private var backends: [RecoveryIOBackend]=[]
    func make(_ endpoint: HIDInputOutputEndpoint,authorize: @escaping @Sendable (HIDPPRequest) throws -> Void) -> any LogitechSessionTransport {
        let recorder=RecoveryRequestRecorder(), backend=RecoveryIOBackend(receiver:receiver,recorder:recorder,faults:faults)
        lock.withLock { backends.append(backend) }
        return HIDInputOutputSession(endpoint:endpoint,backendFactory:{ backend },lockFactory:{ nil },requestTimeout:.milliseconds(30),authorize:{ request in try authorize(request); recorder.record(request) })
    }
    func instances() -> [RecoveryIOBackend] { lock.withLock { backends } }
}

@Suite("Offline Logitech production adapter", .timeLimit(.minutes(1)))
struct LogitechDriverTests {
    private func host(pid: UInt16 = 0xDEAD) -> PhysicalDeviceDescriptor {
        let descriptor: [UInt8]=[0x06,0,0xFF,9,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0]
        let interface=HIDInterfaceDescriptor(registryEntryID:101,usbParentRegistryEntryID:10,vendorID:0x046D,productID:pid,product:"Synthetic receiver",transport:"USB",maxInputReportSize:20,maxOutputReportSize:20,reportDescriptor:descriptor)
        return PhysicalDeviceGrouper.group([interface])[0]
    }
    private func setup(kind: UInt8 = 3,failDPI: Bool = false,secondProfile: Bool = false,physical255: Bool = false) async throws -> (LogitechReceiverDriver,OfflineLogitechReceiver,LogicalDeviceDescriptor,LogicalDeviceSessionID) {
        let fake=OfflineLogitechReceiver(); await fake.setKind(kind); if failDPI { await fake.setDPIFailure() }; if secondProfile { await fake.addSecondProfile() }; if physical255 { await fake.configure255ByteSectors() }; let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in fake.authorizer.install(authorize); return fake })
        let host=host(), session=DeviceSessionID(physicalDeviceID:host.id)
        let targets=try await driver.discoverTargets(host:host,session:session); let target=try #require(targets.first)
        return (driver,fake,target,LogicalDeviceSessionID(address:target.address))
    }
    @Test func quarantinedChildRebuildsAfterOnlineNotificationUsingRealSession() async throws {
        let factory=RecoverySessionFactory(); await factory.faults.dropPings(1)
        let driver=LogitechReceiverDriver(sessionFactory:{ endpoint,authorize in factory.make(endpoint,authorize:authorize) })
        let physical=host(), hostSession=DeviceSessionID(physicalDeviceID:physical.id)
        let initial=try #require(try await driver.discoverTargets(host:physical,session:hostSession).first)
        #expect(initial.capabilities[.batteryRead].failureReason?.contains("timeout") == true)
        let stream=await driver.discoveryEvents()
        let event=Task<DeviceSessionID?,Never> { for await value in stream { return value }; return nil }
        let original=try #require(factory.instances().first); await original.emitOnline()
        #expect(await event.value == hostSession)
        let fresh=try #require(try await driver.discoverTargets(host:physical,session:hostSession).first)
        let telemetry=await driver.readTelemetry(target:fresh,session:LogicalDeviceSessionID(address:fresh.address))
        #expect(telemetry.update.battery?.percent == 50)
        #expect(factory.instances().count == 2); #expect(await original.closes == 1)
        #expect(fresh.address != initial.address)
        let replacement=try #require(factory.instances().last)
        #expect(await replacement.sent.allSatisfy { !$0.command.isRegister && $0.message.deviceIndex == 2 })
        guard case .receiver(2,let identity)=fresh.address.target else { Issue.record("Observed slot was not preserved"); await driver.stop(); return }
        #expect(identity.wirelessProductID == 0xAABB)
        let obsolete=await driver.readTelemetry(target:initial,session:LogicalDeviceSessionID(address:initial.address))
        #expect(obsolete.update.battery == nil); #expect(obsolete.update.batteryFailure?.category == .removed)
        // A callback retained by an old native backend is ignored after close, even
        // when its raw correlation matches the first request on the new transport.
        if let request=await original.sent.last { await original.emit(request.message) }
        #expect(try await driver.readSettings(target:fresh,session:LogicalDeviceSessionID(address:fresh.address)).currentDPI == DPISetting(400))
        for backend in factory.instances() { #expect(await backend.sent.allSatisfy { !$0.command.isWrite }) }
        await driver.stop()
    }
    @Test func continuouslyUnresponsiveChildRebuildsAtMostOncePerDiscovery() async throws {
        let factory=RecoverySessionFactory(); await factory.faults.dropPings(0,always:true)
        let driver=LogitechReceiverDriver(sessionFactory:{ endpoint,authorize in factory.make(endpoint,authorize:authorize) })
        let physical=host(), hostSession=DeviceSessionID(physicalDeviceID:physical.id)
        for expectedInstances in 1...3 {
            let targets=try await driver.discoverTargets(host:physical,session:hostSession)
            let placeholder=try #require(targets.first)
            #expect(targets.count == 1); #expect(placeholder.capabilities[.batteryRead].evidence == .unknown)
            #expect(placeholder.capabilities[.batteryRead].failureReason?.contains("timeout") == true)
            #expect(placeholder.preferenceIdentity == nil); #expect(factory.instances().count == expectedInstances)
        }
        var pings=0, closes=0
        for backend in factory.instances() {
            let sent=await backend.sent; pings+=sent.filter { if case .ping=$0.command { return true }; return false }.count
            closes+=await backend.closes; #expect(sent.allSatisfy { !$0.command.isWrite })
        }
        #expect(pings == 3); #expect(closes == 2)
        await driver.stop()
    }
    @Test func replacementTransportWaitsForOldNativeCloseToDrain() async throws {
        let factory=RecoverySessionFactory(); await factory.faults.dropPings(1)
        let driver=LogitechReceiverDriver(sessionFactory:{ endpoint,authorize in factory.make(endpoint,authorize:authorize) })
        let physical=host(), hostSession=DeviceSessionID(physicalDeviceID:physical.id)
        let old=try #require(try await driver.discoverTargets(host:physical,session:hostSession).first)
        let original=try #require(factory.instances().first); await original.holdClose()
        let recovery=Task { try await driver.discoverTargets(host:physical,session:hostSession) }
        await original.waitForClose()
        #expect(factory.instances().count == 1)
        // Driver state is invalid before the real teardown completes.
        do { _=try await driver.featureDirectory(target:old,session:LogicalDeviceSessionID(address:old.address)); Issue.record("Closing host exposed its old child") } catch {}
        await original.releaseClose()
        let fresh=try #require(try await recovery.value.first)
        #expect(factory.instances().count == 2); #expect(fresh.address != old.address)
        #expect((await driver.readTelemetry(target:fresh,session:LogicalDeviceSessionID(address:fresh.address))).update.battery?.percent == 50)
        for backend in factory.instances() { #expect(await backend.sent.allSatisfy { !$0.command.isWrite }) }
        await driver.stop()
    }
    @Test(arguments:["settings","apply","authorization","telemetry","backup"])
    func settingsQuarantineRequestsReadOnlyRediscoveryAndDropsOldIntent(route: String) async throws {
        let factory=RecoverySessionFactory()
        let driver=LogitechReceiverDriver(sessionFactory:{ endpoint,authorize in factory.make(endpoint,authorize:authorize) })
        let physical=host(); var store=DeviceStore()
        store.reconcile([try #require(LogitechReceiverDriver.identify(physical))],at:Date())
        let hostSession=try #require(store.devices[physical.id]?.sessionID)
        let initial=try #require(try await driver.discoverTargets(host:physical,session:hostSession).first)
        store.reconcileLogicalDevices([initial],for:hostSession)
        let session=try #require(store.logicalDevices[initial.id]?.sessionID)
        let oldSuccessfulResult=await driver.readTelemetry(target:initial,session:session)
        #expect(oldSuccessfulResult.update.battery?.percent == 50)
        let settings=try await driver.readSettings(target:initial,session:session)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:settings)
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(currentDPI:DPISetting(800)))
        _=try await driver.authorizeValidation(request:request,before:before,target:initial,operation:.logitechHIDPP2201DPI)
        await factory.faults.dropNext(.lookupFeature(3))
        do { _=try await driver.readSettings(target:initial,session:session); Issue.record("Dropped read unexpectedly succeeded") }
        catch let error as TelemetryFailure { #expect(error.category == .timeout) }
        let stream=await driver.discoveryEvents()
        let event=Task<DeviceSessionID?,Never> { for await value in stream { return value }; return nil }
        let backupDirectory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:backupDirectory) }
        switch route {
        case "apply":
            let result=try await driver.applySettings(request:request,before:before,target:initial)
            #expect(!result.acknowledged); #expect(result.observed == nil); #expect(result.failure?.category == .removed)
        case "telemetry":
            let result=await driver.readTelemetry(target:initial,session:session)
            #expect(result.update.battery == nil); #expect(result.update.batteryFailure?.category == .removed)
        default:
            do {
                if route == "authorization" { _=try await driver.authorizeValidation(request:request,before:before,target:initial,operation:.logitechHIDPP2201DPI) }
                else if route == "backup" { _=try await driver.exportProfile(target:initial,session:session,saveTo:backupDirectory.appendingPathComponent("backup.json")) }
                else { _=try await driver.readSettings(target:initial,session:session) }
                Issue.record("Quarantined read succeeded")
            } catch {}
        }
        // stop finishes the stream if a broken recovery implementation never emits.
        let original=try #require(factory.instances().first)
        #expect(await original.closes == 1)
        if await original.closes == 0 { await driver.stop(); _=await event.value; return }
        #expect(await event.value == hostSession)
        let fresh=try #require(try await driver.discoverTargets(host:physical,session:hostSession).first)
        store.reconcileLogicalDevices([fresh],for:hostSession)
        let freshSession=try #require(store.logicalDevices[fresh.id]?.sessionID)
        #expect(fresh.address != initial.address)
        let acceptedOldResult=store.apply(oldSuccessfulResult.update,to:oldSuccessfulResult.session)
        #expect(!acceptedOldResult)
        #expect(store.logicalDevices[fresh.id]?.battery == nil)
        #expect((await driver.readTelemetry(target:fresh,session:freshSession)).update.battery?.percent == 50)
        do { _=try await driver.applySettings(request:request,before:before,target:initial); Issue.record("Old target survived rebuild") } catch {}
        let rebound=SettingChangeRequest(id:request.id,target:freshSession,expectedRevision:1,change:request.change)
        let freshBefore=DeviceSettingsSnapshot(session:freshSession,revision:1,capturedAt:Date(),settings:settings)
        do { _=try await driver.applySettings(request:rebound,before:freshBefore,target:fresh); Issue.record("Old intent transferred to replacement") } catch {}
        for backend in factory.instances() { #expect(await backend.sent.allSatisfy { !$0.command.isWrite }) }
        #expect(!FileManager.default.fileExists(atPath:backupDirectory.appendingPathComponent("backup.json").path))
        await driver.stop()
    }
    @Test func runtimeDiscoveryDoesNotAssumePIDWPIDOrSlot() async throws {
        let (driver,fake,target,session)=try await setup()
        guard case .receiver(let slot,let identity)=target.address.target else { Issue.record("Expected a receiver child"); return }
        #expect(slot == 2); #expect(identity.wirelessProductID == 0xAABB); #expect(identity.unitID == "01020304"); #expect(identity.protocolVersion == "4.5")
        #expect(target.product == "Synthetic Mouse"); #expect(!target.capabilities.permits(.dpiWrite))
        let result=await driver.readTelemetry(target:target,session:session); #expect(result.update.battery?.percent == 50); #expect(result.update.charging?.state == .discharging)
        #expect(await fake.commands.allSatisfy { !$0.isWrite }); await driver.stop(); #expect(await fake.closed == 1)
    }
    @Test func candidateGrantIsExactOneUseAndNormalUIStillReadOnly() async throws {
        let (driver,fake,target,session)=try await setup(); let actual=try await driver.readSettings(target:target,session:session)
        let before=DeviceSettingsSnapshot(session:session,revision:7,capturedAt:Date(),settings:actual)
        let request=SettingChangeRequest(target:session,expectedRevision:7,change:DeviceSettingsChange(currentDPI:DPISetting(800)))
        do { _=try await driver.applySettings(request:request,before:before,target:target); Issue.record("Unverified normal write escaped policy") } catch {}
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP2201DPI)
        let result=try await driver.applySettings(request:request,before:before,target:target)
        #expect(result.acknowledged); #expect(result.observed?.currentDPI == DPISetting(800)); #expect(result.before.currentDPI == DPISetting(400))
        do { _=try await driver.applySettings(request:request,before:before,target:target); Issue.record("Candidate grant was replayed") } catch {}
        #expect(await fake.commands.filter(\.isWrite).count == 1); await driver.stop()
    }
    @Test func changedActualBeforeSnapshotSuppressesWrites() async throws {
        let (driver,fake,target,session)=try await setup(); let actual=try await driver.readSettings(target:target,session:session)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual)
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(currentDPI:DPISetting(800)))
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP2201DPI)
        // Emulate an independently read newer snapshot while preserving the exact token.
        let wrong=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:DeviceSettings(currentDPI:DPISetting(1600)))
        let result=try await driver.applySettings(request:request,before:wrong,target:target)
        #expect(result.superseded); #expect(await fake.commands.allSatisfy { !$0.isWrite }); await driver.stop()
    }
    @Test func ackReadbackMismatchReportsActualObserved() async throws {
        let (driver,fake,target,session)=try await setup(); let actual=try await driver.readSettings(target:target,session:session)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual); await fake.setIgnoreDPI()
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(currentDPI:DPISetting(800)))
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP2201DPI)
        let result=try await driver.applySettings(request:request,before:before,target:target)
        #expect(!result.acknowledged); #expect(result.observed?.currentDPI == DPISetting(400)); #expect(result.failure != nil); await driver.stop()
    }
    @Test(arguments:[false,true]) func profileCandidatePreservesOpaqueBytes(physical255: Bool) async throws {
        let (driver,fake,target,session)=try await setup(physical255:physical255); await fake.setModeOnboard(); let actual=try await driver.readSettings(target:target,session:session)
        let table=try #require(actual.stages), old=await fake.profile
        let patched=DPIStageTable(stages:table.stages.map { DPIStage(id:$0.id,dpi:$0.id == 1 ? DPISetting(1600) : $0.dpi) },activeStageID:table.activeStageID,opaqueBytes:table.opaqueBytes,defaultStageID:table.defaultStageID)
        let before=DeviceSettingsSnapshot(session:session,revision:3,capturedAt:Date(),settings:actual)
        let request=SettingChangeRequest(target:session,expectedRevision:3,change:DeviceSettingsChange(stages:patched,persistence:.onboard))
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP8100Profile)
        let result=try await driver.applySettings(request:request,before:before,target:target)
        #expect(result.acknowledged); #expect(result.observed?.stages?.stages[1].dpi == DPISetting(1600))
        let new=await fake.profile; for index in 0..<old.count-2 where ![5,6].contains(index) { #expect(new[index] == old[index]) }
        await driver.stop()
    }
    @Test(arguments:[false,true]) func onboardRateOnlyCandidatePreservesFullProfileAndRestoresWithoutInventingStageIntent(physical255: Bool) async throws {
        let (driver,fake,target,session)=try await setup(physical255:physical255)
        await fake.setModeOnboard(); await fake.selectSyntheticStage(2)
        let original=await fake.profile, directory=await fake.directory
        let actual=try await driver.readSettings(target:target,session:session)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual)
        // Authorize recovery before the first write, preserving the exact rate-only intent.
        let recovery=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(pollingRateHz:1000,persistence:.onboard))
        _=try await driver.authorizeValidation(request:recovery,before:before,target:target,operation:.logitechHIDPP8100Profile)
        #expect(await fake.commands.allSatisfy { !$0.isWrite })
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(pollingRateHz:500,persistence:.onboard))
        #expect(request.change.fields == [.pollingRate]); #expect(request.change.stages == nil)
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP8100Profile)
        let transaction=try await driver.applySettings(request:request,before:before,target:target)
        #expect(transaction.acknowledged); #expect(transaction.observed?.pollingRateHz == 500)
        let updated=await fake.profile
        #expect(updated[0] == 2)
        for index in 1..<original.count-2 { #expect(updated[index] == original[index]) }
        #expect(await fake.directory == directory)
        let observed=try #require(transaction.observed)
        #expect(observed.currentStageID == actual.currentStageID)
        #expect(observed.stages?.stages == actual.stages?.stages)
        #expect(observed.stages?.defaultStageID == actual.stages?.defaultStageID)
        let after=DeviceSettingsSnapshot(session:session,revision:2,capturedAt:Date(),settings:observed)
        let restore=SettingChangeRequest(target:session,expectedRevision:2,change:recovery.change)
        _=try await driver.authorizeValidation(request:restore,before:after,target:target,operation:.logitechHIDPP8100Profile)
        let restored=try await driver.applySettings(request:restore,before:after,target:target)
        #expect(restored.acknowledged); #expect(restored.observed?.pollingRateHz == 1000)
        #expect(await fake.profile == original); #expect(await fake.directory == directory)
        #expect(await fake.commands.filter { if case .startSectorWrite = $0 { true } else { false } }.count == 2)
        #expect(await fake.commands.allSatisfy { if case .setRate = $0 { false } else { true } })
        await driver.stop()
    }
    @Test func physical255ByteProfilesExportEditAndRestoreExactOriginal() async throws {
        let (driver,fake,target,session)=try await setup(physical255:true)
        await fake.setModeOnboard(); await fake.selectSyntheticStage(2)
        #expect(target.capabilities[.onboardRead].failureReason == nil)
        #expect(target.capabilities[.stagesRead].evidence == .discovered)
        #expect(target.capabilities[.stagesWrite].evidence != .writeVerified)
        #expect(target.capabilities[.onboardPersist].evidence != .writeVerified)
        let actual=try await driver.readSettings(target:target,session:session)
        #expect(actual.currentDPI == DPISetting(1600)); #expect(actual.stages?.stages.map(\.dpi.x) == [400,800,1600,3200])
        #expect(actual.stages?.opaqueBytes.count == 255)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual)
        let table=try #require(actual.stages)
        let changed=DPIStageTable(stages:table.stages,activeStageID:table.activeStageID,opaqueBytes:table.opaqueBytes,defaultStageID:1)
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(stages:changed,persistence:.onboard))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let backupURL=folder.appendingPathComponent("before.json"), rollbackURL=folder.appendingPathComponent("rollback.json")
        let backup=try await driver.exportProfile(target:target,session:session,saveTo:backupURL)
        #expect(backup.regions.filter { $0.id.hasPrefix("directory:") || $0.id.hasPrefix("profile:") }.allSatisfy { $0.bytes.count == 255 })
        #expect(await fake.commands.allSatisfy { !$0.isWrite })
        let original=await fake.profile
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP8100Profile)
        let result=try await driver.applySettings(request:request,before:before,target:target)
        #expect(result.acknowledged); #expect(result.observed?.stages?.defaultStageID == 1); #expect(result.observed?.currentStageID == 2)
        let updated=await fake.profile
        #expect(updated.count == 255)
        for index in original.indices where ![1,253,254].contains(index) { #expect(updated[index] == original[index]) }
        let info=try HIDPPOnboardInfo.parse([1,3,1,1,1,8,4,0,255,10,4])
        let planned=try HIDPPProfileSector(sector:1,bytes:updated,info:info).writePlan()
        #expect(await fake.commands.filter(\.isWrite) == planned.commands)
        let writesBeforeRecovery=await fake.commands.filter(\.isWrite).count
        let restoredDraft=try await driver.prepareRestore(backupURL:backupURL,rollbackBackupURL:rollbackURL,target:target,session:session)
        #expect(await fake.commands.filter(\.isWrite).count == writesBeforeRecovery)
        #expect(try FileProfileBackup(url:rollbackURL).load().regions.first(where:{ $0.id == "profile:1" })?.bytes == updated)
        let after=try #require(result.observed), restoreBefore=DeviceSettingsSnapshot(session:session,revision:2,capturedAt:Date(),settings:after)
        let restore=SettingChangeRequest(target:session,expectedRevision:2,change:restoredDraft)
        _=try await driver.authorizeValidation(request:restore,before:restoreBefore,target:target,operation:.logitechHIDPP8100Profile)
        let recovered=try await driver.applySettings(request:restore,before:restoreBefore,target:target)
        #expect(recovered.acknowledged); #expect(recovered.observed == actual)
        #expect(await fake.profile == original)
        #expect(await fake.commands.filter(\.isWrite).count == 36)
        await driver.stop()
    }
    @Test func physical255FailedReadbackNeverAcknowledgesOrRetries() async throws {
        let (driver,fake,target,session)=try await setup(physical255:true)
        await fake.setModeOnboard()
        let actual=try await driver.readSettings(target:target,session:session), table=try #require(actual.stages)
        let changed=DPIStageTable(stages:table.stages,activeStageID:table.activeStageID,opaqueBytes:table.opaqueBytes,defaultStageID:1)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual)
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(stages:changed,persistence:.onboard))
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP8100Profile)
        await fake.setIgnoreProfileWrites()
        let result=try await driver.applySettings(request:request,before:before,target:target)
        #expect(!result.acknowledged); #expect(result.failure != nil); #expect(result.observed == actual)
        #expect(await fake.commands.filter(\.isWrite).count == 18)
        await driver.stop()
    }
    @Test func physical255TypedGrantRejectsTamperedFinalPadding() async throws {
        let (driver,fake,target,session)=try await setup(physical255:true)
        await fake.setModeOnboard()
        let actual=try await driver.readSettings(target:target,session:session), table=try #require(actual.stages)
        let changed=DPIStageTable(stages:table.stages,activeStageID:table.activeStageID,opaqueBytes:table.opaqueBytes,defaultStageID:1)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual)
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(stages:changed,persistence:.onboard))
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP8100Profile)
        await fake.setTamperFinalPad()
        let result=try await driver.applySettings(request:request,before:before,target:target)
        #expect(!result.acknowledged); #expect(result.failure != nil); #expect(result.observed == actual)
        let writes=await fake.commands.filter(\.isWrite)
        #expect(writes.count == 16); #expect(!writes.contains(.endSectorWrite))
        await driver.stop()
    }
    @Test(arguments:[UInt8(0),UInt8(0xFA)]) func keyboardAndUnknownKindsDoNotInheritMouseSettings(kind: UInt8) async throws {
        let (driver,fake,target,session)=try await setup(kind:kind)
        #expect(target.kind == (kind == 0 ? .keyboard : .other)); #expect(!target.capabilities.permits(.dpiRead)); #expect(!target.capabilities.canReadSettings)
        #expect(await driver.readTelemetry(target:target,session:session).update.battery?.percent == 50)
        #expect(await fake.commands.allSatisfy { !$0.isWrite }); await driver.stop()
    }
    @Test func settingsFailureDoesNotDiscardBatteryChild() async throws {
        let (driver,_,target,session)=try await setup(failDPI:true)
        #expect(target.capabilities[.dpiRead].failureReason != nil)
        #expect(await driver.readTelemetry(target:target,session:session).update.battery?.percent == 50); await driver.stop()
    }
    @Test func silentSlotReplacementRejectsOldWriteBeforeSending() async throws {
        let (driver,fake,target,session)=try await setup(); let actual=try await driver.readSettings(target:target,session:session)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual)
        let request=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(currentDPI:DPISetting(800)))
        _=try await driver.authorizeValidation(request:request,before:before,target:target,operation:.logitechHIDPP2201DPI)
        await fake.replaceUnitSilently()
        let result=try await driver.applySettings(request:request,before:before,target:target)
        #expect(result.failure?.category == .removed); #expect(await fake.commands.allSatisfy { !$0.isWrite })
        let newTargets=try await driver.discoverTargets(host:host(),session:session.address.hostSessionID)
        #expect(newTargets.first?.address != target.address); #expect(newTargets.first?.product == target.product)
        await driver.stop()
    }
    @Test func runtimeStageAndStoredDefaultAreIndependent() async throws {
        let (driver,fake,target,session)=try await setup(); await fake.setModeOnboard()
        let initial=try await driver.readSettings(target:target,session:session)
        let select=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(currentStageID:1))
        _=try await driver.authorizeValidation(request:select,before:DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:initial),target:target,operation:.logitechHIDPP8100Profile)
        let selected=try await driver.applySettings(request:select,before:DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:initial),target:target)
        #expect(selected.observed?.currentStageID == 1); #expect(selected.observed?.stages?.defaultStageID == 0)
        let actual=try #require(selected.observed), table=try #require(actual.stages)
        let defaultTable=DPIStageTable(stages:table.stages,activeStageID:table.activeStageID,opaqueBytes:table.opaqueBytes,defaultStageID:2)
        let persist=SettingChangeRequest(target:session,expectedRevision:2,change:DeviceSettingsChange(stages:defaultTable,persistence:.onboard))
        let before=DeviceSettingsSnapshot(session:session,revision:2,capturedAt:Date(),settings:actual)
        _=try await driver.authorizeValidation(request:persist,before:before,target:target,operation:.logitechHIDPP8100Profile)
        let result=try await driver.applySettings(request:persist,before:before,target:target)
        #expect(result.observed?.currentStageID == 1); #expect(result.observed?.stages?.defaultStageID == 2); #expect(await fake.profile[1] == 2)
        await driver.stop()
    }
    @Test func localBackupRestorePreparesDraftAndRollbackWithoutWrites() async throws {
        let (driver,fake,target,session)=try await setup(); let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let backupURL=directory.appendingPathComponent("original.json"), rollbackURL=directory.appendingPathComponent("rollback.json")
        let backup=try await driver.exportProfile(target:target,session:session,saveTo:backupURL,hardwareEvidenceReference:"synthetic-test-only")
        #expect(backup.hardwareEvidenceReference == "synthetic-test-only")
        let draft=try await driver.prepareRestore(backupURL:backupURL,rollbackBackupURL:rollbackURL,target:target,session:session)
        #expect(draft.persistence == .onboard); #expect(draft.stages?.defaultStageID == 0); #expect(FileManager.default.fileExists(atPath:rollbackURL.path))
        #expect(await fake.commands.allSatisfy { !$0.isWrite })
        do { _=try await driver.exportProfile(target:target,session:session,saveTo:backupURL); Issue.record("Backup overwritten") } catch {}
        await driver.stop()
    }
    @Test func unresponsiveSiblingDoesNotRemoveOnlineChild() async throws {
        let fake=OfflineLogitechReceiver(); await fake.addUnresponsiveSlotOne()
        let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in fake.authorizer.install(authorize); return fake })
        let physical=host(), hostSession=DeviceSessionID(physicalDeviceID:physical.id)
        let targets=try await driver.discoverTargets(host:physical,session:hostSession)
        #expect(targets.count == 2)
        let a=try #require(targets.first(where:{ if case .receiver(1,_)=($0.address.target) { return true }; return false }))
        let b=try #require(targets.first(where:{ if case .receiver(2,_)=($0.address.target) { return true }; return false }))
        #expect(a.capabilities[.batteryRead].failureReason?.contains("timeout") == true); #expect(a.preferenceIdentity == nil)
        let result=await driver.readTelemetry(target:b,session:LogicalDeviceSessionID(address:b.address)); #expect(result.update.battery?.percent == 50)
        #expect(await fake.commands.allSatisfy { !$0.isWrite }); await driver.stop()
    }
    @Test func notificationInvalidatesOldAddressAndEmitsRediscovery() async throws {
        let (driver,fake,target,session)=try await setup(); let logical: any DeviceLogicalDriver=driver; let stream=await logical.discoveryEvents()
        let event=Task<DeviceSessionID?,Never> { for await value in stream { return value }; return nil }
        try await fake.disconnect()
        #expect(await event.value == session.address.hostSessionID)
        let result=await driver.readTelemetry(target:target,session:session)
        #expect(result.update.batteryFailure?.category == .removed); #expect(result.update.battery == nil)
        await driver.stop()
    }
    @Test func activeProfileUsesReadDirectoryAndRuntimeScope() async throws {
        let (driver,fake,target,session)=try await setup(secondProfile:true); await fake.setModeOnboard(); let actual=try await driver.readSettings(target:target,session:session)
        let before=DeviceSettingsSnapshot(session:session,revision:1,capturedAt:Date(),settings:actual)
        let invalid=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(activeProfileID:3))
        do { _=try await driver.authorizeValidation(request:invalid,before:before,target:target,operation:.logitechHIDPP8100Profile); Issue.record("Absent profile received a candidate grant") } catch {}
        let valid=SettingChangeRequest(target:session,expectedRevision:1,change:DeviceSettingsChange(activeProfileID:2))
        _=try await driver.authorizeValidation(request:valid,before:before,target:target,operation:.logitechHIDPP8100Profile)
        let result=try await driver.applySettings(request:valid,before:before,target:target)
        #expect(result.acknowledged); #expect(result.observed?.activeProfileID == 2); #expect(result.persistence == .runtime)
        #expect(await fake.commands.filter(\.isWrite) == [.setActiveProfile(2)]); await driver.stop()
    }
    @Test(arguments:[UInt16(0x0A66),UInt16(0x0A87),UInt16(0x0AB5)]) func exactHeadsetADCProducesVoltageOnly(pid: UInt16) async throws {
        let fake=OfflineLogitechReceiver(); await fake.configureHeadset()
        let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in fake.authorizer.install(authorize); return fake })
        let host=host(pid:pid), hostSession=DeviceSessionID(physicalDeviceID:host.id)
        let target=try #require(try await driver.discoverTargets(host:host,session:hostSession).first), session=LogicalDeviceSessionID(address:target.address)
        #expect(target.kind == .other); #expect(!target.capabilities.canReadSettings); #expect(target.capabilities.powerSource == .rechargeableBattery)
        let charging=await driver.readTelemetry(target:target,session:session)
        #expect(charging.update.battery?.value == .voltageOnly(millivolts:4000)); #expect(charging.update.battery?.percent == nil); #expect(charging.update.charging?.state == .charging)
        await fake.setADCFlags(0); let invalid=await driver.readTelemetry(target:target,session:session)
        #expect(invalid.update.battery?.value == .unknown); #expect(invalid.update.charging?.state == .unknown)
        #expect(await fake.commands.allSatisfy { !$0.isWrite }); await driver.stop()
    }
    @Test func absentADCAndUnknownHeadsetNeverSendMeasurement() async throws {
        for pid: UInt16 in [0x0AB5,0xDEAD] {
            let fake=OfflineLogitechReceiver(); await fake.configureHeadset(hasADC:pid == 0xDEAD)
            let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in fake.authorizer.install(authorize); return fake })
            let host=host(pid:pid), session=DeviceSessionID(physicalDeviceID:host.id)
            do { let targets=try await driver.discoverTargets(host:host,session:session); #expect(targets.first?.capabilities.battery == .unsupported) }
            catch { #expect(pid == 0xDEAD) }
            #expect(await fake.commands.allSatisfy { $0 != .adcMeasurement && !$0.isWrite }); await driver.stop()
        }
    }
    @Test func exactWiredCatalogPowerDoesNotDisableSettings() async throws {
        let fake=OfflineLogitechReceiver(); await fake.configureWiredMouse()
        let driver=LogitechReceiverDriver(sessionFactory:{ _,authorize in fake.authorizer.install(authorize); return fake })
        let host=host(pid:0xC332), hostSession=DeviceSessionID(physicalDeviceID:host.id)
        let target=try #require(try await driver.discoverTargets(host:host,session:hostSession).first)
        #expect(target.capabilities.powerSource == .wired); #expect(target.capabilities.battery == .unsupported); #expect(target.capabilities.canReadSettings)
        #expect(try await driver.readSettings(target:target,session:LogicalDeviceSessionID(address:target.address)).currentDPI == DPISetting(400)); await driver.stop()
    }
    @Test func nativeSessionTraceUsesConcreteAsyncProtocolWitness() async throws {
        let host=host(), backend=OfflineTraceBackend()
        let endpoint=try HIDInputOutputEndpoint(physicalDeviceID:host.id,descriptor:host.interfaces[0])
        let session=HIDInputOutputSession(endpoint:endpoint,backendFactory:{ backend },lockFactory:{ nil },traceCapacity:4)
        let transport: any LogitechSessionTransport=session
        _=try await transport.exchange(HIDPPRequest(deviceIndex:2,featureIndex:1,command:.battery1000,softwareID:1))
        let trace=await transport.controlTraceSnapshot()
        #expect(trace.capacity == 4); #expect(trace.entries.count == 1); #expect(!trace.truncated)
        await transport.close()
    }
}
