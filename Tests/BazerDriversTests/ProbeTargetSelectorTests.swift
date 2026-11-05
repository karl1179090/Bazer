// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import Testing

struct ProbeTargetSelectorTests {
    private func mouse(id: UInt64, parent: UInt64) -> HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(registryEntryID: id, usbParentRegistryEntryID: parent, vendorID: 0x1532, productID: 0x00C5, product: "Synthetic mouse", transport: "USB", primaryUsage: .mouse, usages: [.mouse], maxFeatureReportSize: 90, reportDescriptor: [0x05, 1, 0x09, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0])
    }

    @Test
    func twoIdenticalModelsRequireExplicitSessionSelector() throws {
        let groups = PhysicalDeviceGrouper.group([mouse(id: 1, parent: 100), mouse(id: 2, parent: 200)])
        #expect(groups.count == 2)
        #expect(throws: ProbeTargetSelectionError.ambiguousPhysicalDevices(["usb-parent:100", "usb-parent:200"])) {
            try ProbeTargetSelector.select(in: groups, vendorID: 0x1532, productID: 0x00C5)
        }
        let target = try ProbeTargetSelector.select(in: groups, vendorID: 0x1532, productID: 0x00C5, sessionSelector: "usb-parent:200")
        #expect(target.interface.registryEntryID == 2)
        #expect(target.device.id.rawValue == "usb-parent:200")
    }

    @Test
    func wrongProfileAndStaleSessionSelectorAreRejected() {
        let groups = PhysicalDeviceGrouper.group([mouse(id: 1, parent: 100)])
        #expect(throws: ProbeTargetSelectionError.unsupportedDevice) {
            try ProbeTargetSelector.select(in: groups, vendorID: 0x342D, productID: 0xE51A)
        }
        #expect(throws: ProbeTargetSelectionError.sessionSelectorNotFound("usb-parent:999")) {
            try ProbeTargetSelector.select(in: groups, vendorID: 0x1532, productID: 0x00C5, sessionSelector: "usb-parent:999")
        }
    }

    @Test
    func exactProfileDoesNotGuessBetweenTwoControlInterfaces() {
        let groups = PhysicalDeviceGrouper.group([mouse(id: 1, parent: 100), mouse(id: 2, parent: 100)])
        #expect(throws: ProbeTargetSelectionError.ambiguousControlInterfaces) {
            try ProbeTargetSelector.select(in: groups, vendorID: 0x1532, productID: 0x00C5)
        }
    }
}
