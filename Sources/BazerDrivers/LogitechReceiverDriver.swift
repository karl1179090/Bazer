// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import Foundation
import LogitechHIDPP

public protocol LogitechSessionTransport: HIDPPTransport {
    func notifications() async -> AsyncStream<HIDPPMessage>
    func close() async
    func controlTrace() async -> [HIDPPControlTrace]
    func controlTraceSnapshot() async -> HIDPPControlTraceSnapshot
}
public extension LogitechSessionTransport {
    func controlTrace() async -> [HIDPPControlTrace] { [] }
    func controlTraceSnapshot() async -> HIDPPControlTraceSnapshot { HIDPPControlTraceSnapshot(entries:await controlTrace(),capacity:0,droppedCount:0) }
}
extension HIDInputOutputSession: LogitechSessionTransport {}

/// One immutable host generation is shared by all logical children and settings.
/// Receiver PID only selects a receiver protocol variant; it never identifies a mouse.
public actor LogitechReceiverDriver: DeviceLogicalDriver, DeviceSettingsValidationAuthorizing, DeviceProfileBacking {
    public typealias SessionFactory = @Sendable (HIDInputOutputEndpoint,@escaping @Sendable (HIDPPRequest) throws -> Void) -> any LogitechSessionTransport
    private let sessionFactory: SessionFactory
    private let variant: @Sendable (PhysicalDeviceDescriptor) -> HIDPPReceiverVariant
    private var hosts: [DeviceSessionID:Host]=[:]
    private var hostLifecycles: [DeviceSessionID:UUID]=[:]
    private var hostClosures: [DeviceSessionID:(id:UUID,task:Task<Void,Never>)]=[:]
    private var receiverBootstrap: [DeviceSessionID:[UInt8:HIDPPReceiverChild]]=[:]
    private var validationIntents: [UUID:SettingValidationAuthorization]=[:]
    private var rawRates: [DeviceAddress:HIDPPReportRate]=[:]
    private var discoveryObservers: [UUID:AsyncStream<DeviceSessionID>.Continuation]=[:]
    private struct Child {
        let descriptor: LogicalDeviceDescriptor, client: HIDPPClient, features: [HIDPPFeature], firmware: [HIDPPFirmwareEntity]
        let identity: LogicalPeripheralIdentity
        var identityReceivedAt: Date?
        let allowsADC: Bool
    }
    private struct CapabilityDiscovery {
        let capabilities: DeviceCapabilities
        let observation: LogitechHardwareObservation?
    }
    private struct SettingsObservation {
        let settings: DeviceSettings
        let onboardInfo: HIDPPOnboardInfo?
        let profileInfo: HIDPPOnboardInfo?
        let onboardMode: UInt8?
        func matchesMetadata(_ ordinary: LogitechHardwareObservation) -> Bool {
            onboardInfo == ordinary.onboardInfo && profileInfo == ordinary.onboardInfo
                && onboardMode == ordinary.onboardMode && settings.activeProfileID == Int(ordinary.profile.sector)
        }
    }
    private struct Host {
        let epoch=UUID()
        var discoveryGeneration=UUID()
        let descriptor: PhysicalDeviceDescriptor, endpoint: HIDInputOutputEndpoint, transport: any LogitechSessionTransport, policy: LogitechCommandPolicy
        var children: [LogicalDeviceID:Child]=[:]
        var offlineChildren: [LogicalDeviceID:Child]=[:]
        var observed: [UInt8:HIDPPReceiverChild]=[:]
        var observer: Task<Void,Never>?
    }
    public init(sessionFactory: SessionFactory? = nil,receiverVariant: @escaping @Sendable (PhysicalDeviceDescriptor) -> HIDPPReceiverVariant = LogitechReceiverDriver.receiverVariant,controlTraceCapacity: Int = 0) { self.sessionFactory=sessionFactory ?? { endpoint,authorize in HIDInputOutputSession(endpoint:endpoint,traceCapacity:controlTraceCapacity,authorize:authorize) }; variant=receiverVariant }
    public static func receiverVariant(_ host: PhysicalDeviceDescriptor) -> HIDPPReceiverVariant {
        // Names/PIDs are catalogue clues only. Runtime legacy-register responses or
        // an explicit inspected receiver-variant selection establish the protocol.
        return .unknown
    }
    public static func identify(_ device: PhysicalDeviceDescriptor) -> IdentifiedDevice? {
        guard device.vendorID == 0x046D, device.isExternalUSB,
              device.interfaces.allSatisfy({ $0.vendorID == 0x046D && $0.productID == device.productID }) else { return nil }
        let candidates=device.interfaces.compactMap { try? HIDInputOutputEndpoint(physicalDeviceID:device.id,descriptor:$0) }
        guard candidates.count == 1 else { return nil }
        return IdentifiedDevice(descriptor:device,kind:.other,capabilities:.identificationOnly,controlEndpointRegistryEntryID:candidates[0].descriptor.registryEntryID,isReceiver:true)
    }
    public func discoverTargets(host: PhysicalDeviceDescriptor,session: DeviceSessionID) async throws -> [LogicalDeviceDescriptor] {
        let lifecycle=hostLifecycles[session] ?? UUID(); hostLifecycles[session]=lifecycle
        let context=try await openHost(host,session:session,lifecycle:lifecycle)
        do { return try await discoverTargets(context:context,session:session,canRebuild:true) }
        catch where Self.requiresSessionRebuild(error) {
            // Closed transports and quarantined correlations cannot be reused.
            // This invocation may recreate the read-only transport only once.
            guard await discardHost(session,epoch:context.epoch,preserveObserved:true), hostLifecycles[session] == lifecycle else { throw failure(.removed,"Host changed during read-only recovery") }
            let rebuilt=try await openHost(host,session:session,lifecycle:lifecycle)
            return try await discoverTargets(context:rebuilt,session:session,canRebuild:false)
        }
    }
    private func openHost(_ host: PhysicalDeviceDescriptor,session: DeviceSessionID,lifecycle: UUID) async throws -> Host {
        if let closing=hostClosures[session] { await closing.task.value }
        guard hostLifecycles[session] == lifecycle else { throw failure(.removed,"Host invalidated before transport recreation") }
        if hosts[session] == nil {
            let candidates=host.interfaces.compactMap { try? HIDInputOutputEndpoint(physicalDeviceID:host.id,descriptor:$0) }
            guard candidates.count == 1 else { throw failure(.unsupported,"No unique descriptor-confirmed HID++ endpoint") }
            let endpoint=candidates[0], policy=LogitechCommandPolicy()
            let transport=sessionFactory(endpoint,{ try policy.authorize($0) })
            let context=Host(descriptor:host,endpoint:endpoint,transport:transport,policy:policy,observed:receiverBootstrap[session] ?? [:])
            hosts[session]=context
            let stream=await transport.notifications()
            guard hosts[session]?.epoch == context.epoch else { throw failure(.removed,"Host invalidated while subscribing to notifications") }
            let observer=Task { [weak self] in for await message in stream { await self?.connection(message,hostSession:session,epoch:context.epoch) } }
            hosts[session]?.observer=observer
        }
        guard let context=hosts[session] else { throw failure(.removed,"Receiver session ended") }
        return context
    }
    private func discoverTargets(context: Host,session: DeviceSessionID,canRebuild: Bool) async throws -> [LogicalDeviceDescriptor] {
        let host=context.descriptor
        let receiver=HIDPPClient(transport:context.transport,deviceIndex:0xFF,reportKinds:context.endpoint.reportKinds)
        let selectedVariant=variant(host)
        var addresses: [(UInt8,HIDPPReceiverChild?)]=[]
        if selectedVariant != .unknown {
            let pairings=try await receiver.discoverReceiverChildren(variant:selectedVariant)
            addresses=pairings.map { ($0.slot,$0) }
        } else if !context.observed.isEmpty {
            addresses=context.observed.values.filter { $0.online != false }.map { ($0.slot,$0) }
        } else {
            // Root FF is an explicit direct/receiver address, not a guessed child slot.
            // A receiver that only speaks 1.x here will return its structured error.
            do { addresses=try await receiver.discoverLegacyReceiverChildren().map { ($0.slot,$0) } }
            catch HIDPPError.protocolError(let error) where error.style == .register && [1,2,8].contains(error.code) { _=try await receiver.ping(); addresses=[(0xFF,nil)] }
        }
        var discovered: [LogicalDeviceID:Child]=[:]
        for (index,pairing) in addresses.sorted(by:{ $0.0 < $1.0 }) {
            guard hosts[session]?.epoch == context.epoch, hosts[session]?.discoveryGeneration == context.discoveryGeneration else { throw failure(.removed,"Host generation changed during child discovery") }
            context.policy.allowTarget(index)
            let client=HIDPPClient(transport:context.transport,deviceIndex:index,reportKinds:context.endpoint.reportKinds,featureDiscovered:{ context.policy.record($0,for:index) })
            do {
            let version=try await client.ping(); let features=try await client.discoverFeatures(); let info=try await client.readIdentity()
            let headsetProfile=Self.headsetADCProfile(host,kind:info.kind)
            guard index != 0xFF || [0,2,3,5].contains(info.kind) || headsetProfile else { throw failure(.unsupported,"FF Root reply did not identify a supported direct peripheral") }
            if let expected=pairing?.wirelessProductID, let actual=info.transportIDs["wireless"], expected != actual { throw failure(.malformedResponse,"Pairing WPID and peripheral identity disagree") }
            let firmware=info.firmware.map { "\($0.kind):" + $0.rawBytes.map { String(format:"%02X",$0) }.joined() }.joined(separator:";")
            let unit=info.unitID.flatMap { $0.allSatisfy({ $0 == 0 || $0 == 255 }) ? nil : $0.map { String(format:"%02X",$0) }.joined() }
            let identity=LogicalPeripheralIdentity(vendorID:0x046D,wirelessProductID:info.transportIDs["wireless"] ?? pairing?.wirelessProductID,unitID:unit,protocolVersion:version,firmware:firmware.isEmpty ? nil : firmware)
            let address=index == 0xFF ? DeviceAddress(hostSessionID:session,target:.direct,pairingGeneration:UUID()) : DeviceAddress(hostSessionID:session,target:.receiver(index:index,identity:identity),pairingGeneration:UUID())
            let kind: DeviceKind
            if let actualKind=info.kind { kind=[0,2].contains(actualKind) ? .keyboard : ([3,5].contains(actualKind) ? .mouse : .other) }
            else { kind=pairing?.kind == 1 ? .keyboard : (pairing?.kind == 2 ? .mouse : .other) }
            let allowsADC=index == 0xFF && headsetProfile && features.contains(where:{ $0.id == 0x1F20 })
            let exactCatalog=index == 0xFF ? DeviceCatalog.matchUSB(vendorID:host.vendorID ?? 0,productID:host.productID ?? 0) : nil
            let power=exactCatalog?.entry.kind.deviceKind == kind ? (exactCatalog?.variant.powerSource ?? .unknown) : .unknown
            let reliableIdentity=unit != nil && info.receivedAt != nil && !info.firmware.isEmpty && info.transportIDs["wireless"] != nil && info.kind != nil
            let capabilities=try await capabilities(client:client,features:features,name:info.name ?? host.product,kind:kind,powerSource:power,allowsADC:allowsADC,
                host:context,identity:identity,identityIsReliable:reliableIdentity,isReceiver:index != 0xFF).capabilities
            guard hosts[session]?.epoch == context.epoch, hosts[session]?.discoveryGeneration == context.discoveryGeneration else { throw failure(.removed,"Discarded old transport child handshake") }
            let descriptor=LogicalDeviceDescriptor(address:address,product:info.name ?? "Logitech device \(index)",kind:kind,capabilities:capabilities,controlEndpointRegistryEntryID:context.endpoint.descriptor.registryEntryID,preferenceIdentity:DevicePreferenceIdentity.confirmedLogicalUnit(identity),peripheralIdentity:identity,peerPresence:.reachable)
            discovered[descriptor.id]=Child(descriptor:descriptor,client:client,features:features,firmware:info.firmware,identity:identity,identityReceivedAt:info.receivedAt,allowsADC:allowsADC)
            } catch {
                guard hosts[session]?.epoch == context.epoch, hosts[session]?.discoveryGeneration == context.discoveryGeneration else { throw failure(.removed,"Host generation ended during child handshake") }
                if Self.requiresSessionRebuild(error), canRebuild { throw error }
                guard let pairing else { throw error }
                // A transient read-only handshake failure is not a replacement.
                // Connection events remove the old child first, so a reused slot
                // cannot reach this preservation path.
                if let previous = context.children.values.first(where: { child in
                    if case .receiver(let slot,_) = child.descriptor.address.target { return slot == index }
                    return index == 0xFF
                }) {
                    discovered[previous.descriptor.id] = previous
                    continue
                }
                context.policy.removeTarget(index)
                let identity=LogicalPeripheralIdentity(vendorID:0x046D,wirelessProductID:pairing.wirelessProductID)
                let address=DeviceAddress(hostSessionID:session,target:.receiver(index:index,identity:identity),pairingGeneration:UUID())
                let capability=OperationCapability(evidence:.unknown,source:"runtime receiver pairing record; peripheral handshake incomplete",failureReason:String(describing:error))
                let descriptor=LogicalDeviceDescriptor(address:address,product:"Logitech paired device (slot \(index))",kind:pairing.kind == 1 ? .keyboard : (pairing.kind == 2 ? .mouse : .other),capabilities:DeviceCapabilities(operations:[.batteryRead:capability]),controlEndpointRegistryEntryID:context.endpoint.descriptor.registryEntryID)
                discovered[descriptor.id]=Child(descriptor:descriptor,client:client,features:[],firmware:[],identity:identity,identityReceivedAt:nil,allowsADC:false)
            }
        }
        guard hosts[session]?.epoch == context.epoch, hosts[session]?.discoveryGeneration == context.discoveryGeneration else { throw failure(.removed,"Discarded discovery after host invalidation") }
        hosts[session]?.children=discovered
        let offline: [LogicalDeviceDescriptor] = (hosts[session]?.offlineChildren.values.map { child in
            let d = child.descriptor
            return LogicalDeviceDescriptor(address:d.address,product:d.product,kind:d.kind,capabilities:d.capabilities,
                controlEndpointRegistryEntryID:d.controlEndpointRegistryEntryID,preferenceIdentity:d.preferenceIdentity,
                peripheralIdentity:d.peripheralIdentity,isIdentityAmbiguous:d.isIdentityAmbiguous,peerPresence:.unreachable)
        }) ?? []
        return (discovered.values.map(\.descriptor) + offline).sorted { $0.id < $1.id }
    }
    private func connection(_ message: HIDPPMessage,hostSession: DeviceSessionID,epoch: UUID) {
        guard var host=hosts[hostSession], host.epoch == epoch, let child=try? HIDPPReceiverChild.notification(message,variant:variant(host.descriptor) == .lightspeed ? .lightspeed : .unifying) else { return }
        host.observed[child.slot]=child
        host.discoveryGeneration=UUID()
        // WPID cannot prove a reused slot still refers to the same physical unit.
        let removed=host.children.filter { entry in if case .receiver(let index,_)=entry.value.descriptor.address.target { return index == child.slot }; return false }
        for (id,previous) in removed {
            if child.online == false { host.offlineChildren[id] = previous }
            else { host.offlineChildren.removeValue(forKey:id) }
            host.children.removeValue(forKey:id)
        }
        if child.online != false {
            host.offlineChildren = host.offlineChildren.filter { entry in
                if case .receiver(let index,_) = entry.value.descriptor.address.target { return index != child.slot }
                return true
            }
        }
        host.policy.removeTarget(child.slot)
        validationIntents=validationIntents.filter { $0.value.target.address.hostSessionID != hostSession || !removed.keys.contains($0.value.target.deviceID) }
        rawRates=rawRates.filter { entry in !removed.values.contains(where:{ $0.descriptor.address == entry.key }) }
        hosts[hostSession]=host
        for observer in discoveryObservers.values { observer.yield(hostSession) }
    }
    private static func headsetADCProfile(_ host: PhysicalDeviceDescriptor,kind: UInt8?) -> Bool {
        guard let pid=host.productID, [0x0A66,0x0A87,0x0AB5].contains(pid),
              let match=DeviceCatalog.matchUSB(vendorID:host.vendorID ?? 0,productID:pid),match.entry.kind == .headset else { return false }
        return kind == nil || ![0,2,3,5,7].contains(kind!)
    }
    private func capabilities(client: HIDPPClient,features: [HIDPPFeature],name: String,kind: DeviceKind,powerSource: PowerSource,allowsADC: Bool,
                              host: Host,identity: LogicalPeripheralIdentity,identityIsReliable: Bool,isReceiver: Bool) async throws -> CapabilityDiscovery {
        let ids=Set(features.map(\.id)); var operations: [DeviceOperation:OperationCapability]=[:]
        var observedDPI: (HIDPPDPICapabilities,HIDPPDPI)?, observedRate: ([Int],HIDPPReportRate)?
        var hardwareObservation: LogitechHardwareObservation?
        func capability(_ constraints: CapabilityConstraints = CapabilityConstraints()) -> OperationCapability { OperationCapability(evidence:.discovered,constraints:constraints,source:"runtime HID++ feature discovery; writes await validation") }
        let battery = powerSource != .wired && (!ids.isDisjoint(with:[0x1000,0x1001,0x1004]) || allowsADC)
        if battery { operations[.batteryRead]=capability(); operations[.chargingRead]=capability() }
        if powerSource != .wired, ids.contains(0x1001) || allowsADC { operations[.voltageRead]=capability() }
        if kind == .mouse, ids.contains(0x2201) || ids.contains(0x2202) {
            do {
                let (caps,value)=try await client.readDPI(); observedDPI=(caps,value)
                let domain=CapabilityConstraints(allowedValues:caps.xValues.map(Int.init),persistenceScopes:[.runtime])
                operations[.dpiRead]=capability(domain); operations[.dpiWrite]=capability(domain)
                if caps.supportsY { operations[.independentXY]=capability(CapabilityConstraints(allowedValues:caps.yValues.map(Int.init),persistenceScopes:[.runtime])) }
            } catch { if Self.requiresSessionRebuild(error) { throw error }; operations[.dpiRead]=OperationCapability(evidence:.discovered,source:"runtime feature",failureReason:String(describing:error)) }
        }
        if kind == .mouse, ids.contains(0x8060) || ids.contains(0x8061) {
            do {
                let (codes,rate)=try await client.readReportRate(); let actualRates=try codes.map { try HIDPPReportRate(code:$0,extended:rate.extended).hertz }
                observedRate=(actualRates,rate); let rates=actualRates.filter { !Self.isGPW1(name) || $0 <= 1000 }
                let domain=CapabilityConstraints(allowedValues:rates,persistenceScopes:[.runtime]); operations[.pollingRateRead]=capability(domain); operations[.pollingRateWrite]=capability(domain)
            } catch { if Self.requiresSessionRebuild(error) { throw error }; operations[.pollingRateRead]=OperationCapability(evidence:.discovered,source:"runtime feature",failureReason:String(describing:error)) }
        }
        if kind == .mouse, ids.contains(0x8100) {
            operations[.onboardRead]=capability()
            do {
                let (info,mode,active)=try await client.readOnboardInfo()
                let directory=try await client.readProfileSector(0)
                let entries=try HIDPPProfileDirectoryEntry.parse(directory).filter(\.enabled)
                operations[.onboardWrite]=capability(CapabilityConstraints(allowedValues:entries.map { Int($0.sector) },persistenceScopes:[.runtime]))
                if info.knownLayout {
                    let profile=try await client.readProfileSector(active); let stageIDs=(profile.dpiValues ?? []).enumerated().filter { $0.element > 0 }.map(\.offset)
                    operations[.stagesRead]=capability()
                    operations[.stageSelect]=capability(CapabilityConstraints(allowedValues:stageIDs,persistenceScopes:[.runtime]))
                    if info.knownWritableLayout {
                        operations[.stagesWrite]=capability(CapabilityConstraints(allowedValues:operations[.dpiRead]?.constraints.allowedValues ?? [],maximumStages:5,persistenceScopes:[.onboard]))
                        operations[.onboardPersist]=capability(CapabilityConstraints(persistenceScopes:[.onboard]))
                    }
                    if let (dpiCaps,dpi)=observedDPI, let (rates,rate)=observedRate {
                        let currentStage=try await client.readActiveDPIIndex()
                        hardwareObservation=LogitechHardwareObservation(hostVendorID:host.descriptor.vendorID,hostProductID:host.descriptor.productID,
                            controlDescriptorSHA256:host.endpoint.descriptor.descriptorSHA256,peripheralVendorID:identity.vendorID,
                            wirelessProductID:identity.wirelessProductID,protocolVersion:identity.protocolVersion,
                            firmwareSHA256:LogitechVerifiedHardwareProfile.firmwareSHA256(identity.firmware),isReceiver:isReceiver,identityIsReliable:identityIsReliable,
                            features:features,dpiValues:dpiCaps.xValues,supportsIndependentXY:dpiCaps.supportsY,
                            currentDPI:DPISetting(x:dpi.effectiveX,y:dpi.effectiveY ?? dpi.effectiveX),rateValues:rates,currentRate:rate,
                            onboardInfo:info,onboardMode:mode,directory:directory,profile:profile,currentStageID:currentStage)
                    }
                }
            } catch { if Self.requiresSessionRebuild(error) { throw error }; operations[.onboardRead]=OperationCapability(evidence:.discovered,source:"runtime feature",failureReason:String(describing:error)) }
        }
        if powerSource == .replaceableBattery { operations.removeValue(forKey:.chargingRead) }
        let discovered=DeviceCapabilities(battery:battery ? .candidate : .unsupported,chargingQuery:battery && powerSource != .replaceableBattery,powerSource:powerSource,operations:operations)
        return CapabilityDiscovery(capabilities:hardwareObservation.map { LogitechVerifiedHardwareProfile.promoting(discovered,observation:$0) } ?? discovered,observation:hardwareObservation)
    }
    private static func isGPW1(_ name: String) -> Bool { ["pro wireless","g pro wireless gaming mouse","pro wireless gaming mouse"].contains(name.lowercased()) }
    private func child(_ target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) throws -> (Host,Child) {
        guard target.address == session.address, let host=hosts[session.address.hostSessionID], let child=host.children[target.id], child.descriptor.address == target.address else { throw failure(.removed,"Logical target/session generation is stale") }; return (host,child)
    }
    public func readTelemetry(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) async -> LogicalDeviceTelemetryResult {
        let started=Date()
        var attemptedHost: Host?
        do {
            let (host,child)=try child(target,session:session); attemptedHost=host; let lease=try await host.transport.acquireTransaction()
            let client=await child.client.using(transaction:lease)
            let value: HIDPPBattery, currentIdentity: HIDPPIdentity
            let currentFeatures: [HIDPPFeature]
            do { currentIdentity=try await verifyIdentity(client:client,child:child,session:session,forWriting:false); value=try await client.readBattery(allowADC:child.allowsADC); currentFeatures=await client.featureDirectory(); await lease.finish() }
            catch { await lease.finish(); throw error }
            _=try self.child(target,session:session)
            let battery: BatteryValue
            switch value.level { case .percentage(let number): battery = .percentage(number); case .voltage(let mv): battery = .voltageOnly(millivolts:mv); case .approximate(let flag): battery = .approximateLevel([1:.critical,2:.low,4:.good,8:.full][flag] ?? .unknown); case .unknown: battery = .unknown }
            let charging: ChargingState
            if target.capabilities.powerSource == .replaceableBattery { charging = .notApplicable }
            else if value.featureID == 0x1F20 { charging=value.status & 1 == 0 ? .unknown : (value.status & 2 != 0 ? .charging : .discharging) }
            else if value.featureID == 0x1001 {
                if value.status & 0x80 == 0 { charging = .discharging }
                else { charging=[0:value.status & 0x10 == 0 ? .charging : .slow,1:.full,2:.notCharging,7:.error][value.status & 7] ?? .unknown }
            }
            else { charging=[0:.discharging,1:.charging,2:.charging,3:.full,4:.slow,5:.error,6:.error][value.status] ?? .unknown }
            let now=Date(), source=String(format:"HID++ %04X runtime feature",value.featureID)
            let isReceiver: Bool; if case .receiver=child.descriptor.address.target { isReceiver=true } else { isReceiver=false }
            let currentKind: DeviceKind=currentIdentity.kind.map { [3,5].contains($0) ? .mouse : ([0,2].contains($0) ? .keyboard : .other) } ?? .other
            let estimateContext=LogitechBatteryEstimateContext(hostVendorID:host.descriptor.vendorID,hostProductID:host.descriptor.productID,
                controlDescriptorSHA256:host.endpoint.descriptor.descriptorSHA256,identity:child.identity,isReceiver:isReceiver,
                identityIsReliable:!child.descriptor.isIdentityAmbiguous && child.identity.unitID != nil && currentIdentity.receivedAt != nil
                    && currentIdentity.transportIDs["wireless"] == child.identity.wirelessProductID && currentIdentity.kind != nil,
                kind:currentKind,features:currentFeatures)
            let estimate=LogitechBatteryPercentageEstimator.estimate(for:value,context:estimateContext)
            return LogicalDeviceTelemetryResult(session:session,update:DeviceTelemetryUpdate(startedAt:started,finishedAt:now,battery:BatterySample(value:battery,rawBytes:value.rawBytes,receivedAt:now,source:source,percentageEstimate:estimate),batteryFailure:nil,charging:ChargingSample(state:charging,rawValue:value.status,receivedAt:now,source:source),chargingFailure:nil))
        } catch { if let attemptedHost { await requestReadOnlyRediscovery(after:error,host:attemptedHost,session:session.address.hostSessionID) }; let failure=Self.map(error); return LogicalDeviceTelemetryResult(session:session,update:DeviceTelemetryUpdate(startedAt:started,finishedAt:Date(),battery:nil,batteryFailure:failure,charging:nil,chargingFailure:failure)) }
    }
    private static func requiresSessionRebuild(_ error: any Error) -> Bool {
        switch error {
        case HIDPPError.sessionRebuildRequired, HIDPPError.closed: return true
        default: return false
        }
    }
    /// Invalidate before awaiting native teardown, so no old child, grant, callback or
    /// delayed discovery result can be accepted by the replacement transport epoch.
    private func discardHost(_ session: DeviceSessionID,epoch: UUID,preserveObserved: Bool) async -> Bool {
        guard let host=hosts[session], host.epoch == epoch else { return false }
        hosts.removeValue(forKey:session); host.policy.invalidate(); host.observer?.cancel()
        if preserveObserved { receiverBootstrap[session]=host.observed }
        validationIntents=validationIntents.filter { $0.value.target.address.hostSessionID != session }
        rawRates=rawRates.filter { $0.key.hostSessionID != session }
        let id=UUID(), task=Task<Void,Never> { await host.transport.close(); if let observer=host.observer { await observer.value } }
        hostClosures[session]=(id,task)
        await task.value
        if hostClosures[session]?.id == id { hostClosures.removeValue(forKey:session) }
        return true
    }
    private func requestReadOnlyRediscovery(after error: any Error,host: Host,session: DeviceSessionID) async {
        guard Self.requiresSessionRebuild(error), let lifecycle=hostLifecycles[session],
              await discardHost(session,epoch:host.epoch,preserveObserved:true), hostLifecycles[session] == lifecycle else { return }
        for observer in discoveryObservers.values { observer.yield(session) }
    }
    public func invalidateHost(_ session: DeviceSessionID) async {
        hostLifecycles.removeValue(forKey:session); receiverBootstrap.removeValue(forKey:session)
        validationIntents=validationIntents.filter { $0.value.target.address.hostSessionID != session }
        rawRates=rawRates.filter { $0.key.hostSessionID != session }
        if let host=hosts[session] { _=await discardHost(session,epoch:host.epoch,preserveObserved:false) }
        else if let closing=hostClosures[session] { await closing.task.value }
    }
    public func discoveryEvents() async -> AsyncStream<DeviceSessionID> {
        let id=UUID(); let (stream,continuation)=AsyncStream<DeviceSessionID>.makeStream(bufferingPolicy:.bufferingNewest(16))
        discoveryObservers[id]=continuation; continuation.onTermination={ [weak self] _ in Task { await self?.removeDiscoveryObserver(id) } }; return stream
    }
    private func removeDiscoveryObserver(_ id: UUID) { discoveryObservers.removeValue(forKey:id) }
    public func stop() async { for id in Set(hosts.keys).union(hostLifecycles.keys).union(hostClosures.keys) { await invalidateHost(id) }; discoveryObservers.values.forEach { $0.finish() }; discoveryObservers=[:] }
    private func failure(_ category: TelemetryFailureCategory,_ message: String) -> TelemetryFailure { TelemetryFailure(category:category,message:message,operation:"logitech") }
    static func map(_ error: any Error) -> TelemetryFailure {
        if let error=error as? TelemetryFailure { return error }
        if case HIDPPError.ioFailure(let diagnostic)=error {
            let category: TelemetryFailureCategory
            switch UInt32(bitPattern:diagnostic.rawIOReturn) { case 0xE00002C1,0xE00002E2: category = .denied; case 0xE00002D6: category = .timeout; case 0xE00002D7,0xE00002D9,0xE00002C0: category = .removed; case 0xE00002C5,0xE00002D5: category = .busy; default: category = .transport }
            return TelemetryFailure(category:category,message:"HID++ native \(diagnostic.phase) failed",ioReturn:diagnostic.rawIOReturn,operation:diagnostic.phase,endpointRegistryEntryID:diagnostic.endpointRegistryEntryID)
        }
        let category: TelemetryFailureCategory
        switch error { case HIDPPError.timeout: category = .timeout; case HIDPPError.cancelled, is CancellationError: category = .cancelled; case HIDPPError.busy: category = .busy; case HIDPPError.closed, HIDPPError.sessionRebuildRequired: category = .removed; case HIDPPError.invalidValue, HIDPPError.unsupportedFeature: category = .unsupported; case HIDPPError.malformed: category = .malformedResponse; default: category = .transport }
        return TelemetryFailure(category:category,message:String(describing:error),operation:"logitech")
    }
}

extension LogitechReceiverDriver {
    public func exportProfile(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID,saveTo: URL,hardwareEvidenceReference: String? = nil) async throws -> ProfileBackup {
        let backup=try await captureBackup(target:target,session:session,hardwareEvidenceReference:hardwareEvidenceReference)
        try FileProfileBackup(url:saveTo).save(backup); return backup
    }
    private func captureBackup(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID,hardwareEvidenceReference: String?) async throws -> ProfileBackup {
        guard !target.isIdentityAmbiguous else { throw failure(.unsupported,"Ambiguous peripheral identity cannot authorize a strong recovery backup or restore") }
        let (host,child)=try self.child(target,session:session); let lease=try await host.transport.acquireTransaction(); let client=await child.client.using(transaction:lease)
        do {
            try await verifyIdentity(client:client,child:child,session:session,forWriting:false)
            let (info,mode,active)=try await client.readOnboardInfo()
            let directory=try await client.readProfileSector(0); let profile=try await client.readProfileSector(active); let activeDPI=try await client.readActiveDPIIndex()
            _=try self.child(target,session:session)
            let identity=ProfileBackupIdentity(vendorID:0x046D,productID:host.descriptor.productID,wirelessProductID:child.identity.wirelessProductID,unitID:child.identity.unitID,firmware:child.identity.firmware,formatID:"logitech.hidpp8100.profile\(info.profileFormat)",formatVersion:1,descriptorSHA256:host.endpoint.descriptor.descriptorSHA256)
            let backup=ProfileBackup(capturedAt:Date(),identity:identity,session:session,activeProfileID:Int(active),regions:[ProfileBackupRegion(id:"info",bytes:info.rawBytes),ProfileBackupRegion(id:"mode",bytes:[mode]),ProfileBackupRegion(id:"active-dpi-index",bytes:[activeDPI]),ProfileBackupRegion(id:"directory:0",bytes:directory.bytes),ProfileBackupRegion(id:"profile:\(active)",bytes:profile.bytes)],hardwareEvidenceReference:hardwareEvidenceReference)
            await lease.finish(); return backup
        } catch { await lease.finish(); await requestReadOnlyRediscovery(after:error,host:host,session:session.address.hostSessionID); throw error }
    }
    /// Restore prepares known fields only. It never transmits saved button/macro/LED
    /// bytes, changes a mode, or switches the active profile as an implicit side effect.
    public func prepareRestore(backupURL: URL,rollbackBackupURL: URL,target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID,hardwareEvidenceReference: String? = nil) async throws -> DeviceSettingsChange {
        let saved=try FileProfileBackup(url:backupURL).load()
        let current=try await captureBackup(target:target,session:session,hardwareEvidenceReference:hardwareEvidenceReference)
        try saved.validateRestore(to:current.identity,session:session,expectedRegionLengths:Dictionary(uniqueKeysWithValues:current.regions.map { ($0.id,$0.bytes.count) }))
        let old=Dictionary(uniqueKeysWithValues:saved.regions.map { ($0.id,$0.bytes) }), now=Dictionary(uniqueKeysWithValues:current.regions.map { ($0.id,$0.bytes) })
        guard saved.activeProfileID == current.activeProfileID, old["info"] == now["info"], old["mode"] == now["mode"], old["directory:0"] == now["directory:0"],
              let number=current.activeProfileID, let oldBytes=old["profile:\(number)"], let currentBytes=now["profile:\(number)"], let infoBytes=now["info"],
              let oldActive=old["active-dpi-index"]?.first else { throw ProfileBackupError.regionLayoutMismatch }
        let info=try HIDPPOnboardInfo.parse(infoBytes)
        guard info.knownWritableLayout else { throw ProfileBackupError.unknownFormat }
        let original=try HIDPPProfileSector(sector:UInt16(number),bytes:oldBytes,info:info)
        _=try HIDPPProfileSector(sector:UInt16(number),bytes:currentBytes,info:info)
        for index in 0..<currentBytes.count where !(index == 0 || index == 1 || (3..<13).contains(index) || index >= currentBytes.count-2) {
            guard original.bytes[index] == currentBytes[index] else { throw failure(.unsupported,"Backup differs in uneditable profile bytes; generic raw restore is forbidden") }
        }
        let stages=(original.dpiValues ?? []).enumerated().filter { $0.element > 0 }.map { DPIStage(id:UInt8($0.offset),dpi:DPISetting($0.element)) }
        guard stages.contains(where:{ $0.id == oldActive }) else { throw ProfileBackupError.regionLayoutMismatch }
        guard let currentActive=now["active-dpi-index"]?.first else { throw ProfileBackupError.regionLayoutMismatch }
        let table=DPIStageTable(stages:stages,activeStageID:currentActive,opaqueBytes:currentBytes,defaultStageID:original.bytes[1])
        guard table.isValid else { throw ProfileBackupError.regionLayoutMismatch }
        let rate=try HIDPPReportRate(code:original.bytes[0],extended:false)
        let change=DeviceSettingsChange(pollingRateHz:rate.hertz,stages:table,persistence:.onboard)
        let (_,child)=try self.child(target,session:session)
        let originalIDs=child.descriptor.capabilities[.dpiRead].constraints.allowedValues
        guard stages.allSatisfy({ originalIDs.contains(Int($0.dpi.x)) }), child.descriptor.capabilities[.pollingRateRead].constraints.allowedValues.contains(rate.hertz) else { throw failure(.unsupported,"Saved settings exceed the currently discovered domains") }
        try FileProfileBackup(url:rollbackBackupURL).save(current)
        return change
    }
    public func featureDirectory(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) throws -> [HIDPPFeature] { let (_,child)=try self.child(target,session:session); return child.features }
    public func identityReceivedAt(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) throws -> Date? { try child(target,session:session).1.identityReceivedAt }
    public func controlTrace(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) async throws -> [HIDPPControlTrace] { let (host,_)=try child(target,session:session); return await host.transport.controlTrace() }
    public func controlTraceSnapshot(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) async throws -> HIDPPControlTraceSnapshot { let (host,_)=try child(target,session:session); return await host.transport.controlTraceSnapshot() }
    public func readSettings(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) async throws -> DeviceSettings {
        let (host,child)=try child(target,session:session); let lease=try await host.transport.acquireTransaction()
        do { let client=await child.client.using(transaction:lease); try await verifyIdentity(client:client,child:child,session:session,forWriting:false); let value=try await settings(client:client,child:child); _=try self.child(target,session:session); await lease.finish(); return value }
        catch { await lease.finish(); await requestReadOnlyRediscovery(after:error,host:host,session:session.address.hostSessionID); throw Self.map(error) }
    }
    @discardableResult private func verifyIdentity(client: HIDPPClient,child: Child,session: LogicalDeviceSessionID,forWriting: Bool) async throws -> HIDPPIdentity {
        let actual=try await client.readIdentity()
        let unit=actual.unitID.flatMap { $0.allSatisfy({ $0 == 0 || $0 == 255 }) ? nil : $0.map { String(format:"%02X",$0) }.joined() }
        let actualWPID=actual.transportIDs["wireless"]
        if unit != child.identity.unitID || (actualWPID != nil && actualWPID != child.identity.wirelessProductID) || actual.firmware != child.firmware {
            if var host=hosts[session.address.hostSessionID] { host.children.removeValue(forKey:child.descriptor.id); let index: UInt8; if case .receiver(let slot,_)=child.descriptor.address.target { index=slot } else { index=255 }; host.policy.removeTarget(index); hosts[session.address.hostSessionID]=host }
            throw failure(.removed,"Peripheral identity/firmware changed in a reused slot; discard old drafts and rediscover")
        }
        if forWriting, case .receiver=child.descriptor.address.target, unit == nil { throw failure(.unsupported,"Receiver writes require a fresh reliable unit identity; WPID alone is insufficient") }
        _=try self.child(child.descriptor,session:session)
        hosts[session.address.hostSessionID]?.children[child.descriptor.id]?.identityReceivedAt=actual.receivedAt
        return actual
    }
    /// Ordinary rights are recomputed inside the same transport lease as the write.
    /// Cached discovery permissions are only a UI hint, never this authorization.
    private func revalidateOrdinary(request: SettingChangeRequest,client: HIDPPClient,host: Host,child: Child) async throws -> LogitechHardwareObservation {
        let version=try await client.ping(), features=try await client.discoverFeatures()
        let info=try await verifyIdentity(client:client,child:child,session:request.target,forWriting:true)
        let firmware=info.firmware.map { "\($0.kind):"+$0.rawBytes.map { String(format:"%02X",$0) }.joined() }.joined(separator:";")
        let identity=LogicalPeripheralIdentity(vendorID:0x046D,wirelessProductID:info.transportIDs["wireless"],unitID:child.identity.unitID,
            protocolVersion:version,firmware:firmware.isEmpty ? nil : firmware)
        let kind: DeviceKind=info.kind.map { [3,5].contains($0) ? .mouse : ([0,2].contains($0) ? .keyboard : .other) } ?? .other
        let isReceiver: Bool; if case .receiver=request.target.address.target { isReceiver=true } else { isReceiver=false }
        let discovery=try await capabilities(client:client,features:features,name:info.name ?? child.descriptor.product,kind:kind,
            powerSource:child.descriptor.capabilities.powerSource,allowsADC:child.allowsADC,host:host,identity:identity,
            identityIsReliable:identity.unitID != nil && info.receivedAt != nil && !info.firmware.isEmpty && info.transportIDs["wireless"] != nil && info.kind != nil,isReceiver:isReceiver)
        guard let observation=discovery.observation, LogitechVerifiedHardwareProfile.matches(observation),
              request.change.validate(capabilities:discovery.capabilities).isEmpty else {
            throw HIDPPError.sessionRebuildRequired("Ordinary write configuration no longer matches the reviewed hardware profile; rediscover before a new explicit request")
        }
        return observation
    }
    /// Raw period survives the Core nominal-Hz projection, including 3/6/7ms values.
    public func rawReportRate(target: LogicalDeviceDescriptor,session: LogicalDeviceSessionID) throws -> HIDPPReportRate? { _=try child(target,session:session); return rawRates[target.address] }
    private func settings(client: HIDPPClient,child: Child) async throws -> DeviceSettings {
        try await observeSettings(client:client,child:child).settings
    }
    private func observeSettings(client: HIDPPClient,child: Child) async throws -> SettingsObservation {
        let ids=Set(child.features.map(\.id)); var dpi: DPISetting?; var rate: Int?; var stages: DPIStageTable?; var profile: Int?; var currentStage: UInt8?
        var onboardInfo: HIDPPOnboardInfo?, profileInfo: HIDPPOnboardInfo?, onboardMode: UInt8?
        if child.descriptor.kind == .mouse, ids.contains(0x2201) || ids.contains(0x2202) { let (_,value)=try await client.readDPI(); dpi=DPISetting(x:value.effectiveX,y:value.effectiveY ?? value.effectiveX) }
        if child.descriptor.kind == .mouse, ids.contains(0x8060) || ids.contains(0x8061) { let (_,value)=try await client.readReportRate(); rate=value.hertz; rawRates[child.descriptor.address]=value }
        if child.descriptor.kind == .mouse, ids.contains(0x8100) {
            let (info,mode,active)=try await client.readOnboardInfo(); profile=Int(active); onboardInfo=info; onboardMode=mode
            if info.knownLayout {
                let sector=try await client.readProfileSector(active); profileInfo=sector.info
                let index=try await client.readActiveDPIIndex(); currentStage=index
                let values=(sector.dpiValues ?? []).enumerated().filter { $0.element > 0 }.map { DPIStage(id:UInt8($0.offset),dpi:DPISetting($0.element)) }
                if values.contains(where:{ $0.id == index }) { stages=DPIStageTable(stages:values,activeStageID:index,opaqueBytes:sector.bytes,defaultStageID:sector.bytes[1]) }
            }
        }
        return SettingsObservation(settings:DeviceSettings(currentDPI:dpi,pollingRateHz:rate,stages:stages,activeProfileID:profile,currentStageID:currentStage),onboardInfo:onboardInfo,profileInfo:profileInfo,onboardMode:onboardMode)
    }
    public func authorizeValidation(request: SettingChangeRequest,before: DeviceSettingsSnapshot,target: LogicalDeviceDescriptor,operation: SettingValidationOperation) async throws -> SettingValidationAuthorization {
        guard !target.isIdentityAmbiguous else { throw failure(.unsupported,"Ambiguous peripheral identity cannot authorize a setting operation") }
        let (host,child)=try self.child(target,session:request.target); let lease=try await host.transport.acquireTransaction(); let client=await child.client.using(transaction:lease)
        do { try await verifyIdentity(client:client,child:child,session:request.target,forWriting:true); let token=try await authorizeValidationLocked(request:request,before:before,target:target,operation:operation,child:child,client:client); await lease.finish(); return token }
        catch { await lease.finish(); await requestReadOnlyRediscovery(after:error,host:host,session:request.target.address.hostSessionID); throw error }
    }
    private func authorizeValidationLocked(request: SettingChangeRequest,before: DeviceSettingsSnapshot,target: LogicalDeviceDescriptor,operation: SettingValidationOperation,child: Child,client: HIDPPClient) async throws -> SettingValidationAuthorization {
        validationIntents=validationIntents.filter { Date() < $0.value.expiresAt }
        guard before.session == request.target, before.revision == request.expectedRevision,
              child.identity.unitID != nil, child.identity.firmware != nil else { throw failure(.unsupported,"Candidate validation requires current session, revision, confirmed unit and firmware") }
        let actual=try await settings(client:client,child:child)
        guard actual == before.settings else { throw failure(.busy,"Actual settings changed; read a fresh snapshot") }
        let ids=Set(child.features.map(\.id)); var caps=child.descriptor.capabilities
        switch operation {
        case .logitechHIDPP2201DPI:
            guard child.descriptor.kind == .mouse, ids.contains(0x2201), !ids.contains(0x2202), child.features.first(where:{ $0.id == 0x2201 })!.version <= 1, request.change.fields == [.currentDPI], request.change.persistence == .runtime else { throw failure(.unsupported,"Validation is limited to the discovered 2201 unified DPI operation") }
            caps.record(OperationCapability(evidence:.writeVerified,constraints:caps[.dpiWrite].constraints,source:"one candidate validation intent"),for:.dpiWrite)
        case .logitechHIDPP8060PollingRate:
            guard child.descriptor.kind == .mouse, ids.contains(0x8060), !ids.contains(0x8061), child.features.first(where:{ $0.id == 0x8060 })!.version == 0, request.change.fields == [.pollingRate], request.change.persistence == .runtime else { throw failure(.unsupported,"Validation is limited to the discovered 8060 operation") }
            caps.record(OperationCapability(evidence:.writeVerified,constraints:caps[.pollingRateWrite].constraints,source:"one candidate validation intent"),for:.pollingRateWrite)
        case .logitechHIDPP8100Profile:
            guard child.descriptor.kind == .mouse else { throw failure(.unsupported,"Mouse profile validation requires a runtime mouse identity") }
            let (info,mode,_)=try await client.readOnboardInfo()
            if request.change.persistence == .runtime, request.change.fields == [.activeProfile] {
                guard mode == 1 else { throw failure(.unsupported,"Profile activation requires onboard mode; mode changes are explicit") }
                caps.record(OperationCapability(evidence:.writeVerified,constraints:caps[.onboardWrite].constraints,source:"one candidate profile activation"),for:.onboardWrite)
                break
            }
            if request.change.persistence == .runtime, request.change.fields == [.currentStage] {
                guard mode == 1 else { throw failure(.unsupported,"Stage activation requires onboard mode; mode changes are explicit") }
                caps.record(OperationCapability(evidence:.writeVerified,constraints:caps[.stageSelect].constraints,source:"one candidate stage activation"),for:.stageSelect)
                break
            }
            let rateOnly=request.change.fields == [.pollingRate]
            guard request.change.persistence == .onboard, request.change.currentDPI == nil, request.change.activeProfileID == nil, request.change.currentStageID == nil,
                  let table=actual.stages, table.isValid, !table.opaqueBytes.isEmpty,
                  rateOnly || request.change.stages != nil else { throw failure(.unsupported,"Profile validation requires a complete actual profile and an explicit stage-table or rate-only intent") }
            guard mode == 1, info.knownWritableLayout, table.opaqueBytes.count == Int(info.sectorSize) else { throw failure(.unsupported,"Onboard format, mode or physical sector write geometry is read-only") }
            if let requested=request.change.stages {
                guard table.opaqueBytes == requested.opaqueBytes, table.activeStageID == requested.activeStageID, table.stages.map(\.id) == requested.stages.map(\.id) else { throw failure(.unsupported,"Profile validation requires a complete unchanged raw backup, stable current stage and the same stage identifiers") }
                let constraints=CapabilityConstraints(allowedValues:caps[.dpiRead].constraints.allowedValues,maximumStages:5,persistenceScopes:[.onboard])
                caps.record(OperationCapability(evidence:.writeVerified,constraints:constraints,source:"one candidate profile intent"),for:.stagesWrite)
            }
            caps.record(OperationCapability(evidence:.writeVerified,constraints:CapabilityConstraints(persistenceScopes:[.onboard]),source:"one candidate profile intent"),for:.onboardPersist)
            if request.change.pollingRateHz != nil {
                let (_,rate)=try await client.readReportRate()
                guard !rate.extended, rate.hertz == actual.pollingRateHz,
                      try HIDPPReportRate(code:table.opaqueBytes[0],extended:false).hertz == rate.hertz else { throw failure(.unsupported,"Profile format 3 requires a consistent discovered standard period") }
                caps.record(OperationCapability(evidence:.writeVerified,constraints:CapabilityConstraints(allowedValues:caps[.pollingRateRead].constraints.allowedValues,persistenceScopes:[.onboard]),source:"one candidate profile intent"),for:.pollingRateWrite)
            }
        default: throw failure(.unsupported,"Wrong protocol validation operation")
        }
        let issues=request.change.validate(capabilities:caps)
        guard issues.isEmpty else { throw failure(.unsupported,issues.map(\.reason).joined(separator:" ")) }
        let token=SettingValidationAuthorization(request:request,operation:operation,profileID:"logitech.runtime.discovered",capabilities:caps)
        validationIntents[request.id]=token; return token
    }
    public func applySettings(request: SettingChangeRequest,before: DeviceSettingsSnapshot,target: LogicalDeviceDescriptor) async throws -> SettingAdapterTransaction {
        guard !target.isIdentityAmbiguous else { throw failure(.unsupported,"Ambiguous peripheral identity cannot authorize a setting operation") }
        let (host,child)=try self.child(target,session:request.target)
        guard before.session == request.target, before.revision == request.expectedRevision else { throw failure(.removed,"Wrong settings session or revision") }
        let candidate=validationIntents.removeValue(forKey:request.id)
        let isCandidate=candidate?.matches(request,at:Date()) == true
        let capabilities=isCandidate ? candidate!.capabilities : child.descriptor.capabilities
        let issues=request.change.validate(capabilities:capabilities)
        guard issues.isEmpty else { throw failure(.unsupported,issues.map(\.reason).joined(separator:" ")) }
        let lease=try await host.transport.acquireTransaction(); let client=await child.client.using(transaction:lease)
        var actual: DeviceSettings=before.settings
        var expectedOnboardProfile: HIDPPProfileSector?
        var ordinaryObservation: LogitechHardwareObservation?
        var settingsAttempted=false
        do {
            if isCandidate { try await verifyIdentity(client:client,child:child,session:request.target,forWriting:true) }
            else { ordinaryObservation=try await revalidateOrdinary(request:request,client:client,host:host,child:child) }
            let actualObservation=try await observeSettings(client:client,child:child); actual=actualObservation.settings
            if let ordinary=ordinaryObservation, !actualObservation.matchesMetadata(ordinary) {
                throw HIDPPError.sessionRebuildRequired("Ordinary actual-before metadata changed after revalidation")
            }
            guard actual == before.settings else { await lease.finish(); return SettingAdapterTransaction(before:actual,observed:actual,acknowledged:false,persistence:.unknown,superseded:true) }
            _=try self.child(target,session:request.target)
            let index: UInt8; if case .receiver(let slot,_)=target.address.target { index=slot } else { index=0xFF }
            let ids=Set(child.features.map(\.id))
            if request.change.persistence == .runtime {
                if let dpi=request.change.currentDPI {
                    let (caps,old)=try await client.readDPI()
                    let command=HIDPPCommand.setDPI(sensor:0,x:dpi.x,y:caps.supportsY ? dpi.y : nil,lod:old.lod,extended:caps.extended)
                    host.policy.grant([command],target:index,intent:request.id)
                    settingsAttempted=true
                    _=try await client.setDPI(x:dpi.x,y:caps.supportsY ? dpi.y : (dpi.y == dpi.x ? nil : dpi.y))
                }
                if let hz=request.change.pollingRateHz {
                    guard !Self.isGPW1(child.descriptor.product) || hz <= 1000 else { throw failure(.unsupported,"PRO Wireless first generation is limited to 1000Hz") }
                    let (codes,current)=try await client.readReportRate()
                    guard let code=try codes.first(where:{ try HIDPPReportRate(code:$0,extended:current.extended).hertz == hz }) else { throw failure(.unsupported,"Requested rate was not discovered") }
                    host.policy.grant([.setRate(code:code,extended:current.extended)],target:index,intent:request.id); settingsAttempted=true; _=try await client.setReportRate(hertz:hz)
                }
                if let profile=request.change.activeProfileID {
                    guard (0...65535).contains(profile) else { throw failure(.unsupported,"Profile sector does not fit protocol address") }
                    host.policy.grant([.setActiveProfile(UInt16(profile))],target:index,intent:request.id); settingsAttempted=true; _=try await client.setActiveProfile(UInt16(profile))
                }
                if let stage=request.change.currentStageID {
                    guard actual.stages?.stages.contains(where:{ $0.id == stage }) == true else { throw failure(.unsupported,"Requested stage is absent from the current profile") }
                    if let ordinary=ordinaryObservation {
                        let (info,mode,active)=try await client.readOnboardInfo()
                        guard info == ordinary.onboardInfo, mode == ordinary.onboardMode, active == ordinary.profile.sector else {
                            throw HIDPPError.sessionRebuildRequired("Ordinary runtime configuration changed after revalidation")
                        }
                    }
                    host.policy.grant([.setActiveDPIIndex(stage)],target:index,intent:request.id); settingsAttempted=true; _=try await client.setActiveDPIIndex(stage)
                }
                guard request.change.stages == nil else { throw failure(.unsupported,"Runtime activation does not rewrite an onboard stage table") }
                expectedOnboardProfile=ordinaryObservation?.profile
            } else {
                guard ids.contains(0x8100), let active=actual.activeProfileID, (1...65535).contains(active),
                      let old=actual.stages, old.isValid, !old.opaqueBytes.isEmpty,
                      request.change.stages != nil || request.change.fields == [.pollingRate] else { throw failure(.unsupported,"Onboard edit requires a full current profile and an explicit stage-table or rate-only intent") }
                let (info,mode,currentProfile)=try await client.readOnboardInfo()
                guard mode == 1, info.knownWritableLayout, Int(currentProfile) == active else { throw failure(.unsupported,"Onboard profile, mode or write geometry changed") }
                if let ordinary=ordinaryObservation {
                    guard info == ordinary.onboardInfo, currentProfile == ordinary.profile.sector else {
                        throw HIDPPError.sessionRebuildRequired("Ordinary onboard metadata changed after revalidation")
                    }
                }
                // A rate-only request preserves its explicit intent. The adapter owns
                // the complete actual image; callers need not fabricate stage edits.
                let requested=request.change.stages ?? old
                let original=try await client.readProfileSector(UInt16(active))
                if let ordinary=ordinaryObservation, original != ordinary.profile {
                    throw HIDPPError.sessionRebuildRequired("Ordinary original profile or complete metadata changed after revalidation")
                }
                guard original.bytes == requested.opaqueBytes, original.bytes == old.opaqueBytes, requested.activeStageID == old.activeStageID, requested.stages.map(\.id) == old.stages.map(\.id), requested.stages.allSatisfy({ $0.dpi.x == $0.dpi.y }) else { throw failure(.unsupported,"Profile backup, current-stage selection or stage layout changed") }
                let patches=request.change.stages.map { Dictionary(uniqueKeysWithValues:$0.stages.map { (Int($0.id),$0.dpi.x) }) } ?? [:]
                var rateCode: UInt8?
                if let hz=request.change.pollingRateHz { let (codes,current)=try await client.readReportRate(); guard !current.extended, current.hertz == actual.pollingRateHz, try HIDPPReportRate(code:original.bytes[0],extended:false).hertz == current.hertz, let code=try codes.first(where:{ try HIDPPReportRate(code:$0,extended:false).hertz == hz }) else { throw failure(.unsupported,"Profile format 3 requires a consistent discovered standard period") }; rateCode=code }
                let defaultStage=request.change.stages?.defaultStageID
                let updated=try original.patch(dpi:patches,reportRateCode:rateCode,defaultDPIIndex:defaultStage)
                let commands=updated == original ? [] : try updated.writePlan().commands
                host.policy.grant(commands,target:index,intent:request.id)
                do {
                    _=try await client.patchProfileSector(original.sector,expected:original,dpi:patches,reportRateCode:rateCode,defaultDPIIndex:defaultStage)
                    settingsAttempted=true
                } catch {
                    // The client wraps every error after starting a sector write.
                    // Earlier failures are read-only and invalidate ordinary rights.
                    if case HIDPPError.interruptedWrite=error { settingsAttempted=true }
                    throw error
                }
                expectedOnboardProfile=updated
            }
            host.policy.revoke(); let finalObservation=try await observeSettings(client:client,child:child)
            let observed=finalObservation.settings; _=try self.child(target,session:request.target)
            let metadataChanged=ordinaryObservation.map { !finalObservation.matchesMetadata($0) } ?? false
            let imageChanged=expectedOnboardProfile.map { observed.activeProfileID != Int($0.sector) || observed.stages?.opaqueBytes != $0.bytes } ?? false
            if metadataChanged || imageChanged {
                // This is the last actual observation, after the client's own full
                // readback. Preserve it and the transaction failure together; a
                // matching requested rate/default cannot validate a different image.
                await lease.finish()
                if metadataChanged {
                    await requestReadOnlyRediscovery(after:HIDPPError.sessionRebuildRequired("Ordinary final metadata changed"),host:host,session:request.target.address.hostSessionID)
                }
                return SettingAdapterTransaction(before:actual,observed:observed,acknowledged:false,persistence:request.change.persistence,
                    failure:failure(.malformedResponse,"Final observed configuration metadata, profile identity or complete image differs from the verified transaction"))
            }
            await lease.finish(); return SettingAdapterTransaction(before:actual,observed:observed,acknowledged:true,persistence:request.change.persistence)
        } catch {
            host.policy.revoke()
            var observed: DeviceSettings?, recoveryError: any Error=error
            if !isCandidate, !settingsAttempted {
                recoveryError=HIDPPError.sessionRebuildRequired("Ordinary write preflight failed; old permissions and drafts are retired: \(String(describing:error))")
            }
            // A write is never replayed. Best-effort reads may observe an uncertain
            // write only while this transport and child generation are still valid.
            if !Self.requiresSessionRebuild(recoveryError) {
                do { let value=try await settings(client:client,child:child); _=try self.child(target,session:request.target); observed=value }
                catch { if Self.requiresSessionRebuild(error) { recoveryError=error } }
            }
            await lease.finish()
            await requestReadOnlyRediscovery(after:recoveryError,host:host,session:request.target.address.hostSessionID)
            return SettingAdapterTransaction(before:actual,observed:observed,acknowledged:false,persistence:request.change.persistence,failure:Self.map(recoveryError))
        }
    }
}

/// Synchronous transport boundary sees only value snapshots protected by this lock.
/// A grant contains the exact command list for one explicit transaction and is consumed.
private final class LogitechCommandPolicy: @unchecked Sendable {
    private let lock=NSLock()
    private var valid=true
    private var targets: Set<UInt8>=[0xFF]
    private var features: [UInt8:[UInt16:HIDPPFeature]]=[:]
    private var grant: (UUID,UInt8,[HIDPPCommand],Date)?
    func allowTarget(_ index: UInt8) { _=lock.withLock { targets.insert(index) } }
    func removeTarget(_ index: UInt8) { lock.withLock { targets.remove(index); features.removeValue(forKey:index); if grant?.1 == index { grant=nil } } }
    func record(_ feature: HIDPPFeature,for index: UInt8) { lock.withLock { features[index,default:[:]][feature.id]=feature } }
    func grant(_ commands: [HIDPPCommand],target: UInt8,intent: UUID) { lock.withLock { grant=(intent,target,commands,Date().addingTimeInterval(60)) } }
    func revoke() { lock.withLock { grant=nil } }
    func invalidate() { lock.withLock { valid=false; grant=nil } }
    func authorize(_ request: HIDPPRequest) throws {
        try lock.withLock {
            guard valid, targets.contains(request.message.deviceIndex) else { throw HIDPPError.closed }
            if !request.command.isRegister, request.command.featureID != 0 {
                guard features[request.message.deviceIndex]?[request.command.featureID]?.index == request.message.featureIndex else { throw HIDPPError.invalidValue("Request feature index is not in this target's discovered directory") }
            }
            guard request.command.isWrite else { return }
            guard var current=grant,current.1 == request.message.deviceIndex,Date() < current.3,current.2.first == request.command else { throw HIDPPError.invalidValue("No exact single-operation write intent authorizes this command") }
            current.2.removeFirst(); grant=current.2.isEmpty ? nil : current
        }
    }
}
