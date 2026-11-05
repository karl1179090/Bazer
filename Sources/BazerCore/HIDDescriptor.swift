// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

public struct HIDUsage: Hashable, Codable, Sendable, Comparable {
    public let page: UInt32
    public let usage: UInt32

    public init(page: UInt32, usage: UInt32) {
        self.page = page
        self.usage = usage
    }

    public static let mouse = HIDUsage(page: 1, usage: 2)
    public static let keyboard = HIDUsage(page: 1, usage: 6)

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.page, lhs.usage) < (rhs.page, rhs.usage)
    }
}

public enum HIDReportKind: String, Codable, Sendable { case input, output, feature }

/// Bit counts include padding but exclude a separately transmitted Report ID byte.
public struct HIDReportLayout: Equatable, Codable, Sendable {
    public let kind: HIDReportKind
    public let reportID: UInt8
    public let bitCount: Int
    public let applicationUsages: [HIDUsage]
    public let hasUnscopedFields: Bool
    public var byteCount: Int { (bitCount + 7) / 8 }

    public init(kind: HIDReportKind, reportID: UInt8, bitCount: Int, applicationUsages: [HIDUsage] = [], hasUnscopedFields: Bool = true) {
        self.kind = kind; self.reportID = reportID; self.bitCount = bitCount
        self.applicationUsages = Array(Set(applicationUsages)).sorted(); self.hasUnscopedFields = hasUnscopedFields
    }
    private enum CodingKeys: String, CodingKey { case kind, reportID, bitCount, applicationUsages, hasUnscopedFields }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(HIDReportKind.self, forKey: .kind), reportID: try c.decode(UInt8.self, forKey: .reportID),
            bitCount: try c.decode(Int.self, forKey: .bitCount), applicationUsages: try c.decodeIfPresent([HIDUsage].self, forKey: .applicationUsages) ?? [],
            hasUnscopedFields: try c.decodeIfPresent(Bool.self, forKey: .hasUnscopedFields) ?? true)
    }
}

public struct HIDReportDescriptorSummary: Equatable, Codable, Sendable {
    public let usagePages: [UInt32]
    public let usages: [HIDUsage]
    public let applicationUsages: [HIDUsage]
    public let explicitReportIDs: [UInt8]
    public let reports: [HIDReportLayout]
    public let featureItemCount: Int

    public func hasVendorReport(kind: HIDReportKind, reportID: UInt8, byteCount: Int) -> Bool {
        reports.contains { $0.kind == kind && $0.reportID == reportID && $0.byteCount == byteCount
            && !$0.hasUnscopedFields && !$0.applicationUsages.isEmpty && $0.applicationUsages.allSatisfy { $0.page >= 0xFF00 } }
    }
    public func hasReport(kind: HIDReportKind, reportID: UInt8, byteCount: Int) -> Bool {
        reports.contains { $0.kind == kind && $0.reportID == reportID && $0.byteCount == byteCount }
    }
}

public struct HIDInterfaceDescriptor: Equatable, Codable, Sendable, Identifiable {
    public var id: UInt64 { registryEntryID }
    public let registryEntryID: UInt64
    public let usbParentRegistryEntryID: UInt64?
    public let usbParentPath: String?
    public let vendorID: UInt16
    public let productID: UInt16
    public let product: String
    public let manufacturer: String?
    public let transport: String?
    public let locationID: UInt32?
    public let isBuiltIn: Bool
    public let primaryUsage: HIDUsage?
    public let usages: [HIDUsage]
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int
    public let maxFeatureReportSize: Int
    public let reportDescriptor: [UInt8]

    public var descriptorSHA256: String {
        SHA256.hash(data: Data(reportDescriptor)).map { String(format: "%02x", $0) }.joined()
    }
    public var descriptorSummary: HIDReportDescriptorSummary? {
        try? HIDReportDescriptorParser.parse(reportDescriptor)
    }
    public var allUsages: Set<HIDUsage> {
        Set(usages + (primaryUsage.map { [$0] } ?? []) + (descriptorSummary?.applicationUsages ?? []))
    }
    public var hasPhysicalUSBParent: Bool {
        usbParentRegistryEntryID != nil || !(usbParentPath ?? "").isEmpty
    }
    public var isExternalUSB: Bool {
        transport?.caseInsensitiveCompare("USB") == .orderedSame && !isBuiltIn && hasPhysicalUSBParent
    }

    public init(
        registryEntryID: UInt64,
        usbParentRegistryEntryID: UInt64? = nil,
        usbParentPath: String? = nil,
        vendorID: UInt16,
        productID: UInt16,
        product: String,
        manufacturer: String? = nil,
        transport: String? = nil,
        locationID: UInt32? = nil,
        isBuiltIn: Bool = false,
        primaryUsage: HIDUsage? = nil,
        usages: [HIDUsage] = [],
        maxInputReportSize: Int = 0,
        maxOutputReportSize: Int = 0,
        maxFeatureReportSize: Int = 0,
        reportDescriptor: [UInt8] = []
    ) {
        self.registryEntryID = registryEntryID
        self.usbParentRegistryEntryID = usbParentRegistryEntryID
        self.usbParentPath = usbParentPath
        self.vendorID = vendorID
        self.productID = productID
        self.product = product
        self.manufacturer = manufacturer
        self.transport = transport
        self.locationID = locationID
        self.isBuiltIn = isBuiltIn
        self.primaryUsage = primaryUsage
        self.usages = usages.sorted()
        self.maxInputReportSize = maxInputReportSize
        self.maxOutputReportSize = maxOutputReportSize
        self.maxFeatureReportSize = maxFeatureReportSize
        self.reportDescriptor = reportDescriptor
    }
}
