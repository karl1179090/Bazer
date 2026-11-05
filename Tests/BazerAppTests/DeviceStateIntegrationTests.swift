// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import Foundation
import Testing
@testable import BazerApp

@Suite("Home projection and menu cache — offline")
struct DeviceStateIntegrationTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func physicalAndDirectLogicalMirrorProduceOneCardAndOneHistory() throws {
        var store = DeviceStore(); let item = identified(1)
        store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(60), to: session)
        let connected = project(store)
        #expect(connected.count == 1); #expect(!connected[0].isHistory)
        #expect(connected[0].target == .physical(item.descriptor.id))
        store.reconcile([], at: date)
        let history = project(store)
        #expect(history.count == 1); #expect(history[0].isHistory); #expect(history[0].percentage == 60)
        #expect(store.devices[item.descriptor.id]?.currentBattery(at: date) == nil)
    }

    @Test func receiverPeerEvidenceAndSlotReplacementKeepOldPeripheralSummary() throws {
        var store = DeviceStore(); let host = identified(1, receiver: true)
        store.reconcile([host], at: date)
        let session = try #require(store.devices[host.descriptor.id]?.sessionID)
        let first = child(session, unit: "synthetic-old", presence: .unknown)
        store.reconcileLogicalDevices([first], for: session)
        var cards = project(store)
        #expect(cards.count == 1); #expect(cards[0].subtitle == "接收器已连接 · 外设状态待确认")
        let firstSession = try #require(store.logicalDevices[first.id]?.sessionID)
        store.apply(update(60), to: firstSession)
        let offline = child(session, unit: "synthetic-old", presence: .unreachable, generation: first.address.pairingGeneration)
        store.reconcileLogicalDevices([offline], for: session)
        cards = project(store)
        #expect(cards.count == 1); #expect(cards[0].isHistory); #expect(cards[0].percentage == 60)
        #expect(!store.isCurrent(firstSession)); #expect(store.logicalDevices[first.id]?.canRefreshSettings == false)
        let next = child(session, unit: "synthetic-new", presence: .reachable)
        store.reconcileLogicalDevices([next], for: session)
        cards = project(store)
        #expect(cards.filter { !$0.isHistory }.count == 1)
        #expect(cards.filter(\.isHistory).count == 1)
        #expect(cards.first { !$0.isHistory }?.percentage == nil)
        #expect(cards.first { $0.isHistory }?.logical?.descriptor.preferenceIdentity == first.preferenceIdentity)
        #expect(store.apply(update(9), to: firstSession) == false)
    }

    @Test func successfulReconnectDeduplicatesHistoryByIdentityWithoutReusingTelemetry() throws {
        var store = DeviceStore(); let host = identified(1, receiver: true)
        store.reconcile([host], at: date)
        let hostSession = try #require(store.devices[host.descriptor.id]?.sessionID)
        let first = child(hostSession, unit: "stable", presence: .reachable)
        store.reconcileLogicalDevices([first], for: hostSession)
        let old = try #require(store.logicalDevices[first.id]?.sessionID)
        store.apply(update(70), to: old)
        store.reconcileLogicalDevices([], for: hostSession)
        store.reconcileLogicalDevices([child(hostSession, unit: "stable", presence: .reachable)], for: hostSession)
        let cards = project(store)
        #expect(cards.count == 1); #expect(!cards[0].isHistory); #expect(cards[0].percentage == nil)
        #expect(cards[0].logical?.sessionID != old)
    }

    @MainActor @Test func foldingSurvivesReliableReconnectAndAnonymousSlotCannotInherit() throws {
        let model = offlineModel(); var store = DeviceStore(); let host = identified(1, receiver: true)
        store.reconcile([host], at: date)
        let hostSession = try #require(store.devices[host.descriptor.id]?.sessionID)
        let first = child(hostSession, unit: "stable", presence: .reachable)
        store.reconcileLogicalDevices([first], for: hostSession)
        model.consume(snapshot(store)); model.setDeviceFolded(true, for: .logical(first.id), showUndo: false)
        store.reconcileLogicalDevices([], for: hostSession); model.consume(snapshot(store))
        #expect(model.connectedHomeDevices.isEmpty); #expect(model.historyHomeDevices.count == 1)
        store.reconcileLogicalDevices([child(hostSession, unit: "stable", presence: .reachable)], for: hostSession)
        model.consume(snapshot(store))
        #expect(model.foldedHomeTargets == [.logical(first.id)]); #expect(!model.isFoldedSectionExpanded)
        store.reconcileLogicalDevices([child(hostSession, unit: nil, presence: .reachable)], for: hostSession)
        model.consume(snapshot(store))
        #expect(!model.isDeviceFolded(.logical(first.id)))
        model.setDeviceFolded(true, for: .logical(first.id), showUndo: false)
        store.reconcileLogicalDevices([child(hostSession, unit: nil, presence: .reachable)], for: hostSession)
        model.consume(snapshot(store))
        #expect(!model.isDeviceFolded(.logical(first.id)))
    }

    @Test func menuPinsInitialMouseAndKeepsNativeZeroOrEstimateBeyondExpiry() throws {
        for estimated in [false, true] {
            var store = DeviceStore(); let mouse = identified(1), keyboard = identified(2, kind: .keyboard)
            store.reconcile([mouse, keyboard], at: date)
            let session = try #require(store.devices[mouse.descriptor.id]?.sessionID)
            let sample = estimated ? BatterySample(value: .voltageOnly(millivolts: 3900), receivedAt: date, source: "fake voltage", percentageEstimate: BatteryPercentageEstimate(value: 60, source: "fake", resolution: "10%")) : BatterySample(value: .percentage(0), receivedAt: date, source: "fake native")
            store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: sample, batteryFailure: nil,
                charging: ChargingSample(state: .discharging, rawValue: nil, receivedAt: date, source: "fake"), chargingFailure: nil), to: session)
            var menu = MenuBarDisplayState()
            menu.reconcile(project(store), preferredIdentity: nil, fallback: .physical(mouse.descriptor.id))
            #expect(menu.title == (estimated ? "约 60%" : "0%"))
            store.reconcile([keyboard], at: date.addingTimeInterval(200))
            menu.reconcile(HomeDeviceProjector.project(snapshot(store, at: date.addingTimeInterval(200)), audio: [], at: date.addingTimeInterval(200)), preferredIdentity: nil, fallback: .physical(keyboard.descriptor.id))
            #expect(menu.selectedTarget == .physical(mouse.descriptor.id)); #expect(menu.title == (estimated ? "约 60%" : "0%"))
            #expect(!menu.symbol.contains("bolt")); #expect(menu.accessibilityLabel.contains("已断开")); #expect(menu.accessibilityLabel.contains("上次电量")); #expect(menu.accessibilityLabel.contains("最近读取"))
            // Explicit switch must immediately discard the old target's value.
            menu.select(project(store).first { $0.target == .physical(keyboard.descriptor.id) })
            #expect(menu.title == "--")
        }
    }

    @Test func failureKeepsPartitionAndMenuValueWithoutClaimingDisconnected() throws {
        var store = DeviceStore(); let item = identified(1); store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(60), to: session)
        var menu = MenuBarDisplayState(); menu.select(project(store).first)
        let failure = TelemetryFailure(category: .deviceStatus, message: "synthetic status4")
        store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure), to: session)
        let cards = project(store); menu.reconcile(cards, preferredIdentity: nil, fallback: nil)
        #expect(cards.count == 1); #expect(!cards[0].isHistory); #expect(cards[0].percentage == nil)
        #expect(menu.title == "60%"); #expect(menu.accessibilityLabel.contains("状态待确认")); #expect(!menu.accessibilityLabel.contains("已断开"))
    }

    @Test func reconnectWaitsForNewSessionAndLateOldSessionCannotAlterCache() throws {
        var store = DeviceStore(); let item = identified(1); store.reconcile([item], at: date)
        let old = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(60), to: old)
        var menu = MenuBarDisplayState(); menu.select(project(store).first)
        store.reconcile([], at: date); store.reconcile([item], at: date)
        let current = try #require(store.devices[item.descriptor.id]?.sessionID)
        menu.reconcile(project(store), preferredIdentity: nil, fallback: nil)
        #expect(menu.title == "60%"); #expect(menu.selectedSession == current.generation.uuidString)
        #expect(store.apply(update(10), to: old) == false)
        menu.reconcile(project(store), preferredIdentity: nil, fallback: nil); #expect(menu.title == "60%")
        store.apply(update(0), to: current)
        menu.reconcile(project(store), preferredIdentity: nil, fallback: nil); #expect(menu.title == "0%")
        let freshProcessCache = MenuBarDisplayState(); #expect(freshProcessCache.title == "--")
    }

    @Test func audioOnlyAndMultiPartCardsJoinTheSameTwoPartitions() {
        let session = BluetoothAudioSession(generation: 1)
        let readings = [BluetoothAudioComponent.left, .right, .case].enumerated().map { index, part in
            BluetoothAudioBatteryReading(component: part, percent: [35, 50, 2][index], charging: .discharging, source: "fake system", observedAt: date, session: session)
        }
        var device = BluetoothAudioDevice(id: .init(rawValue: "synthetic-audio"), name: "Audio", session: session, batteryReadings: readings, lastReadings: readings, lastSeenAt: date)
        var cards = HomeDeviceProjector.project(snapshot(DeviceStore()), audio: [device], at: date)
        #expect(cards.count == 1); #expect(cards[0].percentage == 35); #expect(cards[0].batteryText == "左 35% · 右 50%")
        device.connection = .disconnected
        cards = HomeDeviceProjector.project(snapshot(DeviceStore()), audio: [device], at: date)
        #expect(cards[0].isHistory); #expect(cards[0].batteryText == "左 35% · 右 50%")
    }

    private func identified(_ parent: UInt64, kind: DeviceKind = .mouse, receiver: Bool = false) -> IdentifiedDevice {
        let endpoint = HIDInterfaceDescriptor(registryEntryID: parent + 100, usbParentRegistryEntryID: parent, vendorID: 0x1532, productID: 0x00C5, product: "Synthetic \(parent)", transport: "USB", locationID: UInt32(parent * 100), primaryUsage: kind == .keyboard ? .keyboard : .mouse)
        return IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([endpoint])[0], kind: kind, capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: parent + 100, isReceiver: receiver)
    }
    private func child(_ host: DeviceSessionID, unit: String?, presence: PeerPresence, generation: UUID = UUID()) -> LogicalDeviceDescriptor {
        LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: host, target: .receiver(index: 1, identity: LogicalPeripheralIdentity(vendorID: 0x046D, unitID: unit)), pairingGeneration: generation), product: unit ?? "Anonymous", kind: .mouse, capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: 101, peerPresence: presence)
    }
    private func update(_ percent: Int) -> DeviceTelemetryUpdate {
        DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: BatterySample(value: .percentage(percent), receivedAt: date, source: "synthetic"), batteryFailure: nil,
            charging: ChargingSample(state: .notCharging, rawValue: nil, receivedAt: date, source: "synthetic"), chargingFailure: nil)
    }
    private func snapshot(_ store: DeviceStore, at timestamp: Date? = nil) -> DeviceStoreSnapshot {
        DeviceStoreSnapshot(capturedAt: timestamp ?? date, devices: store.devices.values.sorted { $0.id < $1.id }, primaryDeviceID: store.primaryDeviceID, isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil, logicalDevices: Array(store.logicalDevices.values), primaryLogicalDeviceID: store.primaryLogicalDeviceID, preferences: store.preferences, historicalDevices: store.historicalDevices, historicalLogicalDevices: store.historicalLogicalDevices)
    }
    private func project(_ store: DeviceStore) -> [HomeDeviceProjection] { HomeDeviceProjector.project(snapshot(store), audio: [], at: date) }
    @MainActor private func offlineModel() -> AppModel {
        AppModel(monitor: BatteryMonitor(discovery: ProjectionDiscovery(), reader: ProjectionReader(), preferences: ProjectionPreferences()), notifications: NotificationService(persistence: ProjectionNotificationPreferences()))
    }
}

private actor ProjectionDiscovery: BatteryMonitorDiscovery {
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: .distantPast, interfaces: []) }
    func events() -> AsyncStream<HIDDiscoveryEvent> { AsyncStream { _ in } }
    func stop() {}
}
private struct ProjectionReader: DeviceTelemetryReading {
    func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult { fatalError("No real telemetry in projection tests") }
}
private struct ProjectionPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}

private struct ProjectionNotificationPreferences: NotificationPreferencesPersisting {
    func load() -> NotificationPreferences { NotificationPreferences() }
    func save(_ preferences: NotificationPreferences) {}
}


extension DeviceStateIntegrationTests {
    @MainActor @Test func persistedFoldCanBeOptimisticallyClearedBeforePreferenceWriteCompletes() throws {
        let item = identified(1), key = try #require(DevicePreferenceIdentity.derive(from: identified(1).descriptor)?.rawValue)
        var store = DeviceStore(preferences: DevicePreferences(foldedIdentities: [key], rememberFoldedDevices: true))
        store.reconcile([item], at: date)
        let model = offlineModel(); model.consume(snapshot(store))
        let target = HomeDeviceTarget.physical(item.descriptor.id)
        #expect(model.isDeviceFolded(target))
        model.setDeviceFolded(false, for: target, showUndo: false)
        #expect(!model.isDeviceFolded(target))
        #expect(model.regularHomeTargets == [target])
    }
    @Test func persistedAudioPrimaryWaitsForItsOwnSnapshotWithoutLeakingMouseValue() throws {
        let item = identified(1); var store = DeviceStore(); store.reconcile([item], at: date)
        let host = try #require(store.devices[item.descriptor.id]?.sessionID); store.apply(update(90), to: host)
        let key = "synthetic-audio:preferred"
        var menu = MenuBarDisplayState()
        menu.reconcile(project(store), preferredIdentity: key, fallback: .physical(item.descriptor.id))
        #expect(menu.title == "--"); #expect(menu.selectedIdentity == key)
        let session = BluetoothAudioSession(generation: 1)
        let reading = BluetoothAudioBatteryReading(percent: 30, charging: .discharging, source: "fake system", observedAt: date, session: session)
        let device = BluetoothAudioDevice(id: .init(rawValue: "synthetic-preferred"), name: "Preferred audio", session: session, identityQuality: .verified, preferenceIdentity: key, batteryReadings: [reading], lastSeenAt: date)
        menu.reconcile(HomeDeviceProjector.project(snapshot(store), audio: [device], at: date), preferredIdentity: key, fallback: .physical(item.descriptor.id))
        #expect(menu.title == "30%"); #expect(menu.name == "Preferred audio")
    }
    @Test func staleChargingSampleCannotKeepTheMenuChargingBolt() throws {
        let item = identified(1); var store = DeviceStore(); store.reconcile([item], at: date)
        let session = try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
            battery: BatterySample(value: .percentage(80), receivedAt: date, source: "synthetic"), batteryFailure: nil,
            charging: ChargingSample(state: .charging, rawValue: nil, receivedAt: date, source: "synthetic"), chargingFailure: nil), to: session)
        var menu = MenuBarDisplayState(); menu.select(project(store).first)
        #expect(menu.symbol.contains("bolt"))
        let later = date.addingTimeInterval(181)
        store.apply(DeviceTelemetryUpdate(startedAt: later, finishedAt: later,
            battery: BatterySample(value: .percentage(60), receivedAt: later, source: "synthetic"), batteryFailure: nil, charging: nil, chargingFailure: nil), to: session)
        menu.reconcile(HomeDeviceProjector.project(snapshot(store, at: later), audio: [], at: later), preferredIdentity: nil, fallback: nil)
        #expect(menu.title == "60%"); #expect(!menu.symbol.contains("bolt"))
    }
}
