// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
@testable import BazerHID
import Foundation
import LogitechHIDPP
import Testing
@testable import HIDProbe

private struct TelemetryMemoryPreferences: DevicePreferencesPersisting {
    func load() -> DevicePreferences { DevicePreferences() }
    func save(_ preferences: DevicePreferences) {}
}

/// Values only: this backend never constructs or opens a native HID device.
private final class TelemetryFixtureBackend: HIDDiscoveryBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = 0
    var stopCount: Int { lock.withLock { stopped } }
    static let interface = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10,
        vendorID: 0x046D, productID: 0xC539, product: "Offline telemetry receiver", transport: "USB",
        primaryUsage: .mouse, reportDescriptor: [0x06, 0, 0xFF, 9, 1, 0xA1, 1, 0x75, 8, 0x85, 0x10,
            0x95, 6, 0x81, 2, 0x91, 2, 0x85, 0x11, 0x95, 19, 0x81, 2, 0x91, 2, 0xC0])
    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) {}
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [Self.interface]) }
    func inspectInterface(registryEntryID: UInt64) throws -> HIDInspectionResult {
        throw HIDDiscoveryError.unsafeEndpoint("Offline telemetry fixture must never inspect/open a device")
    }
    func stop() { lock.withLock { stopped += 1 } }
}

private actor TelemetryFixtureDriver: DeviceLogicalDriver, DeviceSettingsAdapter {
    var readTargets: [LogicalDeviceID] = []
    var settingReads = 0, settingWrites = 0, stopCount = 0
    private var updates: [DeviceTelemetryUpdate]
    private var afterRead: (@Sendable () async -> Void)?
    private var wrongResultSession = false
    private var holdStop = false
    private var stopGate: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    init(updates: [DeviceTelemetryUpdate]) { self.updates = updates }
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) -> [LogicalDeviceDescriptor] {
        (1...2).map { slot in
            let identity = LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0xAAAA,
                unitID: "PRIVATE-OFFLINE-UNIT-\(slot)", protocolVersion: "2.0", firmware: "offline.1")
            return LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: session,
                target: .receiver(index: UInt8(slot), identity: identity), pairingGeneration: UUID()),
                product: "Offline target \(slot)", kind: .mouse,
                capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true,
                    operations: [.batteryRead: OperationCapability(evidence: .discovered)]), controlEndpointRegistryEntryID: 101)
        }
    }
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async -> LogicalDeviceTelemetryResult {
        readTargets.append(target.id)
        let update = updates.removeFirst()
        if let afterRead { await afterRead() }
        return LogicalDeviceTelemetryResult(session: wrongResultSession ? LogicalDeviceSessionID(address: session.address) : session, update: update)
    }
    func readSettings(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) throws -> DeviceSettings {
        settingReads += 1
        throw TelemetryFailure(category: .unsupported, message: "Telemetry must not read settings")
    }
    func applySettings(request: SettingChangeRequest, before: DeviceSettingsSnapshot, target: LogicalDeviceDescriptor) throws -> SettingAdapterTransaction {
        settingWrites += 1
        throw TelemetryFailure(category: .unsupported, message: "Telemetry must not request settings writes")
    }
    func stop() async {
        stopCount += 1
        let waiters = stopWaiters; stopWaiters = []; waiters.forEach { $0.resume() }
        if holdStop { await withCheckedContinuation { stopGate = $0 } }
    }
    func setAfterRead(_ action: @escaping @Sendable () async -> Void) { afterRead = action }
    func returnWrongSession() { wrongResultSession = true }
    func suspendStop() { holdStop = true }
    func waitForStop() async {
        if stopCount > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
    func releaseStop() { holdStop = false; let gate = stopGate; stopGate = nil; gate?.resume() }
}

private actor TelemetrySleepRecorder {
    var intervals: [Double] = []
    func record(_ interval: Double) { intervals.append(interval) }
}
private final class TelemetryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
}

private final class TelemetryFixtureAuthorizer: @unchecked Sendable {
    private let lock = NSLock()
    private var authorize: (@Sendable (HIDPPRequest) throws -> Void)?
    func install(_ authorize: @escaping @Sendable (HIDPPRequest) throws -> Void) { lock.withLock { self.authorize = authorize } }
    func check(_ request: HIDPPRequest) throws { try lock.withLock { try authorize?(request) } }
}

/// Exercises the production driver/client and exact read policy, with value packets
/// instead of native I/O. Only 1001 exists, matching voltage-only device semantics.
private actor TelemetryProtocolFixture: LogitechSessionTransport, HIDPPTransaction {
    nonisolated let authorizer = TelemetryFixtureAuthorizer()
    private let ids: [UInt16] = [0, 1, 3, 5, 0x1001]
    private let events = AsyncStream<HIDPPMessage>.makeStream()
    var requests: [HIDPPRequest] = [], trace: [HIDPPControlTrace] = []
    var closed = false, batteryReads = 0
    func notifications() -> AsyncStream<HIDPPMessage> { events.stream }
    func acquireTransaction() -> any HIDPPTransaction { self }
    func finish() {}
    func close() { closed = true; events.continuation.finish() }
    func controlTraceSnapshot() -> HIDPPControlTraceSnapshot { HIDPPControlTraceSnapshot(entries: trace, capacity: 128, droppedCount: 0) }
    func exchange(_ request: HIDPPRequest) throws -> HIDPPMessage {
        try authorizer.check(request); requests.append(request)
        func be(_ number: UInt16) -> [UInt8] { [UInt8(number >> 8), UInt8(number & 255)] }
        let index = request.message.deviceIndex
        let name = Array("Offline mouse \(index)".utf8)
        let payload: [UInt8]
        switch request.command {
        case .receiverInformation: payload = [3, 0, 0, 0, 0, 0, 2]
        case .pairing(let slot, _): payload = [0x20 + slot - 1, 0, 0, 0xAA, 0xBB, 0, 0, 2]
        case .ping(let nonce): payload = [4, 2, nonce]
        case .lookupFeature(let id): payload = [ids.firstIndex(of: id).map(UInt8.init) ?? 0, 0, id == 0x1001 ? 2 : 0]
        case .featureCount: payload = [UInt8(ids.count - 1)]
        case .featureAt(let offset): payload = be(ids[Int(offset)]) + [0, ids[Int(offset)] == 0x1001 ? 2 : 0]
        case .firmwareInfo: payload = [1, index, 2, 3, 4, 0, 4, 0xAA, 0xBB, 0, 0, 0, 0]
        case .firmwareEntity: payload = [0, 70, 87, 82, 1, 2, 0, 3, 0]
        case .nameLength: payload = [UInt8(name.count)]
        case .nameChunk(let offset): payload = Array(name.dropFirst(Int(offset)))
        case .deviceKind: payload = [3]
        case .battery1001:
            batteryReads += 1; payload = be(UInt16(3890 + batteryReads)) + [0]
        default: throw HIDPPError.invalidValue("No setter or unrelated query is implemented by the offline voltage fixture")
        }
        let received = Date()
        let response = try HIDPPMessage(bytes: [0x11] + Array(request.message.bytes[1..<4]) + payload + Array(repeating: 0, count: 16 - payload.count), receivedAt: received)
        trace.append(HIDPPControlTrace(startedAt: received, receivedAt: received, elapsedMilliseconds: 0,
            request: request, response: response, actualInputLength: response.bytes.count, error: nil))
        return response
    }
}

private struct TelemetryFixture {
    let backend: TelemetryFixtureBackend
    let driver: TelemetryFixtureDriver
    let discovery: HIDDiscovery
    let registry: DriverRegistry
    static func make(_ updates: [DeviceTelemetryUpdate]) -> Self {
        let backend = TelemetryFixtureBackend(), driver = TelemetryFixtureDriver(updates: updates)
        let registry = DriverRegistry(registrations: [DeviceDriverRegistration(id: "offline.telemetry", identify: { host in
            guard host.vendorID == 0x046D else { return nil }
            return IdentifiedDevice(descriptor: host, kind: .other, capabilities: .identificationOnly,
                controlEndpointRegistryEntryID: 101, isReceiver: true)
        }, logicalDriver: driver, settingsAdapter: driver)])
        return Self(backend: backend, driver: driver,
            discovery: HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil }), registry: registry)
    }
    func start() async throws -> (BatteryMonitor, DeviceStoreSnapshot, LogicalDeviceState) {
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, preferences: TelemetryMemoryPreferences(),
            registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start()
        let snapshot = await monitor.initialDiscoveryReady()
        #expect(snapshot.discoveryFailure == nil)
        return (monitor, snapshot, try #require(snapshot.logicalDevices.first { $0.id.rawValue == "usb-parent:10/receiver-slot:1" }))
    }
    static func update(_ value: BatteryValue?, at seconds: Double, failure: TelemetryFailure? = nil) -> DeviceTelemetryUpdate {
        let start = Date(timeIntervalSince1970: seconds), end = start.addingTimeInterval(0.25)
        return DeviceTelemetryUpdate(startedAt: start, finishedAt: end,
            battery: value.map { BatterySample(value: $0, rawBytes: [42], receivedAt: end, source: "offline typed telemetry") },
            batteryFailure: failure,
            charging: value.map { _ in ChargingSample(state: .unknown, rawValue: 42, receivedAt: end, source: "offline charging") },
            chargingFailure: failure)
    }
}

@Suite("CLI telemetry — offline values only", .timeLimit(.minutes(1)))
struct TelemetryProbeTests {
    private let prefix = ["telemetry", "--device", "usb-parent:10/receiver-slot:1"]

    @Test func telemetryRequiresExplicitTargetAndFiniteBoundedReadOnlyOptions() throws {
        #expect(throws: (any Error).self) { try ProbeOptions.parse(["telemetry"]) }
        #expect(throws: (any Error).self) { try ProbeOptions.parse(["telemetry", "--device", ""]) }
        let defaults = try #require(ProbeOptions.parse(prefix).expansion)
        #expect(defaults.action == .telemetry); #expect(defaults.samples == 10); #expect(defaults.interval == 2); #expect(!defaults.trace)
        #expect(try ExpansionProbeOptions.parse(prefix + ["--samples", "1000", "--interval", "3600", "--trace"]).trace)
        for count in ["0", "-1", "1001", "1.5", "nan", "1e300"] {
            #expect(throws: (any Error).self) { try ProbeOptions.parse(prefix + ["--samples", count]) }
        }
        for seconds in ["0", "-1", "0.099", "3601", "nan", "inf", "1e300"] {
            #expect(throws: (any Error).self) { try ProbeOptions.parse(prefix + ["--interval", seconds]) }
        }
        for flags in [["--dpi", "800"], ["--rate", "500"], ["--scope", "runtime"], ["--output", "/tmp/never"],
                      ["--restore-original"], ["--validation-operation", "logitechHIDPP2201DPI"], ["--samples", "1", "--samples", "2"]] {
            #expect(throws: (any Error).self) { try ProbeOptions.parse(prefix + flags) }
        }
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(["capabilities", "--samples", "1"]) }
    }

    @Test func everyAttemptUsesFreshTypedValuesAndKeepsOnlyHashedIdentity() async throws {
        let values: [BatteryValue] = [.percentage(0), .voltageOnly(millivolts: 3892), .approximateLevel(.low), .unknown, .notApplicable]
        let updates = values.enumerated().map { TelemetryFixture.update($0.element, at: Double(100 + $0.offset)) }
        let fixture = TelemetryFixture.make(updates)
        let (monitor, snapshot, target) = try await fixture.start()
        let sleeps = TelemetrySleepRecorder()
        let report = try await TelemetryProbe.capture(options: ExpansionProbeOptions.parse(prefix + ["--samples", "5", "--interval", "0.5"]),
            target: target, initialSnapshot: snapshot, monitor: monitor, driver: fixture.driver, sleep: { await sleeps.record($0) })
        #expect(report.succeeded); #expect(report.samples.map(\.sequence) == [1, 2, 3, 4, 5])
        #expect(report.samples.compactMap { $0.battery?.value } == values)
        #expect(report.samples.map(\.startedAt) == updates.map(\.startedAt))
        #expect(report.samples.map(\.finishedAt) == updates.map(\.finishedAt))
        #expect(await sleeps.intervals == [0.5, 0.5, 0.5, 0.5])
        #expect(await fixture.driver.readTargets == Array(repeating: target.id, count: 5))
        #expect(await fixture.driver.settingReads == 0); #expect(await fixture.driver.settingWrites == 0)
        #expect(report.controlTrace == nil); #expect(report.controlTraceScope == nil)
        let json = try #require(String(data: JSONEncoder().encode(report), encoding: .utf8))
        #expect(json.contains("unitIdentitySHA256")); #expect(!json.contains("PRIVATE-OFFLINE-UNIT"))
        #expect(!json.contains("hostSessionID")); #expect(!json.contains("pairingGeneration")); #expect(!json.contains("controlTrace"))
        await monitor.stop()
    }

    @Test func aFailedReadNeverBecomesANewSampleOfTheMonitorCache() async throws {
        let timeout = TelemetryFailure(category: .timeout, message: "offline timeout", operation: "battery")
        let updates = [TelemetryFixture.update(.percentage(19), at: 100), TelemetryFixture.update(.percentage(61), at: 200),
            TelemetryFixture.update(nil, at: 300, failure: timeout)]
        let fixture = TelemetryFixture.make(updates)
        let (monitor, snapshot, target) = try await fixture.start()
        await monitor.refresh(logicalDeviceID: target.id)
        #expect((await monitor.snapshot()).logicalDevices.first { $0.id == target.id }?.battery?.percent == 19)
        let report = try await TelemetryProbe.capture(options: ExpansionProbeOptions.parse(prefix + ["--samples", "2"]),
            target: target, initialSnapshot: snapshot, monitor: monitor, driver: fixture.driver, sleep: { _ in })
        #expect(!report.succeeded); #expect(report.samples[0].battery?.percent == 61)
        #expect(report.samples[1].battery == nil); #expect(report.samples[1].charging == nil)
        #expect(report.samples[1].batteryFailure == timeout); #expect(report.samples[1].chargingFailure == timeout)
        #expect(report.samples[1].startedAt == updates[2].startedAt)
        #expect(report.samples[1].finishedAt == updates[2].finishedAt)
        await monitor.stop()
    }

    @Test func replacementBetweenAttemptsStopsBeforeReadingTheReusedSelector() async throws {
        let fixture = TelemetryFixture.make([TelemetryFixture.update(.percentage(20), at: 100)])
        let (monitor, snapshot, target) = try await fixture.start()
        let report = try await TelemetryProbe.capture(options: ExpansionProbeOptions.parse(prefix + ["--samples", "3"]),
            target: target, initialSnapshot: snapshot, monitor: monitor, driver: fixture.driver,
            sleep: { _ in await monitor.refreshLogicalDiscovery(deviceID: target.sessionID.address.hostSessionID.physicalDeviceID) })
        #expect(report.samples.count == 1); #expect(report.termination?.category == .removed); #expect(!report.succeeded)
        #expect(await fixture.driver.readTargets.count == 1)
        #expect((await monitor.snapshot()).logicalDevices.first { $0.id == target.id }?.sessionID != target.sessionID)
        await monitor.stop()
    }

    @Test func replacementDuringAReadDiscardsItsValuesAndPreservesTheAttemptTimes() async throws {
        let update = TelemetryFixture.update(.percentage(90), at: 100)
        let fixture = TelemetryFixture.make([update])
        let (monitor, snapshot, target) = try await fixture.start()
        await fixture.driver.setAfterRead { await monitor.refreshLogicalDiscovery(deviceID: target.sessionID.address.hostSessionID.physicalDeviceID) }
        let report = try await TelemetryProbe.capture(options: ExpansionProbeOptions.parse(prefix + ["--samples", "3"]),
            target: target, initialSnapshot: snapshot, monitor: monitor, driver: fixture.driver, sleep: { _ in })
        #expect(report.samples.count == 1); #expect(report.samples[0].battery == nil); #expect(report.samples[0].charging == nil)
        #expect(report.samples[0].startedAt == update.startedAt); #expect(report.samples[0].finishedAt == update.finishedAt)
        #expect(report.samples[0].batteryFailure?.category == .removed); #expect(report.termination?.category == .removed)
        #expect(await fixture.driver.readTargets.count == 1)
        await monitor.stop()
    }

    @Test func aResultForAnotherLogicalGenerationIsRejected() async throws {
        let fixture = TelemetryFixture.make([TelemetryFixture.update(.percentage(90), at: 100)])
        let (monitor, snapshot, target) = try await fixture.start()
        await fixture.driver.returnWrongSession()
        let report = try await TelemetryProbe.capture(options: ExpansionProbeOptions.parse(prefix + ["--samples", "2"]),
            target: target, initialSnapshot: snapshot, monitor: monitor, driver: fixture.driver, sleep: { _ in })
        #expect(!report.succeeded); #expect(report.samples.count == 1); #expect(report.samples[0].battery == nil)
        #expect(report.termination?.category == .removed)
        await monitor.stop()
    }

    @Test func traceIsOneFinalBoundedSnapshotWithExplicitTruncation() async throws {
        let fixture = TelemetryFixture.make([TelemetryFixture.update(.percentage(10), at: 100), TelemetryFixture.update(.percentage(11), at: 200)])
        let (monitor, snapshot, target) = try await fixture.start()
        let captures = TelemetrySleepRecorder()
        let report = try await TelemetryProbe.capture(options: ExpansionProbeOptions.parse(prefix + ["--samples", "2", "--trace"]),
            target: target, initialSnapshot: snapshot, monitor: monitor, driver: fixture.driver,
            trace: { await captures.record(1); return HIDPPControlTraceSnapshot(entries: [], capacity: 128, droppedCount: 9) }, sleep: { _ in })
        #expect(report.succeeded); #expect(await captures.intervals == [1])
        #expect(report.controlTrace?.capacity == 128); #expect(report.controlTrace?.truncated == true)
        #expect(report.controlTrace?.droppedCount == 9); #expect(report.target.controlTrace == nil)
        #expect(report.controlTraceScope?.contains("initial discovery") == true)
        let json = try #require(String(data: JSONEncoder().encode(report), encoding: .utf8))
        #expect(json.contains("\"truncated\":true")); #expect(!json.contains("PRIVATE-OFFLINE-UNIT"))
        await monitor.stop()
    }

    @Test func actualCLIPathReadsOnlyItsTargetAndWaitsForStopDrain() async throws {
        let fixture = TelemetryFixture.make([TelemetryFixture.update(.percentage(30), at: 100)])
        await fixture.driver.suspendStop()
        let completed = TelemetryCompletion()
        let options = try ExpansionProbeOptions.parse(prefix + ["--samples", "1", "--json"])
        let work = Task {
            let succeeded = try await ExpansionProbe.run(options, discovery: fixture.discovery, registry: fixture.registry)
            completed.finish(); return succeeded
        }
        await fixture.driver.waitForStop()
        #expect(!completed.isFinished); #expect(fixture.backend.stopCount == 0)
        #expect(await fixture.driver.readTargets == [LogicalDeviceID(rawValue: "usb-parent:10/receiver-slot:1")])
        #expect(await fixture.driver.settingReads == 0); #expect(await fixture.driver.settingWrites == 0)
        await fixture.driver.releaseStop()
        #expect(try await work.value); #expect(completed.isFinished); #expect(fixture.backend.stopCount == 1)
        #expect(await fixture.driver.stopCount == 1)
    }

    @Test func productionLogitechDriverReadsOnlyTheSelectedBatteryAndNeverInventsPercent() async throws {
        let backend = TelemetryFixtureBackend(), transport = TelemetryProtocolFixture()
        let driver = LogitechReceiverDriver(sessionFactory: { _, authorize in
            transport.authorizer.install(authorize); return transport
        })
        let registry = DriverRegistry(registrations: DriverRegistry.standardRegistrations(logitech: driver))
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        let monitor = BatteryMonitor(discovery: discovery, reader: registry, preferences: TelemetryMemoryPreferences(),
            registry: registry, automaticallyRefreshTelemetry: false)
        await monitor.start()
        let snapshot = await monitor.initialDiscoveryReady()
        #expect(snapshot.discoveryFailure == nil)
        let target = try #require(snapshot.logicalDevices.first { $0.id.rawValue == "usb-parent:10/receiver-slot:1" })
        let report = try await TelemetryProbe.capture(options: ExpansionProbeOptions.parse(prefix + ["--samples", "2", "--trace"]),
            target: target, initialSnapshot: snapshot, monitor: monitor, driver: driver,
            trace: { try await driver.controlTraceSnapshot(target: target.descriptor, session: target.sessionID) }, sleep: { _ in })
        #expect(report.succeeded)
        #expect(report.samples.compactMap { $0.battery?.millivolts } == [3891, 3892])
        #expect(report.samples.allSatisfy { $0.battery?.percent == nil && $0.charging?.state == .discharging })
        let requests = await transport.requests
        #expect(requests.filter { $0.command == .battery1001 }.map { $0.message.deviceIndex } == [1, 1])
        #expect(requests.allSatisfy { !$0.command.isWrite })
        #expect(report.controlTrace?.entries.contains { $0.command == "battery1001.voltage" } == true)
        let json = try #require(String(data: JSONEncoder().encode(report), encoding: .utf8))
        #expect(!json.contains("01020304")); #expect(!json.contains("unitID"))
        await monitor.stop()
        #expect(await transport.closed); #expect(backend.stopCount == 1)
    }

    @Test func unknownTargetStopsDiscoveryWithoutAnyTelemetryRead() async throws {
        let fixture = TelemetryFixture.make([])
        var rejected = false
        do {
            try await ExpansionProbe.run(ExpansionProbeOptions.parse(["telemetry", "--device", "usb-parent:10/receiver-slot:9"]),
                discovery: fixture.discovery, registry: fixture.registry)
        } catch { rejected = true }
        #expect(rejected); #expect(await fixture.driver.readTargets.isEmpty)
        #expect(await fixture.driver.settingWrites == 0); #expect(await fixture.driver.stopCount == 1)
        #expect(fixture.backend.stopCount == 1)
    }
}
