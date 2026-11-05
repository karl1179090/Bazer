// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Testing
@testable import BazerCore

@Suite("M11 private profile backups and scoped report ownership — offline")
struct ProfileBackupTests {
    private final class ReadAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var rejected = false
        func recordNonRegularRejection() { lock.withLock { rejected = true } }
        var rejectedNonRegular: Bool { lock.withLock { rejected } }
    }
    private let session = LogicalDeviceSessionID(address: .direct(DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "offline-host"))))
    private func identity(unit: String? = "hashed-unit") -> ProfileBackupIdentity {
        ProfileBackupIdentity(vendorID: 0x1532, productID: 0x00C5, unitID: unit, firmware: "1.2", formatID: "offline.known.layout", formatVersion: 1, descriptorSHA256: "synthetic-descriptor-hash")
    }
    @Test func backupIntegrityAndExactRestoreIdentityRejectCorruptionAndWrongLayouts() throws {
        let backup = ProfileBackup(capturedAt: Date(), identity: identity(), session: session, regions: [ProfileBackupRegion(id: "sector", bytes: [1,2,3,4])])
        try backup.validateRestore(to: identity(), session: LogicalDeviceSessionID(address: session.address), expectedRegionLengths: ["sector": 4])
        #expect(throws: ProfileBackupError.wrongDevice) { try backup.validateRestore(to: identity(unit: "another-unit"), session: session, expectedRegionLengths: ["sector": 4]) }
        #expect(throws: ProfileBackupError.regionLayoutMismatch) { try backup.validateRestore(to: identity(), session: session, expectedRegionLengths: ["sector": 5]) }
        let anonymous = ProfileBackup(capturedAt: Date(), identity: identity(unit: nil), session: session, regions: backup.regions)
        #expect(throws: ProfileBackupError.staleAnonymousSession) { try anonymous.validateRestore(to: identity(unit: nil), session: LogicalDeviceSessionID(address: session.address), expectedRegionLengths: ["sector": 4]) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
        var regions = try #require(json["regions"] as? [[String: Any]])
        regions[0]["bytes"] = [1,2,3,5]; json["regions"] = regions
        let corrupt = try JSONDecoder().decode(ProfileBackup.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: ProfileBackupError.checksumMismatch("sector")) { try corrupt.validateIntegrity() }
    }
    @Test func backupSaveIsPrivateExclusiveAndNeverFollowsFinalSymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = FileProfileBackup(url: folder.appendingPathComponent("backup.json"))
        let backup = ProfileBackup(capturedAt: Date(), identity: identity(), session: session, regions: [ProfileBackupRegion(id: "sector", bytes: [1,2,3,4])])
        try file.save(backup)
        #expect(try file.load() == backup)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: (any Error).self) { try file.save(backup) }
        let victim = folder.appendingPathComponent("victim.json"), link = folder.appendingPathComponent("link.json")
        try Data("private-existing-file".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: victim.path)
        #expect(throws: (any Error).self) { try FileProfileBackup(url: link).save(backup) }
        #expect(throws: (any Error).self) { _ = try FileProfileBackup(url: link).load() }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "private-existing-file")
    }
    @Test func privateFileRejectsFIFOWithoutAWriterBeforeReading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appendingPathComponent("not-a-backup.fifo")
        try #require(Darwin.mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        let attempt = ReadAttempt()
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            defer { finished.signal() }
            do { _ = try LocalPrivateFile(url: fifo).read() }
            catch LocalPrivateFileError.notRegularFile { attempt.recordNonRegularRejection() }
            catch { }
        }
        try #require(started.wait(timeout: .now() + 2) == .success)
        let finishedWithoutWriter = finished.wait(timeout: .now() + 1) == .success
        if !finishedWithoutWriter {
            // A regressed blocking open must fail this test without stranding its worker.
            // This temporary endpoint is opened only after the bounded assertion fails.
            let unblocker = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            defer { if unblocker >= 0 { Darwin.close(unblocker) } }
            #expect(unblocker >= 0)
            #expect(finished.wait(timeout: .now() + 2) == .success)
        }
        #expect(finishedWithoutWriter)
        #expect(attempt.rejectedNonRegular)
        #expect(throws: LocalPrivateFileError.notRegularFile) { _ = try LocalPrivateFile(url: folder).read() }
    }
    @Test func reportOwnershipCannotBeBorrowedFromAnUnrelatedVendorCollection() throws {
        let vendorDummy: [UInt8] = [0x06,0,0xFF,0x09,1,0xA1,1,0xC0]
        let mouseShort: [UInt8] = [5,1,9,2,0xA1,1,0x85,0x10,0x75,8,0x95,6,0x81,0,0x91,0,0xC0]
        let vendorLong: [UInt8] = [0x06,0,0xFF,0x09,1,0xA1,1,0x85,0x11,0x75,8,0x95,19,0x81,0,0x91,0,0xC0]
        let summary = try HIDReportDescriptorParser.parse(vendorDummy + mouseShort + vendorLong)
        #expect(summary.hasReport(kind: .input, reportID: 0x10, byteCount: 6))
        #expect(!summary.hasVendorReport(kind: .input, reportID: 0x10, byteCount: 6))
        #expect(!summary.hasVendorReport(kind: .output, reportID: 0x10, byteCount: 6))
        #expect(summary.hasVendorReport(kind: .input, reportID: 0x11, byteCount: 19))
        #expect(summary.hasVendorReport(kind: .output, reportID: 0x11, byteCount: 19))
    }
    @Test func sharedReportAcrossVendorAndOrdinaryApplicationsIsNotAuthorized() throws {
        let vendorHalf: [UInt8] = [0x06,0,0xFF,0x09,1,0xA1,1,0x85,0x10,0x75,8,0x95,3,0x81,0,0x91,0,0xC0]
        let keyboardHalf: [UInt8] = [5,1,9,6,0xA1,1,0x85,0x10,0x75,8,0x95,3,0x81,0,0x91,0,0xC0]
        let summary = try HIDReportDescriptorParser.parse(vendorHalf + keyboardHalf)
        #expect(summary.hasReport(kind: .input, reportID: 0x10, byteCount: 6))
        #expect(!summary.hasVendorReport(kind: .input, reportID: 0x10, byteCount: 6))
        #expect(Set(try #require(summary.reports.first).applicationUsages).count == 2)
    }
}
