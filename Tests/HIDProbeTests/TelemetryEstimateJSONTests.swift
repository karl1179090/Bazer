// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import Testing
@testable import HIDProbe

@Suite("CLI voltage estimate JSON — offline values only")
struct TelemetryEstimateJSONTests {
    @Test func actualAttemptJSONKeepsVoltageAndSeparatelyMarksUncalibratedEstimate() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let estimate = try #require(BatteryPercentageEstimate(value: 55, source: "synthetic Solaar curve", resolution: "5% display steps; uncalibrated"))
        let sample = BatterySample(value: .voltageOnly(millivolts: 3845), rawBytes: [15,5,0], receivedAt: date,
            source: "HID++ 1001 runtime feature", percentageEstimate: estimate)
        let update = DeviceTelemetryUpdate(startedAt: date, finishedAt: date, battery: sample, batteryFailure: nil,
            charging: ChargingSample(state: .discharging, rawValue: 0, receivedAt: date, source: "test"), chargingFailure: nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TelemetryProbeSample(sequence: 1, update: update))) as? [String: Any])
        let battery = try #require(json["battery"] as? [String: Any])
        let value = try #require(battery["value"] as? [String: Any])
        #expect((value["voltageOnly"] as? [String: Any])?["millivolts"] as? Int == 3845)
        #expect(value["percentage"] == nil); #expect(battery["rawBytes"] as? [Int] == [15,5,0])
        #expect(battery["source"] as? String == "HID++ 1001 runtime feature")
        let metadata = try #require(battery["percentageEstimate"] as? [String: Any])
        #expect(metadata["value"] as? Int == 55); #expect(metadata["isEstimated"] as? Bool == true)
        #expect(metadata["isCalibrated"] as? Bool == false); #expect(metadata["source"] as? String == "synthetic Solaar curve")
        #expect((metadata["resolution"] as? String)?.contains("5%") == true)
    }
}
