// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import BazerCore

@Suite("M12/M13 complete candidate device catalogue — offline")
struct DeviceCatalogTests {
    @Test func everyMatrixRowHasOneCatalogEntryAndIdentifiersAreUnique() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let matrix = try String(contentsOf: root.appendingPathComponent("docs/razer-logitech-support-matrix-2026-11-04.md"), encoding: .utf8)
        var targetSections: [Substring] = []
        var inTargetSection = false
        for line in matrix.split(separator: "\n") {
            if line.hasPrefix("## ") { inTargetSection = line.hasPrefix("## 2.") || line.hasPrefix("## 3.") || line.hasPrefix("## 4.") }
            if inTargetSection && line.hasPrefix("|") { targetSections.append(line) }
        }
        let rows = targetSections.compactMap { line -> String? in
            let cells = line.split(separator: "|", omittingEmptySubsequences: true)
            guard let first = cells.first else { return nil }
            let cell = first.trimmingCharacters(in: .whitespaces)
            guard !cell.hasPrefix("---"), !cell.contains("型号") else { return nil }
            return cell
        }
        #expect(rows.count == 55)
        #expect(DeviceCatalog.entries.count == 55)
        #expect(Set(DeviceCatalog.entries.map(\.id)).count == 55)
        #expect(Set(rows) == Set(DeviceCatalog.entries.map(\.matrixRow)))
        #expect(DeviceCatalog.entries.allSatisfy { !$0.canonicalName.isEmpty && !$0.variants.isEmpty && !$0.limitations.isEmpty })
        var owners: [String: Set<String>] = [:]
        for entry in DeviceCatalog.entries {
            for alias in [entry.canonicalName] + entry.aliases {
                let key = alias.lowercased().filter { $0.isLetter || $0.isNumber }
                owners[key, default: []].insert(entry.id)
            }
        }
        #expect(owners.values.allSatisfy { $0.count == 1 })
    }
    @Test func noCatalogOperationGrantsWriteXYOrEightKilohertz() {
        for entry in DeviceCatalog.entries {
            #expect(!entry.candidateOperations.contains(.independentXY))
            for variant in entry.variants {
                guard let pid = variant.usbProductID, let match = DeviceCatalog.matchUSB(vendorID: entry.brand.vendorID, productID: pid) else { continue }
                #expect(!DeviceOperation.allCases.filter(\.isWrite).contains { match.capabilities.permits($0) })
            }
        }
        #expect(DeviceCatalog.search("GPW1").first?.canonicalName == "PRO Wireless")
        #expect(DeviceCatalog.search("GPW1").first?.documentedPollingCeilingHz == 1000)
        #expect(DeviceCatalog.matchUSB(vendorID: 0x046D, productID: 0xC539) == nil)
        #expect(DeviceCatalog.search("PRO X3 SUPERSTRIKE").isEmpty)
        #expect(DeviceCatalog.search("SUPERSTRIKE").first?.canonicalName == "PRO X2 SUPERSTRIKE")
    }
    @Test func receiverAndUnconfirmedIdentityNeverBecomeMouseProfiles() throws {
        let receiver = try #require(DeviceCatalog.matchUSB(vendorID: 0x1532, productID: 0x00B3))
        #expect(receiver.entry.kind == .receiver)
        #expect(receiver.capabilities.battery == .unsupported)
        #expect(receiver.entry.candidateOperations.isEmpty)
        let unknown = try #require(DeviceCatalog.search("DeathAdder V4 HyperSpeed").first)
        #expect(unknown.identityStatus == .identityUnconfirmed)
        #expect(unknown.variants.allSatisfy { $0.usbProductID == nil })
        #expect(unknown.candidateOperations.isEmpty)
        #expect(DeviceCatalog.matchUSB(vendorID: 0x1532, productID: 0xB007) == nil)
        #expect(DeviceCatalog.matchUSB(vendorID: 0x1532, productID: 0x0095) == nil)
    }
    @Test func powerAndOfficeKeyboardHeadsetScopeAreExplicitPerVariant() throws {
        let wired = try #require(DeviceCatalog.matchUSB(vendorID: 0x1532, productID: 0x0091))
        #expect(wired.capabilities.powerSource == .wired); #expect(wired.capabilities.battery == .unsupported)
        #expect(wired.capabilities[.batteryRead].evidence == .unknown)
        let replaceable = try #require(DeviceCatalog.matchUSB(vendorID: 0x1532, productID: 0x00B8))
        #expect(replaceable.capabilities.powerSource == .replaceableBattery)
        #expect(!replaceable.capabilities.chargingQuery); #expect(replaceable.capabilities[.chargingRead].evidence == .unknown)
        for entry in DeviceCatalog.entries where entry.kind != .mouse { #expect(!entry.candidateOperations.contains(.dpiWrite)) }
        for entry in DeviceCatalog.entries where entry.id.hasPrefix("logitech.mx-") {
            #expect(!entry.candidateOperations.contains(.onboardWrite)); #expect(!entry.candidateOperations.contains(.pollingRateWrite))
        }
        let keyboard = try #require(DeviceCatalog.search("G915 X").first)
        #expect(keyboard.variants.contains { $0.connection == .wiredUSB && $0.powerSource == .wired })
        #expect(keyboard.variants.contains { $0.connection == .lightspeed && $0.powerSource == .rechargeableBattery })
    }
}
