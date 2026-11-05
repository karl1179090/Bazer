import Testing
import Foundation
@testable import BazerCore

struct DescriptorTests {
    private struct Fixture: Decodable {
        struct ExpectedGroup: Decodable { let id: String; let interfaceIDs: [UInt64] }
        struct Expectation: Decodable {
            let registryEntryID: UInt64
            let sha256: String
            let usagePages: [UInt32]
            let explicitReportIDs: [UInt8]
            let featureItemCount: Int
        }
        let expectedGroups: [ExpectedGroup]
        let interfaces: [HIDInterfaceDescriptor]
        let expectations: [Expectation]
    }

    private func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "hid-interfaces", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test
    func testAllSixPassiveDescriptorsAndHashesMatchBaseline() throws {
        let fixture = try fixture()
        #expect((fixture.interfaces.count) == (6))
        for descriptor in fixture.interfaces {
            let expected = try #require(fixture.expectations.first { $0.registryEntryID == descriptor.registryEntryID })
            let summary = try HIDReportDescriptorParser.parse(descriptor.reportDescriptor)
            #expect((descriptor.descriptorSHA256) == (expected.sha256))
            #expect((summary.usagePages) == (expected.usagePages))
            #expect((summary.explicitReportIDs) == (expected.explicitReportIDs))
            #expect((summary.featureItemCount) == (expected.featureItemCount))
        }
    }

    @Test
    func testSixInterfacesFormExactlyTwoPhysicalDevices() throws {
        let fixture = try fixture()
        let groups = PhysicalDeviceGrouper.group(fixture.interfaces)
        #expect((groups.count) == (2))
        for expected in fixture.expectedGroups {
            let group = try #require(groups.first { $0.id.rawValue == expected.id })
            #expect((group.interfaces.map(\.registryEntryID)) == (expected.interfaceIDs))
        }
        let mouse = try #require(groups.first { $0.productID == 0x00C5 })
        #expect(mouse.allUsages.contains(.keyboard), "Auxiliary keyboard interfaces remain part of the mouse.")
        #expect(mouse.allUsages.contains(.mouse))
        let keyboard = try #require(groups.first { $0.productID == 0xE51A })
        #expect(keyboard.allUsages.contains(.mouse), "Composite mouse usages remain part of the keyboard.")
        #expect(keyboard.allUsages.contains(.keyboard))
    }

    @Test
    func testOnlyMouseControlDescriptorHasFeatureReport() throws {
        let fixture = try fixture()
        for descriptor in fixture.interfaces {
            let summary = try HIDReportDescriptorParser.parse(descriptor.reportDescriptor)
            #expect((summary.hasReport(kind: .feature, reportID: 0, byteCount: 90)) == (descriptor.registryEntryID == 103))
            if descriptor.productID == 0xE51A {
                #expect((summary.featureItemCount) == (0))
                #expect(!(summary.usagePages.contains(0x84)))
                #expect(!(summary.usagePages.contains(0x85)))
                #expect(!(summary.usages.contains(HIDUsage(page: 6, usage: 0x20))))
            }
        }
        let misleading = try #require(fixture.interfaces.first { $0.registryEntryID == 202 })
        #expect((misleading.maxFeatureReportSize) == (1))
        #expect((misleading.descriptorSummary?.featureItemCount) == (0))
    }

    @Test
    func testSameVIDPIDDoesNotMergeDifferentOrUnknownParents() {
        func interface(_ id: UInt64, _ parent: UInt64?) -> HIDInterfaceDescriptor {
            HIDInterfaceDescriptor(registryEntryID: id, usbParentRegistryEntryID: parent, vendorID: 0x1532, productID: 0xC5, product: "same", transport: "USB", locationID: 999)
        }
        let groups = PhysicalDeviceGrouper.group([interface(1, 10), interface(2, 10), interface(3, 20), interface(4, nil), interface(5, nil)])
        #expect((groups.count) == (4))
        #expect((groups.first { $0.id.rawValue == "usb-parent:10" }?.interfaces.count) == (2))
    }

    @Test
    func testExternalUSBRequiresTransportParentAndNoBuiltInFlag() {
        func interface(transport: String?, parent: UInt64?, builtIn: Bool) -> HIDInterfaceDescriptor {
            HIDInterfaceDescriptor(registryEntryID: 1, usbParentRegistryEntryID: parent, vendorID: 0x05AC, productID: 1, product: "Keyboard", transport: transport, isBuiltIn: builtIn)
        }
        #expect(interface(transport: "USB", parent: 10, builtIn: false).isExternalUSB)
        #expect(!(interface(transport: "USB", parent: 10, builtIn: true).isExternalUSB))
        #expect(!(interface(transport: "USB", parent: nil, builtIn: false).isExternalUSB))
        #expect(!(interface(transport: "Bluetooth", parent: 10, builtIn: false).isExternalUSB))
    }

    @Test
    func testDescriptorAndGroupsRoundTripCodable() throws {
        let original = PhysicalDeviceGrouper.group(try fixture().interfaces)
        #expect((try JSONDecoder().decode([PhysicalDeviceDescriptor].self, from: JSONEncoder().encode(original))) == (original))
    }

    @Test
    func testMalformedDescriptorsFailClosed() {
        let malformed: [[UInt8]] = [
            [0x75], [0x85, 0], [0x86, 0, 1], [0xB4], [0xA4], [0xC0],
            [0xA1, 1], [0xFE, 0, 0], [0x77, 0xFF, 0xFF, 0xFF, 0xFF, 0x95, 2, 0xB1, 0]
        ]
        for bytes in malformed { #expect(throws: (any Error).self, "\(bytes)") { try HIDReportDescriptorParser.parse(bytes) } }
    }

    @Test
    func testGlobalPushPopAndPaddedBitCounts() throws {
        let summary = try HIDReportDescriptorParser.parse([
            0x05, 1, 0x09, 2, 0xA1, 1, 0x75, 8, 0x95, 1,
            0xA4, 0x75, 16, 0x81, 2, 0xB4, 0x81, 2, 0xC0
        ])
        #expect((summary.applicationUsages) == ([.mouse]))
        #expect(summary.hasReport(kind: .input, reportID: 0, byteCount: 3))
        let padded = try HIDReportDescriptorParser.parse([0x75, 1, 0x95, 9, 0x81, 1])
        #expect((padded.reports.first?.bitCount) == (9))
        #expect((padded.reports.first?.byteCount) == (2))
    }

    @Test
    func testExtendedUsageEmbedsItsUsagePage() throws {
        let summary = try HIDReportDescriptorParser.parse([0x0B, 0x20, 0, 6, 0, 0xA1, 1, 0xC0])
        #expect((summary.applicationUsages) == ([HIDUsage(page: 6, usage: 0x20)]))
    }
}
