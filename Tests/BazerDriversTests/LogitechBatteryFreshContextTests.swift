// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import Foundation
import LogitechHIDPP
import Testing

private final class FreshEstimateAuthorizer: @unchecked Sendable {
    private let lock = NSLock()
    private var authorize: (@Sendable (HIDPPRequest) throws -> Void)?
    func install(_ value: @escaping @Sendable (HIDPPRequest) throws -> Void) { lock.withLock { authorize = value } }
    func check(_ request: HIDPPRequest) throws { try lock.withLock { try authorize?(request) } }
}

/// Real adapter/client/policy, with packets only. No native backend is constructed.
private actor FreshEstimateReceiver: LogitechSessionTransport, HIDPPTransaction {
    nonisolated let authorizer = FreshEstimateAuthorizer()
    private let stream = AsyncStream<HIDPPMessage>.makeStream()
    private let ids: [UInt16] = [0,1,3,5,0x1001]
    private let firmware = ["01424F547402002600AADF85EE714A00", "004D504D1502002601407985EE714A00", "05000000000000A90000000000000000"].map(freshEstimateHex)
    private var kind: UInt8? = 3
    private var batteryVersion: UInt8 = 2, batteryFlags: UInt8 = 0
    private var requests: [HIDPPCommand] = []
    func notifications() -> AsyncStream<HIDPPMessage> { stream.stream }
    func acquireTransaction() -> any HIDPPTransaction { self }
    func finish() {}
    func close() { stream.continuation.finish() }
    func setKind(_ value: UInt8?) { kind = value }
    func setBatterySchema(version: UInt8, flags: UInt8 = 0) { batteryVersion = version; batteryFlags = flags }
    func takeRequests() -> [HIDPPCommand] { let copy = requests; requests = []; return copy }
    func exchange(_ request: HIDPPRequest) throws -> HIDPPMessage {
        try authorizer.check(request)
        guard !request.command.isWrite else { throw HIDPPError.invalidValue("Offline battery fixture forbids every write") }
        requests.append(request.command)
        let payload: [UInt8]
        switch request.command {
        case .receiverInformation: payload = [3,1,2,3,4,0,1]
        case .pairing: payload = [0x20,0,0,0x40,0x79,0,0,2]
        case .ping(let nonce): payload = [4,2,nonce]
        case .lookupFeature(let id):
            payload = [id == 5 && kind == nil ? 0 : (ids.firstIndex(of: id).map(UInt8.init) ?? 0), id == 0x1001 ? batteryFlags : 0, id == 0x1001 ? batteryVersion : 0]
        case .featureCount: payload = [UInt8(ids.count - 1)]
        case .featureAt(let index):
            let id = ids[Int(index)]; payload = [UInt8(id >> 8), UInt8(id & 255), id == 0x1001 ? batteryFlags : 0, id == 0x1001 ? batteryVersion : 0]
        case .firmwareInfo: payload = [3,1,2,3,4,0,4,0x40,0x79,0,0,0,0]
        case .firmwareEntity(let index): payload = firmware[Int(index)]
        case .nameLength: payload = [4]
        case .nameChunk(let offset): payload = Array("GPW1".utf8.dropFirst(Int(offset)))
        case .deviceKind: payload = [kind ?? 255]
        case .battery1001: payload = [15,5,0] // 3845mV, definitely discharging.
        default: throw HIDPPError.invalidValue("Unrelated operation in offline battery fixture: \(request.command)")
        }
        return try HIDPPMessage(bytes: [0x11] + request.message.bytes[1..<4] + payload + [UInt8](repeating: 0, count: 16 - payload.count), receivedAt: Date())
    }
}

private func freshEstimateHex(_ text: String) -> [UInt8] {
    stride(from: 0, to: text.count, by: 2).map { offset in
        let start = text.index(text.startIndex, offsetBy: offset)
        return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
    }
}

@Suite("Fresh GPW1 estimate context — real adapter, fake packets only")
struct LogitechBatteryFreshContextTests {
    private func setup() async throws -> (LogitechReceiverDriver, FreshEstimateReceiver, LogicalDeviceDescriptor, LogicalDeviceSessionID) {
        // Non-unique descriptor and firmware from the reviewed GPW1 configuration.
        // Unique unit is synthetic; no registry IDs or native I/O are consulted.
        let descriptor = freshEstimateHex("0600ff0901a101851075089506150026ff000901810009019100c00600ff0902a101851175089513150026ff000902810009029100c00600ff0904a10185207508950e150026ff0009418100094191008521951f150026ff000942810009429100c0")
        let host = PhysicalDeviceGrouper.group([HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10,
            vendorID: 0x046D, productID: 0xC539, product: "Offline GPW1 context fixture", transport: "USB",
            maxInputReportSize: 64, maxOutputReportSize: 64, reportDescriptor: descriptor)])[0]
        let fake = FreshEstimateReceiver()
        let driver = LogitechReceiverDriver(sessionFactory: { _, authorize in fake.authorizer.install(authorize); return fake })
        let hostSession = DeviceSessionID(physicalDeviceID: host.id)
        let target = try #require(try await driver.discoverTargets(host: host, session: hostSession).first)
        _ = await fake.takeRequests()
        return (driver, fake, target, LogicalDeviceSessionID(address: target.address))
    }

    @Test func freshKindMustBeMouseEvenWhenDiscoveryCachedMouseAndOtherIdentityStaysEqual() async throws {
        let (driver, fake, target, session) = try await setup()
        let initial = await driver.readTelemetry(target: target, session: session)
        #expect(initial.update.battery?.percentageEstimate?.value == 55)
        let initialRequests = await fake.takeRequests()
        for kind: UInt8? in [0,2,1,4,255,nil,3,5] {
            await fake.setKind(kind)
            let result = await driver.readTelemetry(target: target, session: session)
            #expect(result.update.batteryFailure == nil); #expect(result.update.battery?.value == .voltageOnly(millivolts: 3845))
            #expect(result.update.battery?.rawBytes.prefix(3) == [15,5,0])
            #expect(result.update.battery?.percent == nil)
            #expect(result.update.battery?.percentageEstimate?.value == (kind == 3 || kind == 5 ? 55 : nil))
            let requests = await fake.takeRequests()
            #expect(!requests.contains(where: { $0.isWrite }))
            if kind != nil { #expect(requests == initialRequests, "Fresh metadata must use existing reads, without additional HID requests") }
        }
        await driver.stop()
    }

    @Test func freshFeatureVersionAndFlagsMustMatchInsteadOfDiscoverySnapshot() async throws {
        let (driver, fake, target, session) = try await setup()
        #expect(await driver.readTelemetry(target: target, session: session).update.battery?.percentageEstimate?.value == 55)
        let initialRequests = await fake.takeRequests()
        for (version, flags): (UInt8, UInt8) in [(1,0),(2,1),(3,0),(2,0)] {
            await fake.setBatterySchema(version: version, flags: flags)
            let result = await driver.readTelemetry(target: target, session: session)
            #expect(result.update.batteryFailure == nil); #expect(result.update.battery?.value == .voltageOnly(millivolts: 3845))
            #expect(result.update.battery?.percentageEstimate?.value == (version == 2 && flags == 0 ? 55 : nil))
            #expect(await fake.takeRequests() == initialRequests, "Read-local featureDirectory must not issue a new HID request")
        }
        await driver.stop()
    }
}
