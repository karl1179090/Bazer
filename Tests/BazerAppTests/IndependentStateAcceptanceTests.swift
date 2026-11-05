import Foundation
import Testing
import BazerCore
import BazerDrivers
import BazerHID
@testable import BazerApp

@Suite("Independent state acceptance — synthetic only", .serialized)
@MainActor
struct IndependentStateAcceptanceTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func detailRemainsBoundToOldUnitWhenReceiverSlotIsReused() throws {
        var store = DeviceStore()
        let host = hostItem()
        store.reconcile([host], at: t)
        let hostSession = try #require(store.devices[host.descriptor.id]?.sessionID)
        let a = child(hostSession, unit: "unit-A", slot: 1)
        store.reconcileLogicalDevices([a], for: hostSession)
        let oldSession = try #require(store.logicalDevices[a.id]?.sessionID)
        store.apply(update(60), to: oldSession)
        let model = model(); model.consume(snapshot(store))
        model.navigateToDevice(.logical(a.id))
        store.reconcileLogicalDevices([child(hostSession, unit: "unit-B", slot: 1)], for: hostSession)
        model.consume(snapshot(store))
        // A and B share the same transport slot literal. The route must migrate
        // to A's history target; B's new card must still resolve independently.
        guard case .device(let retainedTarget) = model.route else { Issue.record("Expected retained device route"); return }
        let retainedDetail = try #require(model.associatedLogicalDevice(for: retainedTarget))
        let replacementTarget = try #require(model.connectedHomeDevices.first?.target)
        #expect(model.associatedLogicalDevice(for: replacementTarget)?.descriptor.preferenceIdentity != retainedDetail.descriptor.preferenceIdentity)
        #expect(retainedDetail.sessionID == oldSession, "An open detail must retain unit A's historical state, not silently become unit B")
        #expect(retainedDetail.hostPresence == .removed)
        #expect(model.historyHomeDevices.count == 1)
        #expect(model.connectedHomeDevices.count == 1)
    }

    @Test func settingsOriginAndOpenPresetDraftDoNotRetargetReusedSlot() throws {
        var store=DeviceStore();let host=hostItem();store.reconcile([host],at:t)
        let hs=try #require(store.devices[host.descriptor.id]?.sessionID)
        let a=child(hs,unit:"unit-A",slot:1);store.reconcileLogicalDevices([a],for:hs)
        let old=try #require(store.logicalDevices[a.id])
        let model=model();model.consume(snapshot(store));model.navigateToDevice(.logical(a.id));model.navigateToSettings()
        store.reconcileLogicalDevices([child(hs,unit:"unit-B",slot:1)],for:hs);model.consume(snapshot(store))
        model.navigateBackFromSettings()
        if case .device(let target)=model.route {
            #expect(model.associatedLogicalDevice(for:target)?.sessionID == old.sessionID,"Returning from settings must retain original device A")
        } else {Issue.record("Expected a device route")}
        // The modal is deliberately opened for a value snapshot of A, then the same
        // slot is observed as a third unit. Its old draft must not attach to that unit.
        model.openQuickPresetEditor(for:old,tab:.dpi)
        store.reconcileLogicalDevices([child(hs,unit:"unit-C",slot:1)],for:hs);model.consume(snapshot(store))
        #expect(model.activeOverlay == nil,"Device-bound overlay must close or remain bound to original session instead of resolving the replacement slot")
        #expect(model.sessionQuickPresetDrafts[a.id] == nil,"An old session draft cannot become the replacement unit's local preferences")
    }

    @Test func undoFoldForRemovedUnitCannotUnfoldReplacementUnit() throws {
        let bIdentity=try #require(DevicePreferenceIdentity.confirmedLogicalUnit(.init(vendorID:0x046D,unitID:"unit-B")))
        var store=DeviceStore(preferences:.init(foldedIdentities:[bIdentity.rawValue],rememberFoldedDevices:true))
        let host=hostItem();store.reconcile([host],at:t)
        let hs=try #require(store.devices[host.descriptor.id]?.sessionID)
        let a=child(hs,unit:"unit-A",slot:1);store.reconcileLogicalDevices([a],for:hs)
        let model=model();model.consume(snapshot(store));model.setDeviceFolded(true,for:.logical(a.id))
        let b=child(hs,unit:"unit-B",slot:1);store.reconcileLogicalDevices([b],for:hs);model.consume(snapshot(store))
        #expect(model.isDeviceFolded(.logical(b.id)))
        model.undoLastFoldAction()
        #expect(model.isDeviceFolded(.logical(b.id)),"Undo banner was created for A, so it must not change reliable identity B's folded preference")
    }

    @Test func newlyObservedEarJoinsAnOngoingLowEpisodeBeforeRecovery() async throws {
        let backend = IsolatedNotificationBackend()
        let persistence = IsolatedNotificationMemory()
        let clock = IsolatedClock(t)
        let service = NotificationService(backend: backend, persistence: persistence, now: { clock.value })
        await service.start(); await service.waitForEvaluation()
        service.consumeBluetoothAudio(audio([(.left, 20)], request: 1, time: clock.value))
        await service.waitForEvaluation()
        #expect(backend.messages.count == 1)
        service.consumeBluetoothAudio(audio([(.left, 20), (.right, 19)], request: 2, time: clock.value))
        await service.waitForEvaluation()
        service.consumeBluetoothAudio(audio([(.left, 25)], request: 3, time: clock.value))
        await service.waitForEvaluation()
        #expect(persistence.load().records["independent:headset"]?.isArmed == false, "Right ear was observed low during this episode and is now missing; missing does not prove recovery")
        clock.value = t.addingTimeInterval(LowBatteryPolicy.cooldown)
        service.consumeBluetoothAudio(audio([(.right, 19)], request: 4, time: clock.value))
        await service.waitForEvaluation()
        #expect(backend.messages.count == 1, "A continuing low episode cannot notify again solely because another ear recovered while this ear was missing")
        await service.stop()
    }

    @Test func reliableIdentityCanMoveBetweenSlotsWithoutMenuOrFoldLeakage() throws {
        var store = DeviceStore(); let host = hostItem(); store.reconcile([host], at: t)
        let hs = try #require(store.devices[host.descriptor.id]?.sessionID)
        let a = child(hs, unit: "unit-A", slot: 1)
        store.reconcileLogicalDevices([a], for: hs)
        let aSession = try #require(store.logicalDevices[a.id]?.sessionID)
        store.apply(update(60, estimate: true), to: aSession)
        let model = model(); model.consume(snapshot(store)); model.setDeviceFolded(true, for: .logical(a.id), showUndo: false)
        let b = child(hs, unit: "unit-B", slot: 1), aMoved = child(hs, unit: "unit-A", slot: 2)
        store.reconcileLogicalDevices([b,aMoved], for: hs); model.consume(snapshot(store))
        #expect(model.menuBarTitle == "约 60%")
        #expect(model.menuBarDisplay.selectedTarget == .logical(aMoved.id))
        #expect(model.isDeviceFolded(.logical(aMoved.id)))
        #expect(!model.isDeviceFolded(.logical(b.id)))
        #expect(model.homeDevices.count == 2)
        let acceptedOld = store.apply(update(1), to: aSession)
        #expect(!acceptedOld)
    }

    @Test func chargingCaseDoesNotBlockLowEarAndCaseCannotRearmEarEpisode() throws {
        let snap = audio([(.left,20),(.right,19),(.case,100)], request: 1, time:t, caseCharging:.charging)
        let candidate = try #require(LowBatteryCandidate(device:snap.devices[0],snapshot:snap,at:t))
        #expect(candidate.components.count == 2)
        #expect(candidate.evaluate(record:LowBatteryRecord(),at:t) == .notify(percent:19))
        let onlyCase = audio([(.case,100)],request:2,time:t)
        #expect(LowBatteryCandidate(device:onlyCase.devices[0],snapshot:onlyCase,at:t) == nil)
    }

    @Test func currentChargingFailureDoesNotEraseValidZeroBatteryCache() throws {
        var store = DeviceStore(); let item=hostItem(receiver:false); store.reconcile([item],at:t)
        let s=try #require(store.devices[item.descriptor.id]?.sessionID)
        store.apply(update(60),to:s)
        var menu=MenuBarDisplayState(); menu.select(HomeDeviceProjector.project(snapshot(store),audio:[],at:t).first)
        let failure=TelemetryFailure(category:.timeout,message:"synthetic charging timeout")
        store.apply(DeviceTelemetryUpdate(startedAt:t,finishedAt:t,battery:BatterySample(value:.percentage(0),receivedAt:t,source:"independent"),batteryFailure:nil,charging:nil,chargingFailure:failure),to:s)
        menu.reconcile(HomeDeviceProjector.project(snapshot(store),audio:[],at:t),preferredIdentity:nil,fallback:nil)
        #expect(menu.title == "0%")
        #expect(!menu.symbol.contains("bolt"))
        #expect(menu.accessibilityLabel.contains("待确认"))
    }

    private func hostItem(receiver:Bool=true)->IdentifiedDevice {
        let e=HIDInterfaceDescriptor(registryEntryID:1101,usbParentRegistryEntryID:1001,vendorID:0x1532,productID:0x00C5,product:"Synthetic host",transport:"USB",locationID:400,primaryUsage:.mouse)
        return IdentifiedDevice(descriptor:PhysicalDeviceGrouper.group([e])[0],kind:.mouse,capabilities:DeviceCapabilities(battery:.candidate,chargingQuery:true),controlEndpointRegistryEntryID:1101,isReceiver:receiver)
    }
    private func child(_ host:DeviceSessionID,unit:String,slot:UInt8)->LogicalDeviceDescriptor {
        LogicalDeviceDescriptor(address:DeviceAddress(hostSessionID:host,target:.receiver(index:slot,identity:.init(vendorID:0x046D,unitID:unit)),pairingGeneration:UUID()),product:unit,kind:.mouse,capabilities:DeviceCapabilities(battery:.candidate,chargingQuery:true),controlEndpointRegistryEntryID:1101,peerPresence:.reachable)
    }
    private func update(_ p:Int,estimate:Bool=false)->DeviceTelemetryUpdate {
        let b=estimate ? BatterySample(value:.voltageOnly(millivolts:3900),receivedAt:t,source:"independent voltage",percentageEstimate:.init(value:p,source:"independent",resolution:"10%")) : BatterySample(value:.percentage(p),receivedAt:t,source:"independent native")
        return .init(startedAt:t,finishedAt:t,battery:b,batteryFailure:nil,charging:.init(state:.discharging,rawValue:nil,receivedAt:t,source:"independent"),chargingFailure:nil)
    }
    private func snapshot(_ store:DeviceStore)->DeviceStoreSnapshot {
        .init(capturedAt:t,devices:Array(store.devices.values),primaryDeviceID:store.primaryDeviceID,isMonitoring:true,isSuspended:false,discoveryFailure:nil,preferencesFailure:nil,logicalDevices:Array(store.logicalDevices.values),primaryLogicalDeviceID:store.primaryLogicalDeviceID,preferences:store.preferences,historicalDevices:store.historicalDevices,historicalLogicalDevices:store.historicalLogicalDevices)
    }
    private func model()->AppModel {
        AppModel(monitor:BatteryMonitor(discovery:IsolatedDiscovery(),reader:IsolatedReader(),preferences:IsolatedDevicePreferences()),notifications:NotificationService(backend:IsolatedNotificationBackend(),persistence:IsolatedNotificationMemory(enabled:false)))
    }
    private func audio(_ parts:[(BluetoothAudioComponent,Int)],request:UInt64,time:Date,caseCharging:ChargingState = .discharging)->BluetoothAudioSnapshot {
        let session=BluetoothAudioSession(id:UUID(uuidString:"00000000-0000-0000-0000-000000001001")!,generation:1)
        let readings=parts.map { BluetoothAudioBatteryReading(component:$0.0,percent:$0.1,charging:$0.0 == .case ? caseCharging : .discharging,source:"independent native system",observedAt:time,session:session) }
        let device=BluetoothAudioDevice(id:.init(rawValue:"independent-headset"),name:"Independent headset",session:session,identityQuality:.verified,preferenceIdentity:"independent:headset",batteryReadings:readings,lastSeenAt:time,eventVersion:request)
        return .init(epoch:1,requestID:request,startedAt:time,finishedAt:time,devices:[device],discoveryStatus:.success,powerStatus:.success)
    }
}
@MainActor private final class IsolatedClock { var value:Date; init(_ value:Date){self.value=value} }
private actor IsolatedDiscovery:BatteryMonitorDiscovery {
    func snapshot()->HIDDiscoverySnapshot { .init(capturedAt:.distantPast,interfaces:[]) }
    func events()->AsyncStream<HIDDiscoveryEvent> { AsyncStream { _ in } }
    func stop(){}
}
private struct IsolatedReader:DeviceTelemetryReading { func read(device:PhysicalDeviceDescriptor) async -> DeviceTelemetryResult { fatalError("Real telemetry forbidden") } }
private struct IsolatedDevicePreferences:DevicePreferencesPersisting {func load()->DevicePreferences { .init() };func save(_ value:DevicePreferences){} }
private final class IsolatedNotificationMemory:NotificationPreferencesPersisting,@unchecked Sendable {
    private let lock=NSLock();private var value:NotificationPreferences
    init(enabled:Bool=true){value = .init(isEnabled:enabled)}
    func load()->NotificationPreferences {lock.withLock {value}}
    func save(_ proposed:NotificationPreferences){lock.withLock {value=proposed}}
}
@MainActor private final class IsolatedNotificationBackend:NotificationBackend {
    var messages:[String]=[]
    func authorization() async throws -> NotificationAuthorization {.authorized}
    func requestAuthorization() async throws {Issue.record("OS authorization forbidden")}
    func send(identifier:String,title:String,body:String) async throws {messages.append(body)}
}

// Developer regression additions. The seven independent cases above remain
// traceable to the frozen harness; the detail case reads the actual migrated
// route because a reused transport slot literal cannot identify both units.
extension IndependentStateAcceptanceTests {
    @Test func detailAndSettingsFollowReliableUnitAcrossSlotsWhileNewUnitOwnsOldSlot() throws {
        var store = DeviceStore(); let host = hostItem(); store.reconcile([host], at: t)
        let hs = try #require(store.devices[host.descriptor.id]?.sessionID)
        let a = child(hs, unit: "unit-A", slot: 1); store.reconcileLogicalDevices([a], for: hs)
        let model = model(); model.consume(snapshot(store)); model.navigateToDevice(.logical(a.id)); model.navigateToSettings()
        let moved = child(hs, unit: "unit-A", slot: 2), b = child(hs, unit: "unit-B", slot: 1)
        store.reconcileLogicalDevices([b, moved], for: hs); model.consume(snapshot(store)); model.navigateBackFromSettings()
        #expect(model.route == .device(.logical(moved.id)))
        #expect(model.associatedLogicalDevice(for: .logical(moved.id))?.descriptor.preferenceIdentity == a.preferenceIdentity)
        #expect(model.associatedLogicalDevice(for: .logical(b.id))?.descriptor.preferenceIdentity == b.preferenceIdentity)
    }

    @Test func anonymousSameNameSlotReplacementKeepsOldSessionHistory() throws {
        var store = DeviceStore(); let host = hostItem(); store.reconcile([host], at: t)
        let hs = try #require(store.devices[host.descriptor.id]?.sessionID)
        func anonymous() -> LogicalDeviceDescriptor {
            .init(address: .init(hostSessionID: hs, target: .receiver(index: 1, identity: .init(vendorID: 0x046D)), pairingGeneration: UUID()), product: "Identical display name", kind: .mouse, capabilities: .identificationOnly, peerPresence: .unknown)
        }
        let first = anonymous(); store.reconcileLogicalDevices([first], for: hs)
        let oldSession = try #require(store.logicalDevices[first.id]?.sessionID)
        let model = model(); model.consume(snapshot(store)); model.navigateToDevice(.logical(first.id))
        store.reconcileLogicalDevices([anonymous()], for: hs); model.consume(snapshot(store))
        guard case .device(let target) = model.route else { Issue.record("Expected old anonymous detail"); return }
        #expect(model.associatedLogicalDevice(for: target)?.sessionID == oldSession)
        #expect(model.associatedLogicalDevice(for: target)?.hostPresence == .removed)
        #expect(model.connectedHomeDevices.first?.logical?.sessionID != oldSession)
    }

    @Test func physicalPortPreferenceCannotRetargetAnOpenDetailToANewTransportSession() throws {
        var store = DeviceStore(); let item = hostItem(receiver: false); store.reconcile([item], at: t)
        let old = try #require(store.devices[item.descriptor.id]?.sessionID)
        let model = model(); model.consume(snapshot(store)); model.navigateToDevice(.physical(item.descriptor.id))
        store.reconcile([], at: t); store.reconcile([item], at: t); model.consume(snapshot(store))
        guard case .device(let target) = model.route else { Issue.record("Expected frozen physical detail"); return }
        #expect(model.associatedPhysicalDevice(for: target)?.sessionID == old)
        #expect(model.associatedPhysicalDevice(for: target)?.hostPresence == .removed)
        #expect(model.associatedPhysicalDevice(for: .physical(item.descriptor.id))?.sessionID != old)
    }

    @Test func sessionOnlyAudioNameAndSourceIDCannotRetargetAnOpenDetailAfterSessionRotation() throws {
        let model = model(), id = BluetoothAudioDeviceID(rawValue: "synthetic-reused-source")
        let first = BluetoothAudioDevice(id: id, name: "Same audio name", session: .init(generation: 1), lastSeenAt: t)
        model.consumeBluetoothAudio(.init(epoch: 1, requestID: 1, startedAt: t, finishedAt: t, devices: [first], discoveryStatus: .success, powerStatus: .success))
        model.navigateToDevice(.bluetoothAudio(id))
        let next = BluetoothAudioDevice(id: id, name: "Same audio name", session: .init(generation: 2), lastSeenAt: t)
        model.consumeBluetoothAudio(.init(epoch: 1, requestID: 2, startedAt: t, finishedAt: t, devices: [next], discoveryStatus: .success, powerStatus: .success))
        guard case .device(let target) = model.route else { Issue.record("Expected frozen audio detail"); return }
        #expect(model.associatedBluetoothAudioDevice(for: target)?.session == first.session)
        #expect(model.associatedBluetoothAudioDevice(for: target)?.connection == .disconnected)
        #expect(model.associatedBluetoothAudioDevice(for: .bluetoothAudio(id))?.session == next.session)
    }

    @Test func oldPreferenceSnapshotCannotUndoAnExplicitPrimaryChoice() throws {
        var store = DeviceStore(); let host = hostItem(); store.reconcile([host], at: t)
        let hs = try #require(store.devices[host.descriptor.id]?.sessionID)
        let a = child(hs, unit: "unit-A", slot: 1), b = child(hs, unit: "unit-B", slot: 2)
        store.reconcileLogicalDevices([a, b], for: hs); store.setPrimaryLogical(b.id)
        let old = snapshot(store), model = model(); model.consume(old)
        #expect(model.menuBarDisplay.selectedTarget == .logical(b.id))
        model.setPrimaryTarget(.logical(a.id)); model.consume(old)
        #expect(model.menuBarDisplay.selectedTarget == .logical(a.id))
    }
}

extension IndependentStateAcceptanceTests {
    @Test func replacedSessionDismissesEveryDeviceOverlayAndLateReadFailureCannotAttachToReplacement() async throws {
        for overlayKind in 0..<3 {
            let (monitor, driver, model, old) = try await intentRig()
            let settings = DeviceSettingsSnapshot(session: old.sessionID, revision: 1, capturedAt: t, settings: .init(currentDPI: DPISetting(400)))
            #expect(await monitor.publishSettings(settings)); model.consume(await monitor.snapshot())
            let device = try #require(model.snapshot.logicalDevices.first)
            model.openQuickPresetEditor(for: device, tab: .dpi)
            model.updateOnboardDraft(DeviceSettingsDraft(settings, scope: .onboard), for: old.id)
            let request = SettingChangeRequest(target: old.sessionID, expectedRevision: 1, change: .init(currentDPI: DPISetting(800)))
            if overlayKind == 1 { model.activeOverlay = .onboardFieldPicker(deviceID: old.id, field: .defaultDPI) }
            if overlayKind == 2 {
                model.activeOverlay = .restorePreview(deviceID: old.id, preview: .init(deviceID: old.id, deviceName: old.displayName, backupFileName: "synthetic.json", backupCapturedAt: t, formatSummary: "synthetic", rollbackURL: URL(fileURLWithPath: "/private/tmp/never-created-intent-backup"), request: request, items: []))
            }
            model.readSettings(old.id)
            for _ in 0..<20_000 { if await driver.readSessions.count == 1 { break }; await Task.yield() }
            #expect(await driver.readSessions == [old.sessionID])
            await driver.replaceUnit(); await monitor.refreshLogicalDiscovery(); model.consume(await monitor.snapshot())
            #expect(model.activeOverlay == nil); #expect(model.sessionQuickPresetDrafts[old.id] == nil)
            #expect(model.onboardDrafts[old.id] == nil)
            await driver.releaseOldRead(); await model.waitForSettingsAction(old.id)
            #expect(model.settingsErrors[old.id] == nil, "A's delayed error cannot become B's error")
            #expect(model.onboardDrafts[old.id] == nil); #expect(await driver.readSessions == [old.sessionID])
            model.applySettings(request); await model.waitForSettingsAction(old.id)
            #expect(await driver.writes == 0)
            await model.stop()
        }
    }

    @Test func queuedReadAndDelayedFilePanelPreflightCannotReadOrBackUpReplacementSession() async throws {
        let (monitor, driver, model, old) = try await intentRig()
        let controller = DeviceController(monitor: monitor)
        let first = Task { () -> Bool in
            do { _ = try await controller.readSettings(logicalDeviceID: old.id, expectedSession: old.sessionID); return false }
            catch { return true }
        }
        for _ in 0..<20_000 { if await driver.readSessions.count == 1 { break }; await Task.yield() }
        let queued = Task { () -> Bool in
            do { _ = try await controller.readSettings(logicalDeviceID: old.id, expectedSession: old.sessionID); return false }
            catch { return true }
        }
        for _ in 0..<100 { await Task.yield() }
        await driver.replaceUnit(); await monitor.refreshLogicalDiscovery(); model.consume(await monitor.snapshot())
        await driver.releaseOldRead()
        #expect(await first.value); #expect(await queued.value)
        #expect(await driver.readSessions == [old.sessionID])
        let url = URL(fileURLWithPath: "/private/tmp/never-created-session-guard-\(UUID().uuidString).json")
        // The native file panel itself performs no I/O in this test; this is the
        // deferred continuation with A's original session after B has arrived.
        do { _ = try await controller.exportProfile(logicalDeviceID: old.id, saveTo: url, expectedSession: old.sessionID); Issue.record("Stale file-panel backup was accepted") } catch {}
        do { _ = try await controller.prepareProfileRestore(backupURL: url, rollbackBackupURL: url, logicalDeviceID: old.id, expectedSession: old.sessionID); Issue.record("Stale file-panel restore was accepted") } catch {}
        #expect(await driver.exports == 0); #expect(await driver.restores == 0)
        #expect(await driver.readSessions == [old.sessionID]); #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.snapshot.logicalDevices.first?.settings == nil)
        await model.stop()
    }

    private func intentRig() async throws -> (BatteryMonitor, IntentSessionDriver, AppModel, LogicalDeviceState) {
        let driver = IntentSessionDriver()
        let registry = DriverRegistry(registrations: [.init(id: "synthetic.intent-session", identify: { host in
            IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly, controlEndpointRegistryEntryID: 1, isReceiver: true)
        }, logicalDriver: driver, settingsAdapter: driver)])
        let monitor = BatteryMonitor(discovery: IntentSessionDiscovery(), reader: registry, preferences: IsolatedDevicePreferences(), registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start(); let initial = await monitor.initialDiscoveryReady(), old = try #require(initial.logicalDevices.first)
        let model = AppModel(monitor: monitor, notifications: NotificationService(backend: IsolatedNotificationBackend(), persistence: IsolatedNotificationMemory(enabled: false)))
        model.consume(initial); return (monitor, driver, model, old)
    }
}

private actor IntentSessionDiscovery: BatteryMonitorDiscovery {
    private var continuation: AsyncStream<HIDDiscoveryEvent>.Continuation?
    func snapshot() -> HIDDiscoverySnapshot {
        .init(capturedAt: Date(), interfaces: [.init(registryEntryID: 1, usbParentRegistryEntryID: 1, vendorID: 0xABCD, productID: 1, product: "Synthetic intent host", transport: "USB", locationID: 1, primaryUsage: .mouse)])
    }
    func events() -> AsyncStream<HIDDiscoveryEvent> {
        let pair = AsyncStream<HIDDiscoveryEvent>.makeStream(); continuation = pair.continuation
        pair.continuation.yield(.init(kind: .initial, snapshot: snapshot())); return pair.stream
    }
    func stop() { continuation?.finish() }
}
private actor IntentSessionDriver: DeviceLogicalDriver, DeviceSettingsAdapter, DeviceProfileBacking {
    private var unit = "synthetic-A"
    private var waiter: CheckedContinuation<DeviceSettings, Error>?
    private(set) var readSessions: [LogicalDeviceSessionID] = []
    private(set) var exports = 0, restores = 0, writes = 0
    func replaceUnit() { unit = "synthetic-B" }
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) -> [LogicalDeviceDescriptor] {
        [.init(address: .init(hostSessionID: session, target: .receiver(index: 1, identity: .init(vendorID: 0x046D, unitID: unit)), pairingGeneration: UUID()), product: unit, kind: .mouse, capabilities: .init(operations: [.dpiRead: .init(evidence: .readVerified)]), controlEndpointRegistryEntryID: 1, peerPresence: .reachable)]
    }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) -> LogicalDeviceTelemetryResult {
        .init(session: session, update: .init(startedAt: Date(), finishedAt: Date(), battery: nil, batteryFailure: nil, charging: nil, chargingFailure: nil))
    }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async throws -> DeviceSettings {
        readSessions.append(session)
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func releaseOldRead() { waiter?.resume(throwing: TelemetryFailure(category: .timeout, message: "Synthetic A read failed after B arrived")); waiter = nil }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) throws -> SettingAdapterTransaction {
        writes += 1; throw TelemetryFailure(category: .unsupported, message: "No write authorized by intent-session tests")
    }
    func exportProfile(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, saveTo: URL, hardwareEvidenceReference: String?) throws -> ProfileBackup {
        exports += 1; throw TelemetryFailure(category: .unsupported, message: "No backup I/O authorized by intent-session tests")
    }
    func prepareRestore(backupURL: URL, rollbackBackupURL: URL, target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID, hardwareEvidenceReference: String?) throws -> DeviceSettingsChange {
        restores += 1; throw TelemetryFailure(category: .unsupported, message: "No restore I/O authorized by intent-session tests")
    }
}
