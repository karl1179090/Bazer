// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import LogitechHIDPP

/// Separate from discovery/Razer's synchronous worker. Output completion and input
/// callbacks run on this worker's RunLoop; no wait blocks that RunLoop.
public final class IOKitInputOutputBackend: HIDInputOutputBackend, @unchecked Sendable {
    private let lock=NSLock()
    private var worker: NativeHIDIOWorker?
    private var closed=false
    public init() {}
    public func open(endpoint: HIDInputOutputEndpoint,onReport: @escaping @Sendable (UInt8,[UInt8]) -> Void,onRemoval: @escaping @Sendable () -> Void) async throws {
        guard let value=lock.withLock({ () -> NativeHIDIOWorker? in
            guard !closed else { return nil }
            if let worker { return worker }; let worker=NativeHIDIOWorker(); self.worker=worker; return worker
        }) else { throw HIDPPError.closed }
        try await withCheckedThrowingContinuation { continuation in let accepted=value.enqueue { state in
            do { try state.open(endpoint:endpoint,onReport:onReport,onRemoval:onRemoval); continuation.resume() }
            catch { continuation.resume(throwing:error) }
        }; if !accepted { continuation.resume(throwing:HIDPPError.closed) } }
    }
    public func send(_ message: HIDPPMessage) async throws {
        guard let value=lock.withLock({ closed ? nil : worker }) else { throw HIDPPError.closed }
        try await withCheckedThrowingContinuation { continuation in
            if !value.enqueue({ $0.send(message,continuation:continuation) }) { continuation.resume(throwing:HIDPPError.closed) }
        }
    }
    public func close() async {
        guard let value=lock.withLock({ closed=true; return worker }) else { return }
        await value.close()
    }
}

private final class NativeHIDIOWorker: @unchecked Sendable {
    private let condition=NSCondition()
    private var loop: CFRunLoop?
    private var stopped=false
    private var stopping=false
    private var stopWaiters: [CheckedContinuation<Void,Never>]=[]
    private let state=NativeHIDIOState()
    init() {
        let thread=Thread { [self] in run() }; thread.name="Bazer HID++ Input/Output"; thread.start()
        condition.lock(); while loop == nil { condition.wait() }; condition.unlock()
    }
    private func run() {
        autoreleasepool {
            let current=CFRunLoopGetCurrent()!; var context=CFRunLoopSourceContext()
            context.perform={ _ in }
            let source=CFRunLoopSourceCreate(kCFAllocatorDefault,0,&context)!
            CFRunLoopAddSource(current,source,.defaultMode)
            condition.lock(); loop=current; condition.broadcast(); condition.unlock()
            CFRunLoopRun()
            state.teardown()
            CFRunLoopRemoveSource(current,source,.defaultMode)
            condition.lock(); stopped=true; let waiters=stopWaiters; stopWaiters=[]; condition.unlock()
            waiters.forEach { $0.resume() }
        }
    }
    @discardableResult func enqueue(_ block: @escaping @Sendable (NativeHIDIOState) -> Void) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, !stopping, let current=loop else { return false }
        CFRunLoopPerformBlock(current,CFRunLoopMode.defaultMode.rawValue) { [self] in block(state) }; CFRunLoopWakeUp(current); return true
    }
    func close() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if stopped { condition.unlock(); continuation.resume(); return }
            stopWaiters.append(continuation)
            if stopping { condition.unlock(); return }
            stopping=true; let current=loop
            if let current { CFRunLoopPerformBlock(current,CFRunLoopMode.defaultMode.rawValue) { [self] in state.requestClose { CFRunLoopStop(CFRunLoopGetCurrent()) } }; CFRunLoopWakeUp(current) }
            condition.unlock()
        }
    }
}

/// All fields are confined to NativeHIDIOWorker. @unchecked only permits the worker
/// to enqueue closures; no IOHIDDevice or callback pointer crosses to an actor.
private final class NativeHIDIOState: @unchecked Sendable {
    private var device: IOHIDDevice?
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputCapacity=0
    private var sendBuffer: UnsafeMutablePointer<UInt8>?
    private var sendContinuation: CheckedContinuation<Void,any Error>?
    private var reportHandler: (@Sendable (UInt8,[UInt8]) -> Void)?
    private var removalHandler: (@Sendable () -> Void)?
    private var closeHandlers: [() -> Void]=[]
    private var closing=false
    private var endpointID: UInt64?
    func open(endpoint: HIDInputOutputEndpoint,onReport: @escaping @Sendable (UInt8,[UInt8]) -> Void,onRemoval: @escaping @Sendable () -> Void) throws {
        endpointID=endpoint.descriptor.registryEntryID
        guard !closing else { throw HIDPPError.closed }; guard device == nil else { return }
        let matching=IORegistryEntryIDMatching(endpoint.descriptor.registryEntryID)
        let service=IOServiceGetMatchingService(kIOMainPortDefault,matching)
        guard service != 0 else { throw HIDPPError.transport("Selected registry endpoint was removed") }
        defer { IOObjectRelease(service) }
        guard let created=IOHIDDeviceCreate(kCFAllocatorDefault,service) else { throw HIDPPError.transport("Cannot create selected HID endpoint") }
        let vendor=(IOHIDDeviceGetProperty(created,kIOHIDVendorIDKey as CFString) as? NSNumber)?.uint16Value
        let product=(IOHIDDeviceGetProperty(created,kIOHIDProductIDKey as CFString) as? NSNumber)?.uint16Value
        let descriptor=(IOHIDDeviceGetProperty(created,kIOHIDReportDescriptorKey as CFString) as? Data).map(Array.init)
        let transport=IOHIDDeviceGetProperty(created,kIOHIDTransportKey as CFString) as? String
        let builtIn=(IOHIDDeviceGetProperty(created,kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue == true
        guard vendor == endpoint.descriptor.vendorID, product == endpoint.descriptor.productID, descriptor == endpoint.descriptor.reportDescriptor,
              transport?.caseInsensitiveCompare("USB") == .orderedSame, !builtIn,
              Self.matchesUSBParent(service,expected:endpoint.descriptor) else { throw HIDPPError.invalidValue("Selected endpoint USB identity/parent/descriptor changed; rediscover before access") }
        let result=IOHIDDeviceOpen(created,IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw HIDPPError.ioFailure(HIDPPIODiagnostic(phase:"open",rawIOReturn:result,endpointRegistryEntryID:endpointID)) }
        device=created; reportHandler=onReport; removalHandler=onRemoval
        inputCapacity=max(20,endpoint.descriptor.maxInputReportSize)
        guard inputCapacity <= 1_048_576 else { _=IOHIDDeviceClose(created,0); device=nil; throw HIDPPError.invalidValue("Unreasonable input report capacity") }
        inputBuffer=UnsafeMutablePointer<UInt8>.allocate(capacity:inputCapacity)
        let context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(created,inputBuffer!,inputCapacity,{ context,result,_,kind,reportID,report,length in
            guard let context, result == kIOReturnSuccess, kind == kIOHIDReportTypeInput, reportID == 0x10 || reportID == 0x11 else { return }
            let state=Unmanaged<NativeHIDIOState>.fromOpaque(context).takeUnretainedValue()
            guard !state.closing, length >= 0, length <= state.inputCapacity, length <= 20 else { return }
            // This is the only copied input: HID++ numbered reports, never movement/keys.
            state.reportHandler?(UInt8(reportID),Array(UnsafeBufferPointer(start:report,count:length)))
        },context)
        IOHIDDeviceRegisterRemovalCallback(created,{ context,_,_ in
            guard let context else { return }; let state=Unmanaged<NativeHIDIOState>.fromOpaque(context).takeUnretainedValue()
            guard !state.closing else { return }; state.removalHandler?()
        },context)
        IOHIDDeviceScheduleWithRunLoop(created,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
    }
    private static func matchesUSBParent(_ service: io_registry_entry_t,expected: HIDInterfaceDescriptor) -> Bool {
        func property(_ entry: io_registry_entry_t,_ name: String) -> AnyObject? { IORegistryEntryCreateCFProperty(entry,name as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() }
        func truth(_ value: AnyObject?) -> Bool { if let number=value as? NSNumber { return number.boolValue }; if let data=value as? Data { return data.contains { $0 != 0 } }; return false }
        var current=service; _=IOObjectRetain(current); defer { IOObjectRelease(current) }
        for _ in 0..<64 {
            if truth(property(current,"Built-In")) || truth(property(current,"AAPL,device-internal")) || (property(current,"USBPortType") as? NSNumber)?.intValue == 2 { return false }
            if IOObjectConformsTo(current,"IOUSBHostDevice") != 0 || IOObjectConformsTo(current,"IOUSBDevice") != 0 {
                var id: UInt64=0; guard IORegistryEntryGetRegistryEntryID(current,&id) == kIOReturnSuccess else { return false }
                if let expectedID=expected.usbParentRegistryEntryID { return id == expectedID }
                var bytes=[CChar](repeating:0,count:4096)
                guard IORegistryEntryGetPath(current,kIOServicePlane,&bytes) == kIOReturnSuccess else { return false }
                let path=String(decoding:bytes.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
                return !path.isEmpty && path == expected.usbParentPath
            }
            var parent: io_registry_entry_t=0
            guard IORegistryEntryGetParentEntry(current,kIOServicePlane,&parent) == kIOReturnSuccess, parent != 0 else { return false }
            IOObjectRelease(current); current=parent
        }
        return false
    }
    func send(_ message: HIDPPMessage,continuation: CheckedContinuation<Void,any Error>) {
        guard !closing, let device else { continuation.resume(throwing:HIDPPError.closed); return }
        guard sendContinuation == nil else { continuation.resume(throwing:HIDPPError.busy); return }
        let pointer=UnsafeMutablePointer<UInt8>.allocate(capacity:message.bytes.count)
        pointer.initialize(from:message.bytes,count:message.bytes.count)
        sendBuffer=pointer; sendContinuation=continuation
        let result=IOHIDDeviceSetReportWithCallback(device,kIOHIDReportTypeOutput,CFIndex(message.kind.rawValue),pointer,message.bytes.count,2000,{ context,result,_,_,_,_,_ in
            guard let context else { return }; Unmanaged<NativeHIDIOState>.fromOpaque(context).takeUnretainedValue().sendFinished(result)
        },Unmanaged.passUnretained(self).toOpaque())
        if result != kIOReturnSuccess { sendFinished(result) }
    }
    private func sendFinished(_ result: IOReturn) {
        guard let continuation=sendContinuation else { return }; sendContinuation=nil
        sendBuffer?.deallocate(); sendBuffer=nil
        if result == kIOReturnSuccess { continuation.resume() }
        else { continuation.resume(throwing:HIDPPError.ioFailure(HIDPPIODiagnostic(phase:"outputCompletion",rawIOReturn:result,endpointRegistryEntryID:endpointID))) }
        if closing { teardown(); let handlers=closeHandlers; closeHandlers=[]; handlers.forEach { $0() } }
    }
    func requestClose(_ completion: @escaping () -> Void) {
        closing=true; closeHandlers.append(completion)
        if sendContinuation == nil { teardown(); let handlers=closeHandlers; closeHandlers=[]; handlers.forEach { $0() } }
    }
    func teardown() {
        guard sendContinuation == nil else { return }
        closing=true
        if let device {
            // Same RunLoop, no concurrent callback execution. Context and buffers remain
            // alive through deregistration, unscheduling, close, and RunLoop exit.
            if let inputBuffer { IOHIDDeviceRegisterInputReportCallback(device,inputBuffer,inputCapacity,nil,nil) }
            IOHIDDeviceRegisterRemovalCallback(device,nil,nil)
            IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetCurrent(),CFRunLoopMode.defaultMode.rawValue)
            _=IOHIDDeviceClose(device,IOOptionBits(kIOHIDOptionsTypeNone)); self.device=nil
        }
        inputBuffer?.deallocate(); inputBuffer=nil; reportHandler=nil; removalHandler=nil
    }
}
