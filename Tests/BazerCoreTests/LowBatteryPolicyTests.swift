// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BazerCore

@Suite("Low battery policy — synthetic, no system services")
struct LowBatteryPolicyTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let policy = LowBatteryPolicy()

    @Test func boundariesAndHysteresisRequireBothRecoveryAndCooldown() throws {
        #expect(policy.evaluate(try state(raw: 51), at: date, record: LowBatteryRecord()) == .notify(percent: 20))
        #expect(policy.evaluate(try state(raw: 53), at: date, record: LowBatteryRecord()) == .none)
        let sent = LowBatteryRecord(isArmed: false, lastNotifiedAt: date.addingTimeInterval(-21_600))
        #expect(policy.evaluate(try state(raw: 51), at: date, record: sent) == .none)
        #expect(policy.evaluate(try state(raw: 61), at: date, record: sent) == .none) // 24%
        #expect(policy.evaluate(try state(raw: 64), at: date, record: sent) == .rearm) // 25%
        let recovered = LowBatteryRecord(isArmed: true, lastNotifiedAt: date.addingTimeInterval(-21_599))
        #expect(policy.evaluate(try state(raw: 51), at: date, record: recovered) == .none)
        let ready = LowBatteryRecord(isArmed: true, lastNotifiedAt: date.addingTimeInterval(-21_600))
        #expect(policy.evaluate(try state(raw: 0), at: date, record: ready) == .notify(percent: 0))
    }

    @Test func chargingUnknownStaleRemovedAndFailedNeverNotify() throws {
        for charging in [ChargingState.charging, .unknown] {
            #expect(policy.evaluate(try state(raw: 0, charging: charging), at: date, record: LowBatteryRecord()) == .none)
        }
        let sample = try state(raw: 0)
        #expect(policy.evaluate(sample, at: date.addingTimeInterval(180), record: LowBatteryRecord()) == .none)
        #expect(policy.evaluate(sample, at: date.addingTimeInterval(179), record: LowBatteryRecord()) == .notify(percent: 0))
        var removed = sample; removed.hostPresence = .removed
        #expect(policy.evaluate(removed, at: date, record: LowBatteryRecord()) == .none)
        var failure = sample; failure.batteryFailure = TelemetryFailure(category: .timeout, message: "synthetic")
        #expect(policy.evaluate(failure, at: date, record: LowBatteryRecord()) == .none)
        failure = sample; failure.chargingFailure = TelemetryFailure(category: .timeout, message: "synthetic")
        #expect(policy.evaluate(failure, at: date, record: LowBatteryRecord()) == .none)
        var refreshing = sample; refreshing.isRefreshing = true
        #expect(policy.evaluate(refreshing, at: date, record: LowBatteryRecord()) == .none)
    }

    @Test func freshCacheFromEarlierQueryIsNotCurrentSuccess() throws {
        var sample = try state(raw: 0)
        sample.lastAttemptedAt = date.addingTimeInterval(5)
        sample.lastFinishedAt = date.addingTimeInterval(6)
        #expect(policy.evaluate(sample, at: date.addingTimeInterval(6), record: LowBatteryRecord()) == .none)
        sample = try state(raw: 0); sample.consecutiveFailures = 1
        #expect(policy.evaluate(sample, at: date, record: LowBatteryRecord()) == .none)
        sample = try state(raw: 0)
        sample.charging = ChargingSample(state: .notCharging, rawValue: 0, receivedAt: date.addingTimeInterval(-1), source: "synthetic prior query")
        #expect(policy.evaluate(sample, at: date, record: LowBatteryRecord()) == .none)
    }

    @Test func futureTimestampsAndClockRollbackFailClosed() throws {
        #expect(policy.evaluate(try state(raw: 0), at: date.addingTimeInterval(-1), record: LowBatteryRecord()) == .none)
        let futureHistory = LowBatteryRecord(isArmed: true, lastNotifiedAt: date.addingTimeInterval(1))
        #expect(policy.evaluate(try state(raw: 0), at: date, record: futureHistory) == .none)
    }

    @Test func ambiguousIdentityCannotAcquireRegistryBasedHistory() throws {
        var sample = try state(raw: 0); sample.preferenceIdentity = nil
        #expect(policy.evaluate(sample, at: date, record: LowBatteryRecord()) == .none)
    }

    @Test func persistenceStoresOnlyPreferenceKeysAndEpisodeHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-notification-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileNotificationPreferences(url: folder.appendingPathComponent("preferences.json"))
        #expect(try store.load() == NotificationPreferences())
        let sample = try state(raw: 0)
        let key = try #require(sample.preferenceIdentity?.rawValue)
        let original = NotificationPreferences(isEnabled: true, records: [key: LowBatteryRecord(isArmed: false, lastNotifiedAt: date)])
        try store.save(original)
        let restarted = try store.load()
        #expect(restarted == original)
        #expect(policy.evaluate(sample, at: date, record: try #require(restarted.records[key])) == .none)
        let json = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!json.contains("usb-parent:")); #expect(!json.contains("registryEntryID"))
        #expect(!json.contains("rawValue")); #expect(!json.contains("receivedAt"))
    }

    private func state(raw: UInt8, charging: ChargingState = .notCharging) throws -> DeviceState {
        let endpoint = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 1,
            vendorID: 0x1532, productID: 0x00C5, product: "Synthetic", transport: "USB", locationID: 100,
            primaryUsage: .mouse)
        let identified = IdentifiedDevice(descriptor: PhysicalDeviceGrouper.group([endpoint])[0], kind: .mouse,
            capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: true), controlEndpointRegistryEntryID: 101)
        var store = DeviceStore(); store.reconcile([identified], at: date)
        let session = try #require(store.devices[identified.descriptor.id]?.sessionID)
        store.apply(DeviceTelemetryUpdate(startedAt: date, finishedAt: date,
            battery: BatterySample(rawValue: raw, receivedAt: date, source: "synthetic test"), batteryFailure: nil,
            charging: ChargingSample(state: charging, rawValue: nil, receivedAt: date, source: "synthetic test"), chargingFailure: nil), to: session)
        return try #require(store.devices[identified.descriptor.id])
    }
}
