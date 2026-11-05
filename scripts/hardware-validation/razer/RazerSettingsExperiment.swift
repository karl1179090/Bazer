// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone root-operated experiment. Never imported by the shipping application.
import BazerCore
import BazerDrivers
import BazerHID
import CryptoKit
import Darwin
import Foundation
import RazerProtocol

enum RazerExperimentError: Error, CustomStringConvertible {
    case rejected(String)
    var description: String { switch self { case .rejected(let message): message } }
}
func razerRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw RazerExperimentError.rejected(message) }
}
func razerSHA(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func razerIsSHA(_ string: String) -> Bool {
    string.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

struct RazerExperimentOptions {
    enum Phase: String { case prepare, run, recover, verify }
    enum Field: String, Codable, Sendable {
        case dpi, rate, xy
        var isDPI: Bool { self == .dpi || self == .xy }
        var settingField: SettingField { isDPI ? .currentDPI : .pollingRate }
    }
    let phase: Phase
    let selector: String
    let output: URL
    let before: URL?
    let beforeSHA256: String?
    let field: Field?
    let original: Int?
    let target: Int?
    let originalDPI: DPISetting?
    let targetDPI: DPISetting?
    let holdForPowerCycle: Bool
    static let usage = """
    Razer 1532:00C5 standalone experiment. No arguments/--help performs no HID access.
      prepare --allow-hardware-read --device <current-selector> --output-dir </absolute/new-dir>
      run --allow-setting-write-and-restore --device <current-selector> --before </private/before.json> --before-sha256 <sha256> --field dpi|rate --original <actual-original> --target <different-value> --output-dir </absolute/new-dir>
      recover --allow-original-value-write --device <current-selector> --before </private/before.json> --before-sha256 <sha256> --field dpi|rate --original <actual-original> --output-dir </absolute/new-dir>
      run <same run flags> --hold-for-power-cycle
      verify --allow-hardware-read --device <fresh-selector> --before </private/before.json> --before-sha256 <sha256> --field dpi|rate --original <actual-original> --target <held-value> --output-dir </absolute/new-dir>
    Independent XY uses --field xy --original-x <X> --original-y <Y> and, for run/verify,
      --target-x <X> --target-y <Y>, instead of the scalar --original/--target options.
    dpi requires X=Y; xy uses exact independent axes. Each axis: 100...26000 / step 50.
    Traditional rates: 125,500,1000. There is no unified-DPI fallback for xy.
    run always restores the original after a verified experiment, without retrying writes.
    recover writes only the original field, at most once; it never writes the test value.
    All full settings/raw captures are private 0600 files. No unknown stage writes exist.
    """
    static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let phase = Phase(rawValue: first) else { throw RazerExperimentError.rejected(usage) }
        let flag: String = switch phase {
        case .prepare, .verify: "--allow-hardware-read"
        case .run: "--allow-setting-write-and-restore"
        case .recover: "--allow-original-value-write"
        }
        var values: [String: String] = [:], seen = Set<String>(), index = 1
        while index < arguments.count {
            let option = arguments[index]
            try razerRequire(seen.insert(option).inserted, "Repeated experiment option")
            if option == flag { index += 1; continue }
            if option == "--hold-for-power-cycle", phase == .run { index += 1; continue }
            try razerRequire(index + 1 < arguments.count, "Missing experiment option value")
            values[option] = arguments[index + 1]; index += 2
        }
        let field = values["--field"].flatMap(Field.init(rawValue:))
        var keys: Set<String> = ["--device", "--output-dir"]
        if phase != .prepare {
            keys.formUnion(["--before", "--before-sha256", "--field"])
            keys.formUnion(field == .xy ? ["--original-x", "--original-y"] : ["--original"])
        }
        if phase == .run || phase == .verify { keys.formUnion(field == .xy ? ["--target-x", "--target-y"] : ["--target"]) }
        try razerRequire(seen.contains(flag) && Set(values.keys) == keys, "The phase requires its exact explicit hardware flag and options")
        guard let selector = values["--device"], selector.hasPrefix("usb-parent:"), selector.hasSuffix("/direct"),
              let output = values["--output-dir"], output.hasPrefix("/") else { throw RazerExperimentError.rejected("An exact direct selector and absolute new output directory are required") }
        let before = values["--before"], hash = values["--before-sha256"]
        let original = values["--original"].flatMap(Int.init), target = values["--target"].flatMap(Int.init)
        func axes(_ prefix: String) -> DPISetting? {
            guard let x = values[prefix + "-x"].flatMap(UInt16.init), let y = values[prefix + "-y"].flatMap(UInt16.init) else { return nil }
            return DPISetting(x: x, y: y)
        }
        let originalDPI = axes("--original"), targetDPI = axes("--target")
        if phase != .prepare {
            try razerRequire(before?.hasPrefix("/") == true && hash.map(razerIsSHA) == true && field != nil
                && (field == .xy ? originalDPI != nil : original != nil), "A private before path, exact SHA256, field and complete original value are required")
        }
        if phase == .run || phase == .verify {
            try razerRequire(field == .xy ? targetDPI != nil && targetDPI != originalDPI : target != nil && target != original,
                "A different explicit complete experiment target is required")
        }
        return Self(phase: phase, selector: selector, output: URL(fileURLWithPath: output), before: before.map { URL(fileURLWithPath: $0) }, beforeSHA256: hash, field: field, original: original, target: target, originalDPI: originalDPI, targetDPI: targetDPI, holdForPowerCycle: seen.contains("--hold-for-power-cycle"))
    }
}

struct RazerExperimentFile: Codable, Equatable, Sendable { let path: String; let sha256: String }
struct RazerExperimentFiles: Sendable {
    let directory: URL
    func create() throws {
        let path = directory.standardizedFileURL.path
        try razerRequire(path == directory.path && path == directory.resolvingSymlinksInPath().path, "Output directory must be canonical and contain no symlink")
        try razerRequire(Darwin.mkdir(path, 0o700) == 0, "Output directory must be new with an existing parent")
    }
    static func privateData(_ url: URL) throws -> Data {
        let path = url.standardizedFileURL.path
        var info = stat()
        try razerRequire(path == url.path && path == url.resolvingSymlinksInPath().path && lstat(path, &info) == 0
            && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o777 == 0o600 && info.st_uid == getuid(), "Input must be a canonical user-owned regular 0600 file")
        return try LocalPrivateFile(url: url).read(maximumBytes: 8 * 1_048_576)
    }
    func record(_ name: String) throws -> RazerExperimentFile {
        let url = directory.appendingPathComponent(name)
        return RazerExperimentFile(path: url.path, sha256: razerSHA(try Self.privateData(url)))
    }
    func write<T: Encodable>(_ value: T, _ name: String) throws -> RazerExperimentFile {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let url = directory.appendingPathComponent(name)
        try LocalPrivateFile(url: url).writeNew(encoder.encode(value))
        return try record(name)
    }
}

struct RazerExperimentBefore: Codable, Sendable {
    let schemaVersion: Int
    let purpose: String
    let createdAt: Date
    let selectorAtCapture: String
    let identity: ProfileBackupIdentity
    let settings: DeviceSettingsSnapshot
    let backup: ProfileBackup
    let capture: RazerStageLayoutEvidence
    let backupFile: RazerExperimentFile
    let captureFile: RazerExperimentFile
    func validate() throws {
        try backup.validateIntegrity()
        try razerRequire(schemaVersion == 1 && purpose == "razer00C5.settings.original.readOnly" && createdAt <= Date(), "Unknown before document")
        try Self.validateIdentity(identity)
        try razerRequire(backup.identity == identity && capture.identity == identity && backup.regions.count == 1
            && backup.regions[0].id == "dpi-stage-payload" && backup.regions[0].bytes.count == 80
            && capture.capturedPayload == backup.regions[0].bytes && capture.capturedPayloadSHA256 == razerSHA(Data(capture.capturedPayload))
            && capture.source == .unconfirmedTemplate && capture.layout == .unknown && capture.confirmation == nil
            && capture.observations.count == 1 && capture.observations[0].selectedStageID == nil,
            "Before must retain one complete unconfirmed raw stage image")
        let observation = capture.observations[0]
        guard case let .dpi(dpi) = try RazerSettingResponse.parse(observation.dpiResponse, for: .readDPI()),
              case let .stages(stages) = try RazerSettingResponse.parse(observation.stagesResponse, for: .readStages()) else { throw RazerExperimentError.rejected("Before reply envelopes were not validated") }
        try razerRequire(stages.payload == capture.capturedPayload && settings.settings.stages?.opaqueBytes == stages.payload
            && settings.settings.stages?.stages.isEmpty == true && settings.settings.currentDPI == DPISetting(x: dpi.x, y: dpi.y)
            && observation.observedCurrentDPI == settings.settings.currentDPI && settings.settings.pollingRateHz != nil,
            "Before settings and independently validated raw replies disagree")
        for file in [backupFile, captureFile] {
            try razerRequire(razerIsSHA(file.sha256) && razerSHA(try RazerExperimentFiles.privateData(URL(fileURLWithPath: file.path))) == file.sha256, "Before auxiliary evidence SHA256 changed")
        }
        let decoder = JSONDecoder()
        try razerRequire(try decoder.decode(ProfileBackup.self, from: RazerExperimentFiles.privateData(URL(fileURLWithPath: backupFile.path))) == backup,
            "Backup file does not match embedded original evidence")
        let captureDecoder = JSONDecoder(); captureDecoder.dateDecodingStrategy = .iso8601
        try razerRequire(try captureDecoder.decode(RazerStageLayoutEvidence.self, from: RazerExperimentFiles.privateData(URL(fileURLWithPath: captureFile.path))) == capture,
            "Capture file does not match embedded original evidence")
    }
    static func validateIdentity(_ identity: ProfileBackupIdentity) throws {
        let prefix = "razer-serial-sha256:"
        try razerRequire(identity.vendorID == 0x1532 && identity.productID == 0x00C5 && identity.wirelessProductID == nil
            && identity.unitID?.hasPrefix(prefix) == true && identity.unitID.map { razerIsSHA(String($0.dropFirst(prefix.count))) } == true
            && identity.firmware?.isEmpty == false && razerIsSHA(identity.descriptorSHA256)
            && identity.formatID == "razer.00c5.dpi-stage-payload" && identity.formatVersion == 0,
            "An exact strong 00C5 unit, firmware and descriptor identity are required")
    }
}

private struct RazerMemoryPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}
struct RazerExperimentContext: Sendable {
    let monitor: BatteryMonitor
    let controller: DeviceController
    let target: LogicalDeviceState
    let driver: RazerMouseDriver
    static func make(discovery: HIDDiscovery, selector: String) async throws -> Self {
        let driver = RazerMouseDriver(discovery: discovery)
        // No Logitech adapter, logical driver, input subscription or telemetry reader exists.
        let registration = DeviceDriverRegistration(id: "razer.experiment.only.1532.00c5", identify: { device in
            guard RazerDeviceProfile.deathAdderV3HyperSpeed.matches(device),
                  let endpoint = InterfaceSelector.razerControlInterface(in: device).selected else { return nil }
            return IdentifiedDevice(descriptor: device, kind: .mouse,
                capabilities: DeviceCapabilities(operations: RazerMouseDriver.candidateReadCapabilities), controlEndpointRegistryEntryID: endpoint.registryEntryID)
        }, settingsAdapter: driver)
        let registry = DriverRegistry(registrations: [registration])
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, preferences: RazerMemoryPreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start()
        let snapshot = await monitor.initialDiscoveryReady()
        let targets = snapshot.logicalDevices.filter { $0.id.rawValue == selector && $0.hostPresence == .present && !$0.descriptor.isIdentityAmbiguous }
        guard snapshot.discoveryFailure == nil, targets.count == 1 else {
            await monitor.stop(); throw RazerExperimentError.rejected("No unique present Razer target matches the explicit selector")
        }
        return Self(monitor: monitor, controller: DeviceController(monitor: monitor, registry: registry), target: targets[0], driver: driver)
    }
    func read() async throws -> DeviceSettingsSnapshot { try await controller.readSettings(logicalDeviceID: target.id) }
    func capture(files: RazerExperimentFiles, prefix: String) async throws -> RazerExperimentBefore {
        let initial = try await read()
        let backup = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: files.directory.appendingPathComponent(prefix + "-backup.json"))
        let capture = try await controller.captureStageLayoutEvidence(logicalDeviceID: target.id, saveTo: files.directory.appendingPathComponent(prefix + "-capture.json"))
        // The public capture method returns full precision; its file encodes ISO8601 seconds.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let savedCapture = try decoder.decode(RazerStageLayoutEvidence.self, from: RazerExperimentFiles.privateData(files.directory.appendingPathComponent(prefix + "-capture.json")))
        let settings = try await read()
        try razerRequire(initial.session == settings.session && initial.settings == settings.settings
            && capture.capturedPayload == savedCapture.capturedPayload && backup.identity == savedCapture.identity,
            "Device changed during read-only capture")
        let before = RazerExperimentBefore(schemaVersion: 1, purpose: "razer00C5.settings.original.readOnly", createdAt: Date(),
            selectorAtCapture: target.id.rawValue, identity: backup.identity, settings: settings, backup: backup, capture: savedCapture,
            backupFile: try files.record(prefix + "-backup.json"), captureFile: try files.record(prefix + "-capture.json"))
        try before.validate(); return before
    }
}

struct RazerExperimentSummary: Encodable, Sendable {
    let phase: String
    let state: String
    let selector: String
    let receipt: RazerExperimentFile
    let originalRestored: Bool
    let fullStageUnchanged: Bool
    let settingWrites: Int
    let currentDPI: DPISetting?
    let pollingRateHz: Int?
    let persistenceVerified = false
}
struct RazerExperimentStageReceipt: Codable, Sendable {
    let phase: String
    let createdAt: Date
    let originalEvidence: RazerExperimentFile
    let field: RazerExperimentOptions.Field
    let original: DeviceSettingsChange
    let target: DeviceSettingsChange?
    let result: SettingChangeResult?
    let failure: String?
}

enum RazerSettingsExperiment {
    typealias ContextFactory = @Sendable (String) async throws -> RazerExperimentContext
    static func live(_ selector: String) async throws -> RazerExperimentContext { try await RazerExperimentContext.make(discovery: HIDDiscovery(), selector: selector) }
    static func originalValue(_ before: RazerExperimentBefore, field: RazerExperimentOptions.Field) throws -> Int {
        switch field {
        case .dpi:
            guard let dpi = before.settings.settings.currentDPI, dpi.x == dpi.y else { throw RazerExperimentError.rejected("Unified DPI recovery requires a known symmetric original") }
            return Int(dpi.x)
        case .rate:
            guard let rate = before.settings.settings.pollingRateHz else { throw RazerExperimentError.rejected("Original rate is unknown") }
            return rate
        case .xy: throw RazerExperimentError.rejected("Independent XY requires two explicit original axes")
        }
    }
    static func change(field: RazerExperimentOptions.Field, value: Int) throws -> DeviceSettingsChange {
        switch field {
        case .dpi:
            try razerRequire((100...26000).contains(value) && value % 50 == 0, "DPI is outside 100...26000 / step 50")
            return DeviceSettingsChange(currentDPI: DPISetting(UInt16(value)), persistence: .onboard)
        case .rate:
            try razerRequire([125, 500, 1000].contains(value), "Only traditional 125,500,1000 Hz is permitted")
            return DeviceSettingsChange(pollingRateHz: value, persistence: .onboard)
        case .xy: throw RazerExperimentError.rejected("Independent XY cannot use a unified scalar value")
        }
    }
    static func exactChange(_ options: RazerExperimentOptions, original: Bool) throws -> DeviceSettingsChange {
        guard let field = options.field else { throw RazerExperimentError.rejected("Missing exact field") }
        if field == .xy {
            guard let dpi = original ? options.originalDPI : options.targetDPI else { throw RazerExperimentError.rejected("Independent XY requires both explicit axes") }
            for value in [dpi.x, dpi.y] {
                try razerRequire((100...26000).contains(value) && value % 50 == 0, "Each independent DPI axis must be 100...26000 / step 50")
            }
            return DeviceSettingsChange(currentDPI: dpi, persistence: .onboard)
        }
        guard let value = original ? options.original : options.target else { throw RazerExperimentError.rejected("Missing explicit scalar value") }
        return try change(field: field, value: value)
    }
    static func operation(_ field: RazerExperimentOptions.Field) -> SettingValidationOperation {
        switch field { case .dpi: .razer00C5DPI; case .rate: .razer00C5PollingRate; case .xy: .razer00C5IndependentXY }
    }
    static func loadBefore(_ options: RazerExperimentOptions) throws -> RazerExperimentBefore {
        guard let url = options.before, let hash = options.beforeSHA256 else { throw RazerExperimentError.rejected("Missing original evidence") }
        let bytes = try RazerExperimentFiles.privateData(url)
        try razerRequire(razerSHA(bytes) == hash, "Original before evidence SHA256 mismatch")
        let before = try JSONDecoder().decode(RazerExperimentBefore.self, from: bytes)
        try before.validate(); return before
    }
    static func matchesOriginal(_ current: RazerExperimentBefore, original: RazerExperimentBefore, ignoring field: RazerExperimentOptions.Field? = nil, allowStageDifference: Bool = false) throws {
        try razerRequire(current.identity == original.identity, "Strong unit, firmware or descriptor changed")
        let lhs = current.settings.settings, rhs = original.settings.settings
        if !allowStageDifference {
            try razerRequire(lhs.stages?.opaqueBytes == rhs.stages?.opaqueBytes && current.backup.regions == original.backup.regions,
                "Full unknown stage image changed; no stage write is permitted")
        }
        try razerRequire(lhs.activeProfileID == rhs.activeProfileID && lhs.currentStageID == rhs.currentStageID,
            "Unrelated profile or current stage changed")
        if field?.isDPI != true { try razerRequire(lhs.currentDPI == rhs.currentDPI, "Unrelated DPI changed") }
        if field != .rate { try razerRequire(lhs.pollingRateHz == rhs.pollingRateHz, "Unrelated rate changed") }
        let first = original.capture.observations[0].dpiResponse, second = current.capture.observations[0].dpiResponse
        try razerRequire(first.count == 90 && second.count == 90
            && (8...87).allSatisfy { field?.isDPI == true && (9...12).contains($0) || first[$0] == second[$0] },
            "Unedited DPI payload bytes changed")
    }
    static func apply(_ change: DeviceSettingsChange, context: RazerExperimentContext, snapshot: DeviceSettingsSnapshot,
                      field: RazerExperimentOptions.Field, identity: ProfileBackupIdentity) async throws -> SettingChangeResult {
        // Reading settings can refresh the adapter's firmware cache. Re-check the
        // strong identity after that read, before minting this exact authorization.
        // The driver's own transaction then rechecks that firmware and full before
        // state while holding its HID lease; a changed value supersedes the write.
        let freshIdentity = try await context.driver.exportProfileBackup(target: context.target.descriptor, session: snapshot.session)
        try razerRequire(freshIdentity.identity == identity, "Strong unit, firmware or descriptor changed immediately before authorization")
        let request = SettingChangeRequest(target: snapshot.session, expectedRevision: snapshot.revision, change: change)
        let authorization = try await context.controller.authorizeValidation(request, operation: operation(field))
        return await context.controller.applyValidation(request, authorization: authorization)
    }
    static func execute(_ options: RazerExperimentOptions, factory: ContextFactory = live) async throws -> RazerExperimentSummary {
        // Validate private original evidence, numeric domains and output path before creating HID.
        let original = options.phase == .prepare ? nil : try loadBefore(options)
        if let original, let field = options.field {
            let recovery = try exactChange(options, original: true)
            if field == .xy {
                try razerRequire(recovery.currentDPI == original.settings.settings.currentDPI, "Both explicit original axes must match the original before evidence")
            } else {
                try razerRequire(try originalValue(original, field: field) == options.original, "Explicit original does not match the original before evidence")
            }
            if options.phase == .run || options.phase == .verify { _ = try exactChange(options, original: false) }
        }
        let files = RazerExperimentFiles(directory: options.output); try files.create()
        let context = try await factory(options.selector)
        do {
            let summary = try await perform(options, original: original, context: context, files: files)
            await context.monitor.stop(); return summary
        } catch { await context.monitor.stop(); throw error }
    }
    private static func perform(_ options: RazerExperimentOptions, original: RazerExperimentBefore?, context: RazerExperimentContext,
                                files: RazerExperimentFiles) async throws -> RazerExperimentSummary {
        let actual = try await context.capture(files: files, prefix: "before")
        let beforeFile = try files.write(actual, "before.json")
        if options.phase == .prepare {
            return RazerExperimentSummary(phase: "prepare", state: "privateOriginalCapturedNoSettingsWritten", selector: options.selector,
                receipt: beforeFile, originalRestored: true, fullStageUnchanged: true, settingWrites: 0, currentDPI: actual.settings.settings.currentDPI, pollingRateHz: actual.settings.settings.pollingRateHz)
        }
        guard let original, let field = options.field,
              let input = options.before, let hash = options.beforeSHA256 else { throw RazerExperimentError.rejected("Incomplete explicit operation") }
        let reference = RazerExperimentFile(path: input.path, sha256: hash)
        let readOrRecover = options.phase == .recover || options.phase == .verify
        try matchesOriginal(actual, original: original, ignoring: readOrRecover ? field : nil, allowStageDifference: readOrRecover)
        let recovery = try exactChange(options, original: true)
        if options.phase == .verify {
            let expected = try exactChange(options, original: false)
            try razerRequire(expected.matches(actual.settings.settings, field: field.settingField), "Fresh read does not match both exact axes or the held rate")
            let unchanged = actual.backup.regions == original.backup.regions
            return RazerExperimentSummary(phase: "verify", state: unchanged ? "freshHeldValueVerifiedPendingOriginalRecovery" : "freshHeldValueVerifiedStageDifferencePendingRecovery", selector: options.selector,
                receipt: beforeFile, originalRestored: false, fullStageUnchanged: unchanged, settingWrites: 0, currentDPI: actual.settings.settings.currentDPI, pollingRateHz: actual.settings.settings.pollingRateHz)
        }
        let before = try await context.read()
        try razerRequire(before.settings == actual.settings.settings && before.session == actual.settings.session, "Device changed after private evidence capture")
        // Pre-authorize original semantics before any first test write. Unused token is never replayed.
        let recoveryRequest = SettingChangeRequest(target: before.session, expectedRevision: before.revision, change: recovery)
        _ = try await context.controller.authorizeValidation(recoveryRequest, operation: operation(field))
        _ = try files.write(RazerExperimentStageReceipt(phase: "intent", createdAt: Date(), originalEvidence: reference,
            field: field, original: recovery, target: options.phase == .run ? try exactChange(options, original: false) : nil, result: nil, failure: nil), "intent.json")
        if options.phase == .recover {
            let result = try await apply(recovery, context: context, snapshot: before, field: field, identity: original.identity)
            _ = try files.write(RazerExperimentStageReceipt(phase: "recover", createdAt: Date(), originalEvidence: reference,
                field: field, original: recovery, target: nil, result: result, failure: nil), "recover-result.json")
            try razerRequire(result.status == .verified, "Original recovery did not verify; stop without retry")
            let final = try await context.capture(files: files, prefix: "recovered")
            try matchesOriginal(final, original: original, allowStageDifference: true)
            let receipt = try files.write(final, "recovered.json")
            let unchanged = final.backup.regions == original.backup.regions
            return RazerExperimentSummary(phase: "recover", state: unchanged ? "originalFieldRestoredAndCompleteStageCompared" : "originalFieldRestoredStageDifferenceNeedsReview", selector: options.selector,
                receipt: receipt, originalRestored: true, fullStageUnchanged: unchanged, settingWrites: 1, currentDPI: final.settings.settings.currentDPI, pollingRateHz: final.settings.settings.pollingRateHz)
        }
        let testChange = try exactChange(options, original: false)
        let result = try await apply(testChange, context: context, snapshot: before, field: field, identity: original.identity)
        var receiptFailure = false
        do {
            _ = try files.write(RazerExperimentStageReceipt(phase: "test", createdAt: Date(), originalEvidence: reference,
                field: field, original: recovery, target: testChange, result: result, failure: nil), "test-result.json")
        } catch { receiptFailure = true }
        try razerRequire(result.status == .verified && result.observed != nil, "Experiment did not verify; stop without speculative recovery or retry; use explicit recover after reviewing fresh evidence")
        // Always attempt the already-authorized field restoration after a verified test,
        // even when saving its receipt failed. Do not continue to a second experiment.
        var testCapture: RazerExperimentBefore?
        var testEvidenceFailure = receiptFailure
        do {
            let captured = try await context.capture(files: files, prefix: "tested")
            // A firmware-linked stage change is recorded and never patched. Only
            // the known requested field may be restored using its typed operation.
            try matchesOriginal(captured, original: original, ignoring: field, allowStageDifference: true)
            try razerRequire(testChange.matches(captured.settings.settings, field: field.settingField), "Fresh experiment read differs from either exact DPI axis or the requested rate")
            testCapture = captured
            _ = try files.write(captured, "tested.json")
        } catch { testEvidenceFailure = true }
        // Strong identity is re-read by export/capture before restoring, not inferred from a cached selector.
        // If the fresh complete capture failed, no restore can safely proceed automatically.
        guard let testCapture else { throw RazerExperimentError.rejected("Fresh test identity/full-image validation failed; explicit recovery is required after review") }
        let testStageUnchanged = testCapture.backup.regions == original.backup.regions
        if options.holdForPowerCycle && !testEvidenceFailure {
            let receipt = try files.write(testCapture, "held-pending-restore.json")
            return RazerExperimentSummary(phase: "run", state: testStageUnchanged ? "heldTestValuePendingPowerCycleAndOriginalRecovery" : "heldTestValueStageDifferencePendingOriginalRecovery", selector: options.selector,
                receipt: receipt, originalRestored: false, fullStageUnchanged: testStageUnchanged, settingWrites: 1, currentDPI: testCapture.settings.settings.currentDPI, pollingRateHz: testCapture.settings.settings.pollingRateHz)
        }
        let restoreBefore = try await context.read()
        try razerRequire(restoreBefore.settings == testCapture.settings.settings && restoreBefore.session == before.session,
            "Settings changed before restoration; stop for explicit recovery")
        let restored = try await apply(recovery, context: context, snapshot: restoreBefore, field: field, identity: original.identity)
        var restoreReceiptFailed = false
        do {
            _ = try files.write(RazerExperimentStageReceipt(phase: "restoreOriginal", createdAt: Date(), originalEvidence: reference,
                field: field, original: recovery, target: nil, result: restored, failure: nil), "restore-result.json")
        } catch { restoreReceiptFailed = true }
        try razerRequire(restored.status == .verified, "Original restoration did not verify; stop without another write")
        let final = try await context.capture(files: files, prefix: "restored")
        try matchesOriginal(final, original: original, allowStageDifference: true)
        let finalFile = try files.write(final, "restored.json")
        try razerRequire(!testEvidenceFailure && !restoreReceiptFailed, "Original was restored and compared, but an experiment receipt could not be saved; do not promote this run")
        let unchanged = testStageUnchanged && final.backup.regions == original.backup.regions
        return RazerExperimentSummary(phase: "run", state: unchanged ? "testAndOriginalVerifiedCompleteStageUnchanged" : "originalFieldRestoredStageDifferenceNeedsReview", selector: options.selector,
            receipt: finalFile, originalRestored: true, fullStageUnchanged: unchanged, settingWrites: 2, currentDPI: final.settings.settings.currentDPI, pollingRateHz: final.settings.settings.pollingRateHz)
    }
}

@main struct RazerSettingsMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] { print(RazerExperimentOptions.usage); return }
        do {
            #if RAZER_OFFLINE_TESTS
            guard arguments == ["--offline-self-test"] else { throw RazerExperimentError.rejected("Offline binary accepts only --help or --offline-self-test; hardware phases are disabled") }
            try await RazerSettingsOfflineHarness.run()
            #else
            let result = try await RazerSettingsExperiment.execute(RazerExperimentOptions.parse(arguments))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(result) + Data([10]))
            if !result.fullStageUnchanged { exit(2) }
            #endif
        } catch {
            let safe = (error as? RazerExperimentError)?.description ?? "Experiment failed; inspect private evidence. No write retry was attempted."
            let encoder = JSONEncoder()
            if let bytes = try? encoder.encode(["state": "failedStopForReview", "message": safe]) { FileHandle.standardOutput.write(bytes + Data([10])) }
            exit(1)
        }
    }
}
