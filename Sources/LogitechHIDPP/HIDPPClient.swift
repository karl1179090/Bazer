// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A client belongs to one logical target/session. Recreate it after receiver reconnect,
/// slot reuse, identity change or an exhausted correlation space. It never replays writes.
public actor HIDPPClient {
    private let transport: any HIDPPTransport
    public let deviceIndex: UInt8
    private let reportKinds: Set<HIDPPReportKind>
    private let featureDiscovered: @Sendable (HIDPPFeature) -> Void
    private var features: [UInt16:HIDPPFeature] = [0:HIDPPFeature(id:0,index:0,flags:0,version:0)]
    private var nextSoftwareID: UInt8 = 1
    private var lastReceivedAt: Date?
    private var active: (any HIDPPTransaction)?
    private var busy=false
    public init(transport: any HIDPPTransport,deviceIndex: UInt8,reportKinds: Set<HIDPPReportKind> = [.short,.long],featureDiscovered: @escaping @Sendable (HIDPPFeature) -> Void = { _ in }) { self.transport=transport; self.deviceIndex=deviceIndex; self.reportKinds=reportKinds; self.featureDiscovered=featureDiscovered }

    /// The returned view shares the caller's external lease. Its complete lifetime must be
    /// inside that lease; this supports controller-level read/write/readback transactions.
    public func using(transaction: any HIDPPTransaction) -> HIDPPClient { HIDPPClient(transport: LeasedTransport(transaction),deviceIndex:deviceIndex,reportKinds:reportKinds,featureDiscovered:featureDiscovered) }
    public func featureDirectory() -> [HIDPPFeature] { features.values.sorted { $0.index < $1.index } }

    private func perform<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard !busy else { throw HIDPPError.busy }; busy=true
        do {
            let lease=try await transport.acquireTransaction(); active=lease
            do { let value=try await body(); await lease.finish(); active=nil; busy=false; return value }
            catch { await lease.finish(); active=nil; busy=false; throw error }
        } catch { active=nil; busy=false; throw error }
    }
    private func call(_ command: HIDPPCommand) async throws -> [UInt8] {
        guard let active else { throw HIDPPError.busy }
        let index: UInt8
        if command.isRegister { index=0 }
        else if let entry=features[command.featureID] { index=entry.index }
        else {
            let p=try await call(.lookupFeature(command.featureID)); try require(p,3)
            guard p[0] != 0 else { throw HIDPPError.unsupportedFeature(command.featureID) }
            let feature=HIDPPFeature(id:command.featureID,index:p[0],flags:p[1],version:p[2]); features[command.featureID]=feature; featureDiscovered(feature); index=p[0]
        }
        let sw=nextSoftwareID; nextSoftwareID=nextSoftwareID == 15 ? 1 : nextSoftwareID+1
        let request=try HIDPPRequest(deviceIndex:command.isRegister ? 0xFF : deviceIndex,featureIndex:index,command:command,softwareID:sw,reportKinds:reportKinds)
        let response=try await active.exchange(request)
        switch HIDPPResponseMatcher.match(response,request:request) {
        case .response: lastReceivedAt=response.receivedAt; return response.parameters
        case .failure(let error): throw HIDPPError.protocolError(error)
        case .unrelated: throw HIDPPError.malformed("Transport returned an uncorrelated frame")
        }
    }
    public func ping(nonce: UInt8 = UInt8.random(in:1...255)) async throws -> String {
        try await perform { let p=try await call(.ping(nonce)); try require(p,3); guard p[0] >= 2 else { throw HIDPPError.invalidValue("HID++ 1.x requires its separate register adapter") }; return "\(p[0]).\(p[1])" }
    }
    public func discoverFeatures() async throws -> [HIDPPFeature] {
        try await perform {
            let root=try await call(.lookupFeature(1)); try require(root,3)
            guard root[0] > 0 else { throw HIDPPError.unsupportedFeature(1) }
            features=[0:HIDPPFeature(id:0,index:0,flags:0,version:0),1:HIDPPFeature(id:1,index:root[0],flags:root[1],version:root[2])]
            featureDiscovered(features[1]!)
            let count=try await call(.featureCount); try require(count,1)
            for index in 0...Int(count[0]) {
                let p=try await call(.featureAt(UInt8(index))); try require(p,4)
                let id=u16(p,0)
                if let old=features[id], old.index != UInt8(index) { throw HIDPPError.malformed("Duplicate feature ID at different indices") }
                features[id]=HIDPPFeature(id:id,index:UInt8(index),flags:p[2],version:p[3])
                featureDiscovered(features[id]!)
            }
            guard features[0]?.index == 0, features[1]?.index == root[0] else { throw HIDPPError.malformed("Inconsistent Root/FeatureSet table") }
            return features.values.sorted { $0.index < $1.index }
        }
    }
    public func readIdentity() async throws -> HIDPPIdentity {
        try await perform {
            var name: String?; var kind: UInt8?; var unit: [UInt8]?; var model: [UInt8]?; var tids: [String:UInt16]=[:]; var firmware: [HIDPPFirmwareEntity]=[]; var receivedAt: Date?
            if try await hasFeature(3) {
                let p=try await call(.firmwareInfo); try require(p,1); receivedAt=lastReceivedAt
                if p.count >= 13 {
                    unit=Array(p[1..<5]); model=Array(p[7..<13]); var off=7
                    for (bit,key) in [(1,"bluetooth"),(2,"bluetoothLE"),(4,"wireless"),(8,"usb")] where p[6] & UInt8(bit) != 0 {
                        guard off+1 < 13 else { throw HIDPPError.malformed("Identity transport list exceeds model field") }; tids[key]=u16(p,off); off+=2
                    }
                }
                guard p[0] <= 32 else { throw HIDPPError.malformed("Excessive firmware entity count") }
                for i in 0..<p[0] { let raw=try await call(.firmwareEntity(i)); try require(raw,8); firmware.append(HIDPPFirmwareEntity(index:i,kind:raw[0] & 15,rawBytes:raw)); receivedAt=lastReceivedAt }
            }
            if try await hasFeature(5) {
                let p=try await call(.nameLength); try require(p,1); var bytes: [UInt8]=[]
                while bytes.count < Int(p[0]) { let chunk=try await call(.nameChunk(UInt8(bytes.count))); bytes += chunk.prefix(Int(p[0])-bytes.count) }
                guard let decoded=String(bytes:bytes,encoding:.utf8) else { throw HIDPPError.malformed("Device name is not UTF-8") }; name=decoded
                let k=try await call(.deviceKind); try require(k,1); kind=k[0]; receivedAt=lastReceivedAt
            }
            return HIDPPIdentity(name:name,kind:kind,unitID:unit,modelID:model,transportIDs:tids,firmware:firmware,receivedAt:receivedAt)
        }
    }
    private func hasFeature(_ id: UInt16) async throws -> Bool {
        if features[id] != nil { return true }
        let p=try await call(.lookupFeature(id)); try require(p,3)
        guard p[0] > 0 else { return false }; let feature=HIDPPFeature(id:id,index:p[0],flags:p[1],version:p[2]); features[id]=feature; featureDiscovered(feature); return true
    }
    public func readBattery(allowADC: Bool = false) async throws -> HIDPPBattery {
        try await perform {
            for id: UInt16 in [0x1004,0x1000,0x1001] + (allowADC ? [0x1F20] : []) where try await hasFeature(id) {
                let caps = id == 0x1004 ? try await call(.battery1004Capabilities) : nil
                return try HIDPPBattery.parse(featureID:id,payload:await call(id == 0x1004 ? .battery1004 : (id == 0x1000 ? .battery1000 : (id == 0x1001 ? .battery1001 : .adcMeasurement))),unifiedCapabilities:caps)
            }
            throw HIDPPError.unsupportedFeature(0x1000)
        }
    }
    private func dpiCapabilities(sensor: UInt8) async throws -> HIDPPDPICapabilities {
        let ext=try await hasFeature(0x2202)
        let count=try await call(.sensorCount(extended:ext)); try require(count,1)
        guard sensor < count[0] else { throw HIDPPError.invalidValue("Unknown sensor") }
        var y=false; var lod=false
        if ext { let info=try await call(.sensorInfo(sensor)); try require(info,3); guard info[0] == sensor else { throw HIDPPError.malformed("Wrong sensor info") }; y=info[2] & 1 != 0; lod=info[2] & 2 != 0 }
        func values(_ direction: UInt8) async throws -> [UInt16] {
            var bytes: [UInt8]=[]; var terminated=false
            for page in 0..<(ext ? 256 : 1) {
                let p=try await call(.dpiList(sensor:sensor,direction:direction,page:UInt8(page),extended:ext)); let skip=ext ? 3 : 1
                try require(p,skip+2); guard p[0] == sensor else { throw HIDPPError.malformed("Wrong sensor DPI list") }
                let chunk=Array(p.dropFirst(skip)); bytes += chunk
                // Padding can leave an odd byte: only word-aligned zero terminates.
                terminated=stride(from:0,to:bytes.count-1,by:2).contains { bytes[$0] == 0 && bytes[$0+1] == 0 }
                if terminated || !ext { break }
            }
            return try HIDPPDPICapabilities.decodeList(bytes,requireTerminator:ext)
        }
        let xValues=try await values(0); let yValues=try await y ? values(1) : []
        return HIDPPDPICapabilities(sensor:sensor,extended:ext,supportsY:y,supportsLOD:lod,xValues:xValues,yValues:yValues)
    }
    private func dpiValue(_ caps: HIDPPDPICapabilities) async throws -> HIDPPDPI {
        let value=try HIDPPDPI.parse(await call(.dpi(sensor:caps.sensor,extended:caps.extended)),extended:caps.extended,supportsY:caps.supportsY,supportsLOD:caps.supportsLOD)
        guard value.sensor == caps.sensor else { throw HIDPPError.malformed("Wrong DPI sensor") }; return value
    }
    private func requireHostMode() async throws {
        if try await hasFeature(0x8100) { let p=try await call(.onboardMode); try require(p,1); guard p[0] == 2 else { throw HIDPPError.invalidValue("Onboard mode controls current settings; use an explicit profile edit") } }
    }
    public func readDPI(sensor: UInt8 = 0) async throws -> (HIDPPDPICapabilities,HIDPPDPI) { try await perform { let caps=try await dpiCapabilities(sensor:sensor); return (caps,try await dpiValue(caps)) } }
    public func setDPI(sensor: UInt8 = 0,x: UInt16,y: UInt16? = nil,lod: UInt8? = nil) async throws -> HIDPPDPI {
        try await perform {
            try await requireHostMode()
            let caps=try await dpiCapabilities(sensor:sensor); let before=try await dpiValue(caps)
            guard caps.xValues.contains(x), caps.supportsY || y == nil || y == x, lod == nil || caps.supportsLOD, lod.map({ $0 <= 2 }) ?? true else { throw HIDPPError.invalidValue("DPI dimensions/value exceed discovered support") }
            let actualY=caps.supportsY ? (y ?? before.effectiveY) : nil
            guard actualY.map({ caps.yValues.contains($0) }) ?? true else { throw HIDPPError.invalidValue("Y DPI exceeds discovered support") }
            _ = try await call(.setDPI(sensor:sensor,x:x,y:actualY,lod:lod ?? before.lod,extended:caps.extended))
            let after=try await dpiValue(caps)
            guard after.effectiveX == x, after.effectiveY == actualY, after.lod == (lod ?? before.lod) else { throw HIDPPError.readbackMismatch("DPI write ACK did not match actual X/Y/LOD readback") }; return after
        }
    }
    private func rateState() async throws -> ([UInt8],HIDPPReportRate) {
        let ext=try await hasFeature(0x8061)
        let codes=try HIDPPReportRate.supportedCodes(await call(.rateCapabilities(extended:ext)),extended:ext)
        let p=try await call(.rate(extended:ext)); try require(p,1); let rate=try HIDPPReportRate(code:p[0],extended:ext)
        guard codes.contains(rate.code) else { throw HIDPPError.malformed("Current report rate outside supported set") }; return (codes,rate)
    }
    public func readReportRate() async throws -> ([UInt8],HIDPPReportRate) { try await perform { try await rateState() } }
    public func setReportRate(hertz: Int) async throws -> HIDPPReportRate {
        try await perform {
            try await requireHostMode()
            let (codes,before)=try await rateState()
            guard let code=try codes.first(where: { try HIDPPReportRate(code:$0,extended:before.extended).hertz == hertz }) else { throw HIDPPError.invalidValue("Rate absent from discovered supported set") }
            _ = try await call(.setRate(code:code,extended:before.extended)); let (_,after)=try await rateState()
            guard after.code == code else { throw HIDPPError.readbackMismatch("Report rate did not read back") }; return after
        }
    }
    private func onboardInfo() async throws -> HIDPPOnboardInfo { try HIDPPOnboardInfo.parse(await call(.onboardInfo)) }
    public func readOnboardInfo() async throws -> (HIDPPOnboardInfo,UInt8,UInt16) {
        try await perform { let info=try await onboardInfo(); let mode=try await call(.onboardMode); let active=try await call(.activeProfile); try require(mode,1); try require(active,2); return (info,mode[0],u16(active,0)) }
    }
    public func readActiveDPIIndex() async throws -> UInt8 { try await perform { let p=try await call(.activeDPIIndex); try require(p,1); guard p[0] < 5 else { throw HIDPPError.malformed("Invalid active DPI index") }; return p[0] } }
    public func setActiveDPIIndex(_ index: UInt8) async throws -> UInt8 {
        try await perform {
            let mode=try await call(.onboardMode); try require(mode,1); guard mode[0] == 1 else { throw HIDPPError.invalidValue("Current onboard stage activation requires onboard mode; mode changes are explicit") }
            guard index < 5 else { throw HIDPPError.invalidValue("Invalid DPI index") }
            _=try await call(.activeDPIIndex); _=try await call(.setActiveDPIIndex(index)); let after=try await call(.activeDPIIndex); try require(after,1)
            guard after[0] == index else { throw HIDPPError.readbackMismatch("Active DPI index did not read back") }; return after[0]
        }
    }
    public func setActiveProfile(_ sector: UInt16) async throws -> UInt16 {
        try await perform {
            let mode=try await call(.onboardMode); try require(mode,1); guard mode[0] == 1 else { throw HIDPPError.invalidValue("Profile activation requires onboard mode; mode changes are explicit") }
            let info=try await onboardInfo(); let directory=try await self.sector(0,info:info)
            guard try HIDPPProfileDirectoryEntry.parse(directory).contains(where:{ $0.sector == sector && $0.enabled }) else { throw HIDPPError.invalidValue("Profile is not enabled in the writable directory") }
            _=try await call(.activeProfile); _=try await call(.setActiveProfile(sector)); let after=try await call(.activeProfile); try require(after,2)
            guard u16(after,0) == sector else { throw HIDPPError.readbackMismatch("Active profile did not read back") }; return sector
        }
    }
    /// Mode changes are explicit operations and never part of automatic discovery/read.
    public func setOnboardMode(_ mode: UInt8) async throws -> UInt8 {
        try await perform { _=try await call(.onboardMode); _=try await call(.setOnboardMode(mode)); let after=try await call(.onboardMode); try require(after,1); guard after[0] == mode else { throw HIDPPError.readbackMismatch("Onboard mode did not read back") }; return mode }
    }
    private func sector(_ number: UInt16,info: HIDPPOnboardInfo) async throws -> HIDPPProfileSector {
        guard number < UInt16(info.sectorCount) || (0x100..<(0x100+UInt16(info.romProfileCount)+1)).contains(number) else { throw HIDPPError.invalidValue("Sector outside discovered geometry") }
        var bytes: [UInt8]=[]
        let size=Int(info.sectorSize)
        while bytes.count < size {
            // 8100 rejects a window extending past the physical sector. For a
            // partial tail, overlap the previous window and append only new bytes.
            let offset=min(bytes.count,size-16)
            let chunk=try await call(.readSector(sector:number,offset:UInt16(offset))); try require(chunk,16)
            bytes += chunk.dropFirst(bytes.count-offset).prefix(size-bytes.count)
        }
        return try HIDPPProfileSector(sector:number,bytes:bytes,info:info)
    }
    public func readProfileSector(_ number: UInt16) async throws -> HIDPPProfileSector { try await perform { try await sector(number,info:onboardInfo()) } }
    /// This operation reads the complete original, patches known fields, writes, and
    /// compares the entire sector in a single receiver lease. ACK alone is not success.
    public func patchProfileSector(_ number: UInt16,expected: HIDPPProfileSector,dpi: [Int:UInt16] = [:],reportRateCode: UInt8? = nil,defaultDPIIndex: UInt8? = nil) async throws -> HIDPPProfileSector {
        try await perform {
            let info=try await onboardInfo(); let before=try await sector(number,info:info)
            guard before == expected else { throw HIDPPError.invalidValue("Profile or geometry changed since backup") }
            let directory=try await sector(0,info:info)
            let entries=try HIDPPProfileDirectoryEntry.parse(directory)
            guard entries.contains(where: { $0.sector == number && $0.enabled }) else { throw HIDPPError.invalidValue("Profile is disabled, read-only/ROM, or absent from the writable directory") }
            if !dpi.isEmpty {
                let capabilities=try await dpiCapabilities(sensor:0)
                guard dpi.values.allSatisfy({ capabilities.xValues.contains($0) }) else { throw HIDPPError.invalidValue("Profile DPI exceeds discovered sensor support") }
            }
            if let reportRateCode {
                let codes=try HIDPPReportRate.supportedCodes(await call(.rateCapabilities(extended:false)),extended:false)
                guard codes.contains(reportRateCode) else { throw HIDPPError.invalidValue("Profile rate exceeds discovered standard-period support") }
            }
            let updated=try before.patch(dpi:dpi,reportRateCode:reportRateCode,defaultDPIIndex:defaultDPIIndex)
            if updated.bytes == before.bytes { return before }
            let commands=try updated.writePlan().commands
            var chunks=0; var stage="start"
            do {
                _ = try await call(commands[0]); stage="data"
                for command in commands.dropFirst().dropLast() { _ = try await call(command); chunks+=1 }
                stage="end"; _ = try await call(commands[commands.count-1]); stage="readback"
                let actual=try await sector(number,info:info)
                guard actual.bytes == updated.bytes else { throw HIDPPError.readbackMismatch("Full sector differs from patched backup") }; return actual
            } catch { throw HIDPPError.interruptedWrite(completedChunks:chunks,stage:stage,reason:String(describing:error)) }
        }
    }
    /// Variant is selected from a receiver profile/descriptor, never inferred from a mouse name.
    /// Only the runtime-reported bounded slot count is inspected; no ping scan or notify write.
    public func discoverReceiverChildren(variant: HIDPPReceiverVariant) async throws -> [HIDPPReceiverChild] {
        guard variant != .unknown else { throw HIDPPError.invalidValue("Receiver variant is unknown") }
        return try await perform { try await receiverChildren(variant:variant) }
    }
    /// A successful runtime 2B5/03 response proves the bounded legacy register layout,
    /// without labelling an unidentified receiver Unifying or LIGHTSPEED.
    public func discoverLegacyReceiverChildren() async throws -> [HIDPPReceiverChild] {
        try await perform { try await receiverChildren(variant:.unifying) }
    }
    private func receiverChildren(variant: HIDPPReceiverVariant) async throws -> [HIDPPReceiverChild] {
            let info=try await call(.receiverInformation); try require(info,7)
            let maximum=info[6]; guard (1...6).contains(maximum) else { throw HIDPPError.malformed("Receiver did not report a safe slot bound; use observed connection notifications") }
            var children: [HIDPPReceiverChild]=[]
            for slot in 1...maximum {
                do { let p=try await call(.pairing(slot:slot,variant:variant)); children.append(try HIDPPReceiverChild.pairing(p,slot:slot,variant:variant)) }
                catch HIDPPError.protocolError(let error) where error.style == .register && [2,8].contains(error.code) { continue }
            }
            return children
    }
}

private struct LeasedTransport: HIDPPTransport {
    let transaction: any HIDPPTransaction
    init(_ transaction: any HIDPPTransaction) { self.transaction=transaction }
    func exchange(_ request: HIDPPRequest) async throws -> HIDPPMessage { try await transaction.exchange(request) }
    func acquireTransaction() async throws -> any HIDPPTransaction { BorrowedTransaction(transaction:transaction) }
}
private struct BorrowedTransaction: HIDPPTransaction {
    let transaction: any HIDPPTransaction
    func exchange(_ request: HIDPPRequest) async throws -> HIDPPMessage { try await transaction.exchange(request) }
    func finish() async {}
}
