// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import BazerCore
@testable import BazerBluetooth

@Suite("Bluetooth audio parsing — offline fixtures") struct BluetoothAudioParserTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func fixture() throws -> [String: AccessoryPowerValue] {
        let url = try #require(Bundle.module.url(forResource: "acefast-iops-redacted", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return AccessoryPowerSourceReader.typedValues(raw)
    }
    func parse(_ values: [String: AccessoryPowerValue]) -> BluetoothAudioPowerRecord? {
        AccessoryPowerParser.parse(values, observedAt: date, opaqueKey: BluetoothAudioOpaqueIdentity.key)
    }
    @Test func realRedactedACEFASTHasSingleNativeThirtyAndNoFabricatedTimestamp() throws {
        let record = try #require(parse(try fixture()))
        #expect(record.name == "ACEFAST ACEFIT Air"); #expect(record.percent == 30)
        #expect(record.component == .single); #expect(record.charging == .discharging)
        #expect(record.observedAt == date); #expect(record.sourceUpdatedAt == nil)
        #expect(record.verifiedPreferenceIdentity == nil); #expect(!record.key.contains("REDACTED"))
    }
    @Test func legalZeroHundredAndRatioRounding() throws {
        for (current, max, expected) in [(0.0, 100.0, 0), (100, 100, 100), (1, 3, 33), (2, 3, 67)] {
            var f = try fixture(); f["Current Capacity"] = .number(current); f["Max Capacity"] = .number(max)
            #expect(parse(f)?.percent == expected)
        }
    }
    @Test func malformedCapacityDoesNotInventBattery() throws {
        for bad in [AccessoryPowerValue.number(-1), .number(101), .number(.infinity), .number(.nan), .string("30"), .boolean(false)] {
            var f = try fixture(); f["Current Capacity"] = bad; #expect(parse(f)?.percent == nil)
        }
        for bad in [AccessoryPowerValue.number(0), .number(-1), .string("100"), .boolean(true)] {
            var f = try fixture(); f["Max Capacity"] = bad; #expect(parse(f)?.percent == nil)
        }
        var f = try fixture(); f.removeValue(forKey: "Max Capacity"); #expect(parse(f)?.percent == nil)
    }
    @Test func requiredSchemaAndTypesFailClosed() throws {
        for key in ["Transport Type", "Type", "Name", "Is Present", "Accessory Category"] {
            var f = try fixture(); f.removeValue(forKey: key); #expect(parse(f) == nil)
        }
        for (key, value) in [("Transport Type", AccessoryPowerValue.string("USB")), ("Accessory Category", .string("Keyboard")),
                             ("Accessory Category", .number(3)), ("Is Present", .string("true"))] {
            var f = try fixture(); f[key] = value; #expect(parse(f) == nil)
        }
    }
    @Test func runtimeSourceHandleCanDisplayButNeverAcquirePersistentIdentity() throws {
        var f = try fixture(); f.removeValue(forKey: "Accessory Identifier")
        let record = try #require(parse(f))
        #expect(record.percent == 30); #expect(record.identityKey.isEmpty)
        #expect(record.verifiedPreferenceIdentity == nil); #expect(record.identifierKind == "runtime-only")
        f.removeValue(forKey: "Power Source ID"); #expect(parse(f) == nil)
    }
    @Test func chargingUnknownIsNeverDischarging() throws {
        for bad in [AccessoryPowerValue.string("0"), .number(2), .number(-1)] {
            var f = try fixture(); f["Is Charging"] = bad; #expect(parse(f)?.charging == .unknown)
        }
        var f = try fixture(); f.removeValue(forKey: "Is Charging"); #expect(parse(f)?.charging == .unknown)
        f = try fixture(); f["Power Source State"] = .string("AC Power"); #expect(parse(f)?.charging == .unknown)
        f["Is Charging"] = .boolean(true); #expect(parse(f)?.charging == .charging)
        f["Is Charging"] = .boolean(false); f["Is Charged"] = .boolean(true); #expect(parse(f)?.charging == .full)
    }
    @Test func identifiersAndPartsHaveSeparateSemantics() throws {
        var f = try fixture(); f["Part Identifier"] = .string("Left"); f["Group Identifier"] = .string("synthetic-group")
        let left = try #require(parse(f)); #expect(left.component == .left); #expect(left.groupKey != nil)
        f["Part Identifier"] = .string("Right"); let right = try #require(parse(f))
        #expect(left.key != right.key); #expect(left.groupKey == right.groupKey)
        f["Part Identifier"] = .string("Case"); #expect(parse(f)?.component == .case)
        f.removeValue(forKey: "Group Identifier"); #expect(parse(f)?.groupKey == nil)
    }
    @Test func explicitReviewedOwnIdentityCanBeUsedWithoutNameAssociation() throws {
        let f = try fixture(), initial = try #require(parse(f))
        let verified = try #require(AccessoryPowerParser.parse(f, observedAt: date, verifiedAccessoryKeys: [initial.identityKey], opaqueKey: BluetoothAudioOpaqueIdentity.key))
        #expect(verified.verifiedPreferenceIdentity == "bluetooth-iops:" + initial.identityKey)
        var renamed = f; renamed["Name"] = .string("Completely different name")
        #expect(AccessoryPowerParser.parse(renamed, observedAt: date, verifiedAccessoryKeys: [initial.identityKey], opaqueKey: BluetoothAudioOpaqueIdentity.key)?.verifiedPreferenceIdentity == verified.verifiedPreferenceIdentity)
    }
    @Test func missingPrivateSymbolIsOfflineSafe() {
        let result = AccessoryPowerSourceReader(symbolAvailable: false).read(at: date)
        #expect(result.status == .unavailable); #expect(result.records.isEmpty)
    }
    @Test func profilerIsPartialAndDoesNotInventACEFASTBattery() throws {
        let data = Data("""
        {"SPBluetoothDataType":[{"device_connected":[{"ACEFAST ACEFIT Air":{"device_address":"AA-BB-CC-DD-EE-FF","device_minorType":"Headset"}},{"Mouse":{"device_address":"11-22-33-44-55-66","device_minorType":"Mouse"}}]}]}
        """.utf8)
        let result = BluetoothAudioProfiler.parse(data)
        #expect(result.status == .partial); #expect(result.records.count == 1)
        #expect(result.records.first?.key == BluetoothAudioOpaqueIdentity.discoveryKey(address: "aa:bb:cc:dd:ee:ff"))
        #expect(BluetoothAudioProfiler.parse(Data("{}".utf8)).status == .failed)
    }
    @Test func booleanCapacityIsNotNumericAndNumericChargingIsAccepted() {
        let typed = AccessoryPowerSourceReader.typedValues(["capacity": NSNumber(value: true), "charging": NSNumber(value: 0), "text": "30"])
        #expect(typed["capacity"] == .boolean(true)); #expect(typed["charging"] == .number(0)); #expect(typed["text"] == .string("30"))
    }
    @Test func unknownPartVariantsRetainNativeReportWithoutAcquiringAggregateOrNotificationMeaning() throws {
        let initial = try #require(parse(try fixture()))
        for part in [AccessoryPowerValue.string("Other"), .string("Vendor Part"), .number(1), .boolean(true)] {
            var f = try fixture(); f["Part Identifier"] = part
            let r = try #require(AccessoryPowerParser.parse(f, observedAt: date, verifiedAccessoryKeys: [initial.identityKey], opaqueKey: BluetoothAudioOpaqueIdentity.key))
            #expect(r.component == .unknown); #expect(r.percent == 30)
            let session = BluetoothAudioSession(generation: 1)
            let device = BluetoothAudioDevice(id: .init(rawValue: "test"), name: r.name, session: session,
                identityQuality: .verified, preferenceIdentity: r.verifiedPreferenceIdentity,
                batteryReadings: [.init(component: r.component, componentID: r.key, percent: r.percent, charging: r.charging,
                    source: r.source, observedAt: date, session: session)], lastSeenAt: date)
            #expect(device.currentReadings(at: date).count == 1)
            #expect(device.currentPercent(at: date) == nil); #expect(device.notificationReadings(at: date).isEmpty)
        }
        var missing = try fixture(); missing.removeValue(forKey: "Part Identifier")
        #expect(parse(missing)?.component == .unknown)
        missing["Part Identifier"] = .string("Combined"); #expect(parse(missing)?.component == .single)
        missing["Part Identifier"] = .number(1); let one = try #require(parse(missing))
        missing["Part Identifier"] = .number(2); #expect(parse(missing)?.key != one.key)
    }
}
