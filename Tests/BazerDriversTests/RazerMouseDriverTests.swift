// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
@testable import BazerDrivers
@testable import BazerHID
import Foundation
import RazerProtocol
import Testing

private final class MouseSettingsBackend: HIDDiscoveryBackend, HIDSynchronousReportBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var request: HIDReadOnlyFeatureRequest?
    private var sent: [[UInt8]] = []
    private var dpi: [UInt8] = [1, 3, 32, 4, 176] + Array(repeating: 0xA7, count: 75)
    private var stages: [UInt8] = [1, 3, 2, 3, 3, 32, 4, 176, 0xAA, 0xBB, 7, 6, 64, 7, 208, 0xCC, 0xDD] + Array(repeating: 0xE9, count: 63)
    private var rate: UInt8 = 2
    private var firmwareMinor: UInt8 = 2
    var ignoreRateWrite = false
    var loseDPIAcknowledgement = false
    var invalidateDPIAcknowledgement = false
    var ignoreDPIWrite = false
    var loseDPIReadback = false
    var loseRateReadback = false
    var failFirmwareRead = false
    var failSettingsReads = false
    var mutateStageAfterDPIWrite = false
    private var wroteDPI = false
    private var identityUnavailable = false
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
            case .setDPI:
                wroteDPI = true
                if !ignoreDPIWrite { dpi = Array(request.bytes[8...87]) }
                if mutateStageAfterDPIWrite { stages[8] ^= 1 }
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
                if !identityUnavailable { let serial = Array("OFFLINE-UNIT-123".utf8); bytes[8..<(8 + serial.count)] = serial[...] }
            default: break
            }
            if invalidateDPIAcknowledgement, case .setDPI = request.operation { bytes[0] = 5 }
            bytes[88] = bytes[2...87].reduce(0, ^)
            let failure = loseDPIAcknowledgement && { if case .setDPI = request.operation { true } else { false } }()
            let missingReadback = wroteDPI && {
                switch request.operation {
                case .readDPI: return loseDPIReadback
                case .readPollingRate: return loseRateReadback
                default: return false
                }
            }()
            let missingFirmware = failFirmwareRead && request.operation == .readFirmware
            return HIDRawFeatureReport(operation: diagnostic("getFeature", registryEntryID, code: failure || missingReadback || missingFirmware || failSettingsReads ? -1 : 0), bytes: bytes, actualLength: bytes.count)
        }
    }
    func loseIdentity() { lock.withLock { identityUnavailable = true } }
    func changeStageReservedByte() { lock.withLock { stages[8] ^= 1 } }
    func externalFirmware(_ minor: UInt8) { lock.withLock { firmwareMinor = minor } }
    func externalDPI(_ x: UInt16, _ y: UInt16) { lock.withLock { dpi[1] = UInt8(x >> 8); dpi[2] = UInt8(x & 255); dpi[3] = UInt8(y >> 8); dpi[4] = UInt8(y & 255) } }
}
private struct MouseVolatilePreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}
private func settingsRig(_ backend: MouseSettingsBackend, automaticallyRefreshTelemetry: Bool = true, verifiedWrites: Bool = false,
                         xyVerified: Bool = false, persistedValues: Bool = false, initialSettingsRead: Bool = true) async throws -> (BatteryMonitor, DeviceController, LogicalDeviceState) {
    let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
    if verifiedWrites && initialSettingsRead {
        backend.externalDPI(800, 800)
    }
    let profiles = verifiedWrites ? [RazerVerifiedTestFixtures.profile(descriptorSHA256: MouseSettingsBackend.descriptor.descriptorSHA256, persisted: persistedValues, xy: xyVerified)] : []
    let driver = RazerMouseDriver(discovery: discovery, verifiedProfiles: profiles)
    let registrations = DriverRegistry.standardRegistrations(razerSettings: driver)
    let registry = DriverRegistry(registrations: registrations)
    let monitor = BatteryMonitor(discovery: discovery, reader: registry, preferences: MouseVolatilePreferences(), registry: registry, automaticallyRefreshTelemetry: automaticallyRefreshTelemetry)
    await monitor.start(); _ = await monitor.initialDiscoveryReady()
    let target = try #require(await monitor.snapshot().logicalDevices.first)
    let controller = DeviceController(monitor: monitor)
    if initialSettingsRead { _ = try await controller.readSettings(logicalDeviceID: target.id) }
    return (monitor, controller, try #require(await monitor.snapshot().logicalDevices.first))
}

@Suite("M8/M11 Razer actual read/write/readback through offline HID backend", .serialized)
struct RazerMouseDriverTests {
    @Test func currentSettingsRecoveryRebindsAStoredBackupToFreshReadSessionWithoutAutomaticWrites() async throws {
        let backend = MouseSettingsBackend()
        let (firstMonitor, firstController, original) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("before.json"), originalDPI = backend.dpiPayload
        _ = try await firstController.exportProfile(logicalDeviceID: original.id, saveTo: path)
        await firstMonitor.stop()
        backend.externalDPI(1600, 1600)
        let (monitor, controller, fresh) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true, initialSettingsRead: false)
        #expect(fresh.settings == nil); #expect(fresh.sessionID != original.sessionID)
        #expect(!fresh.capabilities.permits(.dpiWrite))
        let restore = try await controller.prepareProfileRestore(backupURL: path,
            rollbackBackupURL: directory.appendingPathComponent("rollback.json"), logicalDeviceID: fresh.id)
        #expect(restore.target == fresh.sessionID)
        #expect(restore.change.currentDPI == DPISetting(800)); #expect(restore.change.stages == nil)
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        #expect(await controller.apply(restore).status == .verified)
        #expect(backend.dpiPayload == originalDPI)
        await monitor.stop()
    }
    @Test func mintingCandidateAuthorizationCannotMakeOrdinaryApplySkipItsRecoveryBackup() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard))
        _ = try await controller.authorizeValidation(request, operation: .razer00C5DPI)
        #expect(await controller.apply(request).status == .rejected)
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        await monitor.stop()
    }
    @Test func reviewedIndependentXYPairsWriteAndRestoreThroughOrdinaryTransactions() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false,
            verifiedWrites: true, xyVerified: true, persistedValues: true)
        let originalDPI = backend.dpiPayload, originalStages = backend.stagePayload
        #expect(target.capabilities.permits(.independentXY))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, pair) in [DPISetting(x: 800, y: 1600), DPISetting(x: 1600, y: 800)].enumerated() {
            let before = try await controller.readSettings(logicalDeviceID: target.id)
            let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
                change: DeviceSettingsChange(currentDPI: pair, persistence: .onboard))
            let path = directory.appendingPathComponent("before-\(index).json")
            let prepared = try await controller.prepareOnboardChange(request, saveBackupTo: path)
            let result = await controller.apply(prepared)
            #expect(result.status == .verified); #expect(result.observed?.settings.currentDPI == pair)
            #expect(result.persistence == (index == 0 ? .onboard : .unknown))
            #expect(backend.stagePayload == originalStages)
            #expect(Array(backend.dpiPayload[5...79]) == Array(originalDPI[5...79]))
            let restore = try await controller.prepareProfileRestore(backupURL: path,
                rollbackBackupURL: directory.appendingPathComponent("rollback-\(index).json"), logicalDeviceID: target.id)
            #expect(restore.change.currentDPI == DPISetting(800)); #expect(restore.change.stages == nil)
            #expect(await controller.apply(restore).status == .verified)
            #expect(backend.dpiPayload == originalDPI); #expect(backend.stagePayload == originalStages)
        }
        #expect(backend.frames.allSatisfy { !($0[6] == 4 && $0[7] == 6) })
        await monitor.stop()
    }
    @Test func ordinaryProfileRequiresSavedFullCurrentImageAndRestoresOnlyDPIAndRate() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        let originalDPI = backend.dpiPayload, originalStages = backend.stagePayload
        #expect(target.capabilities.permits(.dpiWrite)); #expect(target.capabilities.permits(.pollingRateWrite))
        for operation in [DeviceOperation.independentXY, .stagesWrite, .stageSelect, .onboardWrite] { #expect(!target.capabilities.permits(operation)) }
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), pollingRateHz: 1000, persistence: .onboard))
        #expect(await controller.apply(request).status == .rejected)
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        // A preflight rejection revokes cached write evidence until another real read.
        #expect(await monitor.snapshot().logicalDevices.first?.capabilities.permits(.dpiWrite) == false)
        let fresh = try await controller.readSettings(logicalDeviceID: target.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupURL = directory.appendingPathComponent("before.json")
        let prepared = try await controller.prepareOnboardChange(SettingChangeRequest(target: fresh.session, expectedRevision: fresh.revision, change: request.change), saveBackupTo: backupURL)
        let backup = try FileProfileBackup(url: backupURL).load()
        #expect(backup.identity.formatID == "razer.00c5.current-settings")
        #expect(backup.identity.unitID == RazerVerifiedTestFixtures.unitID)
        #expect(backup.regions.first(where: { $0.id == "current-dpi-payload" })?.bytes == originalDPI)
        #expect(backup.regions.first(where: { $0.id == "dpi-stage-payload" })?.bytes == originalStages)
        let result = await controller.apply(prepared)
        #expect(result.status == .verified); #expect(result.persistence == .unknown)
        #expect(result.observed?.settings.currentDPI == DPISetting(1600))
        #expect(backend.stagePayload == originalStages)
        #expect(Array(backend.dpiPayload[5...79]) == Array(originalDPI[5...79]))
        let restore = try await controller.prepareProfileRestore(backupURL: backupURL, rollbackBackupURL: directory.appendingPathComponent("rollback.json"), logicalDeviceID: target.id)
        #expect(restore.change.fields == [.currentDPI, .pollingRate]); #expect(restore.change.stages == nil)
        #expect(await controller.apply(restore).status == .verified)
        #expect(backend.dpiPayload == originalDPI); #expect(backend.stagePayload == originalStages)
        #expect(backend.frames.allSatisfy { !($0[6] == 4 && $0[7] == 6) })
        await monitor.stop()
    }

    @Test(arguments: [0, 1, 2]) func failedSettingsFirmwareOrUnitReadRevokesOrdinaryPromotion(failure: Int) async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        #expect(target.capabilities.permits(.dpiWrite))
        if failure == 0 { backend.failFirmwareRead = true }
        else if failure == 1 { backend.loseIdentity() }
        else { backend.failSettingsReads = true }
        do {
            _ = try await controller.readSettings(logicalDeviceID: target.id)
            #expect(failure != 2)
        } catch { #expect(failure == 2) }
        let capabilities = try #require(await monitor.snapshot().logicalDevices.first?.capabilities)
        for operation in RazerVerifiedHardwareProfile.managedOperations { #expect(!capabilities.permits(operation)) }
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        await monitor.stop()
    }

    @Test(arguments: [false, true]) func ordinaryWriteRechecksFirmwareAndUnitAfterBackup(changedFirmware: Bool) async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try await controller.prepareOnboardChange(request, saveBackupTo: directory.appendingPathComponent("before.json"))
        if changedFirmware { backend.externalFirmware(3) } else { backend.loseIdentity() }
        #expect(await controller.apply(prepared).status == .rejected)
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        #expect(await monitor.snapshot().logicalDevices.first?.capabilities.permits(.dpiWrite) == false)
        await monitor.stop()
    }

    @Test func currentSettingsRestoreRejectsChangedOpaqueStageImageWithoutStageWrites() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("before.json")
        _ = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: path)
        backend.changeStageReservedByte()
        do {
            _ = try await controller.prepareProfileRestore(backupURL: path, rollbackBackupURL: directory.appendingPathComponent("rollback.json"), logicalDeviceID: target.id)
            Issue.record("Changed opaque stage image was accepted for current-settings recovery")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("rollback.json").path))
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        await monitor.stop()
    }

    @Test func unexpectedStageMutationCannotBeReportedAsVerifiedCurrentSettingsWrite() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard))
        let prepared = try await controller.prepareOnboardChange(request, saveBackupTo: directory.appendingPathComponent("before.json"))
        backend.mutateStageAfterDPIWrite = true
        let result = await controller.apply(prepared)
        #expect(result.status == .outcomeUnknown)
        #expect(result.observed?.settings.currentDPI == DPISetting(1600))
        #expect(result.persistence == .unknown)
        #expect(await monitor.snapshot().logicalDevices.first?.capabilities.permits(.dpiWrite) == false)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 1)
        #expect(backend.frames.allSatisfy { !($0[6] == 4 && $0[7] == 6) })
        await monitor.stop()
    }

    @Test func candidateWriteNeedsOneExactTokenAndPreservesOpaqueDPIBytes() async throws {
        let backend = MouseSettingsBackend(), original = backend.dpiPayload
        let (monitor, controller, target) = try await settingsRig(backend)
        let settings = try #require(target.settings)
        #expect(settings.settings.currentDPI == DPISetting(x: 800, y: 1200))
        #expect(settings.settings.pollingRateHz == 500)
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        #expect(!backend.frames.contains { $0[7] == 0x82 })
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: settings.revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard))
        #expect(await controller.apply(request).status == .rejected)
        let token = try await controller.authorizeValidation(request, operation: .razer00C5DPI)
        let result = await controller.applyValidation(request, authorization: token)
        #expect(result.status == .verified); #expect(result.observed?.settings.currentDPI == DPISetting(1600))
        #expect(result.persistence == .unknown)
        #expect(Array(backend.dpiPayload[5...79]) == Array(original[5...79]))
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 1)
        #expect(await controller.applyValidation(request, authorization: token).status == .rejected)
        #expect(await monitor.snapshot().logicalDevices.first?.capabilities[.dpiWrite].evidence == .unknown)
        await monitor.stop()
    }
    @Test func externalChangeSupersedesDraftWithoutSendingAnySetting() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard))
        let token = try await controller.authorizeValidation(request, operation: .razer00C5DPI)
        backend.externalDPI(1200, 1400)
        let result = await controller.applyValidation(request, authorization: token)
        #expect(result.status == .superseded)
        #expect(result.observed?.settings.currentDPI == DPISetting(x: 1200, y: 1400))
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        await monitor.stop()
    }
    @Test func lostWriteAcknowledgementReadsActualStateWithoutRetry() async throws {
        let backend = MouseSettingsBackend(); backend.loseDPIAcknowledgement = true
        let (monitor, controller, target) = try await settingsRig(backend)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1800), persistence: .onboard))
        let token = try await controller.authorizeValidation(request, operation: .razer00C5DPI)
        let result = await controller.applyValidation(request, authorization: token)
        #expect(result.status == .verified); #expect(result.observed?.settings.currentDPI == DPISetting(1800))
        #expect(result.message != nil)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 1)
        await monitor.stop()
    }
    @Test func aFailedWriteResponseValidationIsNotARecoveredMissingACK() async throws {
        let backend = MouseSettingsBackend(); backend.invalidateDPIAcknowledgement = true
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1800), persistence: .onboard))
        let token = try await controller.authorizeValidation(request, operation: .razer00C5DPI)
        let result = await controller.applyValidation(request, authorization: token)
        #expect(result.status == .outcomeUnknown)
        #expect(result.fields.first?.status == .outcomeUnknown)
        #expect(result.observed?.settings.currentDPI == DPISetting(1800))
        #expect(result.message != nil)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 1)
        await monitor.stop()
    }
    @Test(arguments: [false, true])
    func lostACKDoesNotExcuseMissingOrMismatchedIndependentReadback(missing: Bool) async throws {
        let backend = MouseSettingsBackend()
        backend.loseDPIAcknowledgement = true
        backend.loseDPIReadback = missing; backend.ignoreDPIWrite = !missing
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1800), persistence: .onboard))
        let token = try await controller.authorizeValidation(request, operation: .razer00C5DPI)
        let result = await controller.applyValidation(request, authorization: token)
        #expect(result.status == (missing ? .outcomeUnknown : .readbackMismatch))
        #expect(result.fields.first?.status == (missing ? .outcomeUnknown : .readbackMismatch))
        #expect(result.observed?.settings.currentDPI == (missing ? nil : DPISetting(x: 800, y: 1200)))
        #expect(result.message != nil)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 1)
        await monitor.stop()
    }
    @Test func recoveredDPIACKAndSeparateRateReadFailureKeepIndependentPartialEvidence() async throws {
        let backend = MouseSettingsBackend()
        backend.loseDPIAcknowledgement = true; backend.loseRateReadback = true
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false, verifiedWrites: true)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1800), pollingRateHz: 1000, persistence: .onboard))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try await controller.prepareOnboardChange(request, saveBackupTo: directory.appendingPathComponent("before.json"))
        let result = await controller.apply(prepared)
        #expect(result.status == .partialFailure)
        #expect(result.fields.first(where: { $0.field == .currentDPI })?.status == .verified)
        #expect(result.fields.first(where: { $0.field == .pollingRate })?.status == .outcomeUnknown)
        #expect(result.observed?.settings.currentDPI == DPISetting(1800))
        #expect(result.observed?.settings.pollingRateHz == nil)
        #expect(result.message != nil)
        #expect(backend.frames.filter { $0[6] == 4 && $0[7] == 5 }.count == 1)
        #expect(backend.frames.filter { $0[6] == 0 && $0[7] == 5 }.isEmpty)
        await monitor.stop()
    }

    @Test func acknowledgedRateMismatchNeverCachesRequestedRate() async throws {
        let backend = MouseSettingsBackend(); backend.ignoreRateWrite = true
        let (monitor, controller, target) = try await settingsRig(backend)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(pollingRateHz: 1000, persistence: .onboard))
        let token = try await controller.authorizeValidation(request, operation: .razer00C5PollingRate)
        let result = await controller.applyValidation(request, authorization: token)
        #expect(result.status == .readbackMismatch); #expect(result.observed?.settings.pollingRateHz == 500)
        #expect(await monitor.snapshot().logicalDevices.first?.settings?.settings.pollingRateHz == 500)
        await monitor.stop()
    }
    @Test func savedStageBackupPatchAndRestorePreserveEveryUneditedByte() async throws {
        let backend = MouseSettingsBackend(), original = backend.stagePayload
        let (monitor, controller, target) = try await settingsRig(backend)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backupURL = folder.appendingPathComponent("original.json"), rollbackURL = folder.appendingPathComponent("before-restore.json")
        let raw = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: folder.appendingPathComponent("unconfirmed-backup.json"))
        let evidenceURL = folder.appendingPathComponent("simulated-hardware-layout.json")
        // A temporary model of a future human-confirmed file, not a real hardware support claim.
        let evidence = StageEvidenceTestFixtures.confirmed(identity: raw.identity, payload: original)
        try LocalPrivateFile(url: evidenceURL).writeNew(StageEvidenceTestFixtures.encode(evidence))
        let backup = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: backupURL, hardwareEvidenceReference: evidenceURL.path)
        #expect(backup.identity.unitID?.hasPrefix("razer-serial-sha256:") == true)
        #expect(!(try String(contentsOf: backupURL, encoding: .utf8)).contains("OFFLINE-UNIT"))
        let current = try #require(await monitor.snapshot().logicalDevices.first?.settings)
        let table = try #require(current.settings.stages)
        let changed = DPIStageTable(stages: [DPIStage(id: 3, dpi: DPISetting(x: 1000, y: 1400)), table.stages[1]],
            activeStageID: 7, opaqueBytes: table.opaqueBytes)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: current.revision,
            change: DeviceSettingsChange(stages: changed, persistence: .onboard))
        let token = try await controller.authorizeValidation(request, operation: .razer00C5Stages)
        #expect(await controller.applyValidation(request, authorization: token).status == .verified)
        for index in original.indices where ![1,4,5,6,7].contains(index) { #expect(backend.stagePayload[index] == original[index]) }
        let restore = try await controller.prepareProfileRestore(backupURL: backupURL, rollbackBackupURL: rollbackURL,
            logicalDeviceID: target.id, hardwareEvidenceReference: evidenceURL.path)
        let restoreToken = try await controller.authorizeValidation(restore, operation: .razer00C5Stages)
        #expect(await controller.applyValidation(restore, authorization: restoreToken).status == .verified)
        #expect(backend.stagePayload == original)
        await monitor.stop()
    }
    @Test func firmwareChangeInvalidatesExactCandidateAuthorizationBeforeWriting() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: try #require(target.settings).revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard))
        let token = try await controller.authorizeValidation(request, operation: .razer00C5DPI)
        backend.externalFirmware(3)
        #expect(await controller.applyValidation(request, authorization: token).status == .superseded)
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        await monitor.stop()
    }

    @Test func discoveryOnlyProbeStillReadsExplicitSettingsWithoutAutomaticBatteryQueries() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, _, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false)
        #expect(target.settings?.settings.currentDPI == DPISetting(x: 800, y: 1200))
        #expect(!backend.frames.isEmpty)
        #expect(!backend.frames.contains { $0[6] == 7 && ($0[7] == 0x80 || $0[7] == 0x84) })
        await monitor.stop()
    }

    @Test func readOnlyLayoutCaptureNeverConfirmsOrGrantsAndArbitraryReferencesAreRejected() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend, automaticallyRefreshTelemetry: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.json")
        let capture = try await controller.captureStageLayoutEvidence(logicalDeviceID: target.id, saveTo: path)
        #expect(capture.source == .unconfirmedTemplate); #expect(capture.confirmation == nil)
        #expect(capture.layout == .unknown); #expect(capture.stageIDs.isEmpty)
        #expect(capture.capturedPayload == backend.stagePayload); #expect(capture.observations.count == 1)
        #expect(capture.observations[0].selectedStageID == nil)
        #expect(capture.observations[0].stagesResponse.count == 90); #expect(capture.observations[0].dpiResponse.count == 90)
        #expect(capture.identity.unitID?.hasPrefix("razer-serial-sha256:") == true)
        for reference in ["not evidence", path.path, directory.appendingPathComponent("missing.json").path] {
            do {
                _ = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: directory.appendingPathComponent(UUID().uuidString), hardwareEvidenceReference: reference)
                Issue.record("Arbitrary or unconfirmed layout reference was accepted")
            } catch {}
        }
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        #expect(await monitor.snapshot().logicalDevices.first?.settings?.settings.stages?.stages.isEmpty == true)
        await monitor.stop()
    }

    @Test func currentReservedChangesOrUnavailableUniqueIdentityRejectKnownLayoutWithoutWrites() async throws {
        for loseIdentity in [false, true] {
            let backend = MouseSettingsBackend()
            let (monitor, controller, target) = try await settingsRig(backend)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let raw = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: directory.appendingPathComponent("unknown.json"))
            let evidencePath = directory.appendingPathComponent("model.json")
            try LocalPrivateFile(url: evidencePath).writeNew(StageEvidenceTestFixtures.encode(StageEvidenceTestFixtures.confirmed(identity: raw.identity, payload: backend.stagePayload)))
            if loseIdentity { backend.loseIdentity() } else { backend.changeStageReservedByte() }
            do {
                _ = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: directory.appendingPathComponent("known.json"), hardwareEvidenceReference: evidencePath.path)
                Issue.record("An unavailable identity or changed immutable field was accepted")
            } catch {}
            #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("known.json").path))
            await monitor.stop()
        }
    }
    @Test func changingEvidenceFileAfterCandidateAuthorizationRejectsBeforeAnyStageWrite() async throws {
        let backend = MouseSettingsBackend()
        let (monitor, controller, target) = try await settingsRig(backend)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: directory.appendingPathComponent("raw.json"))
        let evidencePath = directory.appendingPathComponent("model.json")
        let document = StageEvidenceTestFixtures.confirmed(identity: raw.identity, payload: backend.stagePayload)
        try LocalPrivateFile(url: evidencePath).writeNew(StageEvidenceTestFixtures.encode(document))
        _ = try await controller.exportProfile(logicalDeviceID: target.id, saveTo: directory.appendingPathComponent("known.json"), hardwareEvidenceReference: evidencePath.path)
        let snapshot = try #require(await monitor.snapshot().logicalDevices.first?.settings), table = try #require(snapshot.settings.stages)
        let change = DPIStageTable(stages: [DPIStage(id: 3, dpi: DPISetting(x: 1000, y: 1400)), table.stages[1]], activeStageID: 7, opaqueBytes: table.opaqueBytes)
        let request = SettingChangeRequest(target: target.sessionID, expectedRevision: snapshot.revision, change: DeviceSettingsChange(stages: change, persistence: .onboard))
        let authorization = try await controller.authorizeValidation(request, operation: .razer00C5Stages)
        var json = try #require(JSONSerialization.jsonObject(with: StageEvidenceTestFixtures.encode(document)) as? [String: Any])
        json["source"] = "synthetic"
        try JSONSerialization.data(withJSONObject: json).write(to: evidencePath, options: .atomic)
        #expect(await controller.applyValidation(request, authorization: authorization).status == .rejected)
        #expect(backend.frames.allSatisfy { $0[7] >= 0x80 })
        await monitor.stop()
    }

}
