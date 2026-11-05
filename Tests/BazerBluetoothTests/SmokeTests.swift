import Testing
@testable import BazerBluetooth
@Suite("Bluetooth module — synthetic, no system services") struct SmokeTests {
    @Test func opaqueKeysNeverExposeIdentifiers() {
        #expect(!BluetoothAudioOpaqueIdentity.key("iops-accessory:synthetic").contains("synthetic"))
    }
}
