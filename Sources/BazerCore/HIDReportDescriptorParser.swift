// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum HIDDescriptorError: Error, Equatable, Sendable {
    case truncatedItem(offset: Int)
    case invalidReportID(UInt32)
    case invalidGlobalStack(offset: Int)
    case unbalancedCollections
    case reportTooLarge
    case unsupportedLongItem(offset: Int)
}

/// Parses descriptor metadata only. It never subscribes to or decodes input reports.
public enum HIDReportDescriptorParser {
    private struct Globals {
        var usagePage: UInt32 = 0
        var reportSize: UInt32 = 0
        var reportCount: UInt32 = 0
        var reportID: UInt8 = 0
    }
    private struct ReportKey: Hashable {
        let kind: HIDReportKind
        let id: UInt8
    }

    public static func parse(_ bytes: [UInt8]) throws -> HIDReportDescriptorSummary {
        var offset = 0
        var globals = Globals()
        var stack: [Globals] = []
        var localUsages: [HIDUsage] = []
        var pages: Set<UInt32> = []
        var usages: Set<HIDUsage> = []
        var applications: Set<HIDUsage> = []
        var ids: Set<UInt8> = []
        var bits: [ReportKey: Int] = [:]
        var featureCount = 0
        var collectionScopes: [(usages: Set<HIDUsage>, unknown: Bool)] = []
        var reportApplications: [ReportKey: Set<HIDUsage>] = [:]
        var unscopedReports: Set<ReportKey> = []

        while offset < bytes.count {
            let itemOffset = offset
            let prefix = bytes[offset]
            offset += 1
            if prefix == 0xFE { throw HIDDescriptorError.unsupportedLongItem(offset: itemOffset) }
            let sizeCode = Int(prefix & 3)
            let size = sizeCode == 3 ? 4 : sizeCode
            guard bytes.count - offset >= size else {
                throw HIDDescriptorError.truncatedItem(offset: itemOffset)
            }
            var value: UInt32 = 0
            for index in 0..<size { value |= UInt32(bytes[offset + index]) << (index * 8) }
            offset += size
            let type = (prefix >> 2) & 3
            let tag = prefix >> 4

            if type == 1 { // Global items
                switch tag {
                case 0: globals.usagePage = value; pages.insert(value)
                case 7: globals.reportSize = value
                case 8:
                    guard value > 0 && value <= 255 else { throw HIDDescriptorError.invalidReportID(value) }
                    globals.reportID = UInt8(value)
                    ids.insert(UInt8(value))
                case 9: globals.reportCount = value
                case 10: stack.append(globals)
                case 11:
                    guard let restored = stack.popLast() else {
                        throw HIDDescriptorError.invalidGlobalStack(offset: itemOffset)
                    }
                    globals = restored
                default: break
                }
            } else if type == 2 && tag == 0 { // Local Usage; 32-bit usages embed their page.
                let usage = HIDUsage(page: size == 4 ? value >> 16 : globals.usagePage, usage: size == 4 ? value & 0xFFFF : value)
                pages.insert(usage.page)
                usages.insert(usage)
                localUsages.append(usage)
            } else if type == 0 { // Every main item consumes the local state.
                switch tag {
                case 8, 9, 11:
                    let kind: HIDReportKind = tag == 8 ? .input : (tag == 9 ? .output : .feature)
                    let bitCount = UInt64(globals.reportSize) * UInt64(globals.reportCount)
                    // Bound untrusted descriptor sizes before narrowing or accumulating.
                    guard bitCount <= 8 * 1_048_576 else { throw HIDDescriptorError.reportTooLarge }
                    let key = ReportKey(kind: kind, id: globals.reportID)
                    let total = (bits[key] ?? 0) + Int(bitCount)
                    guard total <= 8 * 1_048_576 else { throw HIDDescriptorError.reportTooLarge }
                    bits[key] = total
                    if let scope = collectionScopes.last, !scope.usages.isEmpty {
                        reportApplications[key, default: []].formUnion(scope.usages)
                        if scope.unknown { unscopedReports.insert(key) }
                    } else { unscopedReports.insert(key) }
                    if kind == .feature { featureCount += 1 }
                case 10:
                    var scope = collectionScopes.last ?? (usages: Set<HIDUsage>(), unknown: false)
                    if value == 1 {
                        if let application = localUsages.first { applications.insert(application); scope.usages.insert(application) }
                        else { scope.unknown = true }
                    }
                    collectionScopes.append(scope)
                case 12:
                    guard collectionScopes.popLast() != nil else { throw HIDDescriptorError.unbalancedCollections }
                default: break
                }
                localUsages.removeAll(keepingCapacity: true)
            }
        }
        guard collectionScopes.isEmpty else { throw HIDDescriptorError.unbalancedCollections }
        guard stack.isEmpty else { throw HIDDescriptorError.invalidGlobalStack(offset: bytes.count) }
        let reports = bits.map { HIDReportLayout(kind: $0.key.kind, reportID: $0.key.id, bitCount: $0.value,
            applicationUsages: Array(reportApplications[$0.key] ?? []), hasUnscopedFields: unscopedReports.contains($0.key)) }
            .sorted { ($0.kind.rawValue, $0.reportID) < ($1.kind.rawValue, $1.reportID) }
        return HIDReportDescriptorSummary(
            usagePages: pages.sorted(), usages: usages.sorted(), applicationUsages: applications.sorted(),
            explicitReportIDs: ids.sorted(), reports: reports, featureItemCount: featureCount
        )
    }
}
