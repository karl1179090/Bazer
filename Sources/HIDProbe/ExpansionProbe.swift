// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import Foundation
import CryptoKit
import LogitechHIDPP

struct ExpansionProbeOptions {
    enum Action: String { case capabilities, read, preview, apply, features, export, restore, telemetry; case captureLayout = "capture-layout" }
    let action: Action
    var device: String?
    var json = false
    var trace = false
    var samples = 10
    var interval: Double = 2
    var dpiX: UInt16?
    var dpiY: UInt16?
    var rate: Int?
    var dpiStages: [DPIStage]?
    var defaultStage: UInt8?
    var currentStage: UInt8?
    var activeProfile: Int?
    var scope: SettingPersistence?
    var validationOperation: SettingValidationOperation?
    var restoreOriginal = false
    var input: String?
    var output: String?
    var rollbackOutput: String?
    var hardwareEvidenceReference: String?
    var backupOutput: String?

    static func parse(_ arguments: [String]) throws -> Self {
        let action: Action, start: Int
        switch arguments.first {
        case "capabilities": action = .capabilities; start = 1
        case "telemetry": action = .telemetry; start = 1
        case "settings":
            guard arguments.count > 1, let value = Action(rawValue: arguments[1]), [.read, .preview, .apply].contains(value) else { throw invalid("settings requires read, preview, or apply") }
            action = value; start = 2
        case "logitech":
            guard arguments.count > 1, arguments[1] == "features" else { throw invalid("logitech requires features") }
            action = .features; start = 2
        case "profiles":
            guard arguments.count > 1, let value = Action(rawValue: arguments[1]), [.export, .restore, .captureLayout].contains(value) else { throw invalid("profiles requires export, restore, or capture-layout") }
            action = value; start = 2
        default: throw invalid("unknown expansion command")
        }
        var result = Self(action: action), seen: Set<String> = []
        var index = start
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw invalid("duplicate option \(option)") }
            if option == "--json" { result.json = true; index += 1; continue }
            if option == "--trace" {
                guard [.capabilities, .features, .telemetry].contains(action) else { throw invalid("--trace requires an explicit capabilities/features/telemetry capture") }
                result.trace = true; index += 1; continue
            }
            if option == "--restore-original" {
                guard action == .apply else { throw invalid("--restore-original requires settings apply") }
                result.restoreOriginal = true; index += 1; continue
            }
            guard index + 1 < arguments.count else { throw invalid("missing value for \(option)") }
            let value = arguments[index + 1]
            switch option {
            case "--device": guard !value.isEmpty else { throw invalid("empty logical selector") }; result.device = value
            case "--samples":
                guard action == .telemetry, let count = Int(value), (1...1000).contains(count) else { throw invalid("--samples requires an integer in 1...1000 and telemetry") }
                result.samples = count
            case "--interval":
                guard action == .telemetry, let seconds = Double(value), seconds.isFinite, (0.1...3600).contains(seconds) else { throw invalid("--interval requires seconds in [0.1, 3600] and telemetry") }
                result.interval = seconds
            case "--dpi", "--dpi-x", "--dpi-y":
                guard [.preview, .apply].contains(action), let dpi = UInt16(value), dpi > 0 else { throw invalid("DPI requires an integer in 1...65535 and preview/apply") }
                if option == "--dpi" { guard result.dpiX == nil, result.dpiY == nil else { throw invalid("do not combine unified and axis DPI") }; result.dpiX = dpi; result.dpiY = dpi }
                else if option == "--dpi-x" { guard !seen.contains("--dpi") else { throw invalid("do not combine unified and axis DPI") }; result.dpiX = dpi }
                else { guard !seen.contains("--dpi") else { throw invalid("do not combine unified and axis DPI") }; result.dpiY = dpi }
            case "--rate":
                guard [.preview, .apply].contains(action), let rate = Int(value), (1...8000).contains(rate) else { throw invalid("--rate requires an integer in 1...8000 and preview/apply") }; result.rate = rate
            case "--dpi-stages":
                guard [.preview, .apply].contains(action) else { throw invalid("--dpi-stages requires settings preview/apply") }
                var stages: [DPIStage] = []
                for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
                    let fields = entry.split(separator: ":", omittingEmptySubsequences: false)
                    guard fields.count == 3, let id = UInt8(fields[0]), let x = UInt16(fields[1]), let y = UInt16(fields[2]), x > 0, y > 0 else { throw invalid("--dpi-stages requires id:x:y entries with exact existing stage IDs") }
                    stages.append(DPIStage(id: id, dpi: DPISetting(x: x, y: y)))
                }
                guard !stages.isEmpty, stages.count <= 5, Set(stages.map(\.id)).count == stages.count else { throw invalid("stage edits must contain 1...5 unique IDs") }
                result.dpiStages = stages
            case "--default-stage", "--current-stage":
                guard [.preview, .apply].contains(action), let id = UInt8(value) else { throw invalid("stage ID must be an integer in 0...255 and preview/apply") }
                if option == "--default-stage" { result.defaultStage = id } else { result.currentStage = id }
            case "--active-profile":
                guard [.preview, .apply].contains(action), let id = Int(value), (0...65535).contains(id) else { throw invalid("active profile must be an integer in 0...65535 and preview/apply") }; result.activeProfile = id
            case "--scope":
                guard [.preview, .apply].contains(action), let scope = SettingPersistence(rawValue: value), scope != .unknown else { throw invalid("--scope requires runtime or onboard and preview/apply") }; result.scope = scope
            case "--validation-operation":
                guard [.apply, .restore].contains(action), let operation = SettingValidationOperation(rawValue: value) else { throw invalid("--validation-operation must name one exact implemented validation operation") }; result.validationOperation = operation
            case "--input": guard action == .restore, !value.isEmpty else { throw invalid("--input requires profiles restore") }; result.input = value
            case "--output": guard [.export, .captureLayout].contains(action), !value.isEmpty else { throw invalid("--output requires profiles export or capture-layout") }; result.output = value
            case "--rollback-output": guard action == .restore, !value.isEmpty else { throw invalid("--rollback-output requires profiles restore") }; result.rollbackOutput = value
            case "--hardware-evidence-reference": guard [.export, .restore, .preview, .apply].contains(action), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("a confirmed local evidence file requires profile actions or settings preview/apply") }; result.hardwareEvidenceReference = URL(fileURLWithPath: value).standardizedFileURL.path
            case "--backup-output": guard [.preview, .apply].contains(action), !value.isEmpty else { throw invalid("--backup-output requires settings preview/apply") }; result.backupOutput = value
            default: throw invalid("unknown option \(option)")
            }
            index += 2
        }
        if action != .capabilities, result.device == nil { throw invalid("an explicit --device logical selector is required") }
        if [.preview, .apply].contains(action) {
            guard result.dpiX != nil || result.dpiY != nil || result.rate != nil || result.dpiStages != nil || result.defaultStage != nil || result.currentStage != nil || result.activeProfile != nil, result.scope != nil else { throw invalid("preview/apply requires a setting change and an explicit --scope") }
        }
        if action == .apply, result.scope == .onboard, result.backupOutput == nil { throw invalid("onboard apply requires a new --backup-output file before writing") }
        if [.preview, .apply].contains(action), result.backupOutput != nil || result.hardwareEvidenceReference != nil, result.scope != .onboard { throw invalid("backup/layout evidence flags require --scope onboard") }
        if action == .preview, result.hardwareEvidenceReference != nil, result.backupOutput == nil { throw invalid("a confirmed-layout preview requires a new --backup-output source image") }
        if result.dpiStages != nil || result.defaultStage != nil, result.scope != .onboard { throw invalid("DPI stage tables and their default selection require --scope onboard") }
        if result.validationOperation != nil, action == .apply, !result.restoreOriginal { throw invalid("first-operation validation requires --restore-original to verify recovery in this invocation") }
        if [.export, .captureLayout].contains(action), result.output == nil { throw invalid("profiles export/capture-layout requires --output to a new local file") }
        if action == .restore, result.input == nil || result.rollbackOutput == nil { throw invalid("profiles restore requires --input and a new --rollback-output recovery file") }
        return result
    }
    private static func invalid(_ message: String) -> ProbeCLIError { .arguments(message + "\n" + ProbeOptions.usage) }

    func change(from settings: DeviceSettings) throws -> DeviceSettingsChange {
        var dpi: DPISetting?
        if dpiX != nil || dpiY != nil {
            guard let x = dpiX ?? settings.currentDPI?.x, let y = dpiY ?? settings.currentDPI?.y else { throw Self.invalid("cannot preserve an unknown DPI axis; read both axes first") }
            dpi = DPISetting(x: x, y: y)
        }
        var table: DPIStageTable?
        if dpiStages != nil || defaultStage != nil {
            guard let original = settings.stages, !original.stages.isEmpty, !original.opaqueBytes.isEmpty else { throw Self.invalid("a complete known-layout stage table is required; export with confirmed hardware evidence first") }
            let ids = Set(original.stages.map(\.id))
            guard dpiStages?.allSatisfy({ ids.contains($0.id) }) ?? true else { throw Self.invalid("a stage edit cannot invent, reorder, or remove existing IDs") }
            if let defaultStage, !ids.contains(defaultStage) { throw Self.invalid("default stage must be an existing exact ID") }
            let edits = Dictionary(uniqueKeysWithValues: (dpiStages ?? []).map { ($0.id, $0.dpi) })
            let stages = original.stages.map { DPIStage(id: $0.id, dpi: edits[$0.id] ?? $0.dpi) }
            // Razer has one source-confirmed active field; HID++ format 3 has a
            // distinct stored default and a separately read current selection.
            table = DPIStageTable(stages: stages, activeStageID: original.defaultStageID == nil ? (defaultStage ?? original.activeStageID) : original.activeStageID,
                                  opaqueBytes: original.opaqueBytes, defaultStageID: original.defaultStageID == nil ? nil : (defaultStage ?? original.defaultStageID))
        }
        return DeviceSettingsChange(currentDPI: dpi, pollingRateHz: rate, stages: table, activeProfileID: activeProfile, persistence: scope ?? .runtime, currentStageID: currentStage)
    }
}

private struct ProbeMemoryPreferences: DevicePreferencesPersisting {
    func load() throws -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) throws {}
}
struct LogicalProbeDevice: Encodable {
    let schemaVersion = 1
    let source = "current host discovery and target protocol handshake"
    let capturedAt: Date
    let identityReceivedAt: Date?
    let selector: String
    let generation: UUID
    let product: String
    let host: String
    let hostVendorID: UInt16?
    let hostProductID: UInt16?
    let connection: String?
    let controlEndpointRegistryEntryID: UInt64?
    let controlDescriptorSHA256: String?
    let deviceIndex: UInt8?
    let wirelessProductID: UInt16?
    let protocolVersion: String?
    let firmware: String?
    let unitIdentitySHA256: String?
    let identityAmbiguous: Bool
    let controlTrace: HIDPPControlTraceSnapshot?
    let capabilities: DeviceCapabilities
    let settings: ProbeSettingsValues?
    let settingsRevision: UInt64?
    init(_ device: LogicalDeviceState, hosts: [DeviceState], capturedAt: Date, identityReceivedAt: Date? = nil, controlTrace: HIDPPControlTraceSnapshot? = nil) {
        self.capturedAt = capturedAt; self.identityReceivedAt = identityReceivedAt
        self.controlTrace = controlTrace
        identityAmbiguous = device.descriptor.isIdentityAmbiguous
        selector = device.id.rawValue; generation = device.sessionID.generation; product = device.displayName
        host = device.sessionID.address.hostSessionID.physicalDeviceID.rawValue; capabilities = device.capabilities
        let physical = hosts.first { $0.id == device.sessionID.address.hostSessionID.physicalDeviceID }
        hostVendorID = physical?.descriptor.vendorID; hostProductID = physical?.descriptor.productID
        let endpoint = physical?.descriptor.interfaces.first { $0.registryEntryID == device.descriptor.controlEndpointRegistryEntryID }
        controlEndpointRegistryEntryID = device.descriptor.controlEndpointRegistryEntryID
        controlDescriptorSHA256 = endpoint?.descriptorSHA256; connection = endpoint?.transport
        if let identity = device.descriptor.peripheralIdentity {
            if case let .receiver(index, _) = device.descriptor.address.target { deviceIndex = index }
            else { deviceIndex = 0xFF }
            wirelessProductID = identity.wirelessProductID; protocolVersion = identity.protocolVersion; firmware = identity.firmware
            unitIdentitySHA256 = identity.unitID.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        } else { deviceIndex = nil; wirelessProductID = nil; protocolVersion = nil; firmware = nil; unitIdentitySHA256 = nil }
        settings = device.settings.map { ProbeSettingsValues($0.settings) }; settingsRevision = device.settings?.revision
    }
}
private struct FeatureProbeReport: Encodable {
    let schemaVersion = 1
    let command = "logitech features"
    let source = "runtime discovered target feature directory"
    let receivedAt: Date?
    let target: LogicalProbeDevice
    let features: [HIDPPFeature]
    let controlTrace: HIDPPControlTraceSnapshot?
}
private struct StageLayoutCaptureReport: Encodable {
    let savedTo: String
    let source: RazerStageEvidenceSource
    let layout: RazerStageEvidenceLayout
    let observations: Int
    let hardwareConfirmed = false
    let writeAuthorizationGranted = false
}
/// Never print opaque profile bytes in ordinary CLI output. Recovery images are
/// written only through the explicit local backup workflow.
struct ProbeSettingsValues: Encodable {
    let currentDPI: DPISetting?
    let pollingRateHz: Int?
    let stages: [DPIStage]?
    let stageLayout: String?
    let activeStageID: UInt8?
    let defaultStageID: UInt8?
    let currentStageID: UInt8?
    let activeProfileID: Int?
    init(_ settings: DeviceSettings) {
        currentDPI = settings.currentDPI; pollingRateHz = settings.pollingRateHz
        stages = settings.stages?.stages; activeStageID = settings.stages?.activeStageID; defaultStageID = settings.stages?.defaultStageID; currentStageID = settings.currentStageID; activeProfileID = settings.activeProfileID
        stageLayout = settings.stages.map { $0.stages.isEmpty ? "unconfirmed" : "decoded" }
    }
}
private struct ProbeRequestedSettings: Encodable {
    let values: ProbeSettingsValues
    let persistence: SettingPersistence
    init(_ change: DeviceSettingsChange) {
        values = ProbeSettingsValues(DeviceSettings(currentDPI: change.currentDPI, pollingRateHz: change.pollingRateHz, stages: change.stages, activeProfileID: change.activeProfileID, currentStageID: change.currentStageID))
        persistence = change.persistence
    }
}
private struct SettingsReadReport: Encodable {
    let selector: String
    let revision: UInt64
    let capturedAt: Date
    let settings: ProbeSettingsValues
    init(_ snapshot: DeviceSettingsSnapshot) {
        selector = snapshot.session.deviceID.rawValue; revision = snapshot.revision; capturedAt = snapshot.capturedAt
        settings = ProbeSettingsValues(snapshot.settings)
    }
}
private struct SettingsProbeResult: Encodable {
    let phase: String
    let selector: String
    let status: SettingChangeStatus
    let persistence: SettingPersistence
    let requested: ProbeRequestedSettings
    let before: ProbeSettingsValues?
    let observed: ProbeSettingsValues?
    let message: String?
    let fields: [SettingFieldResult]
    init(_ result: SettingChangeResult, phase: String = "apply") {
        self.phase = phase; selector = result.request.target.deviceID.rawValue
        status = result.status; persistence = result.persistence; requested = ProbeRequestedSettings(result.request.change)
        before = result.before.map { ProbeSettingsValues($0.settings) }; observed = result.observed.map { ProbeSettingsValues($0.settings) }; message = result.message; fields = result.fields
    }
}

enum ExpansionProbe {
    @discardableResult
    static func run(_ options: ExpansionProbeOptions, discovery: HIDDiscovery, registry suppliedRegistry: DriverRegistry? = nil) async throws -> Bool {
        let registry = suppliedRegistry ?? DriverRegistry(registrations: DriverRegistry.standardRegistrations(
            razerReader: RazerBatteryDriver(transport: discovery), razerSettings: RazerMouseDriver(discovery: discovery),
            logitech: LogitechReceiverDriver(controlTraceCapacity: options.trace ? 128 : 0)))
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, preferences: ProbeMemoryPreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        let controller = DeviceController(monitor: monitor, registry: registry)
        await monitor.start()
        do {
            var succeeded = true
            let ready = await monitor.initialDiscoveryReady()
            if let error = ready.discoveryFailure { throw ProbeCLIError.arguments(error) }
            let snapshot = await monitor.snapshot()
            let present = snapshot.logicalDevices.filter { $0.hostPresence == .present }
            if options.action == .capabilities {
                let devices = options.device.map { selector in present.filter { $0.id.rawValue == selector } } ?? present
                if options.device != nil, devices.count != 1 { throw ProbeCLIError.arguments("No unique current logical device matches --device.") }
                var reports: [LogicalProbeDevice] = []
                for device in devices {
                    let received = try await identityReceivedAt(device, monitor: monitor)
                    let trace = options.trace ? try await controlTrace(device, monitor: monitor) : nil
                    reports.append(LogicalProbeDevice(device, hosts: snapshot.devices, capturedAt: snapshot.capturedAt, identityReceivedAt: received, controlTrace: trace))
                }
                try printJSON(reports)
            } else {
                guard let target = present.first(where: { $0.id.rawValue == options.device }), present.filter({ $0.id.rawValue == options.device }).count == 1 else { throw ProbeCLIError.arguments("No unique current logical device matches --device. Run capabilities to inspect current selectors.") }
                switch options.action {
                case .read: try printJSON(SettingsReadReport(try await controller.readSettings(logicalDeviceID: target.id)))
                case .telemetry:
                    guard let host = snapshot.devices.first(where: { $0.id == target.sessionID.address.hostSessionID.physicalDeviceID }),
                          host.descriptor.vendorID == 0x046D, let driver = registry.logicalDriver(for: host.descriptor) else {
                        throw ProbeCLIError.arguments("telemetry requires a current Logitech logical target. The legacy Razer battery command is separate.")
                    }
                    let received = try await identityReceivedAt(target, monitor: monitor)
                    let trace: (@Sendable () async throws -> HIDPPControlTraceSnapshot)?
                    if options.trace, let adapter = driver as? LogitechReceiverDriver {
                        trace = { try await adapter.controlTraceSnapshot(target: target.descriptor, session: target.sessionID) }
                    } else { trace = nil }
                    let report = try await TelemetryProbe.capture(options: options, target: target, initialSnapshot: snapshot,
                        monitor: monitor, driver: driver, identityReceivedAt: received, trace: trace)
                    try printJSON(report, fractionalDates: true)
                    succeeded = report.succeeded
                case .preview, .apply:
                    if options.scope == .onboard, let output = options.backupOutput {
                        _ = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: URL(fileURLWithPath: output), hardwareEvidenceReference: options.hardwareEvidenceReference)
                    }
                    var before = try await controller.readSettings(logicalDeviceID: target.id)
                    let change = try options.change(from: before.settings)
                    var request = SettingChangeRequest(target: before.session, expectedRevision: before.revision, change: change)
                    if options.action == .preview { try printJSON(await controller.preview(request)) }
                    else {
                        if options.restoreOriginal {
                            (before, request) = try await preflightRecovery(before: before, request: request, controller: controller, operation: options.validationOperation,
                                backupURL: options.backupOutput.map { URL(fileURLWithPath: $0) }, hardwareEvidenceReference: options.hardwareEvidenceReference)
                        }
                        if let _ = options.validationOperation, change.fields.allSatisfy({ change.matches(before.settings, field: $0) }) {
                            throw ProbeCLIError.arguments("Validation requires a supported value different from the actual before state; no no-op probe was sent.")
                        }
                        let result: SettingChangeResult
                        if let operation = options.validationOperation {
                            let authorization = try await controller.authorizeValidation(request, operation: operation)
                            result = await controller.applyValidation(request, authorization: authorization)
                        } else { result = await controller.apply(request) }
                        try printJSON(SettingsProbeResult(result))
                        if options.restoreOriginal { try await restoreOriginal(before: before, after: result, controller: controller, operation: options.validationOperation,
                                                                             backupURL: options.backupOutput.map { URL(fileURLWithPath: $0) }, hardwareEvidenceReference: options.hardwareEvidenceReference) }
                        guard result.status == .verified else { throw ProbeCLIError.arguments("Settings were not verified; inspect the reported actual state before another action.") }
                    }
                case .features:
                    guard let adapter = await monitor.settingsAdapter(for: target.id) as? LogitechReceiverDriver else { throw ProbeCLIError.arguments("The selected target has no Logitech feature directory.") }
                    let features = try await adapter.featureDirectory(target: target.descriptor, session: target.sessionID)
                    let received = try await identityReceivedAt(target, monitor: monitor)
                    let trace = options.trace ? try await controlTrace(target, monitor: monitor) : nil
                    try printJSON(FeatureProbeReport(receivedAt: received, target: LogicalProbeDevice(target, hosts: snapshot.devices, capturedAt: snapshot.capturedAt, identityReceivedAt: received), features: features, controlTrace: trace))
                case .export:
                    let url = URL(fileURLWithPath: options.output!)
                    let backup = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: url, hardwareEvidenceReference: options.hardwareEvidenceReference)
                    try printJSON(["savedTo": url.path, "format": backup.identity.formatID, "formatVersion": String(backup.identity.formatVersion), "regions": backup.regions.map(\.id).joined(separator: ","), "identity": backup.identity.unitID == nil ? "current-session-only" : "confirmed-unit-private-backup"])
                case .captureLayout:
                    let url = URL(fileURLWithPath: options.output!)
                    let document = try await controller.captureStageLayoutEvidence(logicalDeviceID: target.id, saveTo: url)
                    try printJSON(StageLayoutCaptureReport(savedTo: url.path, source: document.source, layout: document.layout, observations: document.observations.count))
                case .restore:
                    let request = try await controller.prepareProfileRestore(backupURL: URL(fileURLWithPath: options.input!), rollbackBackupURL: URL(fileURLWithPath: options.rollbackOutput!), logicalDeviceID: target.id, hardwareEvidenceReference: options.hardwareEvidenceReference)
                    let result: SettingChangeResult
                    if let operation = options.validationOperation { result = await controller.applyValidation(request, authorization: try await controller.authorizeValidation(request, operation: operation)) }
                    else { result = await controller.apply(request) }
                    try printJSON(SettingsProbeResult(result))
                    guard result.status == .verified else { throw ProbeCLIError.arguments("Profile recovery was not verified; the rollback backup was preserved. No write is retried automatically.") }
                case .capabilities: break
                }
            }
            await monitor.stop()
            return succeeded
        } catch { await monitor.stop(); throw error }
    }
    private static func identityReceivedAt(_ target: LogicalDeviceState, monitor: BatteryMonitor) async throws -> Date? {
        guard let adapter = await monitor.settingsAdapter(for: target.id) as? LogitechReceiverDriver else { return nil }
        return try await adapter.identityReceivedAt(target: target.descriptor, session: target.sessionID)
    }
    private static func controlTrace(_ target: LogicalDeviceState, monitor: BatteryMonitor) async throws -> HIDPPControlTraceSnapshot? {
        guard let adapter = await monitor.settingsAdapter(for: target.id) as? LogitechReceiverDriver else { return nil }
        return try await adapter.controlTraceSnapshot(target: target.descriptor, session: target.sessionID)
    }

    static func recoveryChange(before: DeviceSettings, requested: DeviceSettingsChange) throws -> DeviceSettingsChange {
        let change = DeviceSettingsChange(currentDPI: requested.currentDPI == nil ? nil : before.currentDPI,
                                          pollingRateHz: requested.pollingRateHz == nil ? nil : before.pollingRateHz,
                                          stages: requested.stages == nil ? nil : before.stages,
                                          activeProfileID: requested.activeProfileID == nil ? nil : before.activeProfileID,
                                          persistence: requested.persistence,
                                          currentStageID: requested.currentStageID == nil ? nil : before.currentStageID)
        guard Set(change.fields) == Set(requested.fields) else { throw ProbeCLIError.arguments("Original values for every changed field are required for recovery; no setting was sent.") }
        return change
    }
    /// A recovery is a second exact operation, not merely a set of present values.
    /// Authorize its original semantics before the first setting report is sent.
    /// The unused preflight token is revision-bound and is never replayed after
    /// the first write; the actual recovery obtains a new exact authorization.
    private static func preflightRecovery(before original: DeviceSettingsSnapshot, request: SettingChangeRequest,
                                          controller: DeviceController, operation: SettingValidationOperation?, backupURL: URL?,
                                          hardwareEvidenceReference: String?) async throws -> (DeviceSettingsSnapshot, SettingChangeRequest) {
        let originalChange = try recoveryChange(before: original.settings, requested: request.change)
        var before = original
        var recovery = SettingChangeRequest(target: before.session, expectedRevision: before.revision, change: originalChange)
        if originalChange.stages != nil {
            guard let backupURL else { throw ProbeCLIError.arguments("A complete saved original stage image is required to authorize recovery before writing.") }
            let rollbackURL = backupURL.deletingLastPathComponent().appendingPathComponent("recovery-preflight-\(UUID().uuidString).json")
            let prepared = try await controller.prepareProfileRestore(backupURL: backupURL, rollbackBackupURL: rollbackURL,
                logicalDeviceID: before.session.deviceID, hardwareEvidenceReference: hardwareEvidenceReference)
            guard let stages = prepared.change.stages,
                  DeviceSettingsChange(stages: stages, persistence: request.change.persistence).matches(original.settings, field: .stages) else {
                throw ProbeCLIError.arguments("The saved stage image does not restore the actual original fields; no setting was sent.")
            }
            before = try await controller.readSettings(logicalDeviceID: before.session.deviceID)
            guard before.session == original.session, before.settings == original.settings else {
                throw ProbeCLIError.arguments("Actual settings changed while validating recovery; no setting was sent.")
            }
            let projected = DeviceSettingsChange(currentDPI: originalChange.currentDPI, pollingRateHz: originalChange.pollingRateHz,
                stages: stages, activeProfileID: originalChange.activeProfileID, persistence: originalChange.persistence,
                currentStageID: originalChange.currentStageID)
            recovery = SettingChangeRequest(target: before.session, expectedRevision: before.revision, change: projected)
        }
        if let operation {
            do { _ = try await controller.authorizeValidation(recovery, operation: operation) }
            catch { throw ProbeCLIError.arguments("The selected operation cannot authorize restoring the actual original values; no setting was sent. " + String(describing: error)) }
        } else {
            let issues = await controller.preview(recovery)
            guard issues.isEmpty else { throw ProbeCLIError.arguments("The complete original values cannot be restored within the verified capability; no setting was sent. " + issues.map(\.reason).joined(separator: " ")) }
        }
        return (before, SettingChangeRequest(id: request.id, target: before.session, expectedRevision: before.revision, change: request.change))
    }
    private static func restoreOriginal(before: DeviceSettingsSnapshot, after: SettingChangeResult, controller: DeviceController, operation: SettingValidationOperation?, backupURL: URL?, hardwareEvidenceReference: String?) async throws {
        guard after.status == .verified, let observed = after.observed else { throw ProbeCLIError.arguments("The change was not verified; automatic recovery was not attempted because the outcome is uncertain.") }
        let change = try recoveryChange(before: before.settings, requested: after.request.change)
        let restore: SettingChangeRequest
        if change.stages != nil {
            guard let backupURL else { throw ProbeCLIError.arguments("Stage recovery requires the saved complete original backup.") }
            let rollbackURL = backupURL.deletingLastPathComponent().appendingPathComponent("pre-recovery-\(UUID().uuidString).json")
            let prepared = try await controller.prepareProfileRestore(backupURL: backupURL, rollbackBackupURL: rollbackURL, logicalDeviceID: observed.session.deviceID, hardwareEvidenceReference: hardwareEvidenceReference)
            guard let restoredStages = prepared.change.stages,
                  DeviceSettingsChange(stages: restoredStages, persistence: change.persistence).matches(before.settings, field: .stages) else {
                throw ProbeCLIError.arguments("The recovery image no longer reconstructs the actual original stage fields; no recovery setting was sent.")
            }
            let restored = DeviceSettingsChange(currentDPI: change.currentDPI, pollingRateHz: change.pollingRateHz, stages: restoredStages,
                                               activeProfileID: change.activeProfileID, persistence: change.persistence, currentStageID: change.currentStageID)
            restore = SettingChangeRequest(target: prepared.target, expectedRevision: prepared.expectedRevision, change: restored)
        } else { restore = SettingChangeRequest(target: observed.session, expectedRevision: observed.revision, change: change) }
        let result: SettingChangeResult
        if let operation { result = await controller.applyValidation(restore, authorization: try await controller.authorizeValidation(restore, operation: operation)) }
        else if restore.change.persistence == .onboard, let backupURL,
                try FileProfileBackup(url: backupURL).load().identity.formatID == "razer.00c5.current-settings" {
            let rollbackURL = backupURL.deletingLastPathComponent().appendingPathComponent("pre-recovery-\(UUID().uuidString).json")
            let prepared = try await controller.prepareOnboardChange(restore, saveBackupTo: rollbackURL,
                hardwareEvidenceReference: hardwareEvidenceReference)
            result = await controller.apply(prepared)
        } else { result = await controller.apply(restore) }
        try printJSON(SettingsProbeResult(result, phase: "restoreOriginal"))
        guard result.status == .verified else { throw ProbeCLIError.arguments("Recovery did not verify. Preserve the displayed before/observed values for manual review.") }
    }
    static func printJSON<T: Encodable>(_ value: T, fractionalDates: Bool = false) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        if fractionalDates {
            encoder.dateEncodingStrategy = .custom { date, encoder in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var container = encoder.singleValueContainer()
                try container.encode(formatter.string(from: date))
            }
        }
        FileHandle.standardOutput.write(try encoder.encode(value) + Data([10]))
    }
}
