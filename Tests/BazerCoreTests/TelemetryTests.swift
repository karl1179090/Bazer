import Testing
import Foundation
@testable import BazerCore

struct TelemetryTests {
    @Test
    func testZeroIsValidAndFreshnessUsesActualTime() throws {
        let received = Date(timeIntervalSince1970: 1_000)
        for (raw, percent) in [(UInt8(0), 0), (128, 50), (255, 100)] {
            let sample = BatterySample(rawValue: raw, receivedAt: received, source: "synthetic-test")
            #expect((sample.percent) == (percent))
            #expect(!(sample.isStale(at: received.addingTimeInterval(179))))
            #expect(sample.isStale(at: received.addingTimeInterval(180)))
            #expect((try JSONDecoder().decode(BatterySample.self, from: JSONEncoder().encode(sample))) == (sample))
        }
    }

    @Test
    func testUnknownChargingAndUnsupportedKeyboardAreExplicit() throws {
        let sample = ChargingSample(state: .unknown, rawValue: nil, receivedAt: Date(timeIntervalSince1970: 0), source: "no-response")
        #expect((sample.state) == (.unknown))
        #expect((sample.rawValue) == nil)
        #expect((DeviceCapabilities.identificationOnly.battery) == (.unsupported))
        #expect(!(DeviceCapabilities.identificationOnly.chargingQuery))
        #expect((try JSONDecoder().decode(ChargingSample.self, from: JSONEncoder().encode(sample))) == (sample))
    }
}
