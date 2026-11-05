// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
@testable import BazerDrivers
@testable import BazerHID
import Foundation
import RazerProtocol
import Testing
@testable import HIDProbe

private final class CLIRecoveryHIDBackend: HIDDiscoveryBackend, HIDSynchronousReportBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var request: HIDReadOnlyFeatureRequest?
    private var sent: [[UInt8]] = []
    private var dpi: [UInt8] = [1, 3, 32, 4, 176] + Array(repeating: 0xA7, count: 75)
    private var stages: [UInt8] = [1, 3, 2, 3, 3, 32, 4, 176, 0xAA, 0xBB, 7, 6, 64, 7, 208, 0xCC, 0xDD] + Array(repeating: 0xE9, count: 63)
    private var rate: UInt8 = 2
    private var firmwareMinor: UInt8 = 2
    var ignoreRateWrite = false
    var loseDPIAcknowledgement = false
    var frames: [[UInt8]] { lock.withLock { sent } }
    var stagePayload: [UInt8] { lock.withLock { stages } }
    var dpiPayload: [UInt8] { lock.withLock { dpi } }
    static var descriptor: HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10, vendorID: 0x1532, productID: 0x00C5,
            product: "Offline Razer fixture", transport: "USB", locationID: 1000, primaryUsage: .mouse, usages: [.mouse], maxFeatureReportSize: 90,
            reportDescriptor: [5,1,9,2,0xA1,1,0x75,8,0x95,90,0xB1,1,0xC0])
    }
    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) {}
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [Self.descriptor]) }
    func inspectInterface(registryEntryID: UInt64) -> HIDInspectionResult { HIDInspectionResult(registryEntryID: registryEntryID, operations: []) }
    func stop() {}
    private func diagnostic(_ phase: String, _ id: UInt64, code: Int32 = 0) -> HIDOperationDiagnostic {
        HIDOperationDiagnostic(phase: phase, registryEntryID: id, rawIOReturn: code, message: "Offline synthetic backend")
    }
    func openFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic { diagnostic("open", registryEntryID) }
    func closeFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic { diagnostic("close", registryEntryID) }
    func setFeature(registryEntryID: UInt64, request: HIDReadOnlyFeatureRequest) -> HIDOperationDiagnostic {
        lock.withLock {
            self.request = request; sent.append(request.bytes)
            switch request.operation {
            case .setDPI: dpi = Array(request.bytes[8...87])
            case .setPollingRate: if !ignoreRateWrite { rate = request.bytes[8] }
            case .setDPIStages: stages = Array(request.bytes[8...87])
            default: break
            }
        }
        return diagnostic("setFeature", registryEntryID)
    }
    func getFeature(registryEntryID: UInt64, reportID: UInt8, capacity: Int) -> HIDRawFeatureReport {
        lock.withLock {
            guard let request else { preconditionFailure("No synthetic request") }
            var bytes = request.bytes; bytes[0] = 2
            switch request.operation {
            case .readFirmware: bytes[8] = 1; bytes[9] = firmwareMinor
            case .readDPI: bytes[8...87] = dpi[...]
            case .readDPIStages: bytes[8...87] = stages[...]
            case .readPollingRate: bytes[8] = rate
            case .readBackupIdentity:
                let serial = Array("OFFLINE-UNIT-123".utf8); bytes[8..<(8 + serial.count)] = serial[...]
            default: break
            }
            bytes[88] = bytes[2...87].reduce(0, ^)
            let failure = loseDPIAcknowledgement && { if case .setDPI = request.operation { true } else { false } }()
            return HIDRawFeatureReport(operation: diagnostic("getFeature", registryEntryID, code: failure ? -1 : 0), bytes: bytes, actualLength: bytes.count)
        }
    }
    func externalStages(_ bytes: [UInt8]) { lock.withLock { stages = bytes } }
    func externalFirmware(_ minor: UInt8) { lock.withLock { firmwareMinor = minor } }
    func externalDPI(_ x: UInt16, _ y: UInt16) { lock.withLock { dpi[1] = UInt8(x >> 8); dpi[2] = UInt8(x & 255); dpi[3] = UInt8(y >> 8); dpi[4] = UInt8(y & 255) } }
}

@Suite("CLI recovery execution — synthetic HID only", .serialized)
struct CLIRecoveryExecutionTests {
    private func run(_ arguments: [String], backend: CLIRecoveryHIDBackend) async throws {
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        try await ExpansionProbe.run(ExpansionProbeOptions.parse(arguments), discovery: discovery)
    }
    @Test func unifiedValidationRejectsAsymmetricRecoveryBeforeAnySettingWrite() async throws {
        let backend = CLIRecoveryHIDBackend(), original = backend.dpiPayload
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-cli-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var rejected = false
        do {
            try await run(["settings", "apply", "--device", "usb-parent:10/direct", "--dpi", "1600", "--scope", "onboard", "--backup-output", folder.appendingPathComponent("before.json").path, "--validation-operation", "razer00C5DPI", "--restore-original"], backend: backend)
        } catch { rejected = true }
        #expect(rejected)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.isEmpty, "Unrecoverable same-operation original must reject before the first setting write")
        #expect(backend.dpiPayload == original)
    }
    @Test func compatibleUnifiedOriginalWritesReadsRestoresAndVerifies() async throws {
        let backend = CLIRecoveryHIDBackend(); backend.externalDPI(800, 800)
        let original = backend.dpiPayload
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-cli-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await run(["settings", "apply", "--device", "usb-parent:10/direct", "--dpi", "1600", "--scope", "onboard", "--backup-output", folder.appendingPathComponent("before.json").path, "--validation-operation", "razer00C5DPI", "--restore-original"], backend: backend)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 2)
        #expect(backend.dpiPayload == original)
    }
    @Test func explicitlyRequestedIndependentXYOperationRestoresAsymmetricOriginal() async throws {
        let backend = CLIRecoveryHIDBackend(), original = backend.dpiPayload
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-cli-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await run(["settings", "apply", "--device", "usb-parent:10/direct", "--dpi-x", "1600", "--dpi-y", "2000", "--scope", "onboard", "--backup-output", folder.appendingPathComponent("before.json").path, "--validation-operation", "razer00C5IndependentXY", "--restore-original"], backend: backend)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 2)
        #expect(backend.dpiPayload == original)
    }
    @Test func originalOutsideTheWriteDomainRejectsBeforeAnySettingWrite() async throws {
        let backend = CLIRecoveryHIDBackend(); backend.externalDPI(175, 175)
        let original = backend.dpiPayload
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-cli-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var rejected = false
        do {
            try await run(["settings", "apply", "--device", "usb-parent:10/direct", "--dpi", "1600", "--scope", "onboard", "--backup-output", folder.appendingPathComponent("before.json").path, "--validation-operation", "razer00C5DPI", "--restore-original"], backend: backend)
        } catch { rejected = true }
        #expect(rejected); #expect(backend.frames.filter { $0[7] < 0x80 }.isEmpty); #expect(backend.dpiPayload == original)
    }
    private func runValues(_ before: DeviceSettings, arguments: [String], corruptStageBackup: Bool = false) async throws -> (CLIRecoveryValueAdapter, Bool) {
        let adapter = CLIRecoveryValueAdapter(before, corruptStageBackup: corruptStageBackup)
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.cli-recovery", identify: { device in
            IdentifiedDevice(descriptor: device, kind: .mouse, capabilities: CLIRecoveryValueAdapter.capabilities(.catalogued), controlEndpointRegistryEntryID: 101)
        }, settingsAdapter: adapter)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-cli-recovery-values-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = CLIRecoveryHIDBackend()
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        var args = ["settings", "apply", "--device", "usb-parent:10/direct"] + arguments + ["--restore-original"]
        if args.contains("onboard") { args += ["--backup-output", folder.appendingPathComponent("before.json").path] }
        do { try await ExpansionProbe.run(ExpansionProbeOptions.parse(args), discovery: discovery, registry: registry); return (adapter, false) }
        catch { return (adapter, true) }
    }
    @Test func everyRequestedFieldHasItsOriginalAuthorizedBeforeTheFirstWrite() async throws {
        let validTable = DPIStageTable(stages: [DPIStage(id: 0, dpi: DPISetting(800)), DPIStage(id: 1, dpi: DPISetting(1600))], activeStageID: 0, opaqueBytes: [0xA5, 0x5A], defaultStageID: 0)
        let invalidDPI = DPIStageTable(stages: [DPIStage(id: 0, dpi: DPISetting(175)), validTable.stages[1]], activeStageID: 0, opaqueBytes: validTable.opaqueBytes, defaultStageID: 0)
        let invalidDefault = DPIStageTable(stages: validTable.stages, activeStageID: 0, opaqueBytes: validTable.opaqueBytes, defaultStageID: 9)
        let cases: [(DeviceSettings, [String])] = [
            (DeviceSettings(pollingRateHz: 333), ["--rate", "500", "--scope", "runtime", "--validation-operation", "logitechHIDPP8060PollingRate"]),
            (DeviceSettings(stages: invalidDPI), ["--dpi-stages", "0:1200:1200", "--scope", "onboard", "--validation-operation", "logitechHIDPP8100Profile"]),
            (DeviceSettings(stages: invalidDefault), ["--default-stage", "1", "--scope", "onboard", "--validation-operation", "logitechHIDPP8100Profile"]),
            (DeviceSettings(currentStageID: 9), ["--current-stage", "1", "--scope", "runtime", "--validation-operation", "logitechHIDPP8100Profile"]),
            (DeviceSettings(activeProfileID: 9), ["--active-profile", "2", "--scope", "runtime", "--validation-operation", "logitechHIDPP8100Profile"]),
            (DeviceSettings(), ["--active-profile", "2", "--scope", "runtime", "--validation-operation", "logitechHIDPP8100Profile"])
        ]
        for (original, args) in cases {
            let (adapter, rejected) = try await runValues(original, arguments: args)
            #expect(rejected); #expect(await adapter.writes.isEmpty); #expect(await adapter.settings == original)
        }
        let (badBackup, rejected) = try await runValues(DeviceSettings(stages: validTable), arguments: ["--default-stage", "1", "--scope", "onboard", "--validation-operation", "logitechHIDPP8100Profile"], corruptStageBackup: true)
        #expect(rejected); #expect(await badBackup.writes.isEmpty)
    }
    @Test func completeCLIChainsRestoreRateStagesDefaultCurrentAndProfile() async throws {
        let table = DPIStageTable(stages: [DPIStage(id: 0, dpi: DPISetting(800)), DPIStage(id: 1, dpi: DPISetting(1600))], activeStageID: 0, opaqueBytes: [0xA5, 0x5A], defaultStageID: 0)
        let original = DeviceSettings(pollingRateHz: 500, stages: table, activeProfileID: 1, currentStageID: 0)
        let commands = [
            ["--rate", "1000", "--scope", "runtime", "--validation-operation", "logitechHIDPP8060PollingRate"],
            ["--dpi-stages", "0:1200:1400", "--default-stage", "1", "--scope", "onboard", "--validation-operation", "logitechHIDPP8100Profile"],
            ["--current-stage", "1", "--scope", "runtime", "--validation-operation", "logitechHIDPP8100Profile"],
            ["--active-profile", "2", "--scope", "runtime", "--validation-operation", "logitechHIDPP8100Profile"]
        ]
        for args in commands {
            let (adapter, rejected) = try await runValues(original, arguments: args)
            #expect(!rejected); #expect(await adapter.writes.count == 2); #expect(await adapter.settings == original)
            #expect(await adapter.authorizationsBeforeFirstWrite >= 2)
        }
    }
    @Test func layoutCaptureIsPrivateReadOnlyUnconfirmedAndCannotAuthorizeStageWriting() async throws {
        let backend = CLIRecoveryHIDBackend()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-cli-layout-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("unconfirmed.json")
        try await run(["profiles", "capture-layout", "--device", "usb-parent:10/direct", "--output", path.path], backend: backend)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bytes = try LocalPrivateFile(url: path).read()
        let document = try decoder.decode(RazerStageLayoutEvidence.self, from: bytes)
        #expect(document.source == .unconfirmedTemplate); #expect(document.layout == .unknown); #expect(document.confirmation == nil)
        #expect(document.observations.count == 1); #expect(document.observations[0].selectedStageID == nil)
        #expect(document.observations[0].stagesResponse.count == 90); #expect(document.observations[0].dpiResponse.count == 90)
        #expect(throws: (any Error).self) { try RazerStageLayoutEvidenceFile.load(reference: path.path) }
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
        var rejected = false
        do {
            try await run(["settings", "apply", "--device", "usb-parent:10/direct", "--dpi-stages", "3:1000:1400", "--scope", "onboard",
                "--backup-output", folder.appendingPathComponent("before.json").path, "--hardware-evidence-reference", path.path,
                "--validation-operation", "razer00C5Stages", "--restore-original"], backend: backend)
        } catch { rejected = true }
        #expect(rejected); #expect(backend.frames.filter { $0[7] < 0x80 }.isEmpty)
        do { try await run(["profiles", "capture-layout", "--device", "usb-parent:10/direct", "--output", path.path], backend: backend); Issue.record("Capture overwrote an existing evidence file") } catch {}
        #expect(try LocalPrivateFile(url: path).read() == bytes)
    }
    @Test func realRazerStageCLIValidatesRecoveryBeforeWritingAndRestoresCompleteImage() async throws {
        let backend = CLIRecoveryHIDBackend(), original = backend.stagePayload
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-cli-layout-roundtrip-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstURL = folder.appendingPathComponent("stage-3.json"), secondURL = folder.appendingPathComponent("stage-7.json")
        try await run(["profiles", "capture-layout", "--device", "usb-parent:10/direct", "--output", firstURL.path], backend: backend)
        var selected = original; selected[1] = 7; backend.externalStages(selected); backend.externalDPI(1600, 2000)
        try await run(["profiles", "capture-layout", "--device", "usb-parent:10/direct", "--output", secondURL.path], backend: backend)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(RazerStageLayoutEvidence.self, from: LocalPrivateFile(url: firstURL).read())
        let second = try decoder.decode(RazerStageLayoutEvidence.self, from: LocalPrivateFile(url: secondURL).read())
        let observations = zip([UInt8(3), 7], [first.observations[0], second.observations[0]]).map { id, item in
            RazerStageLayoutObservation(selectedStageID: id, observedAt: item.observedAt, reportedActiveField: item.reportedActiveField,
                observedCurrentDPI: item.observedCurrentDPI, stagesResponse: item.stagesResponse, dpiResponse: item.dpiResponse)
        }
        // Explicit offline fixture for the separately reviewed-attestation path.
        // capture-layout itself never fills these confirmation fields.
        let evidence = RazerStageLayoutEvidence(source: .hardwareCapture, captureTool: "synthetic regression fixture, no real device",
            capturedAt: first.capturedAt, identity: first.identity, layout: .sevenByteRecords, capturedPayload: first.capturedPayload,
            stageCount: 2, stageIDs: [3, 7], activeSemantics: .protocolStageIdentifier, observations: observations,
            confirmation: RazerStageHardwareConfirmation(confirmedOnHardware: true, confirmedBy: "offline fixture only", confirmedAt: Date()))
        let reference = folder.appendingPathComponent("offline-confirmed-fixture.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try LocalPrivateFile(url: reference).writeNew(encoder.encode(evidence))
        backend.externalStages(original); backend.externalDPI(800, 1200)
        try await run(["settings", "apply", "--device", "usb-parent:10/direct", "--dpi-stages", "3:1000:1400", "--default-stage", "7", "--scope", "onboard",
            "--backup-output", folder.appendingPathComponent("before.json").path, "--hardware-evidence-reference", reference.path,
            "--validation-operation", "razer00C5Stages", "--restore-original"], backend: backend)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 6 }.count == 2)
        #expect(backend.stagePayload == original)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.isEmpty, "Stage recovery must not turn into a separate active-DPI write")
    }
}

private actor CLIRecoveryValueAdapter: DeviceSettingsValidationAuthorizing, DeviceProfileBacking {
    private(set) var settings: DeviceSettings
    private(set) var writes: [DeviceSettingsChange] = []
    private(set) var authorizationsBeforeFirstWrite = 0
    private let corruptStageBackup: Bool
    init(_ settings: DeviceSettings, corruptStageBackup: Bool) { self.settings = settings; self.corruptStageBackup = corruptStageBackup }
    nonisolated static func capabilities(_ evidence: CapabilityEvidence) -> DeviceCapabilities {
        let dpi = CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, maximumStages: 5, persistenceScopes: [.runtime, .onboard])
        return DeviceCapabilities(operations: [
            .dpiRead: OperationCapability(evidence: .discovered), .stagesRead: OperationCapability(evidence: .discovered),
            .dpiWrite: OperationCapability(evidence: evidence, constraints: dpi), .stagesWrite: OperationCapability(evidence: evidence, constraints: dpi),
            .pollingRateWrite: OperationCapability(evidence: evidence, constraints: CapabilityConstraints(allowedValues: [125,500,1000], persistenceScopes: [.runtime, .onboard])),
            .stageSelect: OperationCapability(evidence: evidence, constraints: CapabilityConstraints(allowedValues: [0,1], persistenceScopes: [.runtime])),
            .onboardWrite: OperationCapability(evidence: evidence, constraints: CapabilityConstraints(allowedValues: [1,2,3], persistenceScopes: [.runtime])),
            .independentXY: OperationCapability(evidence: evidence), .onboardPersist: OperationCapability(evidence: evidence)])
    }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> DeviceSettings { settings }
    func authorizeValidation(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor, operation: SettingValidationOperation) throws -> SettingValidationAuthorization {
        guard before.settings == settings, request.change.validate(capabilities: Self.capabilities(.writeVerified)).isEmpty else { throw ProbeCLIError.arguments("Synthetic recovery is outside its exact operation domain") }
        if let table = request.change.stages, let id = table.defaultStageID, !table.stages.contains(where: { $0.id == id }) { throw ProbeCLIError.arguments("Synthetic default stage is not an existing ID") }
        if writes.isEmpty { authorizationsBeforeFirstWrite += 1 }
        return SettingValidationAuthorization(request: request, operation: operation, profileID: "synthetic.cli-recovery", capabilities: Self.capabilities(.writeVerified))
    }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) -> SettingAdapterTransaction {
        let actual = settings
        guard before.settings == actual else { return SettingAdapterTransaction(before: actual, observed: actual, acknowledged: false, persistence: .unknown, superseded: true) }
        writes.append(request.change)
        settings = DeviceSettings(currentDPI: request.change.currentDPI ?? actual.currentDPI, pollingRateHz: request.change.pollingRateHz ?? actual.pollingRateHz,
            stages: request.change.stages ?? actual.stages, activeProfileID: request.change.activeProfileID ?? actual.activeProfileID, currentStageID: request.change.currentStageID ?? actual.currentStageID)
        return SettingAdapterTransaction(before: actual, observed: settings, acknowledged: true, persistence: .unknown)
    }
    func exportProfile(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, saveTo: URL, hardwareEvidenceReference: String?) throws -> ProfileBackup {
        let backup = ProfileBackup(capturedAt: Date(), identity: ProfileBackupIdentity(vendorID: 0x1234, unitID: "synthetic-only", formatID: "synthetic-json-settings", formatVersion: 1, descriptorSHA256: "synthetic-descriptor"),
            session: session, regions: [ProfileBackupRegion(id: "settings-json", bytes: Array(try JSONEncoder().encode(settings)))])
        try FileProfileBackup(url: saveTo).save(backup); return backup
    }
    func prepareRestore(backupURL: URL, rollbackBackupURL: URL, target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, hardwareEvidenceReference: String?) throws -> DeviceSettingsChange {
        let backup = try FileProfileBackup(url: backupURL).load()
        let original = try JSONDecoder().decode(DeviceSettings.self, from: Data(backup.regions[0].bytes))
        _ = try exportProfile(target: target, session: session, saveTo: rollbackBackupURL, hardwareEvidenceReference: hardwareEvidenceReference)
        guard let stages = original.stages else { throw ProbeCLIError.arguments("No original synthetic stage image") }
        let restored = DPIStageTable(stages: stages.stages, activeStageID: stages.activeStageID, opaqueBytes: settings.stages?.opaqueBytes ?? [], defaultStageID: corruptStageBackup ? 1 : stages.defaultStageID)
        return DeviceSettingsChange(stages: restored, persistence: .onboard)
    }
}
