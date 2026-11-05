import Testing
import Foundation
import BazerCore
@testable import BazerDrivers

struct InterfaceSelectorTests {
    private let featureDescriptor: [UInt8] = [0x05, 1, 0x09, 2, 0xA1, 1, 0x06, 0, 0xFF, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0]

    private func interface(_ id: UInt64 = 1, parent: UInt64? = 100, vendor: UInt16 = 0x1532, product: UInt16 = 0x00C5, usage: HIDUsage = .mouse, maxFeature: Int = 90, descriptor: [UInt8]? = nil, builtIn: Bool = false) -> HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(registryEntryID: id, usbParentRegistryEntryID: parent, vendorID: vendor, productID: product, product: "Synthetic", transport: "USB", isBuiltIn: builtIn, primaryUsage: usage, usages: [usage], maxFeatureReportSize: maxFeature, reportDescriptor: descriptor ?? featureDescriptor)
    }
    private func group(_ interfaces: [HIDInterfaceDescriptor]) -> PhysicalDeviceDescriptor {
        PhysicalDeviceDescriptor(id: PhysicalDeviceID(rawValue: "synthetic-group"), interfaces: interfaces)
    }

    @Test
    func testExactMouseControlInterfaceSelectedAndAuxiliaryKeyboardRejected() {
        let auxiliary = interface(2, usage: .keyboard, maxFeature: 1, descriptor: [0x05, 1, 0x09, 6, 0xA1, 1, 0xC0])
        let device = group([interface(), auxiliary])
        let selection = InterfaceSelector.razerControlInterface(in: device)
        #expect((selection.selected?.registryEntryID) == (1))
        #expect((selection.issue) == nil)
        #expect((selection.rejections.first?.registryEntryID) == (2))
        #expect(!(GenericKeyboardDriver.supports(device)))
    }

    @Test
    func testAmbiguousExactEndpointsAreRejected() {
        let selection = InterfaceSelector.razerControlInterface(in: group([interface(1), interface(2)]))
        #expect((selection.selected) == nil)
        #expect((selection.candidates.count) == (2))
        #expect((selection.issue) == (.ambiguousCandidates))
    }

    @Test
    func testWrongModelVendorMissingParentAndBuiltInAreNeverSelected() {
        let rejected = [interface(product: 0x00C4), interface(vendor: 0x342D), interface(parent: nil), interface(builtIn: true)]
        for descriptor in rejected {
            let result = InterfaceSelector.razerControlInterface(in: group([descriptor]))
            #expect((result.selected) == nil)
            #expect((result.issue) == (.noCandidate))
        }
    }

    @Test
    func testFeatureMaximumAloneIsInsufficientAndNumberedReportsRejected() {
        for descriptor in [
            interface(descriptor: []),
            interface(descriptor: [0x75]),
            interface(descriptor: [0x75, 8, 0x95, 90, 0x81, 1]),
            interface(descriptor: [0x85, 1] + featureDescriptor),
            interface(maxFeature: 91)
        ] {
            #expect((InterfaceSelector.razerControlInterface(in: group([descriptor])).selected) == nil)
        }
    }

    @Test
    func testNUT65IsIdentificationOnlyEvenWithCompositeMouseUsage() {
        let vendorInterface = interface(1, vendor: 0x342D, product: 0xE51A, usage: HIDUsage(page: 0xFF60, usage: 0x61), maxFeature: 0, descriptor: [0x75, 8, 0x95, 32, 0x81, 2, 0x91, 2])
        let keyboard = interface(2, vendor: 0x342D, product: 0xE51A, usage: .keyboard, maxFeature: 0, descriptor: [])
        let composite = interface(3, vendor: 0x342D, product: 0xE51A, maxFeature: 1, descriptor: [])
        let device = group([vendorInterface, keyboard, composite])
        #expect(GenericKeyboardDriver.supports(device))
        #expect((GenericKeyboardDriver.capabilities) == (.identificationOnly))
        #expect((InterfaceSelector.razerControlInterface(in: device).selected) == nil)
    }

    @Test
    func testGenericKeyboardRejectsInternalAndVirtualDevicesWithoutVendorBlacklist() {
        #expect(!(GenericKeyboardDriver.supports(group([interface(usage: .keyboard, builtIn: true)]))))
        #expect(!(GenericKeyboardDriver.supports(group([interface(parent: nil, usage: .keyboard)]))))
        #expect(GenericKeyboardDriver.supports(group([interface(vendor: 0x05AC, product: 1, usage: .keyboard)])))
    }
}
