// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import LogitechHIDPP

public struct HIDInputOutputEndpoint: Equatable, Sendable {
    public let physicalDeviceID: PhysicalDeviceID
    public let descriptor: HIDInterfaceDescriptor
    public let reportKinds: Set<HIDPPReportKind>
    public init(physicalDeviceID: PhysicalDeviceID,descriptor: HIDInterfaceDescriptor) throws {
        guard PhysicalDeviceGrouper.group([descriptor]).first?.id == physicalDeviceID else { throw HIDPPError.invalidValue("Endpoint descriptor does not belong to the selected physical host") }
        guard descriptor.vendorID == 0x046D, descriptor.isExternalUSB, let summary=descriptor.descriptorSummary,
              summary.applicationUsages.contains(where: { $0.page >= 0xFF00 }) else {
            throw HIDPPError.invalidValue("HID++ requires a discovered external Logitech vendor collection")
        }
        let kinds=Set(HIDPPReportKind.allCases.filter { kind in
            summary.hasVendorReport(kind:.input,reportID:kind.rawValue,byteCount:kind.length-1) && summary.hasVendorReport(kind:.output,reportID:kind.rawValue,byteCount:kind.length-1)
        })
        guard !kinds.isEmpty else { throw HIDPPError.invalidValue("Descriptor lacks matching numbered HID++ Input/Output layouts") }
        self.physicalDeviceID=physicalDeviceID; self.descriptor=descriptor; reportKinds=kinds
    }
}

/// Implementations own all native objects. Events contain only filtered value packets;
/// ordinary HID input is discarded before it crosses this seam and is never logged.
public protocol HIDInputOutputBackend: Sendable {
    func open(endpoint: HIDInputOutputEndpoint,onReport: @escaping @Sendable (UInt8,[UInt8]) -> Void,onRemoval: @escaping @Sendable () -> Void) async throws
    func send(_ message: HIDPPMessage) async throws
    func close() async
}

public actor HIDInputOutputSession: HIDPPTransport {
    public let endpoint: HIDInputOutputEndpoint
    private let backendFactory: @Sendable () -> any HIDInputOutputBackend
    private let authorize: @Sendable (HIDPPRequest) throws -> Void
    private let lockFactory: @Sendable () throws -> HIDProcessQueryLock?
    private let requestTimeout: Duration
    private let traceCapacity: Int
    private var trace: [HIDPPControlTrace]=[]
    private var droppedTraceCount=0
    private var backend: (any HIDInputOutputBackend)?
    private var processLock: HIDProcessQueryLock?
    private var leaseToken: UUID?
    private var retiredSoftwareIDs: [UInt8:Set<UInt8>]=[:]
    private var retiredRegisterKeys: Set<String>=[]
    private var closed=false
    private var closeComplete=false
    private var closingStarted=false
    private var closeWaiters: [CheckedContinuation<Void,Never>]=[]
    private var idleWaiters: [CheckedContinuation<Void,Never>]=[]
    private var notificationObservers: [UUID:AsyncStream<HIDPPMessage>.Continuation]=[:]
    private struct Pending {
        let id: UUID, request: HIDPPRequest
        let continuation: CheckedContinuation<HIDPPMessage,any Error>
        var sent=false
        var result: Result<HIDPPMessage,any Error>?
        let startedAt: Date, monotonicStart: Double
        var response: HIDPPMessage?, actualInputLength: Int?
    }
    private var pending: Pending?

    /// Construction is offline: no backend, native object, enumeration, or report access.
    /// Default live authorization permits reads only. Drivers must supply an operation-
    /// specific authorization closure before exposing verified writes.
    public init(endpoint: HIDInputOutputEndpoint,backendFactory: @escaping @Sendable () -> any HIDInputOutputBackend = { IOKitInputOutputBackend() },traceCapacity: Int = 0,authorize: @escaping @Sendable (HIDPPRequest) throws -> Void = { request in guard !request.command.isWrite else { throw HIDPPError.invalidValue("This session permits read operations only") } }) {
        self.endpoint=endpoint; self.backendFactory=backendFactory; self.authorize=authorize; lockFactory={ try HIDProcessQueryLock(physicalDeviceID: endpoint.physicalDeviceID) }; requestTimeout = .seconds(2); self.traceCapacity=min(256,max(0,traceCapacity))
    }
    init(endpoint: HIDInputOutputEndpoint,backendFactory: @escaping @Sendable () -> any HIDInputOutputBackend,lockFactory: @escaping @Sendable () throws -> HIDProcessQueryLock?,requestTimeout: Duration = .seconds(2),traceCapacity: Int = 0,authorize: @escaping @Sendable (HIDPPRequest) throws -> Void = { _ in }) { self.endpoint=endpoint; self.backendFactory=backendFactory; self.lockFactory=lockFactory; self.authorize=authorize; self.requestTimeout=requestTimeout; self.traceCapacity=min(256,max(0,traceCapacity)) }

    public func acquireTransaction() async throws -> any HIDPPTransaction {
        try Task.checkCancellation()
        guard !closed else { throw HIDPPError.closed }
        guard leaseToken == nil, pending == nil else { throw HIDPPError.busy }
        let token=UUID(); leaseToken=token
        do {
            processLock=try lockFactory()
            if backend == nil {
                let value=backendFactory(); backend=value
                try await value.open(endpoint:endpoint,onReport:{ [weak self] id,bytes in let receivedAt=Date(); Task { await self?.receive(id: id, bytes: bytes,receivedAt:receivedAt) } },onRemoval:{ [weak self] in Task { await self?.removed() } })
            }
            guard !closed else { throw HIDPPError.closed }
            try Task.checkCancellation()
            return HIDInputOutputLease(session:self,token:token)
        } catch {
            if let backend { await backend.close() }; backend=nil; processLock=nil; leaseToken=nil; throw error
        }
    }
    public func exchange(_ request: HIDPPRequest) async throws -> HIDPPMessage {
        let lease=try await acquireTransaction()
        do { let response=try await lease.exchange(request); await lease.finish(); return response }
        catch { await lease.finish(); throw error }
    }
    fileprivate func exchange(_ request: HIDPPRequest,token: UUID) async throws -> HIDPPMessage {
        guard !closed else { throw HIDPPError.closed }
        guard leaseToken == token, pending == nil, let backend else { throw HIDPPError.busy }
        try authorize(request)
        guard endpoint.reportKinds.contains(request.message.kind) else { throw HIDPPError.invalidValue("Request exceeds discovered endpoint report layouts") }
        guard request.command.isRegister ? !retiredRegisterKeys.contains(request.correlationKey) : !(retiredSoftwareIDs[request.message.deviceIndex] ?? []).contains(request.message.softwareID) else { throw HIDPPError.sessionRebuildRequired("A timed-out/cancelled correlation cannot be reused; close and recreate the session, then resume reads only") }
        try Task.checkCancellation()
        let id=UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending=Pending(id:id,request:request,continuation:continuation,startedAt:Date(),monotonicStart:ProcessInfo.processInfo.systemUptime)
                Task {
                    do { try await backend.send(request.message); self.sendCompleted(id:id,error:nil) }
                    catch { self.sendCompleted(id:id,error:error) }
                }
                Task { try? await Task.sleep(for:requestTimeout); self.expire(id:id,error:HIDPPError.timeout) }
            }
        } onCancel: { Task { await self.expire(id:id,error:HIDPPError.cancelled) } }
    }
    private func sendCompleted(id: UUID,error: (any Error)?) {
        guard pending?.id == id else { return }; pending?.sent=true
        if let error {
            if let request=pending?.request { if request.command.isRegister { retiredRegisterKeys.insert(request.correlationKey) } else { retiredSoftwareIDs[request.message.deviceIndex,default:[]].insert(request.message.softwareID) } }
            pending?.result = .failure(error)
        }
        completeIfReady()
    }
    private func expire(id: UUID,error: any Error) {
        guard pending?.id == id, pending?.result == nil else { return }
        if let request=pending?.request {
            if request.command.isRegister { retiredRegisterKeys.insert(request.correlationKey) }
            else { retiredSoftwareIDs[request.message.deviceIndex,default:[]].insert(request.message.softwareID) }
        }
        pending?.result = .failure(error); completeIfReady()
    }
    private func receive(id: UInt8,bytes: [UInt8],receivedAt: Date) {
        guard !closed, id == 0x10 || id == 0x11, let message=try? HIDPPMessage.normalize(reportID:id,bytes:bytes,receivedAt:receivedAt) else { return }
        if let request=pending?.request, pending?.result == nil {
            switch HIDPPResponseMatcher.match(message,request:request) {
            case .unrelated: break
            case .response: pending?.response=message; pending?.actualInputLength=bytes.count; pending?.result = .success(message); completeIfReady(); return
            case .failure(let error): pending?.response=message; pending?.actualInputLength=bytes.count; pending?.result = .failure(HIDPPError.protocolError(error)); completeIfReady(); return
            }
        }
        // Classic receiver connection events have a register sub-ID and a documented
        // protocol address. swid-zero feature events are not pairing notifications.
        if message.kind == .short, message.featureIndex == 0x41,
           [0x01,0x03,0x04,0x05,0x10].contains(message.address),
           (try? HIDPPReceiverChild.notification(message,variant:.unifying)) != nil {
            for observer in notificationObservers.values { observer.yield(message) }
        }
    }
    private func completeIfReady() {
        guard let current=pending, current.sent, let result=current.result else { return }
        if traceCapacity > 0 {
            let error: (any Error)?; if case .failure(let failure)=result { error=failure } else { error=nil }
            trace.append(HIDPPControlTrace(startedAt:current.startedAt,receivedAt:current.response?.receivedAt,elapsedMilliseconds:max(0,(ProcessInfo.processInfo.systemUptime-current.monotonicStart)*1000),request:current.request,response:current.response,actualInputLength:current.actualInputLength,error:error))
            if trace.count > traceCapacity { let count=trace.count-traceCapacity; droppedTraceCount+=count; trace.removeFirst(count) }
        }
        pending=nil; current.continuation.resume(with:result)
        let waiters=idleWaiters; idleWaiters=[]; waiters.forEach { $0.resume() }
    }
    private func removed() {
        if let id=pending?.id { expire(id:id,error:HIDPPError.transport("Device removed; rebuild session before further reads")) }
        closed=true
    }
    fileprivate func finish(token: UUID) async {
        guard leaseToken == token else { return }
        if pending != nil { await withCheckedContinuation { idleWaiters.append($0) } }
        guard leaseToken == token else { return }
        processLock=nil; leaseToken=nil
    }
    public func notifications() -> AsyncStream<HIDPPMessage> {
        let id=UUID(); let (stream,continuation)=AsyncStream<HIDPPMessage>.makeStream(bufferingPolicy:.bufferingNewest(16))
        if closed { continuation.finish(); return stream }
        notificationObservers[id]=continuation
        continuation.onTermination={ [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { notificationObservers.removeValue(forKey:id) }
    public func controlTrace() async -> [HIDPPControlTrace] { trace }
    public func controlTraceSnapshot() async -> HIDPPControlTraceSnapshot { HIDPPControlTraceSnapshot(entries:trace,capacity:traceCapacity,droppedCount:droppedTraceCount) }
    public func clearControlTrace() { trace=[]; droppedTraceCount=0 }
    /// Idempotent and joins native teardown. In-flight sends finish before the global
    /// lock is released, callbacks unregistered, buffers freed, and this method returns.
    public func close() async {
        if closeComplete { return }
        if closingStarted { await withCheckedContinuation { closeWaiters.append($0) }; return }
        closingStarted=true; closed=true
        if let id=pending?.id { expire(id:id,error:HIDPPError.closed) }
        if pending != nil { await withCheckedContinuation { idleWaiters.append($0) } }
        if let backend { await backend.close() }
        backend=nil; processLock=nil; leaseToken=nil; closeComplete=true
        notificationObservers.values.forEach { $0.finish() }; notificationObservers=[:]
        let waiters=closeWaiters; closeWaiters=[]; waiters.forEach { $0.resume() }
    }
}

private final class HIDInputOutputLease: HIDPPTransaction, @unchecked Sendable {
    let session: HIDInputOutputSession, token: UUID
    init(session: HIDInputOutputSession,token: UUID) { self.session=session; self.token=token }
    func exchange(_ request: HIDPPRequest) async throws -> HIDPPMessage { try await session.exchange(request,token:token) }
    func finish() async { await session.finish(token:token) }
}
