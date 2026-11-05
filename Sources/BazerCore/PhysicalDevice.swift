// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Session identity only; registry IDs must never be persisted as durable device IDs.
public struct PhysicalDeviceID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PhysicalDeviceDescriptor: Equatable, Codable, Sendable, Identifiable {
    public let id: PhysicalDeviceID
    public let interfaces: [HIDInterfaceDescriptor]
    public var vendorID: UInt16? { interfaces.first?.vendorID }
    public var productID: UInt16? { interfaces.first?.productID }
    public var product: String { interfaces.first?.product ?? "Unknown HID device" }
    public var allUsages: Set<HIDUsage> { interfaces.reduce(into: []) { $0.formUnion($1.allUsages) } }
    public var isExternalUSB: Bool { !interfaces.isEmpty && interfaces.allSatisfy(\.isExternalUSB) }

    public init(id: PhysicalDeviceID, interfaces: [HIDInterfaceDescriptor]) {
        self.id = id
        self.interfaces = interfaces.sorted { $0.registryEntryID < $1.registryEntryID }
    }
}

public enum PhysicalDeviceGrouper {
    public static func group(_ interfaces: [HIDInterfaceDescriptor]) -> [PhysicalDeviceDescriptor] {
        let grouped = Dictionary(grouping: interfaces) { descriptor -> PhysicalDeviceID in
            if descriptor.transport?.caseInsensitiveCompare("USB") == .orderedSame {
                if let parent = descriptor.usbParentRegistryEntryID {
                    return PhysicalDeviceID(rawValue: "usb-parent:\(parent)")
                }
                if let path = descriptor.usbParentPath, !path.isEmpty {
                    return PhysicalDeviceID(rawValue: "usb-path:\(path)")
                }
            }
            // Unknown topology never authorizes merging by VID/PID, name, or location.
            return PhysicalDeviceID(rawValue: "interface:\(descriptor.registryEntryID)")
        }
        return grouped.map { PhysicalDeviceDescriptor(id: $0.key, interfaces: $0.value) }.sorted { $0.id < $1.id }
    }
}
