import Foundation
import Testing
import BazerCore
@testable import BazerBluetooth

private actor IndependentBackend: BluetoothAudioBackend {
    var d = BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>(status: .success)
    var p = BluetoothAudioReadResult<BluetoothAudioPowerRecord>(status: .success)
    var event: (@Sendable () -> Void)?
    var calls = 0
    var gated = false
    var waiters: [CheckedContinuation<Void,Never>] = []
    func set(_ d: BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>, _ p: BluetoothAudioReadResult<BluetoothAudioPowerRecord>) { self.d=d;self.p=p }
    func discover() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        calls += 1
        if gated { await withCheckedContinuation { waiters.append($0) } }
        return d
    }
    func readPower() -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> { p }
    func startEvents(_ f: @escaping @Sendable () -> Void) { event=f }
    func stop() { event=nil }
    func gate() { gated=true }
    func fire() { event?() }
    func release() { gated=false;let pending=waiters;waiters=[];pending.forEach{$0.resume()} }
}

@Suite("Independent adversarial acceptance") struct IndependentAdversarialTests {
    let now = Date(timeIntervalSince1970:1_800_000_000)
    func d(_ name: String, _ online: Bool = true) -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        .init(records:[.init(key:"native-A",name:name,isConnected:online)],status:.success)
    }
    func p() -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> {
        .init(records:[.init(key:"power-A",name:"Original",percent:30,charging:.discharging,observedAt:now)],status:.success)
    }
    @Test func renamedNativeMustRevokePriorNameAliasBeforeItsDisconnect() async throws {
        let b=IndependentBackend();await b.set(d("Original"),p())
        let m=BluetoothAudioMonitor(backend:b,clock:{now})
        let first=try #require(await m.refresh().devices.first)
        await b.set(d("Renamed"),p());_=await m.refresh()
        await b.set(d("Renamed",false),p())
        let result=await m.refresh(), accessory=try #require(result.devices.first{$0.id==first.id})
        print("INDEPENDENT rename then native disconnect: \(accessory.connection), cards=\(result.devices.count), percent=\(accessory.currentPercent(at:now) as Any)")
        #expect(accessory.connection != .disconnected,"A revoked same-name correlation must not tombstone the still-present accessory")
        await m.stop()
    }
    @Test func collisionMustRevokePriorNameAliasBeforeOneNativeDisconnects() async throws {
        let b=IndependentBackend();await b.set(d("Original"),p())
        let m=BluetoothAudioMonitor(backend:b,clock:{now});_=await m.refresh()
        let collision = BluetoothAudioReadResult(records:[BluetoothAudioDiscoveryRecord(key:"native-A",name:"Original"),.init(key:"native-B",name:"Original")],status:BluetoothAudioReadStatus.success)
        await b.set(collision,p());_=await m.refresh()
        await b.set(.init(records:[.init(key:"native-A",name:"Original",isConnected:false),.init(key:"native-B",name:"Original")],status:.success),p())
        let result=await m.refresh()
        print("INDEPENDENT collision then native disconnect: \(result.devices.map{($0.connection.rawValue,$0.currentPercent(at:now) as Any)})")
        #expect(!result.devices.contains{$0.connection == .disconnected},"After collision, native-A cannot authoritatively retire power-A")
        await m.stop()
    }
    @Test func unknownPartMustNotBecomeCombinedOrNotificationEligible() throws {
        let values:[String:AccessoryPowerValue] = ["Transport Type":.string("Bluetooth"),"Type":.string("Accessory Source"),"Name":.string("Audio"),"Is Present":.boolean(true),"Accessory Category":.string("Headset"),"Accessory Identifier":.string("synthetic"),"Part Identifier":.string("Other"),"Current Capacity":.number(1),"Max Capacity":.number(100),"Is Charging":.boolean(false),"Power Source State":.string("Battery Power")]
        let key=BluetoothAudioOpaqueIdentity.key("iops-accessory:synthetic")
        let r=try #require(AccessoryPowerParser.parse(values,observedAt:now,verifiedAccessoryKeys:[key],opaqueKey:BluetoothAudioOpaqueIdentity.key))
        let session=BluetoothAudioSession(generation:1)
        let device=BluetoothAudioDevice(id:.init(rawValue:"independent"),name:"Audio",session:session,identityQuality:.verified,preferenceIdentity:r.verifiedPreferenceIdentity,batteryReadings:[.init(component:r.component,percent:r.percent,charging:r.charging,source:r.source,observedAt:now,session:session)],lastSeenAt:now)
        print("INDEPENDENT unknown part: component=\(r.component), summary=\(device.currentPercent(at:now) as Any), notifications=\(device.notificationReadings(at:now).count)")
        #expect(device.notificationReadings(at:now).isEmpty,"Other lacks single/combined/ear-side semantics")
        #expect(device.currentPercent(at:now)==nil,"Other must not be labeled as an explicit system aggregate")
    }
    @Test func eventBurstMustCoalesceAtMostOneSupplementalRead() async {
        let b=IndependentBackend();await b.set(d("Original"),p())
        let m=BluetoothAudioMonitor(backend:b,clock:{now},pollInterval:3600,timeout:2)
        await m.start{_ in};await b.gate()
        let pending=Task{await m.refresh()}
        while await b.calls<2 { await Task.yield() }
        for _ in 0..<30 { await b.fire();for _ in 0..<20 {await Task.yield()} }
        for _ in 0..<200 { await Task.yield() }
        let calls=await b.calls
        print("INDEPENDENT burst: \(calls-1) discovery calls after 30 events during one blocked read")
        #expect(calls<=3,"One active read plus at most one supplemental read per burst")
        await b.release();_=await pending.value;await m.stop()
    }
}
