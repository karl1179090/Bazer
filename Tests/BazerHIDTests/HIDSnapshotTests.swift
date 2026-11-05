import Testing
import Foundation
import BazerCore
@testable import BazerHID

struct HIDSnapshotTests {
    @Test
    func testSnapshotIsValueOnlyAndUsesPhysicalGrouping() throws {
        let interfaces = [1, 2].map {
            HIDInterfaceDescriptor(registryEntryID: UInt64($0), usbParentRegistryEntryID: 100, vendorID: 1, productID: 2, product: "Synthetic", transport: "USB")
        }
        let snapshot = HIDDiscoverySnapshot(capturedAt: Date(timeIntervalSince1970: 0), interfaces: interfaces)
        #expect((snapshot.devices.count) == (1))
        #expect((snapshot.devices[0].interfaces.count) == (2))
        #expect((try JSONDecoder().decode(HIDDiscoverySnapshot.self, from: JSONEncoder().encode(snapshot))) == (snapshot))
    }
}
