import BazerCore
import BazerDrivers
import BazerHID
import Foundation
@testable import BazerApp
import Testing

struct DeviceSettingsDraftTests {
    private var snapshot: DeviceSettingsSnapshot {
        let host = DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "synthetic"))
        return DeviceSettingsSnapshot(session: LogicalDeviceSessionID(address: .direct(host)), revision: 7, capturedAt: Date(timeIntervalSince1970: 100), settings: DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 500))
    }
    private func capabilities(write: Bool = true, xy: Bool = false) -> DeviceCapabilities {
        let constraints = CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, persistenceScopes: [.runtime])
        return DeviceCapabilities(operations: [
            .dpiWrite: OperationCapability(evidence: write ? .writeVerified : .catalogued, constraints: constraints),
            .independentXY: OperationCapability(evidence: xy ? .writeVerified : .unknown),
            .pollingRateWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [125, 500, 1000], persistenceScopes: [.runtime]))
        ])
    }
    @Test func draftPreservesOriginalSessionAndRevisionAndSubmitsOnlyChangedFields() throws {
        let original = snapshot
        var draft = DeviceSettingsDraft(original, scope: .runtime); draft.dpiX = "1200"; draft.dpiY = "1200"
        let request = try #require(draft.request(capabilities: capabilities()))
        #expect(request.target == original.session); #expect(request.expectedRevision == 7)
        #expect(request.change.currentDPI == DPISetting(1200)); #expect(request.change.pollingRateHz == nil)
    }
    @Test func unsupportedXYUnverifiedWritesAndOutOfRangeDraftsCannotConstructRequests() {
        var draft = DeviceSettingsDraft(snapshot, scope: .runtime); draft.dpiX = "1200"
        #expect(draft.request(capabilities: capabilities()) == nil)
        draft.dpiY = "1200"; #expect(draft.request(capabilities: capabilities(write: false)) == nil)
        draft.dpiX = "26050"; draft.dpiY = "26050"; #expect(draft.request(capabilities: capabilities()) == nil)
        draft.dpiX = "nan"; #expect(draft.request(capabilities: capabilities()) == nil)
        draft = DeviceSettingsDraft(snapshot, scope: .runtime); draft.rate = "8000"; #expect(draft.request(capabilities: capabilities()) == nil)
    }
    @Test func verifiedStageDraftPreservesOpaqueAndSeparatesCurrentActionsFromBoardSave() throws {
        let table = DPIStageTable(stages: [DPIStage(id: 0, dpi: DPISetting(800)), DPIStage(id: 1, dpi: DPISetting(1600))], activeStageID: 1, opaqueBytes: [0xA5, 0x5A], defaultStageID: 0)
        let base = snapshot
        let settings = DeviceSettingsSnapshot(session: base.session, revision: base.revision, capturedAt: base.capturedAt,
            settings: DeviceSettings(stages: table, activeProfileID: 2, currentStageID: 1))
        let caps = DeviceCapabilities(operations: [
            .stagesWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(minimum: 100, maximum: 26000, step: 50, maximumStages: 5, persistenceScopes: [.onboard])),
            .onboardPersist: OperationCapability(evidence: .writeVerified), .independentXY: OperationCapability(evidence: .writeVerified),
            .stageSelect: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [0, 1], persistenceScopes: [.runtime])),
            .onboardWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [1, 2, 3], persistenceScopes: [.runtime]))
        ])
        var draft = DeviceSettingsDraft(settings, scope: .runtime)
        draft.stageValues[0] = .init(x: "1200", y: "1400"); draft.defaultStage = "1"; draft.currentStage = "0"; draft.activeProfile = "3"
        let board = try #require(draft.request(capabilities: caps, scope: .onboard))
        #expect(board.change.fields == [.stages]); #expect(board.change.stages?.opaqueBytes == table.opaqueBytes)
        #expect(board.change.stages?.activeStageID == 1); #expect(board.change.stages?.defaultStageID == 1)
        let current = try #require(draft.request(capabilities: caps, scope: .runtime))
        #expect(Set(current.change.fields) == Set([.activeProfile, .currentStage])); #expect(current.change.stages == nil)
        draft.currentStage = "9"; #expect(draft.request(capabilities: caps, scope: .runtime) == nil)
        draft.stageValues[99] = .init(x: "800", y: "800"); #expect(draft.request(capabilities: caps, scope: .onboard) == nil)
    }

    @MainActor @Test func cancellingBlockedSettingsReadKeepsBusyUntilActualCompletion() async throws {
        let descriptor = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10, vendorID: 0x1234, productID: 0x5678,
            product: "Synthetic UI only", transport: "USB", primaryUsage: .mouse)
        let adapter = BlockingUISettingsAdapter()
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "synthetic-ui", identify: { device in
            IdentifiedDevice(descriptor: device, kind: .mouse, capabilities: DeviceCapabilities(operations: [.dpiRead: OperationCapability(evidence: .discovered)]), controlEndpointRegistryEntryID: 101)
        }, settingsAdapter: adapter)])
        let monitor = BatteryMonitor(discovery: UIDiscovery(descriptor: descriptor), reader: registry, preferences: UIDevicePreferences(), registry: registry)
        await monitor.start(); let initial = await monitor.initialDiscoveryReady()
        let child = try #require(initial.logicalDevices.first)
        let model = AppModel(monitor: monitor, notifications: NotificationService(backend: UINotificationBackend(), persistence: UINotificationPreferences()), loginItem: LoginItemService(backend: UILoginBackend()))
        model.consume(initial)
        var entered = adapter.entered.stream.makeAsyncIterator()
        model.readSettings(child.id); _ = await entered.next()
        #expect(model.settingsBusy.contains(child.id))
        model.cancelSettings(child.id)
        #expect(model.settingsBusy.contains(child.id))
        await adapter.release()
        await model.waitForSettingsAction(child.id)
        #expect(!model.settingsBusy.contains(child.id))
        #expect(await adapter.readCount == 1)
        await model.stop()
    }
}

private actor BlockingUISettingsAdapter: DeviceSettingsAdapter {
    nonisolated let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async throws -> DeviceSettings {
        readCount += 1
        await withCheckedContinuation { value in continuation = value; entered.continuation.yield(()) }
        return DeviceSettings(currentDPI: DPISetting(800))
    }
    func release() { continuation?.resume(); continuation = nil }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) async throws -> SettingAdapterTransaction { fatalError("UI read tests never write settings") }
}
private struct UIDiscovery: BatteryMonitorDiscovery {
    let descriptor: HIDInterfaceDescriptor
    func snapshot() async throws -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [descriptor]) }
    func events() async throws -> AsyncStream<HIDDiscoveryEvent> {
        AsyncStream { $0.yield(HIDDiscoveryEvent(kind: .initial, snapshot: HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [descriptor]))); $0.finish() }
    }
    func stop() async {}
}
private struct UIDevicePreferences: DevicePreferencesPersisting { func load() throws -> DevicePreferences { DevicePreferences() }; func save(_ preferences: DevicePreferences) throws {} }
private struct UINotificationPreferences: NotificationPreferencesPersisting { func load() throws -> NotificationPreferences { NotificationPreferences() }; func save(_ preferences: NotificationPreferences) throws {} }
@MainActor private final class UINotificationBackend: NotificationBackend {
    func authorization() async throws -> NotificationAuthorization { .denied }
    func requestAuthorization() async throws { fatalError("No OS authorization in UI tests") }
    func send(identifier: String, title: String, body: String) async throws { fatalError("No real notifications in UI tests") }
}
@MainActor private final class UILoginBackend: LoginItemBackend {
    var status: LoginItemStatus { .notRegistered }
    func register() throws { fatalError("No login item changes in UI tests") }
    func unregister() throws { fatalError("No login item changes in UI tests") }
    func openSettings() { fatalError("No system settings in UI tests") }
}
