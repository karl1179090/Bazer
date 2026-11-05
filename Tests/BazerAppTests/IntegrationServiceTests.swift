// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import Testing
@testable import BazerApp

@Suite("Notification and login services — fakes only")
@MainActor
struct IntegrationServiceTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func defaultsDoNotRequestAuthorizationOrRegisterAnything() async throws {
        let backend = FakeNotificationBackend(), persistence = NotificationMemory()
        let service = NotificationService(backend: backend, persistence: persistence, now: { date })
        #expect(!service.isEnabled); #expect(backend.authorizationReads == 0)
        service.consume(try snapshot(raw: 0))
        await service.start(); await service.waitForEvaluation()
        #expect(backend.requests == 0); #expect(backend.sent.isEmpty)
        let loginBackend = FakeLoginBackend(), login = LoginItemService(backend: FakeLoginBackend())
        login.refresh(); #expect(login.status == .notRegistered)
        let observed = LoginItemService(backend: loginBackend); observed.refresh()
        #expect(loginBackend.registrations == 0); #expect(loginBackend.unregistrations == 0)
        await service.stop()
    }

    @Test func onlyEnableRequestsAndDenialDoesNotPromptAgainOrSend() async throws {
        let backend = FakeNotificationBackend(); backend.resultAfterRequest = .denied
        let service = NotificationService(backend: backend, persistence: NotificationMemory(), now: { date })
        service.consume(try snapshot(raw: 0)); await service.start()
        await service.setEnabledByUser(true); await service.waitForEvaluation()
        #expect(backend.requests == 1); #expect(service.authorization == .denied)
        #expect(service.isEnabled); #expect(!service.canSendTest); #expect(backend.sent.isEmpty)
        await service.setEnabledByUser(false); await service.setEnabledByUser(true)
        await service.sendTestByUser(); await service.waitForEvaluation()
        #expect(backend.requests == 1); #expect(backend.sent.isEmpty)
        await service.stop()
    }

    @Test func testNotificationIsExplicitAndDoesNotConsumeLowBatteryCooldown() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let persistence = NotificationMemory(NotificationPreferences(isEnabled: true))
        let service = NotificationService(backend: backend, persistence: persistence, now: { date })
        await service.start(); await service.waitForEvaluation(); await service.sendTestByUser()
        let test = try #require(backend.sent.first)
        #expect(test.title == "Bazer 测试通知"); #expect(!test.body.contains("%"))
        #expect(try persistence.load().records.isEmpty)
        service.consume(try snapshot(raw: 0)); await service.waitForEvaluation()
        #expect(backend.sent.count == 2); #expect(backend.sent[1].body.contains("0%"))
        await service.stop()
    }

    @Test func duplicateSnapshotsJitterAndRestartDoNotRepeat() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let persistence = NotificationMemory(NotificationPreferences(isEnabled: true))
        let service = NotificationService(backend: backend, persistence: persistence, now: { date })
        let low = try snapshot(raw: 51)
        await service.start(); service.consume(low); service.consume(low); await service.waitForEvaluation()
        service.consume(try snapshot(raw: 53)); await service.waitForEvaluation()
        service.consume(low); await service.waitForEvaluation()
        #expect(backend.sent.count == 1)
        await service.stop()
        let restartedBackend = FakeNotificationBackend(); restartedBackend.current = .authorized
        let restarted = NotificationService(backend: restartedBackend, persistence: persistence, now: { date.addingTimeInterval(21_600) })
        await restarted.start(); restarted.consume(try snapshot(raw: 51, at: date.addingTimeInterval(21_600)))
        await restarted.waitForEvaluation()
        #expect(restartedBackend.sent.isEmpty) // Six hours alone cannot rearm an episode.
        restarted.consume(try snapshot(raw: 64, at: date.addingTimeInterval(21_600)))
        await restarted.waitForEvaluation()
        restarted.consume(try snapshot(raw: 51, at: date.addingTimeInterval(21_600)))
        await restarted.waitForEvaluation()
        #expect(restartedBackend.sent.count == 1)
        await restarted.stop()
    }

    @Test func staleChargingUnknownFailedAndSuspendedNeverSend() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let service = NotificationService(backend: backend, persistence: NotificationMemory(NotificationPreferences(isEnabled: true)), now: { date })
        await service.start()
        for state in [ChargingState.charging, .unknown] {
            service.consume(try snapshot(raw: 0, charging: state)); await service.waitForEvaluation()
        }
        service.consume(try snapshot(raw: 0, at: date.addingTimeInterval(-180))); await service.waitForEvaluation()
        service.consume(try snapshot(raw: 0, failure: true)); await service.waitForEvaluation()
        service.consume(try snapshot(raw: 0, suspended: true)); await service.waitForEvaluation()
        #expect(backend.sent.isEmpty)
        await service.stop()
    }

    @Test func twoSameModelsOnDifferentPortsHaveIndependentCooldown() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let service = NotificationService(backend: backend, persistence: NotificationMemory(NotificationPreferences(isEnabled: true)), now: { date })
        let one = try snapshot(raw: 0), two = try snapshot(raw: 0, parent: 2, location: 200)
        await service.start()
        service.consume(DeviceStoreSnapshot(capturedAt: date, devices: one.devices + two.devices, primaryDeviceID: nil,
            isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil))
        await service.waitForEvaluation(); #expect(backend.sent.count == 2)
        await service.stop()
    }

    @Test func historyIsReservedBeforeEnqueueAndSendErrorCanRetryNextQuery() async throws {
        let persistence = NotificationMemory(NotificationPreferences(isEnabled: true))
        let backend = FakeNotificationBackend(); backend.current = .authorized; backend.sendFailure = true
        backend.beforeSend = { #expect((try? persistence.load().records.values.first?.isArmed) == false) }
        let service = NotificationService(backend: backend, persistence: persistence, now: { date })
        await service.start(); service.consume(try snapshot(raw: 0)); await service.waitForEvaluation()
        #expect(service.errorMessage?.contains("SyntheticSend") == true)
        #expect(try persistence.load().records.values.first?.isArmed == true)
        backend.sendFailure = false
        service.consume(try snapshot(raw: 0)); await service.waitForEvaluation()
        #expect(backend.sent.count == 1)
        await service.stop()
    }

    @Test func persistenceFailurePreventsUntrackedNotification() async throws {
        let persistence = NotificationMemory(NotificationPreferences(isEnabled: true)); persistence.failSave = true
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let service = NotificationService(backend: backend, persistence: persistence, now: { date })
        await service.start(); service.consume(try snapshot(raw: 0)); await service.waitForEvaluation()
        #expect(backend.sent.isEmpty); #expect(service.errorMessage?.contains("未发送") == true)
        await service.stop()
    }

    @Test func inFlightEnqueueCannotDuplicateOrReenableAfterUserDisables() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized; backend.pauseSend = true
        let persistence = NotificationMemory(NotificationPreferences(isEnabled: true))
        let service = NotificationService(backend: backend, persistence: persistence, now: { date })
        await service.start(); service.consume(try snapshot(raw: 0))
        for _ in 0..<100 where backend.resumeSend == nil { await Task.yield() }
        #expect(backend.resumeSend != nil)
        service.consume(try snapshot(raw: 0)); await service.setEnabledByUser(false)
        backend.resumeSend?.resume(); backend.resumeSend = nil
        await service.waitForEvaluation()
        #expect(backend.sent.count == 1); #expect(!service.isEnabled)
        #expect(try !persistence.load().isEnabled)
        await service.stop()
    }

    @Test func newerFailureDuringAuthorizationReadCannotSendEarlierFreshCache() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let service = NotificationService(backend: backend, persistence: NotificationMemory(NotificationPreferences(isEnabled: true)), now: { date })
        await service.start(); await service.waitForEvaluation()
        backend.pauseAuthorization = true
        service.consume(try snapshot(raw: 0))
        for _ in 0..<100 where backend.resumeAuthorization == nil { await Task.yield() }
        #expect(backend.resumeAuthorization != nil)
        service.consume(try snapshot(raw: 0, failure: true))
        backend.pauseAuthorization = false
        backend.resumeAuthorization?.resume(); backend.resumeAuthorization = nil
        await service.waitForEvaluation(); #expect(backend.sent.isEmpty)
        await service.stop()
    }

    @Test func failedSaveStillHonorsDisableForThisProcess() async throws {
        let persistence = NotificationMemory(NotificationPreferences(isEnabled: true))
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let service = NotificationService(backend: backend, persistence: persistence, now: { date })
        await service.start(); await service.waitForEvaluation()
        persistence.failSave = true
        await service.setEnabledByUser(false)
        service.consume(try snapshot(raw: 0)); await service.waitForEvaluation()
        #expect(!service.isEnabled); #expect(backend.sent.isEmpty)
        #expect(service.errorMessage?.contains("本次运行已关闭") == true)
        await service.stop()
    }

    @Test func loginTracksApprovalErrorsAndExternalChangesInsteadOfIntent() {
        let backend = FakeLoginBackend(), service = LoginItemService(backend: FakeLoginBackend())
        service.refresh(); #expect(service.status == .notRegistered)
        let observed = LoginItemService(backend: backend)
        backend.afterRegister = .requiresApproval
        observed.setEnabledByUser(true)
        #expect(observed.status == .requiresApproval)
        observed.openSettingsByUser(); #expect(backend.settingsOpens == 1)
        backend.current = .enabled; observed.refresh(); #expect(observed.status == .enabled)
        observed.setEnabledByUser(false); #expect(observed.status == .notRegistered)
        backend.operationFailure = true
        observed.setEnabledByUser(true)
        #expect(observed.status == .notRegistered)
        #expect(observed.errorMessage?.contains("SyntheticSM 3") == true)
        #expect(backend.registrations == 2); #expect(backend.unregistrations == 1)
    }

    @Test func directLogicalMirrorNotifiesOnceAndReceiverChildrenHaveIndependentNotifications() async throws {
        for receiver in [false, true] {
            let physical = try #require(snapshot(raw: 0).devices.first)
            let identified = IdentifiedDevice(descriptor: physical.descriptor, kind: .mouse, capabilities: physical.capabilities,
                controlEndpointRegistryEntryID: physical.controlEndpointRegistryEntryID, isReceiver: receiver)
            var store = DeviceStore(); store.reconcile([identified], at: date)
            let host = try #require(store.devices[identified.descriptor.id]?.sessionID)
            if receiver {
                let children = [UInt8(1), 2].map { index in
                    LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: host,
                        target: .receiver(index: index, identity: LogicalPeripheralIdentity(vendorID: 0x046D, unitID: "synthetic-unit-\(index)")), pairingGeneration: UUID()),
                        product: "Synthetic child \(index)", kind: .mouse,
                        capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: physical.controlEndpointRegistryEntryID)
                }
                store.reconcileLogicalDevices(children, for: host)
            }
            let update = DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
                battery: BatterySample(value: .percentage(10), receivedAt: date, source: "synthetic"), batteryFailure: nil,
                charging: ChargingSample(state: .notCharging, rawValue: nil, receivedAt: date, source: "synthetic"), chargingFailure: nil)
            store.apply(update, to: host)
            for child in Array(store.logicalDevices.values) { store.apply(update, to: child.sessionID) }
            let backend = FakeNotificationBackend(); backend.current = .authorized
            let persistence = NotificationMemory(NotificationPreferences(isEnabled: true))
            let service = NotificationService(backend: backend, persistence: persistence, now: { date })
            await service.start()
            service.consume(DeviceStoreSnapshot(capturedAt: date, devices: Array(store.devices.values), primaryDeviceID: store.primaryDeviceID,
                isMonitoring: true, isSuspended: false, discoveryFailure: nil, preferencesFailure: nil, logicalDevices: Array(store.logicalDevices.values)))
            await service.waitForEvaluation()
            #expect(backend.sent.count == (receiver ? 2 : 1))
            #expect(try persistence.load().records.count == (receiver ? 2 : 1))
            await service.stop()
        }
    }

    private func snapshot(raw: UInt8, charging: ChargingState = .notCharging, at timestamp: Date? = nil,
        parent: UInt64 = 1, location: UInt32 = 100, failure: Bool = false, suspended: Bool = false) throws -> DeviceStoreSnapshot {
        let timestamp = timestamp ?? date
        let endpoint = HIDInterfaceDescriptor(registryEntryID: parent + 100, usbParentRegistryEntryID: parent,
            vendorID: 0x1532, productID: 0x00C5, product: "Synthetic", transport: "USB", locationID: location, primaryUsage: .mouse)
        let identified = IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([endpoint])[0], kind: .mouse,
            capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: parent + 100)
        var store = DeviceStore(); store.reconcile([identified], at: timestamp)
        let session = try #require(store.devices[identified.descriptor.id]?.sessionID)
        store.apply(DeviceTelemetryUpdate(startedAt: timestamp, finishedAt: timestamp,
            battery: BatterySample(rawValue: raw, receivedAt: timestamp, source: "synthetic test"), batteryFailure: nil,
            charging: ChargingSample(state: charging, rawValue: nil, receivedAt: timestamp, source: "synthetic test"),
            chargingFailure: failure ? TelemetryFailure(category: .timeout, message: "synthetic failure") : nil), to: session)
        return DeviceStoreSnapshot(capturedAt: timestamp, devices: Array(store.devices.values), primaryDeviceID: identified.descriptor.id,
            isMonitoring: true, isSuspended: suspended, discoveryFailure: nil, preferencesFailure: nil)
    }
}

private final class NotificationMemory: NotificationPreferencesPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NotificationPreferences
    var failSave = false
    init(_ value: NotificationPreferences = NotificationPreferences()) { self.value = value }
    func load() throws -> NotificationPreferences { lock.withLock { value } }
    func save(_ preferences: NotificationPreferences) throws {
        try lock.withLock {
            if failSave { throw NSError(domain: "SyntheticPersistence", code: 1) }
            value = preferences
        }
    }
}

@MainActor
private final class FakeNotificationBackend: NotificationBackend {
    struct Sent { let title: String; let body: String }
    var current: NotificationAuthorization = .notDetermined
    var resultAfterRequest: NotificationAuthorization = .authorized
    var requests = 0, authorizationReads = 0
    var sent: [Sent] = []
    var sendFailure = false, pauseSend = false
    var resumeSend: CheckedContinuation<Void, Never>?
    var pauseAuthorization = false
    var resumeAuthorization: CheckedContinuation<Void, Never>?
    var beforeSend: (() -> Void)?
    func authorization() async throws -> NotificationAuthorization {
        authorizationReads += 1
        if pauseAuthorization { await withCheckedContinuation { resumeAuthorization = $0 } }
        return current
    }
    func requestAuthorization() async throws { requests += 1; current = resultAfterRequest }
    func send(identifier: String, title: String, body: String) async throws {
        beforeSend?()
        if pauseSend { await withCheckedContinuation { resumeSend = $0 } }
        if sendFailure { throw NSError(domain: "SyntheticSend", code: 1) }
        sent.append(Sent(title: title, body: body))
    }
}

@MainActor
private final class FakeLoginBackend: LoginItemBackend {
    var current: LoginItemStatus = .notRegistered
    var afterRegister: LoginItemStatus = .enabled
    var operationFailure = false
    var registrations = 0, unregistrations = 0, settingsOpens = 0
    var status: LoginItemStatus { current }
    func register() throws {
        registrations += 1
        if operationFailure { throw NSError(domain: "SyntheticSM", code: 3) }
        current = afterRegister
    }
    func unregister() throws {
        unregistrations += 1
        if operationFailure { throw NSError(domain: "SyntheticSM", code: 3) }
        current = .notRegistered
    }
    func openSettings() { settingsOpens += 1 }
}

extension IntegrationServiceTests {
    @Test func audioNotificationsAreIndependentOfAbsentOrFailedHIDDiscovery() async throws {
        for failedHID in [false, true] {
            let backend = FakeNotificationBackend(); backend.current = .authorized
            let memory = NotificationMemory(NotificationPreferences(isEnabled: true))
            let service = NotificationService(backend: backend, persistence: memory, now: { date })
            if failedHID {
                service.consume(DeviceStoreSnapshot(capturedAt: date, devices: [], primaryDeviceID: nil, isMonitoring: true, isSuspended: false, discoveryFailure: "synthetic HID failure", preferencesFailure: nil))
            }
            await service.start(); service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 1))
            await service.waitForEvaluation()
            #expect(backend.sent.count == 1); #expect(backend.sent.first?.body.contains("系统报告剩余 20%") == true)
            await service.stop()
        }
    }

    @Test func audioStrictAdapterRejectsEveryUnreliableOrInvalidEvidenceBoundary() async throws {
        let baseline = audioSnapshot([(.single, 20)], version: 1)
        let device = try #require(baseline.devices.first)
        var invalid: [BluetoothAudioSnapshot] = []
        for quality in [BluetoothAudioIdentityQuality.sessionOnly, .ambiguous] {
            var d = device; d.identityQuality = quality; invalid.append(replacingAudio(d, in: baseline))
        }
        for connection in [BluetoothAudioConnection.disconnected, .uncertain] {
            var d = device; d.connection = connection; invalid.append(replacingAudio(d, in: baseline))
        }
        for status in [BluetoothAudioReadStatus.failed, .partial, .unavailable] {
            var d = device; d.readStatus = status; invalid.append(replacingAudio(d, in: baseline))
            invalid.append(replacingAudio(device, in: baseline, powerStatus: status))
        }
        for charging in [ChargingState.unknown, .charging, .full, .error] {
            invalid.append(audioSnapshot([(.single, 20)], charging: charging, version: 1))
        }
        for variant in 0..<6 {
            let original = try #require(device.batteryReadings.first)
            let reading = BluetoothAudioBatteryReading(percent: variant == 5 ? nil : 20,
                charging: .discharging, source: "fake system", observedAt: variant == 0 ? date.addingTimeInterval(-180) : date,
                sourceUpdatedAt: variant == 1 ? date.addingTimeInterval(-180) : nil,
                session: variant == 2 ? .init(generation: 99) : original.session,
                isPresent: variant != 3, isNative: variant != 4)
            var d = device; d.batteryReadings = [reading]; invalid.append(replacingAudio(d, in: baseline))
        }
        invalid.append(audioSnapshot([(.case, 0)], version: 1))
        invalid.append(audioSnapshot([(.single, 20), (.left, 10)], version: 1))
        for snapshot in invalid {
            #expect(LowBatteryCandidate(device: snapshot.devices[0], snapshot: snapshot, at: date) == nil)
            let backend = FakeNotificationBackend(); backend.current = .authorized
            let service = NotificationService(backend: backend, persistence: NotificationMemory(NotificationPreferences(isEnabled: true)), now: { date })
            await service.start(); service.consumeBluetoothAudio(snapshot); await service.waitForEvaluation()
            #expect(backend.sent.isEmpty); await service.stop()
        }
    }

    @Test func audioDefaultOffDoesNotPromptAndObservedTimeIsNotAnEventIdentity() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let memory = NotificationMemory()
        let service = NotificationService(backend: backend, persistence: memory, now: { date })
        await service.start(); service.consumeBluetoothAudio(audioSnapshot([(.single, 0)], version: 1)); await service.waitForEvaluation()
        #expect(!service.isEnabled); #expect(backend.requests == 0); #expect(backend.sent.isEmpty)
        await service.setEnabledByUser(true); await service.waitForEvaluation(); #expect(backend.sent.count == 1)
        let repeated = audioSnapshot([(.single, 0)], version: 1, observedAt: date.addingTimeInterval(-1))
        service.consumeBluetoothAudio(repeated); await service.waitForEvaluation()
        service.consumeBluetoothAudio(audioSnapshot([(.single, 0)], version: 2)); await service.waitForEvaluation()
        #expect(backend.sent.count == 1); #expect(try memory.load().records.count == 1)
        await service.stop()
    }

    @Test func audioMultiEarRecoveryRequiresAllEarsAndPersistsAcrossRestartAndReconnect() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let memory = NotificationMemory(NotificationPreferences(isEnabled: true))
        let service = NotificationService(backend: backend, persistence: memory, now: { date })
        await service.start(); service.consumeBluetoothAudio(audioSnapshot([(.left, 20), (.right, 19), (.case, 1)], version: 1)); await service.waitForEvaluation()
        #expect(backend.sent.count == 1); #expect(backend.sent.first?.body.contains("左耳") == true)
        let record = try #require(memory.load().records["synthetic-audio:stable"])
        #expect(record.recoveryComponents == ["left", "right"])
        service.consumeBluetoothAudio(audioSnapshot([(.left, 25)], version: 2)); await service.waitForEvaluation()
        #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == false)
        service.consumeBluetoothAudio(audioSnapshot([(.left, 25), (.right, 24)], version: 3)); await service.waitForEvaluation()
        #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == false)
        service.consumeBluetoothAudio(audioSnapshot([(.left, 25), (.right, 25)], version: 4)); await service.waitForEvaluation()
        #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == true)
        service.consumeBluetoothAudio(audioSnapshot([(.left, 20), (.right, 20)], version: 5)); await service.waitForEvaluation()
        #expect(backend.sent.count == 1, "Recovery still respects the six-hour cooldown")
        await service.stop()
        let later = date.addingTimeInterval(LowBatteryPolicy.cooldown)
        let restartedBackend = FakeNotificationBackend(); restartedBackend.current = .authorized
        let restarted = NotificationService(backend: restartedBackend, persistence: memory, now: { later })
        await restarted.start(); restarted.consumeBluetoothAudio(audioSnapshot([(.left, 20), (.right, 20)], version: 1, generation: 99, observedAt: later)); await restarted.waitForEvaluation()
        #expect(restartedBackend.sent.count == 1)
        restarted.consumeBluetoothAudio(audioSnapshot([(.left, 20), (.right, 20)], version: 2, generation: 100, observedAt: later)); await restarted.waitForEvaluation()
        #expect(restartedBackend.sent.count == 1, "Reconnect never rearms a continuing low episode")
        await restarted.stop()
    }

    @Test func audioDisconnectOrSleepDuringAuthorizationWaitCannotSendOldCandidate() async throws {
        for sleeping in [false, true] {
            let backend = FakeNotificationBackend(); backend.current = .authorized
            let service = NotificationService(backend: backend, persistence: NotificationMemory(NotificationPreferences(isEnabled: true)), now: { date })
            await service.start(); await service.waitForEvaluation()
            backend.pauseAuthorization = true
            let low = audioSnapshot([(.single, 20)], version: 1)
            service.consumeBluetoothAudio(low)
            for _ in 0..<1000 where backend.resumeAuthorization == nil { await Task.yield() }
            #expect(backend.resumeAuthorization != nil)
            if sleeping { service.setSuspended(true) }
            else {
                var device = low.devices[0]; device.connection = .disconnected
                service.consumeBluetoothAudio(replacingAudio(device, in: low))
            }
            backend.pauseAuthorization = false; backend.resumeAuthorization?.resume(); backend.resumeAuthorization = nil
            await service.waitForEvaluation(); #expect(backend.sent.isEmpty)
            await service.stop()
        }
    }

    @Test func audioReserveAndPersistenceFailuresUseExistingDeliveryRules() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let memory = NotificationMemory(NotificationPreferences(isEnabled: true)); memory.failSave = true
        let service = NotificationService(backend: backend, persistence: memory, now: { date })
        await service.start(); service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 1)); await service.waitForEvaluation()
        #expect(backend.sent.isEmpty)
        memory.failSave = false; backend.sendFailure = true
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 2)); await service.waitForEvaluation()
        #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == true)
        backend.sendFailure = false
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 3)); await service.waitForEvaluation()
        #expect(backend.sent.count == 1); #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == false)
        await service.stop()
    }

    private func audioSnapshot(_ parts: [(BluetoothAudioComponent, Int)], charging: ChargingState = .discharging,
        version: UInt64, generation: UInt64 = 1, observedAt: Date? = nil, requestID: UInt64? = nil) -> BluetoothAudioSnapshot {
        let time = observedAt ?? date, session = BluetoothAudioSession(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, generation: generation)
        let readings = parts.map { BluetoothAudioBatteryReading(component: $0.0, percent: $0.1, charging: charging, source: "fake native system", observedAt: time, session: session) }
        let device = BluetoothAudioDevice(id: .init(rawValue: "synthetic-audio"), name: "Synthetic headset", session: session, identityQuality: .verified, preferenceIdentity: "synthetic-audio:stable", batteryReadings: readings, lastReadings: readings, lastSeenAt: time, eventVersion: version)
        return BluetoothAudioSnapshot(requestID: requestID ?? version, startedAt: time, finishedAt: time, devices: [device], discoveryStatus: .success, powerStatus: .success)
    }
    private func replacingAudio(_ device: BluetoothAudioDevice, in original: BluetoothAudioSnapshot,
        powerStatus: BluetoothAudioReadStatus = .success) -> BluetoothAudioSnapshot {
        BluetoothAudioSnapshot(requestID: original.requestID, startedAt: original.startedAt, finishedAt: original.finishedAt, devices: [device], discoveryStatus: original.discoveryStatus, powerStatus: powerStatus)
    }
}


extension IntegrationServiceTests {
    @Test func audioUnchangedPercentReevaluatesAfterCooldownWithoutInventingANewEvent() async throws {
        let memory = NotificationMemory(NotificationPreferences(isEnabled: true,
            records: ["synthetic-audio:stable": LowBatteryRecord(isArmed: true, lastNotifiedAt: date, recoveryComponents: ["single"])]))
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let clock = NotificationTestClock(date.addingTimeInterval(10))
        let service = NotificationService(backend: backend, persistence: memory, now: { clock.date })
        await service.start()
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 7, observedAt: clock.date, requestID: 1))
        await service.waitForEvaluation(); #expect(backend.sent.isEmpty)
        clock.date = date.addingTimeInterval(LowBatteryPolicy.cooldown)
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 7, observedAt: clock.date, requestID: 2))
        await service.waitForEvaluation(); #expect(backend.sent.count == 1)
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 7, observedAt: clock.date, requestID: 3))
        await service.waitForEvaluation(); #expect(backend.sent.count == 1)
        await service.stop()
    }
    @Test func audioUnchangedSuccessfulReadCanRetrySaveOrDeliveryFailure() async throws {
        let memory = NotificationMemory(NotificationPreferences(isEnabled: true))
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let service = NotificationService(backend: backend, persistence: memory, now: { date })
        await service.start(); memory.failSave = true
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 7, requestID: 1)); await service.waitForEvaluation()
        #expect(backend.sent.isEmpty)
        memory.failSave = false; backend.sendFailure = true
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 7, requestID: 2)); await service.waitForEvaluation()
        #expect(backend.sent.isEmpty); #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == true)
        backend.sendFailure = false
        service.consumeBluetoothAudio(audioSnapshot([(.single, 20)], version: 7, requestID: 3)); await service.waitForEvaluation()
        #expect(backend.sent.count == 1)
        await service.stop()
    }
}

@MainActor private final class NotificationTestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

extension IntegrationServiceTests {
    @Test func newlyObservedEarRemainsRequiredWhenUnionPersistenceFailsThenProcessRestarts() async throws {
        let backend = FakeNotificationBackend(); backend.current = .authorized
        let memory = NotificationMemory(NotificationPreferences(isEnabled: true))
        let clock = NotificationTestClock(date)
        let service = NotificationService(backend: backend, persistence: memory, now: { clock.date })
        await service.start()
        service.consumeBluetoothAudio(audioSnapshot([(.left, 20)], version: 1)); await service.waitForEvaluation()
        #expect(backend.sent.count == 1)
        memory.failSave = true
        service.consumeBluetoothAudio(audioSnapshot([(.left, 20), (.right, 19)], version: 2)); await service.waitForEvaluation()
        service.consumeBluetoothAudio(audioSnapshot([(.left, 25)], version: 3)); await service.waitForEvaluation()
        #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == false)
        #expect(service.errorMessage?.contains("耳侧恢复状态") == true)
        memory.failSave = false
        service.consumeBluetoothAudio(audioSnapshot([(.left, 25)], version: 4)); await service.waitForEvaluation()
        let record = try #require(memory.load().records["synthetic-audio:stable"])
        #expect(record.recoveryComponents == ["left", "right"]); #expect(!record.isArmed)
        await service.stop()
        clock.date = date.addingTimeInterval(LowBatteryPolicy.cooldown)
        let restartedBackend = FakeNotificationBackend(); restartedBackend.current = .authorized
        let restarted = NotificationService(backend: restartedBackend, persistence: memory, now: { clock.date })
        await restarted.start()
        restarted.consumeBluetoothAudio(audioSnapshot([(.left, 25)], version: 5, observedAt: clock.date)); await restarted.waitForEvaluation()
        restarted.consumeBluetoothAudio(audioSnapshot([(.right, 19)], version: 6, observedAt: clock.date)); await restarted.waitForEvaluation()
        #expect(restartedBackend.sent.isEmpty)
        #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == false)
        restarted.consumeBluetoothAudio(audioSnapshot([(.left, 25), (.right, 25)], version: 7, observedAt: clock.date)); await restarted.waitForEvaluation()
        #expect(try memory.load().records["synthetic-audio:stable"]?.isArmed == true)
        await restarted.stop()
    }

    @Test func unknownAudioPartsCannotTriggerOrSatisfyEarRecovery() throws {
        let snapshot = audioSnapshot([(.unknown, 0), (.left, 30)], version: 1)
        let candidate = try #require(LowBatteryCandidate(device: snapshot.devices[0], snapshot: snapshot, at: date))
        #expect(candidate.componentIDs == ["left"]); #expect(candidate.percent == 30)
        #expect(candidate.evaluate(record: LowBatteryRecord(isArmed: false, recoveryComponents: ["left", "right"]), at: date) == .none)
        let unknown = audioSnapshot([(.unknown, 0)], version: 2)
        #expect(LowBatteryCandidate(device: unknown.devices[0], snapshot: unknown, at: date) == nil)
    }
}
