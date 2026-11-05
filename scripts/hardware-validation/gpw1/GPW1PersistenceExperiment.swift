// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone, explicit experiment. Only the root agent may execute hardware phases.
// This does not relax HIDProbe's --restore-original contract or add a product command.
import BazerCore
import BazerDrivers
import BazerHID
import CryptoKit
import Darwin
import Foundation
import LogitechHIDPP

enum ExperimentError: Error, CustomStringConvertible {
    case rejected(String)
    var description: String { switch self { case .rejected(let message): message } }
}
func requireExperiment(_ value: Bool, _ message: String) throws {
    guard value else { throw ExperimentError.rejected(message) }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func unitDigest(_ unit: String?) -> String? { unit.map { digest(Data($0.utf8)) } }
func validDigest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

struct ExperimentOptions {
    enum Phase: String { case apply, observe, restore }
    let phase: Phase
    let input: URL
    let inputSHA256: String
    let powerCycleEvidence: URL?
    let powerCycleEvidenceSHA256: String?
    static let usage = """
    Root-only standalone experiment; hardware access starts only in an explicit phase.
      gpw1-persistence apply --reference <current-capabilities.json> --reference-sha256 <sha256>
      gpw1-persistence observe --manifest <private-manifest.json> --manifest-sha256 <sha256> [--power-cycle-evidence <root-record.json> --power-cycle-evidence-sha256 <sha256>]
      gpw1-persistence restore --manifest <private-manifest.json> --manifest-sha256 <sha256>
    apply changes only profile 1's non-current stage 0 from 400 to 450 DPI and exits.
    observe never writes settings. Physical power-cycle evidence is an external attestation.
    restore is explicit and restores profile bytes, then original current stage 2 if needed.
    All backup/manifest/evidence files are new private files under HardwareBackups.
    No phase retries, replays a write, changes mode, or automatically restores another phase.
    """
    static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let phase = Phase(rawValue: first) else { throw ExperimentError.rejected(usage) }
        var values: [String: String] = [:], index = 1
        while index < arguments.count {
            let name = arguments[index]
            guard index + 1 < arguments.count, values[name] == nil else { throw ExperimentError.rejected("Missing or repeated option") }
            values[name] = arguments[index + 1]; index += 2
        }
        let pathKey = phase == .apply ? "--reference" : "--manifest"
        let hashKey = pathKey + "-sha256"
        let evidenceKeys: Set<String> = phase == .observe ? ["--power-cycle-evidence", "--power-cycle-evidence-sha256"] : []
        try requireExperiment(Set(values.keys).isSubset(of: Set([pathKey, hashKey]).union(evidenceKeys)), "Unsupported phase option")
        guard let path = values[pathKey], path.hasPrefix("/"), let hash = values[hashKey], validDigest(hash) else {
            throw ExperimentError.rejected("An absolute input path and exact lowercase SHA256 are required")
        }
        let evidence = values["--power-cycle-evidence"], evidenceHash = values["--power-cycle-evidence-sha256"]
        try requireExperiment((evidence == nil) == (evidenceHash == nil), "Power-cycle evidence requires both path and SHA256")
        if let evidence, let evidenceHash { try requireExperiment(evidence.hasPrefix("/") && validDigest(evidenceHash), "Invalid external evidence reference") }
        return Self(phase: phase, input: URL(fileURLWithPath: path), inputSHA256: hash,
            powerCycleEvidence: evidence.map { URL(fileURLWithPath: $0) }, powerCycleEvidenceSHA256: evidenceHash)
    }
}

struct StrongExperimentIdentity: Codable, Equatable, Sendable {
    let unitSHA256: String
    let firmware: String
    let descriptorSHA256: String
    let hostVendorID: UInt16
    let hostProductID: UInt16
    let wirelessProductID: UInt16
    let protocolVersion: String
    static func reference(_ bytes: Data) throws -> Self {
        let json = try JSONSerialization.jsonObject(with: bytes)
        let records: [[String: Any]]
        if let array = json as? [[String: Any]] { records = array }
        else if let object = json as? [String: Any], let target = object["target"] as? [String: Any] { records = [target] }
        else if let object = json as? [String: Any] { records = [object] }
        else { throw ExperimentError.rejected("Reference is not a diagnostic identity envelope") }
        let matches = records.compactMap { record -> Self? in
            guard (record["hostVendorID"] as? NSNumber)?.uint16Value == 0x046D,
                  record["identityAmbiguous"] as? Bool == false,
                  let unit = record["unitIdentitySHA256"] as? String, validDigest(unit),
                  let firmware = record["firmware"] as? String, !firmware.isEmpty,
                  let descriptor = record["controlDescriptorSHA256"] as? String, validDigest(descriptor),
                  let pid = record["hostProductID"] as? NSNumber,
                  let wpid = record["wirelessProductID"] as? NSNumber,
                  let version = record["protocolVersion"] as? String, !version.isEmpty else { return nil }
            return Self(unitSHA256: unit, firmware: firmware, descriptorSHA256: descriptor,
                hostVendorID: 0x046D, hostProductID: pid.uint16Value, wirelessProductID: wpid.uint16Value, protocolVersion: version)
        }
        try requireExperiment(matches.count == 1, "Reference must contain exactly one confirmed Logitech unit")
        return matches[0]
    }
    func matches(_ target: LogicalDeviceState, hosts: [DeviceState]) -> Bool {
        guard !target.descriptor.isIdentityAmbiguous, target.hostPresence == .present,
              let identity = target.descriptor.peripheralIdentity,
              let host = hosts.first(where: { $0.id == target.sessionID.address.hostSessionID.physicalDeviceID }),
              let endpoint = host.descriptor.interfaces.first(where: { $0.registryEntryID == target.descriptor.controlEndpointRegistryEntryID }) else { return false }
        return unitDigest(identity.unitID) == unitSHA256 && identity.firmware == firmware
            && identity.wirelessProductID == wirelessProductID && identity.protocolVersion == protocolVersion
            && host.descriptor.vendorID == hostVendorID && host.descriptor.productID == hostProductID
            && endpoint.descriptorSHA256 == descriptorSHA256
    }
    func validate(_ backup: ProfileBackup) throws {
        try backup.validateIntegrity()
        try requireExperiment(unitDigest(backup.identity.unitID) == unitSHA256 && backup.identity.firmware == firmware
            && backup.identity.descriptorSHA256 == descriptorSHA256 && backup.identity.vendorID == hostVendorID
            && backup.identity.productID == hostProductID && backup.identity.wirelessProductID == wirelessProductID,
            "Backup strong unit, firmware or endpoint identity mismatch")
    }
}

struct ExperimentFile: Codable, Equatable, Sendable { let path: String, sha256: String }
struct SafeExperimentSettings: Codable, Equatable, Sendable {
    let currentDPI: DPISetting?
    let pollingRateHz: Int?
    let stages: [DPIStage]
    let defaultStageID: UInt8?
    let currentStageID: UInt8?
    let activeProfileID: Int?
    init(_ settings: DeviceSettings) {
        currentDPI = settings.currentDPI; pollingRateHz = settings.pollingRateHz; stages = settings.stages?.stages ?? []
        defaultStageID = settings.stages?.defaultStageID; currentStageID = settings.currentStageID; activeProfileID = settings.activeProfileID
    }
}
struct ExperimentManifest: Codable, Sendable {
    let schemaVersion: Int
    let phase: String
    let createdAt: Date
    let identity: StrongExperimentIdentity
    let reference: ExperimentFile
    let before: ExperimentFile
    let after: ExperimentFile?
    let preparedIntent: ExperimentFile?
    let beforeRegionHashes: [String: String]
    let expectedAfterRegionHashes: [String: String]
    let originalSettings: SafeExperimentSettings
    let profileID: Int
    let stageID: UInt8
    let originalDPI: UInt16
    let experimentDPI: UInt16
    let originalCurrentStageID: UInt8
}
struct ExperimentResult: Encodable {
    let phase: String
    let state: String
    let manifest: ExperimentFile
    let capturedBackup: ExperimentFile
    let unitSHA256: String
    let currentSelector: String
    let currentStageID: UInt8
    let profileBytesMatch: Bool
    let allRegionsMatch: Bool
    let runtimeStageRestoreApplied: Bool
    let physicalPowerCycleVerifiedByTool = false
    let externalPowerCycleAttestation: ExperimentFile?
}

struct ExperimentFiles: Sendable {
    let root: URL
    static var live: Self {
        Self(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bazer/HardwareBackups", isDirectory: true))
    }
    func newDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireExperiment(root.standardizedFileURL.path == root.resolvingSymlinksInPath().path, "Backup root cannot contain symlink components")
        let directory = root.appendingPathComponent("gpw1-persistence-" + UUID().uuidString, isDirectory: true)
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw ExperimentError.rejected("Cannot exclusively create experiment directory") }
        return directory
    }
    func validatePath(_ url: URL, mustExist: Bool = true) throws {
        let path = url.standardizedFileURL.path
        try requireExperiment(path.hasPrefix(root.standardizedFileURL.path + "/") && path == url.path
            && path == url.resolvingSymlinksInPath().path, "Private experiment path is outside the backup root or traverses a symlink")
        if mustExist {
            var status = stat()
            try requireExperiment(lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
                && status.st_mode & 0o777 == 0o600 && status.st_uid == getuid(), "Experiment file must be a user-owned regular 0600 file")
        } else { try requireExperiment(!FileManager.default.fileExists(atPath: path), "Experiment output already exists") }
    }
    func record(_ url: URL) throws -> ExperimentFile {
        try validatePath(url)
        return ExperimentFile(path: url.path, sha256: digest(try LocalPrivateFile(url: url).read(maximumBytes: 8 * 1_048_576)))
    }
    func checkedData(_ file: ExperimentFile) throws -> Data {
        let url = URL(fileURLWithPath: file.path); try validatePath(url)
        let bytes = try LocalPrivateFile(url: url).read(maximumBytes: 8 * 1_048_576)
        try requireExperiment(validDigest(file.sha256) && digest(bytes) == file.sha256, "Experiment file SHA256 changed")
        return bytes
    }
    func backup(_ file: ExperimentFile) throws -> ProfileBackup {
        let backup = try JSONDecoder().decode(ProfileBackup.self, from: checkedData(file)); try backup.validateIntegrity(); return backup
    }
    func write<T: Encodable>(_ value: T, to url: URL) throws -> ExperimentFile {
        try validatePath(url, mustExist: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalPrivateFile(url: url).writeNew(encoder.encode(value)); return try record(url)
    }
}

struct ExperimentPlan {
    let before: ProfileBackup
    let expectedAfterRegions: [String: [UInt8]]
    let change: DeviceSettingsChange
    static func regions(_ backup: ProfileBackup) -> [String: [UInt8]] { Dictionary(uniqueKeysWithValues: backup.regions.map { ($0.id, $0.bytes) }) }
    static func hashes(_ regions: [String: [UInt8]]) -> [String: String] { regions.mapValues { digest(Data($0)) } }
    static func checkedImage(_ backup: ProfileBackup, identity: StrongExperimentIdentity) throws -> (HIDPPProfileSector, UInt8) {
        try identity.validate(backup)
        let map = regions(backup)
        try requireExperiment(backup.identity.formatID == "logitech.hidpp8100.profile3" && backup.identity.formatVersion == 1
            && backup.activeProfileID == 1 && Set(map.keys) == Set(["info", "mode", "active-dpi-index", "directory:0", "profile:1"]), "Unknown backup format or region layout")
        let info = try HIDPPOnboardInfo.parse(map["info"]!)
        try requireExperiment(info.knownWritableLayout && map["mode"] == [1] && map["active-dpi-index"]?.count == 1,
            "Unknown writable profile layout or device is not already in onboard mode")
        let profile = try HIDPPProfileSector(sector: 1, bytes: map["profile:1"]!, info: info)
        let directory = try HIDPPProfileSector(sector: 0, bytes: map["directory:0"]!, info: info)
        let entries = try HIDPPProfileDirectoryEntry.parse(directory)
        try requireExperiment(entries.contains { $0.sector == 1 && $0.enabled }, "Profile 1 is absent, disabled or read-only")
        let index = map["active-dpi-index"]![0]
        try requireExperiment(index < 5 && (profile.dpiValues?[Int(index)] ?? 0) > 0, "Unknown current DPI stage")
        return (profile, index)
    }
    init(before: ProfileBackup, settings: DeviceSettings, capabilities: DeviceCapabilities, identity: StrongExperimentIdentity) throws {
        let (profile, index) = try Self.checkedImage(before, identity: identity)
        guard let table = settings.stages else { throw ExperimentError.rejected("No complete known stage table") }
        let decodedIDs = (profile.dpiValues ?? []).enumerated().filter { $0.element > 0 }.map { UInt8($0.offset) }
        try requireExperiment(table.isValid && table.stages.map(\.id) == decodedIDs
            && table.stages.allSatisfy { $0.dpi.x == $0.dpi.y && capabilities[.dpiRead].constraints.accepts(Int($0.dpi.x)) },
            "Original current/default stage, identifiers or DPI domain is not valid")
        try requireExperiment(index == 2 && settings.currentStageID == 2 && table.activeStageID == 2
            && settings.activeProfileID == 1 && table.opaqueBytes == profile.bytes && table.defaultStageID == profile.bytes[1], "Original profile/current/default stage differs from the explicit experiment")
        try requireExperiment(profile.dpiValues?[0] == 400 && table.stages.first(where: { $0.id == 0 })?.dpi == DPISetting(400)
            && settings.currentDPI == table.stages.first(where: { $0.id == 2 })?.dpi,
            "Stage 0 must be the existing non-current 400 DPI stage")
        try requireExperiment(capabilities[.dpiRead].constraints.accepts(400) && capabilities[.dpiRead].constraints.accepts(450), "400/450 are outside the discovered DPI domain")
        let storedRate = try HIDPPReportRate(code: profile.bytes[0], extended: false)
        try requireExperiment(settings.pollingRateHz == storedRate.hertz, "Runtime/profile rate differs before the experiment")
        let updated = try profile.patch(dpi: [0: 450])
        var expected = Self.regions(before); expected["profile:1"] = updated.bytes
        expectedAfterRegions = expected; self.before = before
        change = DeviceSettingsChange(stages: DPIStageTable(stages: table.stages.map {
            DPIStage(id: $0.id, dpi: $0.id == 0 ? DPISetting(450) : $0.dpi)
        }, activeStageID: table.activeStageID, opaqueBytes: table.opaqueBytes, defaultStageID: table.defaultStageID), persistence: .onboard)
    }
    static func compare(_ actual: ProfileBackup, expected: [String: [UInt8]], identity: StrongExperimentIdentity,
                        allowCurrentStageDifference: Bool) throws -> Bool {
        _ = try checkedImage(actual, identity: identity)
        let current = regions(actual)
        try requireExperiment(Set(current.keys) == Set(expected.keys), "Backup regions changed")
        for (id, bytes) in expected where !(allowCurrentStageDifference && id == "active-dpi-index") {
            try requireExperiment(current[id] == bytes, "Complete region differs from the exact experiment image: " + id)
        }
        return current == expected
    }
    static func validateRecovery(_ request: SettingChangeRequest, original: ProfileBackup, current: ProfileBackup,
                                 capabilities: DeviceCapabilities, identity: StrongExperimentIdentity) throws {
        let (saved, _) = try checkedImage(original, identity: identity)
        let (now, index) = try checkedImage(current, identity: identity)
        let savedStages = (saved.dpiValues ?? []).enumerated().filter { $0.element > 0 }.map { DPIStage(id: UInt8($0.offset), dpi: DPISetting($0.element)) }
        let rate = try HIDPPReportRate(code: saved.bytes[0], extended: false)
        guard let table = request.change.stages else { throw ExperimentError.rejected("Complete restoration table is missing") }
        try requireExperiment(request.change.persistence == .onboard && Set(request.change.fields) == Set([.stages, .pollingRate])
            && table.isValid && table.stages == savedStages && table.activeStageID == index && table.defaultStageID == saved.bytes[1]
            && table.opaqueBytes == now.bytes && request.change.pollingRateHz == rate.hertz
            && savedStages.allSatisfy { capabilities[.dpiRead].constraints.accepts(Int($0.dpi.x)) }
            && capabilities[.pollingRateRead].constraints.accepts(rate.hertz),
            "Complete restoration requires valid existing current/default IDs, the same stages, preserved raw bytes and discovered legal values")
    }
}

private struct ExperimentMemoryPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}
struct ExperimentContext: Sendable {
    let monitor: BatteryMonitor
    let controller: DeviceController
    let target: LogicalDeviceState
    let identity: StrongExperimentIdentity
    static func authorizePhase(_ request: HIDPPRequest, readOnly: Bool) throws {
        try requireExperiment(!readOnly || !request.command.isWrite, "Observe transport rejects every setting write")
    }
    func requireCurrent() async throws {
        let snapshot = await monitor.snapshot()
        try requireExperiment(snapshot.isMonitoring && !snapshot.isSuspended && snapshot.logicalDevices.contains {
            $0.id == target.id && $0.sessionID == target.sessionID && identity.matches($0, hosts: snapshot.devices)
        }, "The exact logical session changed during this phase")
    }
    func read() async throws -> DeviceSettingsSnapshot {
        try await requireCurrent()
        let result = try await controller.readSettings(logicalDeviceID: target.id)
        try await requireCurrent(); return result
    }
    func export(to url: URL) async throws -> ProfileBackup {
        try await requireCurrent()
        let backup = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: url)
        try await requireCurrent(); try identity.validate(backup); return backup
    }
    static func live(identity: StrongExperimentIdentity, readOnly: Bool) async throws -> Self {
        let discovery = HIDDiscovery()
        do {
            let passive = try await discovery.snapshot()
            let hosts = Set(passive.devices.filter { host in
                host.vendorID == identity.hostVendorID && host.productID == identity.hostProductID
                    && host.interfaces.filter { $0.descriptorSHA256 == identity.descriptorSHA256
                        && (try? HIDInputOutputEndpoint(physicalDeviceID: host.id, descriptor: $0)) != nil }.count == 1
            }.map(\.id))
            try requireExperiment(!hosts.isEmpty, "No current descriptor-confirmed host matches the reference")
            let driver = LogitechReceiverDriver(sessionFactory: { endpoint, authorize in
                HIDInputOutputSession(endpoint: endpoint, traceCapacity: 0, authorize: { request in
                    try requireExperiment(endpoint.descriptor.descriptorSHA256 == identity.descriptorSHA256,
                        "Control endpoint changed")
                    try ExperimentContext.authorizePhase(request, readOnly: readOnly)
                    try authorize(request)
                })
            })
            let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "experiment.exact-logitech-host", identify: { host in
                hosts.contains(host.id) ? LogitechReceiverDriver.identify(host) : nil
            }, logicalDriver: driver, settingsAdapter: driver)])
            let monitor = BatteryMonitor(discovery: discovery, reader: registry, preferences: ExperimentMemoryPreferences(),
                registry: registry, automaticallyRefreshTelemetry: false)
            await monitor.start()
            let snapshot = await monitor.initialDiscoveryReady()
            guard snapshot.discoveryFailure == nil else { await monitor.stop(); throw ExperimentError.rejected("Target discovery failed") }
            let targets = snapshot.logicalDevices.filter { identity.matches($0, hosts: snapshot.devices) }
            guard targets.count == 1 else { await monitor.stop(); throw ExperimentError.rejected("Strong identity has no unique current target") }
            return Self(monitor: monitor, controller: DeviceController(monitor: monitor, registry: registry), target: targets[0], identity: identity)
        } catch { await discovery.stop(); throw error }
    }
}

enum GPW1PersistenceExperiment {
    typealias ContextFactory = @Sendable (StrongExperimentIdentity, Bool) async throws -> ExperimentContext
    static func execute(_ options: ExperimentOptions, files: ExperimentFiles = .live,
                        factory: ContextFactory = { try await ExperimentContext.live(identity: $0, readOnly: $1) }) async throws -> ExperimentResult {
        let inputBytes: Data
        if options.phase == .apply {
            inputBytes = try LocalPrivateFile(url: options.input).read(maximumBytes: 8 * 1_048_576)
            try requireExperiment(digest(inputBytes) == options.inputSHA256, "Reference SHA256 changed")
        } else { inputBytes = try files.checkedData(ExperimentFile(path: options.input.path, sha256: options.inputSHA256)) }
        let manifest: ExperimentManifest?, identity: StrongExperimentIdentity
        if options.phase == .apply { manifest = nil; identity = try StrongExperimentIdentity.reference(inputBytes) }
        else {
            let loaded = try JSONDecoder().decode(ExperimentManifest.self, from: inputBytes)
            try validateManifest(loaded, files: files); manifest = loaded; identity = loaded.identity
        }
        let context = try await factory(identity, options.phase == .observe)
        do {
            let result: ExperimentResult
            switch options.phase {
            case .apply: result = try await apply(options, context: context, files: files)
            case .observe: result = try await observe(options, manifest: manifest!, context: context, files: files)
            case .restore: result = try await restore(options, manifest: manifest!, context: context, files: files)
            }
            await context.monitor.stop(); return result
        } catch { await context.monitor.stop(); throw error }
    }
    static func validateManifest(_ manifest: ExperimentManifest, files: ExperimentFiles) throws {
        try requireExperiment(manifest.schemaVersion == 1 && ["preparedIntent", "verifiedAwaitingUserPowerCycle"].contains(manifest.phase)
            && manifest.profileID == 1 && manifest.stageID == 0 && manifest.originalDPI == 400 && manifest.experimentDPI == 450
            && manifest.originalCurrentStageID == 2, "Unknown experiment manifest or intent")
        let referenceData = try LocalPrivateFile(url: URL(fileURLWithPath: manifest.reference.path)).read(maximumBytes: 8 * 1_048_576)
        try requireExperiment(validDigest(manifest.reference.sha256) && digest(referenceData) == manifest.reference.sha256,
            "Original reference file SHA256 changed")
        try requireExperiment(StrongExperimentIdentity.reference(referenceData) == manifest.identity,
            "Manifest identity differs from its pinned original reference")
        let before = try files.backup(manifest.before)
        let (profile, index) = try ExperimentPlan.checkedImage(before, identity: manifest.identity)
        try requireExperiment(index == 2 && profile.dpiValues?[0] == 400
            && manifest.originalSettings.currentStageID == 2 && manifest.originalSettings.activeProfileID == 1,
            "Original manifest state differs from the exact experiment")
        let stages = (profile.dpiValues ?? []).enumerated().filter { $0.element > 0 }.map { DPIStage(id: UInt8($0.offset), dpi: DPISetting($0.element)) }
        let rate = try HIDPPReportRate(code: profile.bytes[0], extended: false)
        let canonical = DeviceSettings(currentDPI: stages.first(where: { $0.id == index })?.dpi, pollingRateHz: rate.hertz,
            stages: DPIStageTable(stages: stages, activeStageID: index, defaultStageID: profile.bytes[1]), activeProfileID: 1, currentStageID: index)
        try requireExperiment(canonical.stages?.isValid == true && manifest.originalSettings == SafeExperimentSettings(canonical),
            "Manifest original settings do not describe a valid complete before image")
        let original = ExperimentPlan.regions(before)
        var expected = original; expected["profile:1"] = try profile.patch(dpi: [0: 450]).bytes
        try requireExperiment(manifest.beforeRegionHashes == ExperimentPlan.hashes(original)
            && manifest.expectedAfterRegionHashes == ExperimentPlan.hashes(expected), "Manifest region expectations were changed")
        if let after = manifest.after {
            _ = try ExperimentPlan.compare(files.backup(after), expected: expected, identity: manifest.identity, allowCurrentStageDifference: false)
        } else { try requireExperiment(manifest.phase == "preparedIntent", "Verified manifest has no after image") }
        if let intent = manifest.preparedIntent { _ = try files.checkedData(intent) }
    }
    private static func apply(_ options: ExperimentOptions, context: ExperimentContext, files: ExperimentFiles) async throws -> ExperimentResult {
        let directory = try files.newDirectory()
        let beforeURL = directory.appendingPathComponent("before.json")
        let before = try await context.export(to: beforeURL)
        let beforeFile = try files.record(beforeURL)
        let original = try await context.read()
        let plan = try ExperimentPlan(before: before, settings: original.settings, capabilities: context.target.capabilities, identity: context.identity)
        // Prove the complete original restoration operation before any setting write.
        let preflightURL = directory.appendingPathComponent("restore-preflight-current.json")
        let recovery = try await context.controller.prepareProfileRestore(backupURL: beforeURL, rollbackBackupURL: preflightURL,
            logicalDeviceID: context.target.id)
        try requireExperiment(recovery.change.persistence == .onboard && Set(recovery.change.fields) == Set([.stages, .pollingRate])
            && recovery.change.fields.allSatisfy { recovery.change.matches(original.settings, field: $0) }, "Complete original restoration plan is not representable")
        let preflightBackup = try files.backup(files.record(preflightURL))
        _ = try ExperimentPlan.compare(preflightBackup, expected: ExperimentPlan.regions(before),
            identity: context.identity, allowCurrentStageDifference: false)
        try ExperimentPlan.validateRecovery(recovery, original: before, current: preflightBackup,
            capabilities: context.target.capabilities, identity: context.identity)
        _ = try await context.controller.authorizeValidation(recovery, operation: .logitechHIDPP8100Profile)
        let fresh = try await context.read()
        try requireExperiment(fresh.session == original.session && fresh.settings == original.settings, "Original settings changed during recovery preflight")
        _ = try files.checkedData(beforeFile)
        let intent = ExperimentManifest(schemaVersion: 1, phase: "preparedIntent", createdAt: Date(), identity: context.identity,
            reference: ExperimentFile(path: options.input.path, sha256: options.inputSHA256), before: beforeFile, after: nil, preparedIntent: nil,
            beforeRegionHashes: ExperimentPlan.hashes(ExperimentPlan.regions(before)), expectedAfterRegionHashes: ExperimentPlan.hashes(plan.expectedAfterRegions),
            originalSettings: SafeExperimentSettings(original.settings), profileID: 1, stageID: 0, originalDPI: 400, experimentDPI: 450, originalCurrentStageID: 2)
        let intentFile = try files.write(intent, to: directory.appendingPathComponent("prepared-intent.json"))
        // This private, fsynced intent points to the original even if a later write or read is uncertain.
        FileHandle.standardError.write(Data("Prepared private recovery intent: \(intentFile.path) SHA256 \(intentFile.sha256)\n".utf8))
        let request = SettingChangeRequest(target: fresh.session, expectedRevision: fresh.revision, change: plan.change)
        let authorization = try await context.controller.authorizeValidation(request, operation: .logitechHIDPP8100Profile)
        let result = await context.controller.applyValidation(request, authorization: authorization)
        try requireExperiment(result.status == .verified, "Apply did not verify; preserve the prepared intent and do not retry or auto-restore")
        let afterURL = directory.appendingPathComponent("after.json")
        let after = try await context.export(to: afterURL)
        _ = try ExperimentPlan.compare(after, expected: plan.expectedAfterRegions, identity: context.identity, allowCurrentStageDifference: false)
        let afterFile = try files.record(afterURL)
        let verified = ExperimentManifest(schemaVersion: 1, phase: "verifiedAwaitingUserPowerCycle", createdAt: Date(), identity: context.identity,
            reference: intent.reference, before: beforeFile, after: afterFile, preparedIntent: intentFile,
            beforeRegionHashes: intent.beforeRegionHashes, expectedAfterRegionHashes: intent.expectedAfterRegionHashes,
            originalSettings: intent.originalSettings, profileID: 1, stageID: 0, originalDPI: 400, experimentDPI: 450, originalCurrentStageID: 2)
        let manifestFile = try files.write(verified, to: directory.appendingPathComponent("manifest.json"))
        return ExperimentResult(phase: "apply", state: "verifiedAwaitingUserPowerCycle", manifest: manifestFile, capturedBackup: afterFile,
            unitSHA256: context.identity.unitSHA256, currentSelector: context.target.id.rawValue, currentStageID: 2,
            profileBytesMatch: true, allRegionsMatch: true, runtimeStageRestoreApplied: false, externalPowerCycleAttestation: nil)
    }
    private static func expectedAfter(_ manifest: ExperimentManifest, files: ExperimentFiles) throws -> [String: [UInt8]] {
        let before = try files.backup(manifest.before)
        let (profile, _) = try ExperimentPlan.checkedImage(before, identity: manifest.identity)
        var expected = ExperimentPlan.regions(before); expected["profile:1"] = try profile.patch(dpi: [0: 450]).bytes
        return expected
    }
    private static func evidenceURL(_ manifest: ExperimentManifest, kind: String) -> URL {
        URL(fileURLWithPath: manifest.before.path).deletingLastPathComponent().appendingPathComponent(kind + "-" + UUID().uuidString + ".json")
    }
    private static func observe(_ options: ExperimentOptions, manifest: ExperimentManifest, context: ExperimentContext,
                                files: ExperimentFiles) async throws -> ExperimentResult {
        try requireExperiment(manifest.phase == "verifiedAwaitingUserPowerCycle" && manifest.after != nil, "Observe requires a verified apply manifest")
        var attestation: ExperimentFile?
        if let path = options.powerCycleEvidence, let hash = options.powerCycleEvidenceSHA256 {
            let bytes = try LocalPrivateFile(url: path).read(maximumBytes: 1_048_576)
            try requireExperiment(digest(bytes) == hash, "External power-cycle evidence SHA256 changed")
            attestation = ExperimentFile(path: path.path, sha256: hash)
        }
        let url = evidenceURL(manifest, kind: "observe")
        let observed = try await context.export(to: url)
        let all = try ExperimentPlan.compare(observed, expected: expectedAfter(manifest, files: files), identity: context.identity, allowCurrentStageDifference: true)
        let (_, index) = try ExperimentPlan.checkedImage(observed, identity: context.identity)
        let result = ExperimentResult(phase: "observe", state: "experimentProfileObservedPhysicalPowerCycleIsExternalEvidence",
            manifest: ExperimentFile(path: options.input.path, sha256: options.inputSHA256), capturedBackup: try files.record(url),
            unitSHA256: context.identity.unitSHA256, currentSelector: context.target.id.rawValue, currentStageID: index,
            profileBytesMatch: true, allRegionsMatch: all, runtimeStageRestoreApplied: false, externalPowerCycleAttestation: attestation)
        _ = try files.write(result, to: evidenceURL(manifest, kind: "observe-evidence")); return result
    }
    private static func restore(_ options: ExperimentOptions, manifest: ExperimentManifest, context: ExperimentContext,
                                files: ExperimentFiles) async throws -> ExperimentResult {
        let currentURL = evidenceURL(manifest, kind: "before-explicit-restore")
        let current = try await context.export(to: currentURL)
        let original = try files.backup(manifest.before)
        let originalRegions = ExperimentPlan.regions(original), currentRegions = ExperimentPlan.regions(current)
        let profileAlreadyOriginal = currentRegions["profile:1"] == originalRegions["profile:1"]
        _ = try ExperimentPlan.compare(current, expected: profileAlreadyOriginal ? originalRegions : expectedAfter(manifest, files: files),
            identity: context.identity, allowCurrentStageDifference: true)
        if !profileAlreadyOriginal {
            let rollback = evidenceURL(manifest, kind: "restore-rollback")
            let request = try await context.controller.prepareProfileRestore(backupURL: URL(fileURLWithPath: manifest.before.path),
                rollbackBackupURL: rollback, logicalDeviceID: context.target.id)
            let rollbackBackup = try files.backup(files.record(rollback))
            _ = try ExperimentPlan.compare(rollbackBackup, expected: currentRegions, identity: context.identity, allowCurrentStageDifference: false)
            try ExperimentPlan.validateRecovery(request, original: original, current: rollbackBackup,
                capabilities: context.target.capabilities, identity: context.identity)
            let authorization = try await context.controller.authorizeValidation(request, operation: .logitechHIDPP8100Profile)
            let result = await context.controller.applyValidation(request, authorization: authorization)
            try requireExperiment(result.status == .verified, "Explicit profile restore did not verify; no automatic write retry was attempted")
        }
        let profileURL = evidenceURL(manifest, kind: "restored-profile")
        let profileRestored = try await context.export(to: profileURL)
        _ = try ExperimentPlan.compare(profileRestored, expected: originalRegions, identity: context.identity, allowCurrentStageDifference: true)
        let settings = try await context.read()
        var stageApplied = false
        if settings.settings.currentStageID != manifest.originalCurrentStageID {
            try requireExperiment(settings.settings.stages?.stages.contains { $0.id == manifest.originalCurrentStageID } == true,
                "Original current stage is no longer legal")
            let request = SettingChangeRequest(target: settings.session, expectedRevision: settings.revision,
                change: DeviceSettingsChange(persistence: .runtime, currentStageID: manifest.originalCurrentStageID))
            let authorization = try await context.controller.authorizeValidation(request, operation: .logitechHIDPP8100Profile)
            let result = await context.controller.applyValidation(request, authorization: authorization)
            try requireExperiment(result.status == .verified, "Explicit current-stage restore did not verify; no retry was attempted")
            stageApplied = true
        }
        let finalURL = evidenceURL(manifest, kind: "restored-final")
        let final = try await context.export(to: finalURL)
        _ = try ExperimentPlan.compare(final, expected: originalRegions, identity: context.identity, allowCurrentStageDifference: false)
        let finalSettings = try await context.read()
        try requireExperiment(SafeExperimentSettings(finalSettings.settings) == manifest.originalSettings, "Final settings differ from the actual original")
        let result = ExperimentResult(phase: "restore", state: "originalProfileBytesAndCurrentStageVerified", manifest: ExperimentFile(path: options.input.path, sha256: options.inputSHA256),
            capturedBackup: try files.record(finalURL), unitSHA256: context.identity.unitSHA256, currentSelector: context.target.id.rawValue,
            currentStageID: manifest.originalCurrentStageID, profileBytesMatch: true, allRegionsMatch: true,
            runtimeStageRestoreApplied: stageApplied, externalPowerCycleAttestation: nil)
        _ = try files.write(result, to: evidenceURL(manifest, kind: "restore-evidence")); return result
    }
}

@main struct GPW1PersistenceMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] { print(ExperimentOptions.usage); return }
        do {
            #if GPW1_OFFLINE_TESTS
            if arguments == ["--offline-self-test"] { try await GPW1PersistenceOfflineHarness.run(); return }
            #endif
            let result = try await GPW1PersistenceExperiment.execute(ExperimentOptions.parse(arguments))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(result) + Data([10]))
        } catch {
            let message = (error as? ExperimentError)?.description ?? "Experiment failed; preserve private evidence. No automatic retry or recovery was attempted."
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(["state": "failedNoAutomaticRetryOrRecovery", "errorType": String(reflecting: type(of: error)), "message": message]) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
            exit(1)
        }
    }
}
