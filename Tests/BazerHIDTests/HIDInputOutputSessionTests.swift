// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
@testable import BazerHID
import Foundation
import LogitechHIDPP
import Testing

private actor OfflineIOBackend: HIDInputOutputBackend {
    var reports: (@Sendable (UInt8,[UInt8]) -> Void)?
    var removal: (@Sendable () -> Void)?
    var sendContinuation: CheckedContinuation<Void,any Error>?
    var sent: [HIDPPMessage]=[]
    var opened=0, closed=0
    var sendWaiters: [(Int,CheckedContinuation<Void,Never>)]=[]
    func open(endpoint: HIDInputOutputEndpoint,onReport: @escaping @Sendable (UInt8,[UInt8]) -> Void,onRemoval: @escaping @Sendable () -> Void) { opened+=1; reports=onReport; removal=onRemoval }
    func send(_ message: HIDPPMessage) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sent.append(message); sendContinuation=continuation
            let ready=sendWaiters.filter { $0.0 <= sent.count }; sendWaiters.removeAll { $0.0 <= sent.count }; ready.forEach { $0.1.resume() }
        }
    }
    func waitForSend(_ count: Int) async { if sent.count >= count { return }; await withCheckedContinuation { sendWaiters.append((count,$0)) } }
    func completeSend() { let continuation=sendContinuation; sendContinuation=nil; continuation?.resume() }
    func failSend(_ error: HIDPPError) { let continuation=sendContinuation; sendContinuation=nil; continuation?.resume(throwing:error) }
    func emit(_ bytes: [UInt8],id: UInt8 = 0x10) { reports?(id,bytes) }
    func remove() { removal?() }
    func close() { closed+=1 }
}

@Suite("Offline Input/Output lifecycle", .serialized, .timeLimit(.minutes(1)))
struct HIDInputOutputSessionTests {
    private func endpoint() throws -> HIDInputOutputEndpoint {
        let descriptor: [UInt8]=[0x06,0x00,0xFF,0x09,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0]
        return try HIDInputOutputEndpoint(physicalDeviceID:PhysicalDeviceID(rawValue:"usb-parent:99"),descriptor:HIDInterfaceDescriptor(registryEntryID:999,usbParentRegistryEntryID:99,vendorID:0x046D,productID:0xDEAD,product:"Synthetic receiver",transport:"USB",maxInputReportSize:20,maxOutputReportSize:20,reportDescriptor:descriptor))
    }
    private func request(index: UInt8 = 0x41,sw: UInt8 = 1) throws -> HIDPPRequest { try HIDPPRequest(deviceIndex:2,featureIndex:index,command:.battery1000,softwareID:sw) }
    @Test func constructionIsLazyAndDescriptorMustHaveExactLayouts() async throws {
        let fake=OfflineIOBackend(); let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ nil })
        #expect(await fake.opened == 0); await session.close(); #expect(await fake.opened == 0)
        let bad=HIDInterfaceDescriptor(registryEntryID:1,usbParentRegistryEntryID:2,vendorID:0x046D,productID:9,product:"offline malformed",transport:"USB",maxInputReportSize:20,maxOutputReportSize:20,reportDescriptor:[5,1,9,2,0xA1,1,0x75,8,0x95,20,0x81,2,0x91,2,0xC0])
        #expect(throws:HIDPPError.self) { try HIDInputOutputEndpoint(physicalDeviceID:PhysicalDeviceID(rawValue:"usb-parent:2"),descriptor:bad) }
        #expect(throws:HIDPPError.self) { try HIDInputOutputEndpoint(physicalDeviceID:PhysicalDeviceID(rawValue:"wrong-host"),descriptor:endpoint().descriptor) }
    }
    @Test func inputBeforeSendCompletionAndFeatureIndex41AreValid() async throws {
        let fake=OfflineIOBackend(); let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ nil })
        let req=try request(); let task=Task { try await session.exchange(req) }; await fake.waitForSend(1)
        // Same-feature dynamic index 41 must not be swallowed as a receiver notification.
        await fake.emit(req.message.bytes); await fake.completeSend()
        #expect(try await task.value.bytes == req.message.bytes)
        await session.close(); await session.close(); #expect(await fake.closed == 1)
        await fake.emit(req.message.bytes) // A late callback cannot complete a closed request twice.
    }
    @Test func cancellationHoldsGlobalLockUntilActualSendCompletes() async throws {
        let fake=OfflineIOBackend(); let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ try HIDProcessQueryLock(directory:directory) })
        let req=try request(index:9); let task=Task { try await session.exchange(req) }; await fake.waitForSend(1); task.cancel()
        await Task.yield()
        #expect(throws:(any Error).self) { try HIDProcessQueryLock(directory:directory) }
        await fake.completeSend()
        do { _=try await task.value; Issue.record("Cancelled request succeeded") } catch {}
        do { let lock=try HIDProcessQueryLock(directory:directory); _=lock }
        do { _=try await session.exchange(req); Issue.record("Quarantined software ID was reused") }
        catch HIDPPError.sessionRebuildRequired { } catch { Issue.record("Wrong quarantine failure: \(error)") }
        await session.close()
    }
    @Test func fullLeaseExcludesOtherChildRequestsAndLateFrames() async throws {
        let fake=OfflineIOBackend(); let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ nil })
        let lease=try await session.acquireTransaction()
        do { _=try await session.acquireTransaction(); Issue.record("Receiver lease allowed a second child") } catch HIDPPError.busy {} catch { Issue.record("Wrong busy error") }
        let first=try request(index:7); let task=Task { try await lease.exchange(first) }; await fake.waitForSend(1); task.cancel(); await fake.completeSend()
        do { _=try await task.value } catch {}
        let second=try request(index:7,sw:2); let next=Task { try await lease.exchange(second) }; await fake.waitForSend(2)
        await fake.emit(first.message.bytes); await fake.emit([0,0,0,0,0,0,0],id:1); await fake.completeSend(); await fake.emit(second.message.bytes)
        #expect(try await next.value.bytes == second.message.bytes)
        await lease.finish(); let again=try await session.acquireTransaction(); await again.finish(); await session.close()
    }
    @Test func concurrentCloseWaitsForSendAndClosesOnce() async throws {
        let fake=OfflineIOBackend(); let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ nil })
        let task=Task { try await session.exchange(request()) }; await fake.waitForSend(1)
        let close1=Task { await session.close() }; let close2=Task { await session.close() }
        await Task.yield(); #expect(await fake.closed == 0); await fake.completeSend()
        await close1.value; await close2.value
        do { _=try await task.value; Issue.record("Close let a request succeed") } catch {}
        #expect(await fake.closed == 1)
    }
    @Test func nativeBackendClosedWithoutOpeningRejectsNewWorkOffline() async throws {
        let backend=IOKitInputOutputBackend(); await backend.close(); await backend.close()
        do { try await backend.send(request().message); Issue.record("Closed native backend accepted send") } catch HIDPPError.closed {} catch { Issue.record("Wrong closed error") }
        do { try await backend.open(endpoint:endpoint(),onReport:{ _,_ in },onRemoval:{}); Issue.record("Closed native backend accepted open") } catch HIDPPError.closed {} catch { Issue.record("Wrong closed error") }
    }
    @Test func timeoutThenLateInputCannotSatisfyAnotherRequest() async throws {
        let fake=OfflineIOBackend(); let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ nil },requestTimeout:.milliseconds(20))
        let first=try request(index:7); let pending=Task { try await session.exchange(first) }; await fake.waitForSend(1)
        try await Task.sleep(for:.milliseconds(40)); await fake.emit(first.message.bytes); await fake.completeSend()
        do { _=try await pending.value; Issue.record("A late input defeated timeout") } catch HIDPPError.timeout {} catch { Issue.record("Unexpected \(error)") }
        do { _=try await session.exchange(first); Issue.record("Timed out correlation was reused") } catch HIDPPError.sessionRebuildRequired {} catch { Issue.record("Unexpected \(error)") }
        let second=try request(index:7,sw:2); let next=Task { try await session.exchange(second) }; await fake.waitForSend(2)
        await fake.emit(first.message.bytes); await fake.completeSend(); await fake.emit(second.message.bytes)
        #expect(try await next.value.bytes == second.message.bytes); await session.close()
    }
    @Test func reportOwnershipRejectsVendorDummyAndAllowsSeparateOrdinaryCollection() throws {
        let vendorDummy: [UInt8]=[0x06,0,0xFF,9,1,0xA1,1,0xC0]
        let ordinary10: [UInt8]=[5,1,9,2,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0xC0]
        func descriptor(_ bytes: [UInt8]) -> HIDInterfaceDescriptor { HIDInterfaceDescriptor(registryEntryID:1,usbParentRegistryEntryID:2,vendorID:0x046D,productID:0xDEAD,product:"offline",transport:"USB",maxInputReportSize:20,maxOutputReportSize:20,reportDescriptor:bytes) }
        #expect(throws:HIDPPError.self) { try HIDInputOutputEndpoint(physicalDeviceID:PhysicalDeviceID(rawValue:"usb-parent:2"),descriptor:descriptor(vendorDummy+ordinary10)) }
        var ordinary1=ordinary10; ordinary1[9]=1
        let accepted=try HIDInputOutputEndpoint(physicalDeviceID:PhysicalDeviceID(rawValue:"usb-parent:2"),descriptor:descriptor(ordinary1+endpoint().descriptor.reportDescriptor))
        #expect(accepted.reportKinds == [.short,.long])
    }
    @Test func boundedControlTraceExcludesUnrelatedInputAndPreservesLengths() async throws {
        let fake=OfflineIOBackend(); let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ nil },traceCapacity:2)
        let lease=try await session.acquireTransaction()
        for index in 1...3 {
            let request=try request(index:7,sw:UInt8(index)); let work=Task { try await lease.exchange(request) }; await fake.waitForSend(index)
            await fake.emit([1,2,3,4,5,6,7],id:1)
            var wrong=request.message.bytes; wrong[1]=99; await fake.emit(wrong)
            await fake.completeSend(); await fake.emit(Array(request.message.bytes.dropFirst()))
            _=try await work.value
        }
        let trace=await session.controlTrace()
        #expect(trace.count == 2); #expect(trace.map(\.softwareID) == [2,3]); #expect(trace.allSatisfy { $0.command == "battery1000.status" && $0.actualInputLength == 6 && $0.transmittedLength == 7 && $0.elapsedMilliseconds >= 0 && $0.receivedAt != nil })
        let snapshot=await session.controlTraceSnapshot(); #expect(snapshot.truncated); #expect(snapshot.droppedCount == 1); #expect(snapshot.capacity == 2)
        await lease.finish(); await session.close()
    }
    @Test func profileControlTraceIsRedactedAndRawIOReturnIsStructured() async throws {
        let fake=OfflineIOBackend(); let session=HIDInputOutputSession(endpoint:try endpoint(),backendFactory:{ fake },lockFactory:{ nil },traceCapacity:2)
        let profile=try HIDPPRequest(deviceIndex:2,featureIndex:7,command:.readSector(sector:1,offset:0),softwareID:1)
        let read=Task { try await session.exchange(profile) }; await fake.waitForSend(1)
        await fake.completeSend(); await fake.emit(profile.message.bytes,id:0x11); _=try await read.value
        let next=Task { try await session.exchange(request(index:7,sw:2)) }; await fake.waitForSend(2)
        let diagnostic=HIDPPIODiagnostic(phase:"outputCompletion",rawIOReturn:Int32(bitPattern:0xE00002D6),endpointRegistryEntryID:999)
        await fake.failSend(.ioFailure(diagnostic)); do { _=try await next.value; Issue.record("Native failure returned success") } catch {}
        let trace=await session.controlTrace()
        #expect(trace[0].redacted); #expect(trace[0].tx.count == 4); #expect(trace[0].rx?.count == 4); #expect(trace[0].transmittedLength == 20); #expect(trace[0].actualInputLength == 20)
        #expect(trace[0].txSHA256.count == 64); #expect(trace[0].rxSHA256?.count == 64); #expect(trace[0].maskDescription != nil)
        #expect(trace[1].io == diagnostic); #expect(trace[1].rx == nil)
        await session.close()
    }
}
