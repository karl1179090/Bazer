// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
@testable import BazerHID
import Foundation
import LogitechHIDPP
import Testing

private final class ClosedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: HIDPPRequest?
    func record(_ value: HIDPPRequest) { lock.withLock { request = value } }
    func matching(_ message: HIDPPMessage) -> HIDPPRequest? { lock.withLock { request?.message.bytes == message.bytes ? request : nil } }
}
/// Value-only backend driving the real matcher/removal callback; no process lock or native I/O.
private actor ClosedRecoveryBackend: HIDInputOutputBackend {
    let recorder: ClosedRequestRecorder
    var input: (@Sendable (UInt8, [UInt8]) -> Void)?
    var removal: (@Sendable () -> Void)?
    var requests: [HIDPPRequest] = []
    var closes = 0
    let features: [UInt16] = [0, 1, 3, 5, 0x1004, 0x2201]
    private var dpi: UInt16 = 400
    private var removeOnWrite = false
    init(recorder: ClosedRequestRecorder) { self.recorder = recorder }
    func open(endpoint: HIDInputOutputEndpoint, onReport: @escaping @Sendable (UInt8, [UInt8]) -> Void,
              onRemoval: @escaping @Sendable () -> Void) { input = onReport; removal = onRemoval }
    func remove() { removal?() }
    func removeDuringNextWrite() { removeOnWrite = true }
    func close() { closes += 1 }
    func send(_ message: HIDPPMessage) throws {
        guard let request = recorder.matching(message) else { throw HIDPPError.malformed("unrecorded fake command") }
        requests.append(request)
        let payload: [UInt8]
        switch request.command {
        case .receiverInformation: payload = [3, 1, 2, 3, 4, 0, 1]
        case .pairing(let slot, _):
            if slot == 1 { payload = [request.message.parameters[0], 0, 0, 0xAA, 0xBB, 0, 0, 2] }
            else { input?(0x10, [0x10, 255, 0x8F, 0x83, 0xB5, 8, 0]); return }
        case .ping(let nonce): payload = [4, 5, nonce]
        case .lookupFeature(let id): payload = [features.firstIndex(of: id).map(UInt8.init) ?? 0, 0, 0]
        case .featureCount: payload = [UInt8(features.count - 1)]
        case .featureAt(let index): payload = [UInt8(features[Int(index)] >> 8), UInt8(features[Int(index)] & 255), 0, 0]
        case .firmwareInfo: payload = [1, 1, 2, 3, 4, 0, 4, 0xAA, 0xBB, 0, 0, 0, 0]
        case .firmwareEntity: payload = [0, 70, 87, 82, 1, 2, 0, 3, 0]
        case .nameLength: payload = [7]
        case .nameChunk(let offset): payload = Array("Offline".utf8.dropFirst(Int(offset)))
        case .deviceKind: payload = [3]
        case .battery1004Capabilities: payload = [15, 3]
        case .battery1004: payload = [50, 4, 0, 0]
        case .sensorCount: payload = [1]
        case .dpiList: payload = [0, 1, 0x90, 3, 0x20, 6, 0x40, 0, 0]
        case .dpi: payload = [0, UInt8(dpi >> 8), UInt8(dpi & 255), 3, 0x20]
        case .setDPI(_, let value, _, _, _):
            dpi = value
            if removeOnWrite { removeOnWrite = false; removal?(); return }
            payload = []
        default: throw HIDPPError.invalidValue("Unexpected fake recovery command")
        }
        input?(0x11, [0x11] + message.bytes[1..<4] + payload + [UInt8](repeating: 0, count: 16 - payload.count))
    }
}
private final class ClosedRecoveryFactory: @unchecked Sendable {
    struct Instance: Sendable { let session: HIDInputOutputSession; let backend: ClosedRecoveryBackend }
    private let lock = NSLock()
    private var created: [Instance] = []
    func instances() -> [Instance] { lock.withLock { created } }
    func make(_ endpoint: HIDInputOutputEndpoint, authorize: @escaping @Sendable (HIDPPRequest) throws -> Void) -> any LogitechSessionTransport {
        let recorder = ClosedRequestRecorder(), backend = ClosedRecoveryBackend(recorder: recorder)
        let session = HIDInputOutputSession(endpoint: endpoint, backendFactory: { backend }, lockFactory: { nil },
            requestTimeout: .milliseconds(100), authorize: { request in try authorize(request); recorder.record(request) })
        lock.withLock { created.append(Instance(session: session, backend: backend)) }
        return session
    }
}
@Suite("Logitech closed transport recovery — offline", .timeLimit(.minutes(1)))
struct LogitechClosedRecoveryTests {
    @Test(arguments: [false, true]) func nativeRemovalClosesOldGenerationAndRediscoversWithReadCommandsOnly(readBeforeDiscovery: Bool) async throws {
        let descriptor: [UInt8] = [0x06,0,0xFF,9,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0]
        let endpoint = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 1001, vendorID: 0x046D,
            productID: 0xDEAD, product: "Offline receiver", transport: "USB", maxInputReportSize: 20, maxOutputReportSize: 20,
            reportDescriptor: descriptor)
        let host = try #require(PhysicalDeviceGrouper.group([endpoint]).first), factory = ClosedRecoveryFactory()
        let driver = LogitechReceiverDriver(sessionFactory: { endpoint, authorize in factory.make(endpoint, authorize: authorize) })
        let hostSession = DeviceSessionID(physicalDeviceID: host.id)
        let old = try #require(try await driver.discoverTargets(host: host, session: hostSession).first)
        let original = try #require(factory.instances().first)
        await original.backend.remove()
        for _ in 0..<100 { await Task.yield() }
        if readBeforeDiscovery {
            let failed = await driver.readTelemetry(target: old, session: LogicalDeviceSessionID(address: old.address))
            #expect(failed.update.battery == nil); #expect(failed.update.batteryFailure?.category == .removed)
        }
        let fresh = try #require(try await driver.discoverTargets(host: host, session: hostSession).first)
        #expect(factory.instances().count == 2); #expect(await original.backend.closes == 1)
        #expect(fresh.address != old.address)
        let result = await driver.readTelemetry(target: fresh, session: LogicalDeviceSessionID(address: fresh.address))
        #expect(result.update.battery?.percent == 50)
        let stale = await driver.readTelemetry(target: old, session: LogicalDeviceSessionID(address: old.address))
        #expect(stale.update.batteryFailure?.category == .removed)
        for instance in factory.instances() { #expect(await instance.backend.requests.allSatisfy { !$0.command.isWrite }) }
        await driver.stop()
    }
    @Test func removalDuringExplicitWriteNeverReplaysThatWriteOrItsIntent() async throws {
        let descriptor: [UInt8] = [0x06,0,0xFF,9,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0]
        let endpoint = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 1001, vendorID: 0x046D,
            productID: 0xDEAD, product: "Offline receiver", transport: "USB", maxInputReportSize: 20, maxOutputReportSize: 20,
            reportDescriptor: descriptor)
        let host = try #require(PhysicalDeviceGrouper.group([endpoint]).first), factory = ClosedRecoveryFactory()
        let driver = LogitechReceiverDriver(sessionFactory: { endpoint, authorize in factory.make(endpoint, authorize: authorize) })
        let hostSession = DeviceSessionID(physicalDeviceID: host.id)
        let old = try #require(try await driver.discoverTargets(host: host, session: hostSession).first)
        let session = LogicalDeviceSessionID(address: old.address)
        let before = DeviceSettingsSnapshot(session: session, revision: 1, capturedAt: Date(), settings: try await driver.readSettings(target: old, session: session))
        let request = SettingChangeRequest(target: session, expectedRevision: 1, change: DeviceSettingsChange(currentDPI: DPISetting(800)))
        _ = try await driver.authorizeValidation(request: request, before: before, target: old, operation: .logitechHIDPP2201DPI)
        let original = try #require(factory.instances().first)
        await original.backend.removeDuringNextWrite()
        let result = try await driver.applySettings(request: request, before: before, target: old)
        #expect(!result.acknowledged); #expect(result.failure != nil)
        let fresh = try #require(try await driver.discoverTargets(host: host, session: hostSession).first)
        #expect(factory.instances().count == 2); #expect(fresh.address != old.address)
        #expect(await original.backend.requests.filter { $0.command.isWrite }.count == 1)
        let replacement = try #require(factory.instances().last)
        #expect(await replacement.backend.requests.allSatisfy { !$0.command.isWrite })
        do { _ = try await driver.applySettings(request: request, before: before, target: old); Issue.record("Old explicit write survived removal") } catch {}
        let freshSession = LogicalDeviceSessionID(address: fresh.address)
        let rebound = SettingChangeRequest(id: request.id, target: freshSession, expectedRevision: 1, change: request.change)
        let freshBefore = DeviceSettingsSnapshot(session: freshSession, revision: 1, capturedAt: Date(), settings: try await driver.readSettings(target: fresh, session: freshSession))
        do { _ = try await driver.applySettings(request: rebound, before: freshBefore, target: fresh); Issue.record("Old write intent transferred") } catch {}
        #expect(await replacement.backend.requests.allSatisfy { !$0.command.isWrite })
        await driver.stop()
    }
}
