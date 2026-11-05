// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import BazerCore
@testable import BazerBluetooth

@Suite("Bluetooth audio identity and freshness — offline") struct BluetoothAudioIdentityAndFreshnessTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func freshnessRejects180SecondsFutureDatesAndOldSourceTimestamps() {
        let session = BluetoothAudioSession(generation: 1)
        let reading = BluetoothAudioBatteryReading(percent: 0, charging: .discharging, source: "fake", observedAt: date, session: session)
        #expect(reading.isFresh(at: date.addingTimeInterval(179))); #expect(!reading.isFresh(at: date.addingTimeInterval(180)))
        #expect(!reading.isFresh(at: date.addingTimeInterval(-1)))
        let old = BluetoothAudioBatteryReading(percent: 100, source: "fake", observedAt: date, sourceUpdatedAt: date.addingTimeInterval(-181), session: session)
        #expect(!old.isFresh(at: date))
        let future = BluetoothAudioBatteryReading(percent: 100, source: "fake", observedAt: date, sourceUpdatedAt: date.addingTimeInterval(1), session: session)
        #expect(!future.isFresh(at: date.addingTimeInterval(2)))
    }
    @Test func currentBatteryAndNotificationRejectWrongGenerationFailuresAndUnknownCharging() {
        let session = BluetoothAudioSession(generation: 1)
        let r = BluetoothAudioBatteryReading(percent: 20, charging: .discharging, source: "fake", observedAt: date, session: session)
        var device = BluetoothAudioDevice(id: .init(rawValue: "fake"), name: "Air", session: session, identityQuality: .verified,
            preferenceIdentity: "verified", batteryReadings: [r], lastSeenAt: date)
        #expect(device.currentPercent(at: date) == 20); #expect(device.notificationReadings(at: date).count == 1)
        device.session = .init(generation: 2); #expect(device.currentPercent(at: date) == nil)
        device.session = session; device.readStatus = .failed; #expect(device.currentPercent(at: date) == nil)
        device.readStatus = .success; device.connection = .disconnected; #expect(device.notificationReadings(at: date).isEmpty)
        device.connection = .connected
        device.batteryReadings = [.init(percent: 20, charging: .unknown, source: "fake", observedAt: date, session: session)]
        #expect(device.currentPercent(at: date) == 20); #expect(device.notificationReadings(at: date).isEmpty)
        device.batteryReadings = [.init(component: .case, percent: 1, charging: .discharging, source: "fake", observedAt: date, session: session)]
        #expect(device.currentPercent(at: date) == nil); #expect(device.notificationReadings(at: date).isEmpty)
    }
    @Test func verifiedOwnSourcesAreIndependentOfEqualNamesAndNeverBorrowDiscoveryKeys() {
        let native = [BluetoothAudioDiscoveryRecord(key: "native-a", name: "Equal", verifiedPreferenceIdentity: "native-identity")]
        let namesOnly = BluetoothAudioMatcher.match(discovery: native, power: [.init(key: "p", name: "Equal", percent: 20, observedAt: date)])
        #expect(namesOnly.first?.preferenceIdentity == nil)
        let owned = BluetoothAudioMatcher.match(discovery: native + [.init(key: "native-b", name: "Equal")], power: [
            .init(key: "p1", name: "Equal", verifiedPreferenceIdentity: "source-1", percent: 20, observedAt: date),
            .init(key: "p2", name: "Equal", verifiedPreferenceIdentity: "source-2", percent: 60, observedAt: date)])
        #expect(owned.count == 2); #expect(Set(owned.compactMap(\.preferenceIdentity)) == ["source-1", "source-2"])
        let collided = BluetoothAudioMatcher.match(discovery: [], power: [
            .init(key: "p1", name: "One", verifiedPreferenceIdentity: "reused", percent: 20, observedAt: date),
            .init(key: "p2", name: "Two", verifiedPreferenceIdentity: "reused", percent: 60, observedAt: date)])
        #expect(collided.allSatisfy { $0.preferenceIdentity == nil && $0.quality == .ambiguous })
        let direct = BluetoothAudioMatcher.match(discovery: native, power: [.init(key: "p", name: "Renamed", directDiscoveryKey: "native-a", percent: 20, observedAt: date)])
        #expect(direct.first?.discoveryKeys == ["native-a"])
        let missingDirect = BluetoothAudioMatcher.match(discovery: native, power: [.init(key: "p", name: "Equal", directDiscoveryKey: "absent", percent: 20, observedAt: date)])
        #expect(missingDirect.first?.discoveryKeys.isEmpty == true)
        let conflicting = BluetoothAudioMatcher.match(discovery: native, power: [
            .init(key: "p1", name: "Equal", groupKey: "g", directDiscoveryKey: "native-a", verifiedPreferenceIdentity: "group", component: .left, percent: 20, observedAt: date),
            .init(key: "p2", name: "Equal", groupKey: "g", directDiscoveryKey: "native-b", verifiedPreferenceIdentity: "group", component: .right, percent: 60, observedAt: date)])
        #expect(conflicting.first?.hasConflict == true); #expect(conflicting.first?.preferenceIdentity == nil)
    }
    @Test func equalNamesDoNotGroupPartsWithoutExplicitGroupEvidence() {
        let records = [BluetoothAudioPowerRecord(key: "p1", name: "Equal", component: .left, percent: 20, observedAt: date),
                       BluetoothAudioPowerRecord(key: "p2", name: "Equal", component: .right, percent: 60, observedAt: date)]
        #expect(BluetoothAudioMatcher.match(discovery: [], power: records).count == 2)
    }
    @Test func registryOnlyAcceptsFullyReviewedUniqueSourceEvidence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-audio-evidence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = BluetoothAudioIdentityEvidenceRegistry(url: folder.appendingPathComponent("evidence.json"))
        #expect(registry.loadVerifiedKeys().isEmpty)
        let key = BluetoothAudioOpaqueIdentity.key("iops-accessory:synthetic")
        func evidence(reconnect: Bool = true) -> BluetoothAudioIdentityEvidence {
            .init(identifierKey: key, identifierNamespace: "iops-accessory",
                semanticReference: "https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeysPrivate.h",
                reconnectVerified: reconnect, processRestartVerified: true, nameIndependentIdentityVerified: true,
                collisionIsolationVerified: true, evidenceReference: "synthetic-test-review", approvedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        try registry.saveReviewed([evidence(reconnect: false)]); #expect(registry.loadVerifiedKeys().isEmpty)
        try registry.saveReviewed([evidence()]); #expect(registry.loadVerifiedKeys() == [key])
        try registry.saveReviewed([evidence(), evidence()]); #expect(registry.loadVerifiedKeys().isEmpty)
        try Data("{}".utf8).write(to: registry.url); #expect(registry.loadVerifiedKeys().isEmpty)
    }
}
