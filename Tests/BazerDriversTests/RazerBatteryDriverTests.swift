import BazerCore
@testable import BazerDrivers
@testable import BazerHID
import Foundation
import RazerProtocol
import Testing

private actor ReplayTransport: HIDFeatureGroupTransport {
    var count = 0
    let batteryStatus: UInt8
    let chargingStatus: UInt8
    let chargingRaw: UInt8
    let rawByPhysicalID: [String: UInt8]
    init(batteryStatus: UInt8 = 2, chargingStatus: UInt8 = 2, chargingRaw: UInt8 = 0, rawByPhysicalID: [String: UInt8] = [:]) {
        self.batteryStatus = batteryStatus; self.chargingStatus = chargingStatus; self.chargingRaw = chargingRaw; self.rawByPhysicalID = rawByPhysicalID
    }
    func queryGroup(_ group: HIDFeatureQueryGroup, validate: @escaping @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation) async throws -> HIDFeatureGroupResult {
        count += 1
        let received = Date(timeIntervalSince1970: 10_000)
        let commands = group.requests.map { request in
            var response = request.bytes
            let isBattery = request.commandID == 0x80
            response[0] = isBattery ? batteryStatus : chargingStatus
            response[9] = isBattery ? (rawByPhysicalID[group.physicalDeviceID.rawValue] ?? 128) : chargingRaw
            response[88] = response[2...87].reduce(0, ^)
            let validation = validate(request, response)
            let failure = validation.valid ? nil : TelemetryFailure(category: validation.failureCategory ?? .malformedResponse, message: validation.error ?? "synthetic failure", protocolStatus: validation.protocolStatus)
            return HIDFeatureCommandResult(commandID: request.commandID!, response: validation.valid ? response : nil, receivedAt: validation.valid ? received : nil, attempts: [], failure: failure)
        }
        return HIDFeatureGroupResult(physicalDeviceID: group.physicalDeviceID, registryEntryID: group.registryEntryID, startedAt: received, finishedAt: received, elapsedMilliseconds: 1, budgetMilliseconds: 2000, budgetExceeded: false, cancellationRequested: false, synchronousCallCannotBeInterrupted: true, operations: [], commands: commands)
    }
}

struct RazerBatteryDriverTests {
    private func device(parent: UInt64 = 10, vendor: UInt16 = 0x1532, product: UInt16 = 0xC5) -> PhysicalDeviceDescriptor {
        let interface = HIDInterfaceDescriptor(registryEntryID: parent + 1, usbParentRegistryEntryID: parent, vendorID: vendor, productID: product, product: "Synthetic driver fixture", transport: "USB", primaryUsage: .mouse, usages: [.mouse], maxFeatureReportSize: 90, reportDescriptor: [5, 1, 9, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0])
        return PhysicalDeviceGrouper.group([interface])[0]
    }

    @Test func batterySuccessAndChargingFailureAreIndependentAndKeepReceivedTime() async {
        let transport = ReplayTransport(chargingStatus: 4)
        let result = await RazerBatteryDriver(transport: transport).read(device: device())
        #expect(result.battery?.rawValue == 128)
        #expect(result.battery?.percent == 50)
        #expect(result.battery?.receivedAt == Date(timeIntervalSince1970: 10_000))
        #expect(result.batteryFailure == nil)
        #expect(result.charging == nil)
        #expect(result.chargingFailure?.category == .deviceStatus)
        #expect(result.chargingFailure?.protocolStatus == 4)
        #expect(result.chargingFailure?.message.contains("0x04") == true)
    }

    @Test func twoPhysicalMiceDoNotShareSamplesAndRawZeroIsPreserved() async {
        let transport = ReplayTransport(rawByPhysicalID: ["usb-parent:10": 0, "usb-parent:20": 255])
        let driver = RazerBatteryDriver(transport: transport)
        let first = await driver.read(device: device(parent: 10))
        let second = await driver.read(device: device(parent: 20))
        #expect(first.battery?.percent == 0)
        #expect(second.battery?.percent == 100)
        #expect(first.physicalDeviceID != second.physicalDeviceID)
        #expect(first.endpointRegistryEntryID != second.endpointRegistryEntryID)
        #expect(await transport.count == 2)
    }

    @Test func unknownChargingDoesNotBecomeNotChargingAndNoDefaultBatteryOnFailure() async {
        let unknown = await RazerBatteryDriver(transport: ReplayTransport(chargingRaw: 2)).read(device: device())
        #expect(unknown.charging?.state == .unknown)
        #expect(unknown.charging?.rawValue == 2)
        let failed = await RazerBatteryDriver(transport: ReplayTransport(batteryStatus: 4, chargingStatus: 4)).read(device: device())
        #expect(failed.battery == nil)
        #expect(failed.charging == nil)
        #expect(failed.batteryFailure?.category == .deviceStatus)
    }

    @Test func keyboardAndUnverifiedModelNeverReachTransport() async {
        let transport = ReplayTransport()
        let driver = RazerBatteryDriver(transport: transport)
        for target in [device(vendor: 0x342D, product: 0xE51A), device(product: 0xC4), device(product: 0xCB)] {
            let result = await driver.read(device: target)
            #expect(result.battery == nil && result.charging == nil)
            #expect(result.batteryFailure?.category == .unsupported)
        }
        #expect(await transport.count == 0)
    }

    @Test func realCapturedFramesReplayStrictlyAndStatusFourZeroIsNeverZeroPercent() throws {
        struct Fixture: Decodable {
            struct Frame: Decodable { let command: UInt8; let rxHex: String; let expectedStatus: UInt8; let rawByte9: UInt8 }
            let synthetic: Bool
            let frames: [Frame]
        }
        let url = try #require(Bundle.module.url(forResource: "real-razer-responses-2026-11-04", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(!fixture.synthetic)
        #expect(fixture.frames.contains { $0.command == 0x84 && $0.rawByte9 == 1 && $0.expectedStatus == 2 })
        for frame in fixture.frames {
            let chars = Array(frame.rxHex)
            let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
            let command = try #require(RazerCommand(rawValue: frame.command))
            let request = HIDReadOnlyFeatureRequest(reportID: 0, bytes: RazerRequest(command: command).bytes)
            let validation = RazerBatteryDriver.validate(request, bytes)
            #expect(validation.checks.filter { $0.name != "status" }.allSatisfy { $0.passed })
            if frame.expectedStatus == 2 {
                #expect(validation.valid)
                #expect(try RazerResponse.parse(bytes, for: RazerRequest(command: command)).rawValue == frame.rawByte9)
            } else {
                #expect(!validation.valid)
                #expect(validation.failureCategory == .deviceStatus)
                #expect(validation.protocolStatus == 4)
                #expect(frame.rawByte9 == 0)
                #expect(throws: RazerProtocolError.deviceStatus(4)) { try RazerResponse.parse(bytes, for: RazerRequest(command: command)) }
            }
        }
    }
}
