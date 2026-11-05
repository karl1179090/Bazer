// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import Foundation
import LogitechHIDPP
import Testing

private actor ControllerDiscovery: BatteryMonitorDiscovery {
    private var continuation: AsyncStream<HIDDiscoveryEvent>.Continuation?
    let descriptor = HIDInterfaceDescriptor(registryEntryID: 1, usbParentRegistryEntryID: 1, vendorID: 0xABCD, productID: 1,
        product: "Offline controller target", transport: "USB", locationID: 1000, primaryUsage: .mouse, usages: [.mouse])
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [descriptor]) }
    func events() -> AsyncStream<HIDDiscoveryEvent> {
        let (stream, continuation) = AsyncStream<HIDDiscoveryEvent>.makeStream(); self.continuation = continuation
        continuation.yield(HIDDiscoveryEvent(kind: .initial, snapshot: snapshot())); return stream
    }
    func stop() { continuation?.finish() }
}
private actor ControllerAdapter: DeviceSettingsAdapter, DeviceProfileBacking {
    var settings = DeviceSettings(currentDPI: DPISetting(400), pollingRateHz: 500)
    private(set) var applyCalls = 0
    private var blocked: CheckedContinuation<Void, Never>?
    let blockFirst: Bool
    let mutateDuringExport: Bool
    init(blockFirst: Bool = false, mutateDuringExport: Bool = false) { self.blockFirst = blockFirst; self.mutateDuringExport = mutateDuringExport }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> DeviceSettings { settings }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) async -> SettingAdapterTransaction {
        applyCalls += 1
        let actual = settings
        guard actual == before.settings else { return SettingAdapterTransaction(before: actual, observed: actual, acknowledged: false, persistence: .runtime, superseded: true) }
        if blockFirst, applyCalls == 1 {
            await withCheckedContinuation { blocked = $0 }
            return SettingAdapterTransaction(before: actual, observed: nil, acknowledged: false, persistence: .unknown,
                failure: TelemetryFailure(category: .timeout, message: "Synthetic unknown first write"))
        }
        settings = DeviceSettings(currentDPI: request.change.currentDPI ?? settings.currentDPI, pollingRateHz: settings.pollingRateHz)
        return SettingAdapterTransaction(before: actual, observed: settings, acknowledged: true, persistence: .runtime)
    }
    func release() { blocked?.resume(); blocked = nil }
    func exportProfile(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, saveTo: URL, hardwareEvidenceReference: String?) throws -> ProfileBackup {
        let backup = ProfileBackup(capturedAt: Date(), identity: ProfileBackupIdentity(vendorID: 0xABCD, unitID: "offline-unit", formatID: "offline-profile", formatVersion: 1, descriptorSHA256: "offline-descriptor"), session: session,
            regions: [ProfileBackupRegion(id: "whole-image", bytes: [1,2,3,4])])
        try FileProfileBackup(url: saveTo).save(backup)
        if mutateDuringExport { settings = DeviceSettings(currentDPI: settings.currentDPI, pollingRateHz: 1000) }
        return backup
    }
    func prepareRestore(backupURL: URL, rollbackBackupURL: URL, target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, hardwareEvidenceReference: String?) throws -> DeviceSettingsChange {
        throw TelemetryFailure(category: .unsupported, message: "Not part of this fixture")
    }
}
private struct ControllerPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}
private func controllerRig(_ adapter: any DeviceSettingsAdapter) async throws -> (BatteryMonitor, DeviceController, DeviceSettingsSnapshot) {
    let capabilities = DeviceCapabilities(powerSource: .wired, operations: [
        .dpiRead: OperationCapability(evidence: .readVerified), .pollingRateRead: OperationCapability(evidence: .readVerified),
        .dpiWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, persistenceScopes: [.runtime, .onboard])),
        .pollingRateWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [125,500,1000], persistenceScopes: [.runtime, .onboard])),
        .onboardPersist: OperationCapability(evidence: .writeVerified)])
    let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.controller", identify: { descriptor in
        IdentifiedDevice(descriptor: descriptor, kind: .mouse, capabilities: capabilities, controlEndpointRegistryEntryID: 1)
    }, settingsAdapter: adapter)])
    let monitor = BatteryMonitor(discovery: ControllerDiscovery(), reader: registry, preferences: ControllerPreferences(), registry: registry)
    await monitor.start(); let snapshot = await monitor.initialDiscoveryReady()
    let controller = DeviceController(monitor: monitor)
    let state = try #require(snapshot.logicalDevices.first)
    return (monitor, controller, try await controller.readSettings(logicalDeviceID: state.id))
}
@Suite("Controller FIFO, cancellation and actual observations — offline", .timeLimit(.minutes(1)))
struct DeviceControllerTests {
    @Test func partialReadbackPublishesOnlyActualValues() async throws {
        let adapter = ControllerAdapter()
        let (monitor, controller, before) = try await controllerRig(adapter)
        let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(800), pollingRateHz: 1000))
        let result = await controller.apply(request)
        #expect(result.status == .partialFailure)
        #expect(result.observed?.settings.currentDPI == DPISetting(800))
        #expect(result.observed?.settings.pollingRateHz == 500)
        #expect(await monitor.snapshot().logicalDevices.first?.settings?.settings.pollingRateHz == 500)
        await monitor.stop()
    }
    @Test func cancellingQueuedChangeCannotSendAfterEarlierUnknownWriteReturns() async throws {
        let adapter = ControllerAdapter(blockFirst: true)
        let (monitor, controller, before) = try await controllerRig(adapter)
        let firstRequest = SettingChangeRequest(target: before.session, expectedRevision: before.revision, change: DeviceSettingsChange(currentDPI: DPISetting(800)))
        let first = Task { await controller.apply(firstRequest) }
        for _ in 0..<20_000 { if await adapter.applyCalls == 1 { break }; await Task.yield() }
        #expect(await adapter.applyCalls == 1)
        let secondRequest = SettingChangeRequest(target: before.session, expectedRevision: before.revision, change: DeviceSettingsChange(currentDPI: DPISetting(1200)))
        let second = Task { await controller.apply(secondRequest) }
        for _ in 0..<100 { await Task.yield() }
        second.cancel()
        await adapter.release()
        #expect(await first.value.status == .outcomeUnknown)
        #expect(await second.value.status == .superseded)
        #expect(await adapter.applyCalls == 1)
        #expect(await monitor.snapshot().logicalDevices.first?.settings?.revision == before.revision)
        await monitor.stop()
    }
    @Test func preparingVerifiedOnboardChangeSavesRecoveryAndRebindsOnlyUnchangedActualBefore() async throws {
        for mutate in [false, true] {
            let adapter = ControllerAdapter(mutateDuringExport: mutate)
            let (monitor, controller, before) = try await controllerRig(adapter)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("before.json")
            let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
                change: DeviceSettingsChange(currentDPI: DPISetting(800), persistence: .onboard))
            do {
                let prepared = try await controller.prepareOnboardChange(request, saveBackupTo: path)
                #expect(!mutate)
                #expect(prepared.target == request.target); #expect(prepared.change == request.change)
                #expect(prepared.expectedRevision > before.revision)
            } catch let failure as TelemetryFailure {
                #expect(mutate); #expect(failure.category == .cancelled)
            }
            #expect(FileManager.default.fileExists(atPath: path.path))
            #expect(await adapter.applyCalls == 0)
            if mutate { #expect(await monitor.snapshot().logicalDevices.first?.settings?.settings.pollingRateHz == 1000) }
            await monitor.stop()
        }
    }

}

private actor CollidingSettingsDriver: DeviceLogicalDriver, DeviceSettingsValidationAuthorizing, DeviceProfileBacking {
    private(set) var writes = 0
    private(set) var authorizations = 0
    private(set) var exports = 0
    private(set) var restores = 0
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) -> [LogicalDeviceDescriptor] {
        let identity = LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: "duplicated-handshake-unit")
        let capabilities = DeviceCapabilities(operations: [
            .dpiRead: OperationCapability(evidence: .readVerified),
            .dpiWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, persistenceScopes: [.runtime]))])
        return [UInt8(1), 2].map { slot in
            LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: session, target: .receiver(index: slot, identity: identity), pairingGeneration: session.generation),
                product: "Duplicate identity target", kind: .mouse, capabilities: capabilities, controlEndpointRegistryEntryID: 1)
        }
    }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async -> LogicalDeviceTelemetryResult {
        LogicalDeviceTelemetryResult(session: session, update: DeviceTelemetryUpdate(startedAt: Date(), finishedAt: Date(), battery: nil, batteryFailure: nil, charging: nil, chargingFailure: nil))
    }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> DeviceSettings { DeviceSettings(currentDPI: DPISetting(400)) }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) -> SettingAdapterTransaction {
        writes += 1
        return SettingAdapterTransaction(before: before.settings, observed: before.settings, acknowledged: true, persistence: .runtime)
    }
    func authorizeValidation(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor, operation: SettingValidationOperation) throws -> SettingValidationAuthorization {
        authorizations += 1
        throw TelemetryFailure(category: .unsupported, message: "This fixture must never be asked to grant an ambiguous target")
    }
    func exportProfile(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, saveTo: URL, hardwareEvidenceReference: String?) throws -> ProfileBackup {
        exports += 1
        let backup = ProfileBackup(capturedAt: Date(), identity: ProfileBackupIdentity(vendorID: 0x046D, unitID: "duplicated-handshake-unit", formatID: "offline-profile", formatVersion: 1, descriptorSHA256: "offline-hash"), session: session,
            regions: [ProfileBackupRegion(id: "sector", bytes: [1,2,3])])
        try FileProfileBackup(url: saveTo).save(backup); return backup
    }
    func prepareRestore(backupURL: URL, rollbackBackupURL: URL, target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, hardwareEvidenceReference: String?) -> DeviceSettingsChange {
        restores += 1; return DeviceSettingsChange(currentDPI: DPISetting(800))
    }
}
extension DeviceControllerTests {
    @Test func collidingUnitsCannotReachNormalWriteCandidateGrantOrStrongBackupRestore() async throws {
        let driver = CollidingSettingsDriver()
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.colliding-targets", identify: { host in
            IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly, isReceiver: true)
        }, logicalDriver: driver, settingsAdapter: driver)])
        let monitor = BatteryMonitor(discovery: ControllerDiscovery(), reader: registry, preferences: ControllerPreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start(); let initial = await monitor.initialDiscoveryReady()
        #expect(initial.logicalDevices.count == 2)
        #expect(initial.logicalDevices.allSatisfy { $0.descriptor.isIdentityAmbiguous && $0.descriptor.preferenceIdentity == nil })
        let controller = DeviceController(monitor: monitor), target = try #require(initial.logicalDevices.first)
        let before = try await controller.readSettings(logicalDeviceID: target.id)
        let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision, change: DeviceSettingsChange(currentDPI: DPISetting(800)))
        #expect(await controller.apply(request).status == .rejected)
        do { _ = try await controller.authorizeValidation(request, operation: .logitechHIDPP2201DPI); Issue.record("Ambiguous candidate grant was accepted") } catch {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do { _ = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: directory.appendingPathComponent("strong.json")); Issue.record("Ambiguous strong backup was accepted") } catch {}
        do { _ = try await controller.prepareProfileRestore(backupURL: directory.appendingPathComponent("previous-session.json"), rollbackBackupURL: directory.appendingPathComponent("rollback.json"), logicalDeviceID: target.id); Issue.record("Ambiguous restore was accepted") } catch {}
        #expect(await driver.writes == 0); #expect(await driver.authorizations == 0)
        #expect(await driver.exports == 0); #expect(await driver.restores == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("strong.json").path))
        await monitor.stop()
    }
}

// Production Logitech adapter and Controller share this value-only transport fixture.
private final class ControllerNVMAuthorizer: @unchecked Sendable {
    private let lock=NSLock()
    private var closure: (@Sendable (HIDPPRequest) throws -> Void)?
    func install(_ value: @escaping @Sendable (HIDPPRequest) throws -> Void) { lock.withLock { closure=value } }
    func check(_ request: HIDPPRequest) throws { try lock.withLock { try closure?(request) } }
}
private actor ControllerNVMReceiver: LogitechSessionTransport, HIDPPTransaction {
    nonisolated let authorizer=ControllerNVMAuthorizer()
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
    var writingLength=0, ignoreProfileWrites=false, tamperFinalPad=false, injectFailure=0, readbackPending=false
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
    func setFault(_ fault: Int) { injectFailure=fault }
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
            if sector == 1, readbackPending, injectFailure == 2 { readbackPending=false; throw HIDPPError.timeout }
            if sector == 1, readbackPending, injectFailure == 3, offset == 239 { readbackPending=false; var tail=Array(profile[239..<255]); tail[15] ^= 1; p=tail; break }
            let b=sector == 0 ? directory : profile
            guard Int(offset)+16 <= b.count else { throw HIDPPError.invalidValue("Synthetic firmware rejects read beyond physical sector") }
            p=Array(b[Int(offset)..<Int(offset)+16])
        case .startSectorWrite(_,let length):
            guard Int(length) == profile.count else { throw HIDPPError.invalidValue("Synthetic write count differs from physical size") }
            writingLength=Int(length); staging=[]; p=[]
        case .sectorWriteData: staging+=request.message.parameters; p=[]
        case .endSectorWrite:
            guard staging.count == ((writingLength+15)/16)*16, staging.dropFirst(writingLength).allSatisfy({ $0 == 0 }) else { throw HIDPPError.invalidValue("Invalid synthetic write data or final padding") }
            if !ignoreProfileWrites { profile=Array(staging.prefix(writingLength)) }
            readbackPending=true
            if injectFailure == 1 { profile[40] ^= 0x80; let crc=HIDPPCRC.ccitt(Array(profile.dropLast(2))); profile[253]=UInt8(crc >> 8); profile[254]=UInt8(crc & 255) }
            if injectFailure == 4 { profile[3]=0x90; profile[4]=1; let crc=HIDPPCRC.ccitt(Array(profile.dropLast(2))); profile[253]=UInt8(crc >> 8); profile[254]=UInt8(crc & 255) }
            p=[]
        default: throw HIDPPError.invalidValue("Unimplemented synthetic receiver command")
        }
        return try HIDPPMessage(bytes:[0x11]+request.message.bytes[1..<4]+p+[UInt8](repeating:0,count:16-p.count))
    }
}

private actor ControllerNVMDiscovery: BatteryMonitorDiscovery {
    let descriptor: HIDInterfaceDescriptor
    var continuation: AsyncStream<HIDDiscoveryEvent>.Continuation?
    init() {
        let raw: [UInt8]=[0x06,0,0xFF,9,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0]
        descriptor=HIDInterfaceDescriptor(registryEntryID:101,usbParentRegistryEntryID:10,vendorID:0x046D,productID:0xDEAD,product:"Controller synthetic receiver",transport:"USB",maxInputReportSize:20,maxOutputReportSize:20,reportDescriptor:raw)
    }
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt:Date(),interfaces:[descriptor]) }
    func events() -> AsyncStream<HIDDiscoveryEvent> {
        let pair=AsyncStream<HIDDiscoveryEvent>.makeStream(); continuation=pair.continuation
        continuation?.yield(HIDDiscoveryEvent(kind:.initial,snapshot:snapshot())); return pair.stream
    }
    func stop() { continuation?.finish() }
}
private struct ControllerNVMPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}

extension DeviceControllerTests {
    @Test(arguments: [0, 1, 2, 3, 4])
    func completeProfileVerificationFailureCannotBeOverruledByKnownFieldReadback(fault: Int) async throws {
        let fake = ControllerNVMReceiver()
        await fake.configure255ByteSectors(); await fake.setModeOnboard(); await fake.selectSyntheticStage(2)
        let driver = LogitechReceiverDriver(sessionFactory: { _, authorize in
            fake.authorizer.install(authorize); return fake
        })
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.controller.nvm",
            identify: LogitechReceiverDriver.identify, logicalDriver: driver, settingsAdapter: driver)])
        let monitor = BatteryMonitor(discovery: ControllerNVMDiscovery(), reader: registry,
            preferences: ControllerNVMPreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start()
        let initial = await monitor.initialDiscoveryReady()
        let target = try #require(initial.logicalDevices.first)
        let controller = DeviceController(monitor: monitor, registry: registry)
        let before = try await controller.readSettings(logicalDeviceID: target.id)
        let table = try #require(before.settings.stages)
        let requested = DPIStageTable(stages: table.stages.map {
            DPIStage(id: $0.id, dpi: $0.id == 0 ? DPISetting(800) : $0.dpi)
        }, activeStageID: table.activeStageID, opaqueBytes: table.opaqueBytes, defaultStageID: table.defaultStageID)
        let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
            change: DeviceSettingsChange(stages: requested, persistence: .onboard))
        let authorization = try await controller.authorizeValidation(request, operation: .logitechHIDPP8100Profile)
        await fake.setFault(fault)
        let result = await controller.applyValidation(request, authorization: authorization)
        let observed = try #require(result.observed)
        #expect(result.status == (fault == 0 ? .verified : (fault == 4 ? .readbackMismatch : .outcomeUnknown)))
        #expect(result.fields.first?.status == (fault == 0 ? .verified : (fault == 4 ? .readbackMismatch : .outcomeUnknown)))
        #expect(observed.settings.stages?.stages.first?.dpi == DPISetting(fault == 4 ? 400 : 800))
        #expect(observed.settings.stages?.opaqueBytes == (await fake.profile))
        #expect(await monitor.snapshot().logicalDevices.first?.settings?.settings == observed.settings)
        #expect(await fake.commands.filter(\.isWrite).count == 18)
        if fault != 0 { #expect(result.message?.contains("interruptedWrite") == true) }
        if fault == 1 { #expect(observed.settings.stages?.opaqueBytes[40] != table.opaqueBytes[40]) }
        await monitor.stop()
    }
}

private actor ControllerFailureAdapter: DeviceSettingsAdapter {
    static let original = DeviceSettings(currentDPI: DPISetting(400), pollingRateHz: 500)
    let observed: DeviceSettings?
    let acknowledged: Bool
    let failure: TelemetryFailure?
    let fieldFailures: [SettingField: TelemetryFailure]
    let failureScope: SettingFailureScope
    private(set) var applyCalls = 0
    init(observed: DeviceSettings?, acknowledged: Bool, failure: TelemetryFailure? = nil,
         fieldFailures: [SettingField: TelemetryFailure] = [:], failureScope: SettingFailureScope = .transaction) {
        self.observed = observed; self.acknowledged = acknowledged; self.failure = failure
        self.fieldFailures = fieldFailures; self.failureScope = failureScope
    }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> DeviceSettings { Self.original }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot,
                       target: LogicalDeviceDescriptor) -> SettingAdapterTransaction {
        applyCalls += 1
        return SettingAdapterTransaction(before: Self.original, observed: observed, acknowledged: acknowledged,
            persistence: .runtime, failure: failure, fieldFailures: fieldFailures, failureScope: failureScope)
    }
}
extension DeviceControllerTests {
    @Test(arguments: [false, true])
    func aNamedFieldFailureCannotBeVerifiedButIndependentReadbackSurvives(mismatch: Bool) async throws {
        let failure = TelemetryFailure(category: .timeout, message: "Synthetic polling-rate write timed out")
        let observed = DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: mismatch ? 500 : 1000)
        let adapter = ControllerFailureAdapter(observed: observed, acknowledged: false, failure: failure,
            fieldFailures: [.pollingRate: failure], failureScope: .perField)
        let (monitor, controller, before) = try await controllerRig(adapter)
        let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(800), pollingRateHz: 1000))
        let result = await controller.apply(request)
        #expect(result.status == .partialFailure)
        #expect(result.fields.first(where: { $0.field == .currentDPI })?.status == .verified)
        #expect(result.fields.first(where: { $0.field == .pollingRate })?.status == (mismatch ? .readbackMismatch : .outcomeUnknown))
        #expect(result.fields.first(where: { $0.field == .pollingRate })?.message == failure.message)
        #expect(result.observed?.settings == observed)
        #expect(await adapter.applyCalls == 1)
        await monitor.stop()
    }
    @Test(arguments: [0, 1, 2])
    func unscopedOrInvalidFieldFailuresConservativelyInvalidateMatchingFields(mode: Int) async throws {
        let failure = TelemetryFailure(category: .malformedResponse, message: "Synthetic full validation failure")
        let fields: [SettingField: TelemetryFailure] = mode == 0 ? [.pollingRate: failure] : (mode == 1 ? [:] : [.stages: failure])
        let observed = DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 1000)
        let adapter = ControllerFailureAdapter(observed: observed, acknowledged: true, failure: failure,
            fieldFailures: fields, failureScope: mode == 0 ? .transaction : .perField)
        let (monitor, controller, before) = try await controllerRig(adapter)
        let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(800), pollingRateHz: 1000))
        let result = await controller.apply(request)
        #expect(result.status == .outcomeUnknown)
        #expect(result.fields.allSatisfy { $0.status == .outcomeUnknown })
        #expect(result.observed?.settings == observed)
        await monitor.stop()
    }
    @Test func missingACKAloneDoesNotInvalidateIndependentReadback() async throws {
        let observed = DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 1000)
        let adapter = ControllerFailureAdapter(observed: observed, acknowledged: false)
        let (monitor, controller, before) = try await controllerRig(adapter)
        let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(800), pollingRateHz: 1000))
        let result = await controller.apply(request)
        #expect(result.status == .verified)
        #expect(result.fields.allSatisfy { $0.status == .verified })
        #expect(result.observed?.settings == observed)
        await monitor.stop()
    }
}

extension DeviceControllerTests {
    @Test(arguments: [0, 1, 2])
    func invalidSavedDefaultOrCurrentStageRejectsRestoreBeforeRollback(mode: Int) async throws {
        let fake = ControllerNVMReceiver()
        await fake.configure255ByteSectors(); await fake.setModeOnboard(); await fake.selectSyntheticStage(2)
        let driver = LogitechReceiverDriver(sessionFactory: { _, authorize in
            fake.authorizer.install(authorize); return fake
        })
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.controller.restore",
            identify: LogitechReceiverDriver.identify, logicalDriver: driver, settingsAdapter: driver)])
        let monitor = BatteryMonitor(discovery: ControllerNVMDiscovery(), reader: registry,
            preferences: ControllerNVMPreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start()
        let initial = await monitor.initialDiscoveryReady()
        let target = try #require(initial.logicalDevices.first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try await driver.exportProfile(target: target.descriptor, session: target.sessionID,
            saveTo: folder.appendingPathComponent("original.json"))
        let regions = original.regions.map { region in
            var bytes = region.bytes
            if region.id == "profile:1" {
                if mode == 2 { bytes[7] = 0; bytes[8] = 0 }
                else { bytes[1] = mode == 0 ? 4 : 254 }
                let crc = HIDPPCRC.ccitt(Array(bytes.dropLast(2)))
                bytes[253] = UInt8(crc >> 8); bytes[254] = UInt8(crc & 255)
            }
            if mode == 2 && region.id == "active-dpi-index" { bytes = [1] }
            return ProfileBackupRegion(id: region.id, bytes: bytes)
        }
        let saved = ProfileBackup(capturedAt: original.capturedAt, identity: original.identity, session: original.session,
            activeProfileID: original.activeProfileID, regions: regions)
        let backupURL = folder.appendingPathComponent("invalid.json"), rollbackURL = folder.appendingPathComponent("rollback.json")
        try FileProfileBackup(url: backupURL).save(saved)
        do {
            _ = try await driver.prepareRestore(backupURL: backupURL, rollbackBackupURL: rollbackURL,
                target: target.descriptor, session: target.sessionID)
            Issue.record("Invalid stage membership returned a restore draft")
        } catch let error as ProfileBackupError {
            #expect(error == .regionLayoutMismatch)
        }
        #expect(!FileManager.default.fileExists(atPath: rollbackURL.path))
        #expect(await fake.commands.allSatisfy { !$0.isWrite })
        #expect(await fake.profile == original.regions.first(where: { $0.id == "profile:1" })?.bytes)
        await monitor.stop()
    }
}
