// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import Foundation
import Testing
@testable import HIDProbe

struct PassiveClassificationTests {
    /// Descriptor bytes from the 2026-11-04 passive C539 capture. Registry IDs,
    /// parent, location and product labels are replaced with offline fixture values.
    private func receiver(productID: UInt16 = 0xC539, vendorID: UInt16 = 0x046D, transport: String = "USB") -> PhysicalDeviceDescriptor {
        let layouts: [(String, HIDUsage, Int, Int)] = [
            ("05010906a101050719e029e71500250175019508810281039505050819012905910295017503910195067508150026a400050719002aa4008100c0", .keyboard, 8, 1),
            ("05010902a10185020901a10005091901291015002501951075018102050116018026ff7f751095020930093181061581257f7508950109388106050c0a380295018106c0c0050c0901a101850375109502150126ff0219012aff028100c005010980a10185047502950115012503098209810983816075068103c006bcff0988a1018508190129ff150126ff00750895018100c0", .mouse, 9, 1),
            ("0600ff0901a101851075089506150026ff000901810009019100c00600ff0902a101851175089513150026ff000902810009029100c00600ff0904a10185207508950e150026ff0009418100094191008521951f150026ff000942810009429100c0", HIDUsage(page: 0xFF00, usage: 1), 32, 32)
        ]
        let interfaces = layouts.enumerated().map { index, layout in
            HIDInterfaceDescriptor(registryEntryID: UInt64(101 + index), usbParentRegistryEntryID: 10,
                vendorID: vendorID, productID: productID, product: "Offline composite host", transport: transport,
                primaryUsage: layout.1, usages: [layout.1], maxInputReportSize: layout.2, maxOutputReportSize: layout.3,
                reportDescriptor: hex(layout.0))
        }
        return PhysicalDeviceDescriptor(id: PhysicalDeviceID(rawValue: "usb-parent:10"), interfaces: interfaces)
    }
    private func hex(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        return stride(from: 0, to: bytes.count, by: 2).map { UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)! }
    }

    @Test func compositeLogitechControlDescriptorTakesPrecedenceOverItsKeyboardCollection() throws {
        for productID: UInt16 in [0xC539, 0xFAFA] {
            let host = receiver(productID: productID)
            #expect(GenericKeyboardDriver.supports(host))
            #expect(LogitechReceiverDriver.identify(host)?.controlEndpointRegistryEntryID == 103)
            let report = ProbeDevice(host, evidence: [:])
            #expect(report.classification == "receiverCandidate")
            #expect(report.identificationReasons.contains("descriptorConfirmedControlEndpoint"))
            #expect(report.identificationReasons.contains("receiverOrDirectPeripheralPendingProtocolHandshake"))
            #expect(report.batterySupport == "unknown")
            #expect(report.product == "Offline composite host")
            let json = try #require(String(data: JSONEncoder().encode(report), encoding: .utf8))
            #expect(!json.contains("G Pro Wireless")); #expect(!json.contains("unitID"))
        }
    }

    @Test func rawBrandOrKeyboardUsageCannotInventAHIDPPControlEndpoint() {
        let host = receiver()
        let keyboardOnly = PhysicalDeviceDescriptor(id: host.id, interfaces: [host.interfaces[0]])
        #expect(LogitechReceiverDriver.identify(keyboardOnly) == nil)
        #expect(ProbeDevice(keyboardOnly, evidence: [:]).classification == "externalUSBKeyboard")
        let otherVendor = receiver(productID: 0xFAFA, vendorID: 0xFFFF)
        #expect(LogitechReceiverDriver.identify(otherVendor) == nil)
        #expect(ProbeDevice(otherVendor, evidence: [:]).classification == "externalUSBKeyboard")
        #expect(ProbeDevice(receiver(transport: "Bluetooth"), evidence: [:]).classification == "excluded")
        var interfaces = host.interfaces
        let endpoint = interfaces[2]
        interfaces.append(HIDInterfaceDescriptor(registryEntryID: 104, usbParentRegistryEntryID: 10,
            vendorID: endpoint.vendorID, productID: endpoint.productID, product: endpoint.product, transport: "USB",
            primaryUsage: endpoint.primaryUsage, reportDescriptor: endpoint.reportDescriptor))
        let ambiguous = PhysicalDeviceDescriptor(id: host.id, interfaces: interfaces)
        #expect(LogitechReceiverDriver.identify(ambiguous) == nil)
        #expect(ProbeDevice(ambiguous, evidence: [:]).classification != "receiverCandidate")
    }
}
