// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import CoreFoundation
import Darwin
import Foundation
import Testing

/// Synthetic metadata only. No test in this file constructs the IOKit backend.
private func syntheticInterface(_ id: UInt64 = 101, parent: UInt64 = 10, vendor: UInt16 = 0x1532, product: UInt16 = 0x00C5, usage: HIDUsage = .mouse, feature: Bool = true) -> HIDInterfaceDescriptor {
    HIDInterfaceDescriptor(registryEntryID: id, usbParentRegistryEntryID: parent, vendorID: vendor, productID: product, product: "Synthetic test device", transport: "USB", primaryUsage: usage, usages: [usage], maxFeatureReportSize: feature ? 90 : 0, reportDescriptor: feature ? [0x05, 1, 0x09, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0] : [0x05, 1, 0x09, 6, 0xA1, 1, 0xC0])
}

private struct BackendCall: Sendable {
    let phase: String
    let threadID: UInt64
    let onMainThread: Bool
}

/// Only control/trace access crosses threads, protected by lock. Backend methods,
/// metadata mutations, and callbacks execute on the service's dedicated run loop.
private final class FakeHIDBackend: HIDDiscoveryBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [BackendCall] = []
    private var loop: CFRunLoop?
    private var interfaces: [HIDInterfaceDescriptor]
    private var onChange: ((HIDDiscoveryEvent) -> Void)?
    let openResult: Int32
    let stopSignal = AsyncStream<Void>.makeStream()

    init(_ interfaces: [HIDInterfaceDescriptor] = [syntheticInterface()], openResult: Int32 = 0) {
        self.interfaces = interfaces
        self.openResult = openResult
    }

    var trace: [BackendCall] { lock.withLock { calls } }

    private func record(_ phase: String) {
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        let call = BackendCall(phase: phase, threadID: threadID, onMainThread: Thread.isMainThread)
        lock.withLock { calls.append(call) }
    }

    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) {
        record("start")
        self.onChange = onChange
        lock.withLock { loop = CFRunLoopGetCurrent() }
    }

    func snapshot() -> HIDDiscoverySnapshot {
        record("snapshot")
        return HIDDiscoverySnapshot(capturedAt: Date(), interfaces: interfaces)
    }

    func inspectInterface(registryEntryID: UInt64) -> HIDInspectionResult {
        record("inspect:\(registryEntryID)")
        var operations = [HIDOperationDiagnostic(phase: "open", registryEntryID: registryEntryID, rawIOReturn: openResult, message: "synthetic result")]
        if openResult == 0 { operations.append(HIDOperationDiagnostic(phase: "close", registryEntryID: registryEntryID, rawIOReturn: 0, message: "synthetic result")) }
        return HIDInspectionResult(registryEntryID: registryEntryID, operations: operations)
    }

    func emit(_ interfaces: [HIDInterfaceDescriptor], kind: HIDDiscoveryEvent.Kind, id: UInt64) {
        guard let loop = lock.withLock({ self.loop }) else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            self.interfaces = interfaces
            onChange?(HIDDiscoveryEvent(kind: kind, interfaceRegistryEntryID: id, snapshot: snapshot()))
        }
        CFRunLoopWakeUp(loop)
    }

    func stop() {
        record("stop")
        onChange = nil
        lock.withLock { loop = nil }
        stopSignal.continuation.yield(())
        stopSignal.continuation.finish()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HIDDiscoveryTests {
    @Test
    func backendLifetimeAndInspectionUseOneDedicatedThread() async throws {
        let backend = FakeHIDBackend()
        let discovery = HIDDiscovery(backendFactory: { backend })
        let snapshot = try await discovery.snapshot()
        #expect(snapshot.devices.count == 1)
        let result = try await discovery.inspectControlInterface(registryEntryID: 101)
        #expect(result.succeeded)
        #expect(result.operations.map(\.phase) == ["open", "close"])
        await discovery.stop()
        let trace = backend.trace
        #expect(trace.map(\.phase) == ["start", "snapshot", "snapshot", "inspect:101", "stop"])
        #expect(Set(trace.map(\.threadID)).count == 1)
        #expect(trace.allSatisfy { !$0.onMainThread })
    }

    @Test
    func passiveSnapshotsAndWatchNeverOpenAndRemovalDoesNotMergeAnotherMouse() async throws {
        let first = syntheticInterface()
        let second = syntheticInterface(201, parent: 20)
        let backend = FakeHIDBackend([first, second])
        let discovery = HIDDiscovery(backendFactory: { backend })
        let stream = try await discovery.events()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial?.kind == .initial)
        #expect(initial?.snapshot.devices.count == 2)
        backend.emit([second], kind: .removed, id: 101)
        let removed = await iterator.next()
        #expect(removed?.kind == .removed)
        #expect(removed?.snapshot.devices.count == 1)
        #expect(removed?.snapshot.interfaces.first?.registryEntryID == 201)
        backend.emit([first, second], kind: .added, id: 101)
        let added = await iterator.next()
        #expect(added?.kind == .added)
        #expect(added?.snapshot.devices.count == 2)
        // Earlier emitted snapshots are immutable and retain their original devices.
        #expect(removed?.snapshot.interfaces.count == 1)
        await discovery.stop()
        #expect(await iterator.next() == nil)
        #expect(backend.trace.allSatisfy { !$0.phase.hasPrefix("inspect:") })
    }

    @Test
    func keyboardAndAuxiliaryMouseInterfacesCannotReachOpen() async throws {
        let mouse = syntheticInterface()
        let auxiliary = syntheticInterface(102, usage: .keyboard, feature: false)
        let keyboard = syntheticInterface(301, parent: 30, vendor: 0x342D, product: 0xE51A, usage: .keyboard, feature: false)
        let backend = FakeHIDBackend([mouse, auxiliary, keyboard])
        let discovery = HIDDiscovery(backendFactory: { backend })
        for id: UInt64 in [102, 301] {
            do {
                _ = try await discovery.inspectControlInterface(registryEntryID: id)
                Issue.record("Unsafe synthetic endpoint was allowed to open")
            } catch let error as HIDDiscoveryError {
                guard case .unsafeEndpoint = error else { Issue.record("Unexpected error: \(error)"); continue }
            }
        }
        await discovery.stop()
        #expect(backend.trace.allSatisfy { !$0.phase.hasPrefix("inspect:") })
    }

    @Test
    func ambiguousControlInterfacesNeverReachOpen() async throws {
        let backend = FakeHIDBackend([syntheticInterface(), syntheticInterface(102)])
        let discovery = HIDDiscovery(backendFactory: { backend })
        do {
            _ = try await discovery.inspectControlInterface(registryEntryID: 101)
            Issue.record("Ambiguous endpoints were allowed to open")
        } catch let error as HIDDiscoveryError {
            guard case .unsafeEndpoint = error else { Issue.record("Unexpected error: \(error)"); await discovery.stop(); return }
        }
        await discovery.stop()
        #expect(backend.trace.allSatisfy { !$0.phase.hasPrefix("inspect:") })
    }

    @Test
    func removedEndpointCannotReachOpen() async throws {
        let backend = FakeHIDBackend([])
        let discovery = HIDDiscovery(backendFactory: { backend })
        do {
            _ = try await discovery.inspectControlInterface(registryEntryID: 101)
            Issue.record("Removed endpoint was allowed to open")
        } catch { #expect(error as? HIDDiscoveryError == .missingInterface(101)) }
        await discovery.stop()
        #expect(backend.trace.allSatisfy { !$0.phase.hasPrefix("inspect:") })
    }

    @Test
    func rawOpenFailurePreservesEndpointPhaseAndSignedReturnWithoutClose() async throws {
        let failure = Int32(bitPattern: 0xE00002C1)
        let backend = FakeHIDBackend(openResult: failure)
        let discovery = HIDDiscovery(backendFactory: { backend })
        let result = try await discovery.inspectControlInterface(registryEntryID: 101)
        await discovery.stop()
        #expect(!result.succeeded)
        #expect(result.operations.count == 1)
        #expect(result.operations[0].rawIOReturn == failure)
        #expect(result.operations[0].ioReturnHex == "0xE00002C1")
        #expect(result.operations[0].phase == "open")
        #expect(result.operations[0].registryEntryID == 101)
        let encoded = try JSONEncoder().encode(result)
        #expect(String(decoding: encoded, as: UTF8.self).contains("0xE00002C1"))
    }

    @Test
    func concurrentStopFinishesBackendExactlyOnceAndDoesNotRestart() async throws {
        let backend = FakeHIDBackend()
        let discovery = HIDDiscovery(backendFactory: { backend })
        _ = try await discovery.snapshot()
        async let first: Void = discovery.stop()
        async let second: Void = discovery.stop()
        _ = await (first, second)
        #expect(backend.trace.filter { $0.phase == "stop" }.count == 1)
        do { _ = try await discovery.snapshot(); Issue.record("Stopped discovery restarted") }
        catch { #expect(error as? HIDDiscoveryError == .stopped) }
    }

    @Test
    func stoppingBeforeFirstSnapshotNeverConstructsBackend() async {
        let backend = FakeHIDBackend()
        let discovery = HIDDiscovery(backendFactory: { backend })
        await discovery.stop()
        #expect(backend.trace.isEmpty)
    }

    @Test
    func droppingDiscoveryReleasesTheBackendOnItsThread() async throws {
        let backend = FakeHIDBackend()
        var discovery: HIDDiscovery? = HIDDiscovery(backendFactory: { backend })
        var stopped = backend.stopSignal.stream.makeAsyncIterator()
        _ = try await discovery!.snapshot()
        discovery = nil
        #expect(await stopped.next() != nil)
        #expect(backend.trace.last?.phase == "stop")
        #expect(Set(backend.trace.map(\.threadID)).count == 1)
    }
}
