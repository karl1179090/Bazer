// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// Values crossing the dedicated HID thread boundary. No HID handles cross it.
public struct HIDDiscoverySnapshot: Equatable, Codable, Sendable {
    public let capturedAt: Date
    public let interfaces: [HIDInterfaceDescriptor]
    public let registryEvidence: [HIDRegistryEvidence]
    public var devices: [PhysicalDeviceDescriptor] { PhysicalDeviceGrouper.group(interfaces) }

    public init(capturedAt: Date, interfaces: [HIDInterfaceDescriptor], registryEvidence: [HIDRegistryEvidence] = []) {
        self.capturedAt = capturedAt
        self.interfaces = interfaces.sorted { $0.registryEntryID < $1.registryEntryID }
        self.registryEvidence = registryEvidence.sorted { $0.interfaceRegistryEntryID < $1.interfaceRegistryEntryID }
    }
}

public protocol HIDDiscoveryService: Sendable {
    func snapshot() async throws -> HIDDiscoverySnapshot
}

public struct HIDRegistryNode: Equatable, Codable, Sendable {
    public let registryEntryID: UInt64
    public let registryClass: String
    public let path: String?

    public init(registryEntryID: UInt64, registryClass: String, path: String?) {
        self.registryEntryID = registryEntryID
        self.registryClass = registryClass
        self.path = path
    }
}

public struct HIDRegistryEvidence: Equatable, Codable, Sendable {
    public let interfaceRegistryEntryID: UInt64
    public let nearestUSBParent: HIDRegistryNode?
    /// Interface first, ending at the nearest physical USB device, never at a hub above it.
    public let ancestry: [HIDRegistryNode]
    public let internalEvidence: [String]
    public let diagnostics: [HIDOperationDiagnostic]

    public init(interfaceRegistryEntryID: UInt64, nearestUSBParent: HIDRegistryNode?, ancestry: [HIDRegistryNode], internalEvidence: [String], diagnostics: [HIDOperationDiagnostic] = []) {
        self.interfaceRegistryEntryID = interfaceRegistryEntryID
        self.nearestUSBParent = nearestUSBParent
        self.ancestry = ancestry
        self.internalEvidence = internalEvidence
        self.diagnostics = diagnostics
    }
}

public struct HIDOperationDiagnostic: Equatable, Codable, Sendable {
    public let phase: String
    public let registryEntryID: UInt64
    public let rawIOReturn: Int32
    public let message: String
    public let ioReturnHex: String

    public init(phase: String, registryEntryID: UInt64, rawIOReturn: Int32, message: String) {
        self.phase = phase
        self.registryEntryID = registryEntryID
        self.rawIOReturn = rawIOReturn
        self.ioReturnHex = String(format: "0x%08X", UInt32(bitPattern: rawIOReturn))
        self.message = message
    }
}

public struct HIDInspectionResult: Equatable, Codable, Sendable {
    public let registryEntryID: UInt64
    public let operations: [HIDOperationDiagnostic]
    public var succeeded: Bool { operations.count == 2 && operations.allSatisfy { $0.rawIOReturn == 0 } }

    public init(registryEntryID: UInt64, operations: [HIDOperationDiagnostic]) {
        self.registryEntryID = registryEntryID
        self.operations = operations
    }
}

public struct HIDDiscoveryEvent: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case initial, added, removed, changed }
    public let kind: Kind
    public let interfaceRegistryEntryID: UInt64?
    public let snapshot: HIDDiscoverySnapshot

    public init(kind: Kind, interfaceRegistryEntryID: UInt64? = nil, snapshot: HIDDiscoverySnapshot) {
        self.kind = kind
        self.interfaceRegistryEntryID = interfaceRegistryEntryID
        self.snapshot = snapshot
    }
}
