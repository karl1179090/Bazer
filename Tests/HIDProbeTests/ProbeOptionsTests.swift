@testable import HIDProbe
import Testing

struct ProbeOptionsTests {
    @Test func hugeNaNInfiniteAndInvalidDurationsFailBeforeDiscovery() {
        for value in ["1e300", "nan", "inf", "-inf", "0", "-1", "86401"] {
            #expect(throws: (any Error).self) { try ProbeOptions.parse(["watch", "--duration", value, "--json"]) }
        }
    }
    @Test func validDurationBoundsAndBatterySampleBounds() throws {
        #expect(try ProbeOptions.parse(["watch", "--duration", "86400"]).duration == 86400)
        let prefix = ["battery", "--vid", "1532", "--pid", "00C5"]
        #expect(try ProbeOptions.parse(prefix + ["--samples", "1000", "--interval", "3600"]).samples == 1000)
        for value in ["0", "-1", "1001", "1e300", "999999999999999999999"] {
            #expect(throws: (any Error).self) { try ProbeOptions.parse(prefix + ["--samples", value]) }
        }
        for value in ["0", "-1", "0.09", "3601", "1e300", "nan", "inf"] {
            #expect(throws: (any Error).self) { try ProbeOptions.parse(prefix + ["--interval", value]) }
        }
    }
}
