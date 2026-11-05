// SPDX-License-Identifier: GPL-3.0-or-later
import BazerBluetooth
import BazerCore
import BazerDrivers
import BazerHID
import Foundation
import Testing
@testable import BazerApp

@Suite("UI redesign interaction & motion spec — offline")
struct UIRedesignInteractionTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    @Test func routeStateMachineTracksSettingsOriginAndPanelCloseResetsToHome() throws {
        let model = offlineModel()
        let mouse = identified(parent: 1, name: "Razer Viper V3 Pro")
        let keyboard = identified(parent: 2, kind: .keyboard, support: .unsupported, name: "Keychron Q1")
        var store = DeviceStore()
        store.reconcile([mouse, keyboard], at: date)
        model.consume(makeSnapshot(from: store))

        let mouseTarget = HomeDeviceTarget.physical(mouse.descriptor.id)
        #expect(model.route == .home)

        // Home -> Device
        model.navigateToDevice(mouseTarget)
        #expect(model.route == .device(mouseTarget))
        #expect(model.routeDirection == .forwardHorizontal)

        // Device -> Settings (origin: .device)
        model.navigateToSettings()
        #expect(model.route == .settings(origin: .device(mouseTarget)))
        #expect(model.routeDirection == .enterVertical)

        // Top-left back from Settings returns to the exact same Device page
        model.navigateBackFromSettings()
        #expect(model.route == .device(mouseTarget))
        #expect(model.routeDirection == .exitVertical)

        // Device -> Settings -> "返回设备列表" returns directly to Home
        model.navigateToSettings()
        #expect(model.route == .settings(origin: .device(mouseTarget)))
        model.navigateFromSettingsToDeviceList()
        #expect(model.route == .home)
        #expect(model.routeDirection == .exitVertical)

        // Home -> Settings (origin: .home) -> Back returns to Home
        model.navigateToSettings()
        #expect(model.route == .settings(origin: .home))
        model.navigateBackFromSettings()
        #expect(model.route == .home)

        // Escape key dismisses active overlay first before allowing panel close
        model.navigateToDevice(mouseTarget)
        model.isFoldedSectionExpanded = true
        model.activeOverlay = .primaryDevicePicker
        #expect(model.handleEscapeKey() == true)
        #expect(model.activeOverlay == nil)
        #expect(model.handleEscapeKey() == false)

        // Panel close resets route to Home and collapses folded section
        model.activeOverlay = .primaryDevicePicker
        model.handlePanelDidClose()
        #expect(model.route == .home)
        #expect(model.isFoldedSectionExpanded == false)
        #expect(model.activeOverlay == nil)
        #expect(model.foldUndoBanner == nil)
    }

    @MainActor
    @Test func foldingAndUnfoldingPreservesOriginalRelativeOrderAndSupportsUndo() throws {
        let model = offlineModel()
        let first = identified(parent: 1, name: "First Mouse")
        let second = identified(parent: 2, kind: .keyboard, support: .unsupported, name: "Middle Keyboard")
        let third = identified(parent: 3, name: "Third Mouse")
        var store = DeviceStore()
        store.reconcile([first, second, third], at: date)
        model.consume(makeSnapshot(from: store))

        let t1 = HomeDeviceTarget.physical(first.descriptor.id)
        let t2 = HomeDeviceTarget.physical(second.descriptor.id)
        let t3 = HomeDeviceTarget.physical(third.descriptor.id)

        #expect(model.regularHomeTargets == [t1, t2, t3])
        #expect(model.foldedHomeTargets.isEmpty)

        // Fold the middle device (Keyboard)
        model.setDeviceFolded(true, for: t2)
        #expect(model.regularHomeTargets == [t1, t3])
        #expect(model.foldedHomeTargets == [t2])
        #expect(model.foldUndoBanner?.deviceName == "Middle Keyboard")

        // Undo fold within 5s restores t2 to the middle position [t1, t2, t3]
        model.undoLastFoldAction()
        #expect(model.regularHomeTargets == [t1, t2, t3])
        #expect(model.foldedHomeTargets.isEmpty)
        #expect(model.foldUndoBanner == nil)

        // Fold t1 and t2, then unfold t1 -> relative order [t1, t3] is preserved
        model.setDeviceFolded(true, for: t1)
        model.setDeviceFolded(true, for: t2)
        #expect(model.regularHomeTargets == [t3])
        #expect(model.foldedHomeTargets == [t1, t2])
        model.setDeviceFolded(false, for: t1)
        #expect(model.regularHomeTargets == [t1, t3])
        #expect(model.foldedHomeTargets == [t2])
    }

    @Test func deviceStorePersistsFoldedDevicesQuickPresetsAndAppearancePreferences() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-ui-prefs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("preferences.json")
        let prefsStore = FileDevicePreferences(url: fileURL)

        let id1 = "usb-port:1532:00C5:00100000"
        let customPresets = DeviceQuickPresets(
            dpiPresets: [DPISetting(400), DPISetting(800), DPISetting(1600), DPISetting(x: 800, y: 1600)],
            pollingRatePresets: [125, 500, 1000]
        )

        var store = DeviceStore(preferences: DevicePreferences())
        // Default: rememberFoldedDevices == false -> setDeviceFolded does not persist foldedIdentities
        #expect(store.preferences.rememberFoldedDevices == false)
        store.setDeviceFolded(true, identityKey: id1)
        #expect(store.preferences.foldedIdentities.isEmpty)

        // Enable rememberFoldedDevices -> persists foldedIdentities
        store.setRememberFoldedDevices(true, activeFoldedKeys: [id1])
        #expect(store.preferences.rememberFoldedDevices == true)
        #expect(store.preferences.foldedIdentities == [id1])

        // Quick presets, menuBarPercentage, appearanceMode
        store.setQuickPresets(customPresets, for: id1)
        store.setShowMenuBarPercentage(false)
        store.setAppearanceMode(.dark)

        try prefsStore.save(store.preferences)
        let loaded = try prefsStore.load()
        #expect(loaded.schemaVersion == DevicePreferences.currentSchemaVersion)
        #expect(loaded.rememberFoldedDevices == true)
        #expect(loaded.foldedIdentities == [id1])
        #expect(loaded.quickPresets[id1] == customPresets)
        #expect(loaded.showMenuBarPercentage == false)
        #expect(loaded.appearanceMode == BazerAppearanceMode.dark)

        // Turning off rememberFoldedDevices clears persisted foldedIdentities
        var reloadedStore = DeviceStore(preferences: loaded)
        reloadedStore.setRememberFoldedDevices(false, activeFoldedKeys: [id1])
        #expect(reloadedStore.preferences.rememberFoldedDevices == false)
        #expect(reloadedStore.preferences.foldedIdentities.isEmpty)
    }

    @Test func quickPresetDraftValidatesCountDuplicatesRangeStepAndIndependentXY() throws {
        // 1. Symmetric-only device capabilities (e.g. Logitech GPW1)
        let symmetricCaps = DeviceCapabilities(operations: [
            .dpiWrite: OperationCapability(
                evidence: .writeVerified,
                constraints: CapabilityConstraints(minimum: 100, maximum: 25600, step: 50, persistenceScopes: [.runtime])
            ),
            .independentXY: OperationCapability(evidence: .unknown),
            .pollingRateWrite: OperationCapability(
                evidence: .writeVerified,
                constraints: CapabilityConstraints(allowedValues: [125, 250, 500, 1000], persistenceScopes: [.runtime])
            )
        ])

        var draft = QuickPresetModalDraft(
            activeTab: .dpi,
            dpiPresets: [DPISetting(800), DPISetting(1600)],
            ratePresets: [125, 500, 1000]
        )

        #expect(draft.validateDPIRows(capabilities: symmetricCaps).isEmpty)
        #expect(draft.validateRateRows(capabilities: symmetricCaps).isEmpty)
        #expect(draft.canAddDPIRow)
        #expect(draft.canRemoveDPIRow)

        // Independent X/Y rejected on symmetric-only device
        draft.dpiRows[0].rawText = "800/1600"
        #expect(draft.validateDPIRows(capabilities: symmetricCaps)[draft.dpiRows[0].id] == "当前设备不支持独立 X/Y DPI")

        // Duplicate DPI rejected
        draft.dpiRows[0].rawText = "1600"
        #expect(draft.validateDPIRows(capabilities: symmetricCaps)[draft.dpiRows[0].id] == "与同组其它快捷选项重复")

        // Step mismatch rejected
        draft.dpiRows[0].rawText = "825"
        #expect(draft.validateDPIRows(capabilities: symmetricCaps)[draft.dpiRows[0].id]?.contains("步进") == true)

        // Out of range rejected
        draft.dpiRows[0].rawText = "30000"
        #expect(draft.validateDPIRows(capabilities: symmetricCaps)[draft.dpiRows[0].id]?.contains("超出设备支持范围") == true)

        // Valid symmetric DPI
        draft.dpiRows[0].rawText = "800"
        #expect(draft.validateDPIRows(capabilities: symmetricCaps).isEmpty)

        // Unsupported polling rate rejected
        draft.rateRows[0].rawText = "333"
        #expect(draft.validateRateRows(capabilities: symmetricCaps)[draft.rateRows[0].id]?.contains("当前设备仅支持") == true)

        // Restore valid rate
        draft.rateRows[0].rawText = "250"
        #expect(draft.validateRateRows(capabilities: symmetricCaps).isEmpty)

        // 2. Independent X/Y permitted device (e.g. Razer Viper V3 Pro)
        let xyCaps = DeviceCapabilities(operations: [
            .dpiWrite: OperationCapability(
                evidence: .writeVerified,
                constraints: CapabilityConstraints(minimum: 100, maximum: 35000, step: 1, persistenceScopes: [.runtime])
            ),
            .independentXY: OperationCapability(evidence: .writeVerified),
            .pollingRateWrite: OperationCapability(
                evidence: .writeVerified,
                constraints: CapabilityConstraints(allowedValues: [125, 250, 500, 1000], persistenceScopes: [.runtime])
            )
        ])
        draft.dpiRows[0].rawText = "800 / 1600"
        #expect(draft.validateDPIRows(capabilities: xyCaps).isEmpty)
        #expect(draft.parsedDPIs?.first == DPISetting(x: 800, y: 1600))

        // 3. Max 8 items limit
        while draft.canAddDPIRow {
            draft.addDPIRow(capabilities: xyCaps)
        }
        #expect(draft.dpiRows.count == QuickPresetModalDraft.maxCount)
        #expect(!draft.canAddDPIRow)
    }

    @MainActor
    @Test func quickPresetModalCloseKeepsSessionDraftWhileCancelDiscardsDraft() throws {
        let model = offlineModel()
        var store = DeviceStore()
        let item = identified(parent: 10, name: "Razer Viper V3 Pro")
        store.reconcile([item], at: date)
        let hostSession = try #require(store.devices[item.descriptor.id]?.sessionID)
        let logicalDesc = makeLogicalDescriptor(hostSession: hostSession)
        _ = store.reconcileLogicalDevices([logicalDesc], for: hostSession)
        let logicalID = logicalDesc.id
        let logicalSession = try #require(store.logicalDevices[logicalID]?.sessionID)
        let settingsSnap = makeSettingsSnapshot(session: logicalSession, dpi: DPISetting(800), rate: 1000)
        _ = store.applySettings(settingsSnap)
        model.consume(makeSnapshot(from: store))

        let logical = try #require(model.snapshot.logicalDevices.first)
        model.openQuickPresetEditor(for: logical, tab: .dpi)
        #expect(model.activeOverlay == .quickPresetEditor(deviceID: logical.id, initialTab: .dpi))

        // Modify draft in session and close via X/Esc -> draft is preserved
        model.sessionQuickPresetDrafts[logical.id]?.dpiRows[0].rawText = "1200"
        model.closeQuickPresetEditorKeepingDraft(for: logical.id)
        #expect(model.activeOverlay == nil)

        model.openQuickPresetEditor(for: logical, tab: .dpi)
        #expect(model.sessionQuickPresetDrafts[logical.id]?.dpiRows[0].rawText == "1200")

        // Cancel explicitly -> discards session draft and restores saved presets on reopen
        model.cancelQuickPresetEditor(for: logical.id)
        #expect(model.activeOverlay == nil)
        model.openQuickPresetEditor(for: logical, tab: .dpi)
        #expect(model.sessionQuickPresetDrafts[logical.id]?.dpiRows[0].rawText == "400")
    }

    @MainActor
    @Test func onboardDraftPersistsAcrossSettingsRoundTripAndSingleSelectNoOpOnConfirmedValue() throws {
        let model = offlineModel()
        var store = DeviceStore()
        let item = identified(parent: 10, name: "Razer Viper V3 Pro")
        store.reconcile([item], at: date)
        let hostSession = try #require(store.devices[item.descriptor.id]?.sessionID)
        let logicalDesc = makeLogicalDescriptor(hostSession: hostSession)
        _ = store.reconcileLogicalDevices([logicalDesc], for: hostSession)
        let logicalID = logicalDesc.id
        let logicalSession = try #require(store.logicalDevices[logicalID]?.sessionID)
        let settingsSnap = makeSettingsSnapshot(session: logicalSession, dpi: DPISetting(800), rate: 1000)
        _ = store.applySettings(settingsSnap)
        model.consume(makeSnapshot(from: store))

        let logical = try #require(model.snapshot.logicalDevices.first)
        let target = HomeDeviceTarget.physical(item.descriptor.id)
        model.navigateToDevice(target)

        // Clicking already-confirmed DPI (800) or polling rate (1000) is a no-op
        model.selectDPIPreset(DPISetting(800), for: logical)
        #expect(model.pendingParameterSwitches[logical.id] == nil)
        #expect(!model.settingsBusy.contains(logical.id))

        model.selectPollingRatePreset(1000, for: logical)
        #expect(model.pendingParameterSwitches[logical.id] == nil)
        #expect(!model.settingsBusy.contains(logical.id))

        // Mutate onboard draft and navigate to Settings and back -> draft is preserved in memory
        var draft = try #require(model.onboardDraft(for: logical))
        draft.stageValues[1] = .init(x: "1600", y: "1600")
        draft.defaultStage = "1"
        model.updateOnboardDraft(draft, for: logical.id)

        model.navigateToSettings()
        #expect(model.route == .settings(origin: .device(target)))
        model.navigateBackFromSettings()
        #expect(model.route == .device(target))

        let preserved = try #require(model.onboardDraft(for: logical))
        #expect(preserved.stageValues[1]?.x == "1600")
        #expect(preserved.defaultStage == "1")
    }

    @MainActor
    @Test func panelOpenRefreshReadsBatteryDPIAndPollingRateTogether() async throws {
        let descriptor = HIDInterfaceDescriptor(
            registryEntryID: 301,
            usbParentRegistryEntryID: 30,
            vendorID: 0x1532,
            productID: 0x00C5,
            product: "Razer DeathAdder V3 HyperSpeed",
            transport: "USB",
            primaryUsage: .mouse
        )
        let adapter = SyntheticSettingsAdapter(dpi: DPISetting(1600), rate: 1000)
        let reader = SyntheticTelemetryReader(percentage: 92)
        let registry = DriverRegistry(registrations: [
            DeviceDriverRegistration(
                id: "synthetic-razer-ui",
                identify: { device in
                    IdentifiedDevice(
                        descriptor: device,
                        kind: .mouse,
                        capabilities: DeviceCapabilities(
                            battery: .verified,
                            chargingQuery: true,
                            operations: [
                                .dpiRead: OperationCapability(evidence: .readVerified),
                                .pollingRateRead: OperationCapability(evidence: .readVerified)
                            ]
                        ),
                        controlEndpointRegistryEntryID: 301
                    )
                },
                settingsAdapter: adapter
            )
        ])
        let monitor = BatteryMonitor(
            discovery: SingleDeviceUIDiscovery(descriptor: descriptor),
            reader: reader,
            preferences: MemoryUIPreferences(),
            registry: registry
        )
        await monitor.start()
        let initial = await monitor.initialDiscoveryReady()
        let model = AppModel(
            monitor: monitor,
            notifications: NotificationService(backend: UINotificationBackend(), persistence: UINotificationPreferences()),
            loginItem: LoginItemService(backend: UILoginBackend()),
            audioMonitor: BluetoothAudioMonitor(backend: EmptyUIAudioBackend())
        )
        model.consume(initial)

        model.handlePanelDidOpen(openSessionID: UUID())
        await model.waitForAllDeviceInformationRefresh()
        model.consume(await monitor.snapshot())

        let logical = try #require(model.snapshot.logicalDevices.first)
        #expect(logical.settings?.settings.currentDPI == DPISetting(1600))
        #expect(logical.settings?.settings.pollingRateHz == 1000)
        #expect(await adapter.readCount >= 1)
        await model.stop()
    }

    // MARK: - Helpers

    private func identified(
        parent: UInt64,
        kind: DeviceKind = .mouse,
        support: BatterySupport = .candidate,
        name: String = "Synthetic Mouse"
    ) -> IdentifiedDevice {
        let interface = HIDInterfaceDescriptor(
            registryEntryID: parent + 100,
            usbParentRegistryEntryID: parent,
            vendorID: 0x1532,
            productID: 0x00C5,
            product: name,
            transport: "USB",
            locationID: UInt32(0x0010_0000 + parent),
            primaryUsage: kind == .mouse ? .mouse : .keyboard
        )
        return IdentifiedDevice(
            descriptor: PhysicalDeviceDescriptor(id: PhysicalDeviceID(rawValue: "usb-parent:\(parent)"), interfaces: [interface]),
            kind: kind,
            capabilities: DeviceCapabilities(battery: support, chargingQuery: support != .unsupported),
            controlEndpointRegistryEntryID: support == .unsupported ? nil : interface.registryEntryID
        )
    }

    private func makeLogicalDescriptor(hostSession: DeviceSessionID) -> LogicalDeviceDescriptor {
        let caps = DeviceCapabilities(
            battery: .verified,
            chargingQuery: true,
            operations: [
                .dpiRead: OperationCapability(evidence: .readVerified),
                .dpiWrite: OperationCapability(
                    evidence: .writeVerified,
                    constraints: CapabilityConstraints(minimum: 100, maximum: 35000, step: 1, persistenceScopes: [.runtime, .onboard])
                ),
                .independentXY: OperationCapability(evidence: .writeVerified),
                .stagesRead: OperationCapability(evidence: .readVerified),
                .stagesWrite: OperationCapability(
                    evidence: .writeVerified,
                    constraints: CapabilityConstraints(minimum: 100, maximum: 35000, step: 1, maximumStages: 5, persistenceScopes: [.onboard])
                ),
                .stageSelect: OperationCapability(
                    evidence: .writeVerified,
                    constraints: CapabilityConstraints(allowedValues: [1, 2], persistenceScopes: [.runtime])
                ),
                .pollingRateRead: OperationCapability(evidence: .readVerified),
                .pollingRateWrite: OperationCapability(
                    evidence: .writeVerified,
                    constraints: CapabilityConstraints(allowedValues: [125, 250, 500, 1000], persistenceScopes: [.runtime, .onboard])
                ),
                .onboardPersist: OperationCapability(evidence: .writeVerified)
            ]
        )
        let identity = LogicalPeripheralIdentity(vendorID: 0x1532, wirelessProductID: 0x00C5, unitID: "RAZER123", firmware: "1.0.0")
        return LogicalDeviceDescriptor(
            address: .direct(hostSession),
            product: "Razer Viper V3 Pro",
            kind: .mouse,
            capabilities: caps,
            controlEndpointRegistryEntryID: 110,
            preferenceIdentity: DevicePreferenceIdentity.confirmedLogicalUnit(identity),
            peripheralIdentity: identity
        )
    }

    private func makeSettingsSnapshot(session: LogicalDeviceSessionID, dpi: DPISetting, rate: Int) -> DeviceSettingsSnapshot {
        let table = DPIStageTable(
            stages: [
                DPIStage(id: 1, dpi: DPISetting(400)),
                DPIStage(id: 2, dpi: dpi),
            ],
            activeStageID: 2,
            opaqueBytes: [0x01, 0x02],
            defaultStageID: 2
        )
        return DeviceSettingsSnapshot(
            session: session,
            revision: 1,
            capturedAt: date,
            settings: DeviceSettings(
                currentDPI: dpi,
                pollingRateHz: rate,
                stages: table,
                currentStageID: 2
            )
        )
    }

    private func makeSnapshot(from store: DeviceStore) -> DeviceStoreSnapshot {
        DeviceStoreSnapshot(
            capturedAt: date,
            devices: store.devices.values.sorted { $0.id < $1.id },
            primaryDeviceID: store.primaryDeviceID,
            isMonitoring: true,
            isSuspended: false,
            discoveryFailure: nil,
            preferencesFailure: nil,
            logicalDevices: store.logicalDevices.values.sorted { $0.id < $1.id },
            primaryLogicalDeviceID: store.primaryLogicalDeviceID,
            preferences: store.preferences
        )
    }

    private func offlineMonitor() -> BatteryMonitor {
        BatteryMonitor(discovery: EmptyUIDiscovery(), reader: NeverReadUI(), preferences: MemoryUIPreferences())
    }

    @MainActor
    private func offlineModel() -> AppModel {
        AppModel(
            monitor: offlineMonitor(),
            notifications: NotificationService(backend: UINotificationBackend(), persistence: UINotificationPreferences()),
            loginItem: LoginItemService(backend: UILoginBackend())
        )
    }
}

private struct UINotificationPreferences: NotificationPreferencesPersisting {
    func load() throws -> NotificationPreferences { NotificationPreferences() }
    func save(_ preferences: NotificationPreferences) throws {}
}

@MainActor
private final class UINotificationBackend: NotificationBackend {
    func authorization() async throws -> NotificationAuthorization { .denied }
    func requestAuthorization() async throws {}
    func send(identifier: String, title: String, body: String) async throws {}
}

@MainActor
private final class UILoginBackend: LoginItemBackend {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
    func openSettings() {}
}

private struct EmptyUIDiscovery: BatteryMonitorDiscovery {
    func snapshot() async throws -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: []) }
    func events() async throws -> AsyncStream<HIDDiscoveryEvent> { AsyncStream { $0.finish() } }
    func stop() async {}
}

private struct NeverReadUI: DeviceTelemetryReading {
    func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult {
        fatalError("Offline UI tests must never read hardware")
    }
}

private struct MemoryUIPreferences: DevicePreferencesPersisting {
    func load() throws -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) throws {}
}

private struct EmptyUIAudioBackend: BluetoothAudioBackend {
    func discover() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> { .init(status: .success) }
    func readPower() async -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> { .init(status: .success) }
}

private struct SingleDeviceUIDiscovery: BatteryMonitorDiscovery {
    let descriptor: HIDInterfaceDescriptor
    func snapshot() async throws -> HIDDiscoverySnapshot {
        HIDDiscoverySnapshot(capturedAt: Date(timeIntervalSince1970: 2_000_000), interfaces: [descriptor])
    }
    func events() async throws -> AsyncStream<HIDDiscoveryEvent> {
        AsyncStream {
            $0.yield(HIDDiscoveryEvent(kind: .initial, snapshot: HIDDiscoverySnapshot(capturedAt: Date(timeIntervalSince1970: 2_000_000), interfaces: [descriptor])))
            $0.finish()
        }
    }
    func stop() async {}
}

private actor SyntheticTelemetryReader: DeviceTelemetryReading {
    let percentage: Int
    init(percentage: Int) { self.percentage = percentage }
    func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult {
        let now = Date(timeIntervalSince1970: 2_000_005)
        return DeviceTelemetryResult(
            physicalDeviceID: device.id,
            endpointRegistryEntryID: 301,
            startedAt: now,
            finishedAt: now,
            battery: BatterySample(value: .percentage(percentage), receivedAt: now, source: "synthetic"),
            batteryFailure: nil,
            charging: ChargingSample(state: .notCharging, rawValue: nil, receivedAt: now, source: "synthetic"),
            chargingFailure: nil
        )
    }
}

private actor SyntheticSettingsAdapter: DeviceSettingsAdapter {
    let dpi: DPISetting
    let rate: Int
    private(set) var readCount = 0
    init(dpi: DPISetting, rate: Int) {
        self.dpi = dpi
        self.rate = rate
    }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async throws -> DeviceSettings {
        readCount += 1
        return DeviceSettings(currentDPI: dpi, pollingRateHz: rate)
    }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) async throws -> SettingAdapterTransaction {
        fatalError("UI read test never writes settings")
    }
}
