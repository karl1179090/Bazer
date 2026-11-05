// SPDX-License-Identifier: GPL-3.0-or-later
// Compile only with -D GPW1_OFFLINE_TESTS. No real HID backend is constructed here.
import BazerCore
import BazerDrivers
import BazerHID
import CryptoKit
import Foundation
import LogitechHIDPP

private final class PersistenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var authorize: (@Sendable (HIDPPRequest) throws -> Void)?
    func install(_ authorize: @escaping @Sendable (HIDPPRequest) throws -> Void) { lock.withLock { self.authorize = authorize } }
    func check(_ request: HIDPPRequest) throws { try lock.withLock { try authorize?(request) } }
}
private final class PersistenceDiscovery: HIDDiscoveryBackend {
    let descriptor: HIDInterfaceDescriptor
    init(_ descriptor: HIDInterfaceDescriptor) { self.descriptor = descriptor }
    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) {}
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [descriptor]) }
    func inspectInterface(registryEntryID: UInt64) throws -> HIDInspectionResult { throw ExperimentError.rejected("Offline harness cannot open/inspect HID") }
    func stop() {}
}
private struct PersistencePreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}
private actor PersistenceDevice {
    private(set) var profile: [UInt8]
    let originalProfile: [UInt8]
    let directory: [UInt8]
    private(set) var current: UInt8 = 2
    private(set) var calls: [HIDPPCommand] = []
    private(set) var closes = 0, contexts = 0
    private var staging: [UInt8] = []
    private var driftOnWrite = false, omit450 = false, weakUnit = false, unknownFormat = false
    init() {
        var profile = (0..<255).map { UInt8(($0 * 17 + 7) & 255) }
        profile[0] = 1; profile[1] = 2; profile[2] = 1
        for (index, dpi) in [UInt16(400), 800, 1600, 3200, 6400].enumerated() {
            profile[3 + index * 2] = UInt8(dpi & 255); profile[4 + index * 2] = UInt8(dpi >> 8)
        }
        Self.seal(&profile); self.profile = profile; originalProfile = profile
        var directory = [UInt8](repeating: 255, count: 255)
        directory.replaceSubrange(0..<8, with: [0, 1, 1, 0, 255, 255, 0, 0]); Self.seal(&directory); self.directory = directory
    }
    private static func seal(_ bytes: inout [UInt8]) {
        let crc = HIDPPCRC.ccitt(Array(bytes.dropLast(2))); bytes[bytes.count - 2] = UInt8(crc >> 8); bytes[bytes.count - 1] = UInt8(crc & 255)
    }
    func nextContext() -> UInt64 { contexts += 1; return UInt64(100 + contexts) }
    func close() { closes += 1 }
    func setCurrent(_ value: UInt8) { current = value }
    func driftNextWrite() { driftOnWrite = true }
    func exclude450() { omit450 = true }
    func useWeakUnit() { weakUnit = true }
    func useUnknownFormat() { unknownFormat = true }
    func useInvalidDefault() { profile[1] = 5; Self.seal(&profile) }
    func macroDrift() { profile[40] ^= 1; Self.seal(&profile) }
    func response(_ request: HIDPPRequest) throws -> HIDPPMessage {
        calls.append(request.command)
        func be(_ number: UInt16) -> [UInt8] { [UInt8(number >> 8), UInt8(number & 255)] }
        let ids: [UInt16] = [0, 1, 3, 5, 0x2201, 0x8060, 0x8100]
        let name = Array("Offline persistence mouse".utf8)
        let payload: [UInt8]
        switch request.command {
        case .receiverInformation: payload = [3, 0, 0, 0, 0, 0, 1]
        case .pairing: payload = [0x20, 0, 0, 0xAB, 0xCD, 0, 0, 2]
        case .ping(let nonce): payload = [4, 2, nonce]
        case .lookupFeature(let id): payload = [ids.firstIndex(of: id).map(UInt8.init) ?? 0, 0, 0]
        case .featureCount: payload = [UInt8(ids.count - 1)]
        case .featureAt(let index): payload = be(ids[Int(index)]) + [0, 0]
        case .firmwareInfo: payload = [1] + (weakUnit ? [0, 0, 0, 0] : [1, 2, 3, 4]) + [0, 4, 0xAB, 0xCD, 0, 0, 0, 0]
        case .firmwareEntity: payload = [0, 70, 65, 75, 1, 2, 0, 3]
        case .nameLength: payload = [UInt8(name.count)]
        case .nameChunk(let offset): payload = Array(name.dropFirst(Int(offset)).prefix(16))
        case .deviceKind: payload = [3]
        case .sensorCount: payload = [1]
        case .dpiList:
            payload = omit450 ? [0] + [UInt16(400), 800, 1600, 3200, 6400, 0].flatMap(be) : [0] + be(100) + be(0xE032) + be(25600) + [0, 0]
        case .dpi:
            let offset = 3 + Int(current) * 2
            payload = [0] + be(UInt16(profile[offset]) | UInt16(profile[offset + 1]) << 8) + be(800)
        case .rateCapabilities: payload = [0b10001011]
        case .rate: payload = [profile[0]]
        case .onboardInfo: payload = [1, unknownFormat ? 4 : 3, 1, 5, 1, 8, 16, 0, 255, 10, 4]
        case .onboardMode: payload = [1]
        case .activeProfile: payload = [0, 1]
        case .activeDPIIndex: payload = [current]
        case .setActiveDPIIndex(let index): current = index; payload = []
        case .readSector(let sector, let offset):
            try requireExperiment(Int(offset) + 16 <= 255, "Production reader exceeded the physical sector")
            let bytes = sector == 0 ? directory : profile; payload = Array(bytes[Int(offset)..<Int(offset) + 16])
        case .startSectorWrite(let sector, let length):
            try requireExperiment(sector == 1 && length == 255, "Wrong experimental write sector/physical length")
            staging = []; payload = []
        case .sectorWriteData(let chunk): staging += chunk; payload = []
        case .endSectorWrite:
            try requireExperiment(staging.count == 256 && staging.last == 0, "255-byte write did not have an exact zero-padded tail")
            profile = Array(staging.prefix(255))
            if driftOnWrite { driftOnWrite = false; profile[40] ^= 1; Self.seal(&profile) }
            payload = []
        default: throw ExperimentError.rejected("Unexpected fake protocol command")
        }
        return try HIDPPMessage(bytes: [0x11] + Array(request.message.bytes[1..<4]) + payload + Array(repeating: 0, count: 16 - payload.count), receivedAt: Date())
    }
}
private actor PersistenceTransport: LogitechSessionTransport, HIDPPTransaction {
    nonisolated let gate = PersistenceGate()
    let device: PersistenceDevice
    let events = AsyncStream<HIDPPMessage>.makeStream()
    init(_ device: PersistenceDevice) { self.device = device }
    func notifications() -> AsyncStream<HIDPPMessage> { events.stream }
    func acquireTransaction() -> any HIDPPTransaction { self }
    func finish() {}
    func close() async { events.continuation.finish(); await device.close() }
    func exchange(_ request: HIDPPRequest) async throws -> HIDPPMessage { try gate.check(request); return try await device.response(request) }
}

enum GPW1PersistenceOfflineHarness {
    private static let descriptorBytes: [UInt8] = [0x06, 0, 0xFF, 9, 1, 0xA1, 1, 0x75, 8, 0x85, 0x10, 0x95, 6, 0x81, 2,
        0x91, 2, 0x85, 0x11, 0x95, 19, 0x81, 2, 0x91, 2, 0xC0]
    private static var identity: StrongExperimentIdentity {
        let descriptor = HIDInterfaceDescriptor(registryEntryID: 501, usbParentRegistryEntryID: 101, vendorID: 0x046D, productID: 0xFAFA,
            product: "Offline host", transport: "USB", reportDescriptor: descriptorBytes)
        return StrongExperimentIdentity(unitSHA256: unitDigest("01020304")!, firmware: "0:0046414B010200030000000000000000",
            descriptorSHA256: descriptor.descriptorSHA256, hostVendorID: 0x046D, hostProductID: 0xFAFA, wirelessProductID: 0xABCD, protocolVersion: "4.2")
    }
    private static func factory(_ device: PersistenceDevice) -> GPW1PersistenceExperiment.ContextFactory {
        { expected, readOnly in
            let hostID = await device.nextContext()
            let descriptor = HIDInterfaceDescriptor(registryEntryID: hostID + 400, usbParentRegistryEntryID: hostID,
                vendorID: 0x046D, productID: 0xFAFA, product: "Offline host", transport: "USB", reportDescriptor: descriptorBytes)
            let discovery = HIDDiscovery(backendFactory: { PersistenceDiscovery(descriptor) })
            let transport = PersistenceTransport(device)
            let driver = LogitechReceiverDriver(sessionFactory: { _, authorize in
                transport.gate.install { request in try ExperimentContext.authorizePhase(request, readOnly: readOnly); try authorize(request) }
                return transport
            })
            let registry = DriverRegistry(registrations: DriverRegistry.standardRegistrations(logitech: driver))
            let monitor = BatteryMonitor(discovery: discovery, reader: registry, preferences: PersistencePreferences(),
                registry: registry, automaticallyRefreshTelemetry: false)
            await monitor.start()
            let snapshot = await monitor.initialDiscoveryReady()
            let targets = snapshot.logicalDevices.filter { expected.matches($0, hosts: snapshot.devices) }
            guard snapshot.discoveryFailure == nil, targets.count == 1 else {
                await monitor.stop(); throw ExperimentError.rejected("Offline strong identity did not match")
            }
            return ExperimentContext(monitor: monitor, controller: DeviceController(monitor: monitor, registry: registry), target: targets[0], identity: expected)
        }
    }
    private static func reject(_ message: String, _ operation: () async throws -> Void) async throws {
        var failed = false
        do { try await operation() } catch { failed = true }
        try requireExperiment(failed, message)
    }
    private static func reference(in folder: URL) throws -> ExperimentFile {
        let record: [String: Any] = ["hostVendorID": identity.hostVendorID, "hostProductID": identity.hostProductID,
            "wirelessProductID": identity.wirelessProductID, "identityAmbiguous": false, "unitIdentitySHA256": identity.unitSHA256,
            "firmware": identity.firmware, "controlDescriptorSHA256": identity.descriptorSHA256, "protocolVersion": identity.protocolVersion]
        let bytes = try JSONSerialization.data(withJSONObject: [record], options: [.sortedKeys])
        let path = folder.appendingPathComponent("reference-" + UUID().uuidString + ".json")
        try LocalPrivateFile(url: path).writeNew(bytes); return ExperimentFile(path: path.path, sha256: digest(bytes))
    }
    private static func options(_ phase: String, _ file: ExperimentFile) throws -> ExperimentOptions {
        let key = phase == "apply" ? "--reference" : "--manifest"
        return try ExperimentOptions.parse([phase, key, file.path, key + "-sha256", file.sha256])
    }
    static func run() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/gpw1-persistence-offline-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        // Foundation canonicalizes the existing macOS /private/tmp alias to /tmp.
        let files = ExperimentFiles(root: folder.standardizedFileURL.appendingPathComponent("HardwareBackups", isDirectory: true))
        let reference = try Self.reference(in: folder), device = PersistenceDevice()
        let apply = try await GPW1PersistenceExperiment.execute(options("apply", reference), files: files, factory: factory(device))
        try requireExperiment(apply.state == "verifiedAwaitingUserPowerCycle" && !apply.physicalPowerCycleVerifiedByTool, "Apply incorrectly claimed physical persistence")
        try files.validatePath(URL(fileURLWithPath: apply.manifest.path)); try files.validatePath(URL(fileURLWithPath: apply.capturedBackup.path))
        let manifestBytes = try files.checkedData(apply.manifest)
        try await reject("Existing manifest was overwritten") { _ = try files.write(["collision": true], to: URL(fileURLWithPath: apply.manifest.path)) }
        try requireExperiment(try files.checkedData(apply.manifest) == manifestBytes, "Rejected overwrite changed manifest bytes")
        let link = URL(fileURLWithPath: apply.manifest.path).deletingLastPathComponent().appendingPathComponent("fixture-symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: apply.manifest.path))
        try await reject("Manifest symlink was followed") { _ = try files.checkedData(ExperimentFile(path: link.path, sha256: apply.manifest.sha256)) }
        try requireExperiment(await device.closes == 1, "Apply did not drain/close its session")
        let writesAfterApply = await device.calls.filter(\.isWrite).count
        // An external power-cycle may select a different stage. Observe must not fix it.
        await device.setCurrent(0)
        let observe = try await GPW1PersistenceExperiment.execute(options("observe", apply.manifest), files: files, factory: factory(device))
        try requireExperiment(observe.profileBytesMatch && !observe.allRegionsMatch && observe.currentStageID == 0
            && !observe.physicalPowerCycleVerifiedByTool && observe.currentSelector != apply.currentSelector, "Observe did not preserve the explicit stage difference/dynamic selector")
        try requireExperiment(await device.calls.filter(\.isWrite).count == writesAfterApply, "Observe sent a settings write")
        let restored = try await GPW1PersistenceExperiment.execute(options("restore", apply.manifest), files: files, factory: factory(device))
        try requireExperiment(restored.allRegionsMatch && restored.runtimeStageRestoreApplied, "Restore did not verify complete original/current stage")
        let restoredProfile = await device.profile, restoredIndex = await device.current
        try requireExperiment(restoredProfile == device.originalProfile && restoredIndex == 2, "Restore did not restore exact physical bytes and stage")
        let writesAfterRestore = await device.calls.filter(\.isWrite).count
        _ = try await GPW1PersistenceExperiment.execute(options("restore", apply.manifest), files: files, factory: factory(device))
        try requireExperiment(await device.calls.filter(\.isWrite).count == writesAfterRestore, "Already-original restore sent a no-op setting probe")
        let output = try String(decoding: JSONEncoder().encode(restored), as: UTF8.self)
        try requireExperiment(!output.contains("01020304") && !output.contains("profileBytes\"") && !output.contains("unitID"), "Ordinary output leaked private identity/profile bytes")

        let disallowed = PersistenceDevice(); await disallowed.exclude450()
        try await reject("Illegal DPI domain did not fail closed") { _ = try await GPW1PersistenceExperiment.execute(options("apply", reference), files: files, factory: factory(disallowed)) }
        try requireExperiment(await disallowed.calls.allSatisfy { !$0.isWrite }, "Preflight rejection sent settings")
        let weak = PersistenceDevice(); await weak.useWeakUnit()
        try await reject("Weak unit identity reached apply") { _ = try await GPW1PersistenceExperiment.execute(options("apply", reference), files: files, factory: factory(weak)) }
        try requireExperiment(await weak.calls.allSatisfy { !$0.isWrite }, "Weak identity rejection sent settings")
        let unknown = PersistenceDevice(); await unknown.useUnknownFormat()
        try await reject("Unknown profile layout reached apply") { _ = try await GPW1PersistenceExperiment.execute(options("apply", reference), files: files, factory: factory(unknown)) }
        try requireExperiment(await unknown.calls.allSatisfy { !$0.isWrite }, "Unknown format rejection sent settings")
        let invalidDefault = PersistenceDevice(); await invalidDefault.useInvalidDefault()
        try await reject("Missing default stage was allowed into a recovery plan") { _ = try await GPW1PersistenceExperiment.execute(options("apply", reference), files: files, factory: factory(invalidDefault)) }
        try requireExperiment(await invalidDefault.calls.allSatisfy { !$0.isWrite }, "Invalid current/default restoration plan sent settings")

        let drift = PersistenceDevice(); await drift.driftNextWrite()
        let directoriesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: files.root.path))
        try await reject("Valid-CRC opaque readback drift advanced the experiment") { _ = try await GPW1PersistenceExperiment.execute(options("apply", reference), files: files, factory: factory(drift)) }
        let newDirectories = Set(try FileManager.default.contentsOfDirectory(atPath: files.root.path)).subtracting(directoriesBefore)
        try requireExperiment(newDirectories.count == 1, "Failed experiment evidence was not identifiable")
        let failedDirectory = files.root.appendingPathComponent(newDirectories.first!)
        let failedFiles = try FileManager.default.contentsOfDirectory(atPath: failedDirectory.path)
        try requireExperiment(failedFiles.contains("prepared-intent.json") && failedFiles.contains("before.json") && !failedFiles.contains("manifest.json"), "Uncertain write lost intent/original or emitted a success manifest")
        try requireExperiment(await drift.calls.filter { if case .startSectorWrite = $0 { return true }; return false }.count == 1, "Failed write was replayed or automatically restored")

        let altered = PersistenceDevice()
        let alteredApply = try await GPW1PersistenceExperiment.execute(options("apply", reference), files: files, factory: factory(altered))
        await altered.macroDrift()
        let alteredWrites = await altered.calls.filter(\.isWrite).count
        try await reject("Unknown macro/opaque drift was allowed into restore") { _ = try await GPW1PersistenceExperiment.execute(options("restore", alteredApply.manifest), files: files, factory: factory(altered)) }
        try requireExperiment(await altered.calls.filter(\.isWrite).count == alteredWrites, "Unknown-byte rejection wrote settings")
        let manifest = try JSONDecoder().decode(ExperimentManifest.self, from: files.checkedData(alteredApply.manifest))
        let beforeURL = URL(fileURLWithPath: manifest.before.path)
        var modified = try Data(contentsOf: beforeURL); modified.append(10); try modified.write(to: beforeURL)
        let contextsBefore = await altered.contexts
        try await reject("Changed before-file hash reached discovery") { _ = try await GPW1PersistenceExperiment.execute(options("restore", alteredApply.manifest), files: files, factory: factory(altered)) }
        try requireExperiment(await altered.contexts == contextsBefore, "Changed file hash was checked after hardware discovery")

        let write = try HIDPPRequest(deviceIndex: 1, featureIndex: 6, command: .setActiveDPIIndex(2), softwareID: 1)
        try await reject("Observe phase gate accepted a setter") { try ExperimentContext.authorizePhase(write, readOnly: true) }
        let invalid = ["apply", "--reference", reference.path, "--reference-sha256", reference.sha256, "--dpi", "450"]
        try await reject("Unexpected edit option accepted") { _ = try ExperimentOptions.parse(invalid) }
        let badHash = ExperimentOptions(phase: .apply, input: URL(fileURLWithPath: reference.path), inputSHA256: String(repeating: "0", count: 64),
            powerCycleEvidence: nil, powerCycleEvidenceSHA256: nil)
        let beforeBadHash = await device.contexts
        try await reject("Changed reference hash reached discovery") { _ = try await GPW1PersistenceExperiment.execute(badHash, files: files, factory: factory(device)) }
        try requireExperiment(await device.contexts == beforeBadHash, "Reference hash failed after hardware discovery")
        print("Offline persistence harness passed: exact apply/observe/restore, 255-byte NVM, strong identity, zero-write guards, private files, hash tamper, valid-CRC opaque drift, no replay/automatic recovery, dynamic host and stop/drain. No real HID backend was constructed.")
    }
}
