import BazerCore
@testable import BazerHID
import CoreFoundation
import Darwin
import Foundation
import LogitechHIDPP
import RazerProtocol
import Testing

private final class TestQueryClock: HIDQueryClock {
    var seconds = 0.0
    var sleeps: [Double] = []
    var monotonicSeconds: Double { seconds }
    var date: Date { Date(timeIntervalSince1970: 1_000 + seconds) }
    func sleep(seconds: Double) { sleeps.append(seconds); self.seconds += seconds }
}

private final class TestReportBackend: HIDSynchronousReportBackend, @unchecked Sendable {
    let clock: TestQueryClock
    private let traceLock = NSLock()
    private var calls: [(String, UInt64, Bool)] = []
    var openCode: Int32 = 0
    var setCodes: [Int32] = []
    var getCodes: [Int32] = []
    var replies: [[UInt8]] = []
    var returnedLength: Int?
    var getDelay = 0.0
    var onGet: (() -> Void)?
    var command: UInt8 = 0x80
    var interfaces: [HIDInterfaceDescriptor]
    let getEntered = AsyncStream<Void>.makeStream()
    let releaseGet = DispatchSemaphore(value: 0)
    var blockGet = false
    var changeHandler: ((HIDDiscoveryEvent) -> Void)?

    init(clock: TestQueryClock = TestQueryClock(), interfaces: [HIDInterfaceDescriptor]? = nil) {
        self.clock = clock
        self.interfaces = interfaces ?? [Self.mouse()]
    }
    static func mouse(_ id: UInt64 = 101, parent: UInt64 = 10, vendor: UInt16 = 0x1532, product: UInt16 = 0xC5) -> HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(registryEntryID: id, usbParentRegistryEntryID: parent, vendorID: vendor, productID: product, product: "Synthetic test only", transport: "USB", primaryUsage: .mouse, usages: [.mouse], maxFeatureReportSize: 90, reportDescriptor: [5, 1, 9, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0])
    }
    var phases: [String] { traceLock.withLock { calls.map(\.0) } }
    var threadIDs: Set<UInt64> { traceLock.withLock { Set(calls.map(\.1)) } }
    var usesMainThread: Bool { traceLock.withLock { calls.contains { $0.2 } } }
    private func record(_ phase: String) {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        traceLock.withLock { calls.append((phase, id, Thread.isMainThread)) }
    }
    private func diagnostic(_ phase: String, _ endpoint: UInt64, _ code: Int32 = 0) -> HIDOperationDiagnostic {
        HIDOperationDiagnostic(phase: phase, registryEntryID: endpoint, rawIOReturn: code, message: "synthetic test result")
    }
    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) { record("start"); changeHandler = onChange }
    func snapshot() -> HIDDiscoverySnapshot { record("snapshot"); return HIDDiscoverySnapshot(capturedAt: clock.date, interfaces: interfaces) }
    func inspectInterface(registryEntryID: UInt64) -> HIDInspectionResult { record("inspect"); return HIDInspectionResult(registryEntryID: registryEntryID, operations: []) }
    func stop() { record("stop") }
    func openFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic { record("open"); return diagnostic("open", registryEntryID, openCode) }
    func closeFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic { record("close"); return diagnostic("close", registryEntryID) }
    func setFeature(registryEntryID: UInt64, request: HIDReadOnlyFeatureRequest) -> HIDOperationDiagnostic {
        record("set:\(request.commandID!)")
        command = request.commandID!
        return diagnostic("setFeature", registryEntryID, setCodes.isEmpty ? 0 : setCodes.removeFirst())
    }
    func getFeature(registryEntryID: UInt64, reportID: UInt8, capacity: Int) -> HIDRawFeatureReport {
        record("get:\(command)")
        getEntered.continuation.yield(())
        if blockGet { releaseGet.wait() }
        onGet?()
        clock.seconds += getDelay
        let bytes = replies.isEmpty ? Self.synthetic(command: command) : replies.removeFirst()
        return HIDRawFeatureReport(operation: diagnostic("getFeature", registryEntryID, getCodes.isEmpty ? 0 : getCodes.removeFirst()), bytes: bytes, actualLength: returnedLength ?? bytes.count)
    }
    static func synthetic(command: UInt8 = 0x80, status: UInt8 = 2, raw: UInt8 = 128) -> [UInt8] {
        var bytes = RazerRequest(command: RazerCommand(rawValue: command)!).bytes
        bytes[0] = status; bytes[9] = raw; bytes[88] = bytes[2...87].reduce(0, ^)
        return bytes
    }
}

private actor ConcurrentMouseIOBackend: HIDInputOutputBackend {
    private var onReport: (@Sendable (UInt8, [UInt8]) -> Void)?
    func open(endpoint: HIDInputOutputEndpoint, onReport: @escaping @Sendable (UInt8, [UInt8]) -> Void, onRemoval: @escaping @Sendable () -> Void) {
        self.onReport = onReport
    }
    func send(_ message: HIDPPMessage) { onReport?(message.kind.rawValue, message.bytes) }
    func close() { onReport = nil }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HIDFeatureTransportTests {
    private func request(endpoint: UInt64 = 101, parent: UInt64 = 10) -> HIDFeatureQueryGroup {
        HIDFeatureQueryGroup(physicalDeviceID: PhysicalDeviceID(rawValue: "usb-parent:\(parent)"), registryEntryID: endpoint, requests: [RazerCommand.battery, .charging].map { HIDReadOnlyFeatureRequest(reportID: 0, bytes: RazerRequest(command: $0).bytes) })
    }
    private static func validate(_ request: HIDReadOnlyFeatureRequest, _ bytes: [UInt8]) -> HIDReportValidation {
        do {
            _ = try RazerResponse.parse(bytes, for: RazerRequest(command: RazerCommand(rawValue: request.commandID!)!))
            return HIDReportValidation(valid: true, retryable: false, error: nil, checks: [])
        } catch RazerProtocolError.busy {
            return HIDReportValidation(valid: false, retryable: true, error: "busy", checks: [], failureCategory: .busy)
        } catch {
            return HIDReportValidation(valid: false, retryable: true, error: String(describing: error), checks: [])
        }
    }
    private func run(_ backend: TestReportBackend, cancellation: HIDQueryCancellation = HIDQueryCancellation()) throws -> HIDFeatureGroupResult {
        try HIDFeatureQueryRunner.run(request(), backend: backend, clock: backend.clock, cancellation: cancellation, validate: Self.validate)
    }

    @Test func completeGroupHasOneOpenCloseAndNoCommandInterleaving() throws {
        let backend = TestReportBackend()
        let result = try run(backend)
        #expect(backend.phases == ["open", "set:128", "get:128", "set:132", "get:132", "close"])
        #expect(backend.clock.sleeps == [0.031, 0.031])
        #expect(result.commands.allSatisfy { $0.response != nil && $0.failure == nil && $0.attempts.count == 1 })
        #expect(!result.budgetExceeded)
        #expect(result.synchronousCallCannotBeInterrupted)
    }

    @Test func busyThenValidRetriesOnlyWithinBoundAndKeepsTrace() throws {
        let backend = TestReportBackend()
        backend.replies = [TestReportBackend.synthetic(status: 1), TestReportBackend.synthetic()]
        let result = try run(backend)
        #expect(result.commands[0].attempts.count == 2)
        #expect(result.commands[0].attempts[0].failure?.category == .busy)
        #expect(result.commands[0].response != nil)
        #expect(result.commands[1].attempts.count == 1)
    }

    @Test func staleWrongTransactionAndBadChecksumNeverBecomeSamples() throws {
        let backend = TestReportBackend()
        var stale = TestReportBackend.synthetic(); stale[1] = 0x3F
        var wrongCommand = TestReportBackend.synthetic(command: 0x84)
        wrongCommand[9] = 255; wrongCommand[88] = wrongCommand[2...87].reduce(0, ^)
        var badChecksum = TestReportBackend.synthetic(); badChecksum[88] ^= 1
        backend.replies = [stale, wrongCommand, badChecksum]
        let result = try run(backend)
        #expect(result.commands[0].response == nil)
        #expect(result.commands[0].attempts.count == 3)
        #expect(result.commands[0].attempts.allSatisfy { $0.failure?.category == .malformedResponse })
        #expect(result.commands[1].response != nil)
    }

    @Test func lateSynchronousGetIsRetainedUntilReturnThenDiscardedAndClosed() throws {
        let backend = TestReportBackend(); backend.getDelay = 2.1
        let result = try run(backend)
        #expect(result.budgetExceeded)
        #expect(result.commands.allSatisfy { $0.response == nil && $0.failure?.category == .timeout })
        #expect(result.commands[0].attempts.count == 1)
        #expect(result.commands[0].attempts[0].rx?.count == 90)
        #expect(result.commands[0].attempts[0].discardedAfterDeadline)
        #expect(backend.phases == ["open", "set:128", "get:128", "close"])
    }

    @Test func invalidReturnedLengthAndImmediateErrorsRemainDiagnostic() throws {
        let oversized = TestReportBackend(); oversized.returnedLength = 91
        let result = try run(oversized)
        #expect(result.commands.allSatisfy { $0.response == nil && $0.attempts.count == 3 })
        #expect(result.commands[0].attempts[0].actualLength == 91)
        let denied = TestReportBackend(); denied.openCode = Int32(bitPattern: 0xE00002E2)
        let deniedResult = try run(denied)
        #expect(denied.phases == ["open"])
        #expect(deniedResult.commands.allSatisfy { $0.failure?.category == .denied && $0.attempts.isEmpty })
        #expect(deniedResult.operations[0].ioReturnHex == "0xE00002E2")
        let removed = TestReportBackend(); removed.setCodes = [Int32(bitPattern: 0xE00002C0), Int32(bitPattern: 0xE00002C0)]
        #expect(try run(removed).commands.allSatisfy { $0.failure?.category == .removed })
        #expect(!removed.phases.contains { $0.hasPrefix("get:") })
        #expect(removed.phases.last == "close")
    }

    @Test func cancellationDuringGetDiscardsResponseAndDoesNotPretendToCancelKernel() throws {
        let backend = TestReportBackend(); let token = HIDQueryCancellation()
        backend.onGet = { token.cancel() }
        let result = try run(backend, cancellation: token)
        #expect(result.cancellationRequested)
        #expect(result.commands.allSatisfy { $0.response == nil && $0.failure?.category == .cancelled })
        #expect(backend.phases == ["open", "set:128", "get:128", "close"])
    }

    @Test func arbitraryOrConfigurationReportsFailBeforeAnyOpen() {
        let backend = TestReportBackend()
        for index in [1, 5, 6, 7, 8, 88, 89] {
            var bytes = request().requests[0].bytes; bytes[index] ^= 1
            let group = HIDFeatureQueryGroup(physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, requests: [HIDReadOnlyFeatureRequest(reportID: 0, bytes: bytes), request().requests[1]])
            #expect(throws: (any Error).self) { try HIDFeatureQueryRunner.run(group, backend: backend, clock: backend.clock, cancellation: HIDQueryCancellation(), validate: Self.validate) }
        }
        #expect(backend.phases.isEmpty)
    }

    @Test func reservationIsPerPhysicalDeviceAndHeldAcrossInFlightGroup() {
        let reservations = HIDQueryReservations(); let first = PhysicalDeviceID(rawValue: "a"); let second = PhysicalDeviceID(rawValue: "b")
        #expect(reservations.acquire(first)); #expect(!reservations.acquire(first)); #expect(reservations.acquire(second))
        reservations.release(first); #expect(reservations.acquire(first))
    }

    private func typed(_ operation: HIDFeatureOperation) throws -> HIDReadOnlyFeatureRequest {
        HIDReadOnlyFeatureRequest(operation: operation, bytes: try operation.canonicalBytes())
    }

    @Test func typedPolicyRejectsUnboundSettingsAndAutomaticWritesBeforeOpen() throws {
        let backend = TestReportBackend()
        let session = HIDFeatureSessionBinding(id: UUID(), physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let read = try typed(.readDPI(storage: 1))
        let write = try typed(.setPollingRate(hertz: 500))
        for group in [
            HIDFeatureQueryGroup(physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, requests: [read]),
            HIDFeatureQueryGroup(session: session, intent: .automaticRead, requests: [read]),
            HIDFeatureQueryGroup(session: session, intent: .explicitRead, requests: [write])
        ] {
            #expect(throws: (any Error).self) { try HIDFeatureQueryRunner.run(group, backend: backend, clock: backend.clock, cancellation: HIDQueryCancellation(), validate: { _, _ in HIDReportValidation(valid: true, retryable: false, error: nil, checks: []) }) }
        }
        #expect(backend.phases.isEmpty)
    }

    @Test func legacyCodableGroupsRemainReadOnlyAfterDecoding() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as? [String: Any])
        json.removeValue(forKey: "session"); json.removeValue(forKey: "intent")
        var requests = try #require(json["requests"] as? [[String: Any]])
        for index in requests.indices { requests[index].removeValue(forKey: "operation") }
        json["requests"] = requests
        let decoded = try JSONDecoder().decode(HIDFeatureQueryGroup.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.intent == .automaticRead)
        #expect(decoded.requests.map(\.operation) == [.battery, .charging])
        try HIDFeatureQueryRunner.validateAllowlist(decoded)
    }

    @Test func typedPolicyChecksEveryByteAndParameterEvenWhenChecksumIsRecomputed() throws {
        let session = HIDFeatureSessionBinding(id: UUID(), physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let operation = HIDFeatureOperation.setDPI(storage: 1, x: 800, y: 1600)
        let intent = try HIDFeatureWriteIntent(session: session, operation: operation)
        for index in 0..<90 {
            var bytes = try operation.canonicalBytes(); bytes[index] ^= 1
            if index != 88 { bytes[88] = bytes[2...87].reduce(0, ^) }
            var group = HIDFeatureQueryGroup(session: session, intent: .userInitiatedWrite(intent), requests: [HIDReadOnlyFeatureRequest(operation: operation, bytes: bytes)])
            var before = try HIDFeatureOperation.readDPI(storage: 1).canonicalBytes(); before[0] = 2
            group.priorDPIResponse = before
            #expect(throws: (any Error).self) { try HIDFeatureQueryRunner.validateAllowlist(group) }
        }
        for operation in [HIDFeatureOperation.setDPI(storage: 0, x: 800, y: 800), .setDPI(storage: 1, x: 99, y: 800), .setDPI(storage: 1, x: 26050, y: 800), .setDPI(storage: 1, x: 801, y: 800), .setPollingRate(hertz: 8000), .setPollingRate(hertz: 250), .setDPIStages(payload: Array(repeating: 0, count: 38))] {
            #expect(throws: (any Error).self) { try operation.canonicalBytes() }
        }
    }

    @Test func writeTimeoutBusyAndMalformedAckNeverRetry() throws {
        let session = HIDFeatureSessionBinding(id: UUID(), physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let operation = HIDFeatureOperation.setPollingRate(hertz: 500)
        let typedRequest = try typed(operation)
        let group = HIDFeatureQueryGroup(session: session, intent: .userInitiatedWrite(try HIDFeatureWriteIntent(session: session, operation: operation)), requests: [typedRequest])
        for code in [Int32(bitPattern: 0xE00002D6), Int32(0)] {
            let backend = TestReportBackend(); backend.setCodes = [code]
            var busy = typedRequest.bytes; busy[0] = 1
            backend.replies = [busy]
            let result = try HIDFeatureQueryRunner.run(group, backend: backend, clock: backend.clock, cancellation: HIDQueryCancellation(), validate: { _, _ in HIDReportValidation(valid: true, retryable: true, error: nil, checks: []) })
            #expect(result.commands[0].attempts.count == 1)
            #expect(result.commands[0].response == nil)
            #expect(backend.phases.filter { $0.hasPrefix("set:") }.count == 1)
        }
    }

    @Test func liveBindingAllowsExplicitReadButRejectsForeignAndReplayedWriteIntents() async throws {
        let backend = TestReportBackend()
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        let binding = try await discovery.bindFeatureSession(physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let operation = HIDFeatureOperation.setPollingRate(hertz: 500)
        let typedRequest = try typed(operation)
        var ack = typedRequest.bytes; ack[0] = 2
        backend.replies = [ack]
        let group = HIDFeatureQueryGroup(session: binding, intent: .userInitiatedWrite(try HIDFeatureWriteIntent(session: binding, operation: operation)), requests: [typedRequest])
        let result = try await discovery.queryGroup(group, validate: { _, _ in HIDReportValidation(valid: true, retryable: false, error: nil, checks: []) })
        #expect(result.commands[0].response == ack)
        do { _ = try await discovery.queryGroup(group, validate: Self.validate); Issue.record("Replayed write intent accepted") } catch {}
        let foreign = HIDDiscovery(backendFactory: { TestReportBackend() }, processLockFactory: { _ in nil })
        do { _ = try await foreign.queryGroup(HIDFeatureQueryGroup(session: binding, intent: .explicitRead, requests: [try typed(.readPollingRate)]), validate: Self.validate); Issue.record("Foreign session accepted") } catch {}
        #expect(backend.phases.filter { $0.hasPrefix("set:") }.count == 1)
        await foreign.stop(); await discovery.stop()
    }

    @Test func adaptiveTransactionKeepsOneProcessLockAcrossReadWriteAndReadback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = TestReportBackend()
        backend.onGet = { #expect(throws: (any Error).self) { try HIDProcessQueryLock(directory: directory) } }
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { try HIDProcessQueryLock(physicalDeviceID: $0, directory: directory) })
        let session = try await discovery.bindFeatureSession(physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let read = try typed(.readPollingRate), write = try typed(.setPollingRate(hertz: 1000))
        var before = read.bytes; before[0] = 2; before[8] = 2; before[88] = before[2...87].reduce(0, ^)
        var ack = write.bytes; ack[0] = 2
        var after = read.bytes; after[0] = 2; after[8] = 1; after[88] = after[2...87].reduce(0, ^)
        backend.replies = [before, ack, after]
        let result = try await discovery.withFeatureTransaction(session: session) { transaction in
            let accept: @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation = { _, _ in HIDReportValidation(valid: true, retryable: false, error: nil, checks: []) }
            let original = try transaction.query(requests: [read], validate: accept)
            let intent = try HIDFeatureWriteIntent(session: session, operation: write.operation!)
            _ = try transaction.query(requests: [write], intent: .userInitiatedWrite(intent), validate: accept)
            let observed = try transaction.query(requests: [read], validate: accept)
            return [original.commands[0].response![8], observed.commands[0].response![8]]
        }
        #expect(result == [2, 1])
        let released = try HIDProcessQueryLock(directory: directory); withExtendedLifetime(released) {}
        #expect(backend.phases.filter { $0.hasPrefix("set:") } == ["set:133", "set:5", "set:133"])
        await discovery.stop()
    }

    @Test func dpiPolicyUsesActualTransactionReadAndPreservesEveryOpaqueByte() async throws {
        let backend = TestReportBackend()
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        let session = try await discovery.bindFeatureSession(physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let read = RazerSettingRequest.readDPI()
        var before = read.bytes; before[0] = 2; before[9...14] = [3, 32, 6, 64, 0xA5, 0x5A][...]; before[87] = 0xD9; before[88] = before[2...87].reduce(0, ^)
        let constraints = try RazerDPIConstraints(minimum: 100, maximum: 26000, step: 50)
        guard case .dpi(let original) = try RazerSettingResponse.parse(before, for: read) else { Issue.record("wrong response"); return }
        let write = try RazerSettingRequest.writeDPI(from: original, x: 1200, constraints: constraints)
        var ack = write.bytes; ack[0] = 2
        backend.replies = [before, ack]
        let result = try await discovery.withFeatureTransaction(session: session) { transaction in
            let accept: @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation = { _, _ in HIDReportValidation(valid: true, retryable: false, error: nil, checks: []) }
            _ = try transaction.query(requests: [HIDReadOnlyFeatureRequest(operation: .readDPI(storage: 1), bytes: read.bytes)], validate: accept)
            let operation = HIDFeatureOperation.setDPI(storage: 1, x: 1200, y: 1600)
            let intent = try HIDFeatureWriteIntent(session: session, operation: operation)
            return try transaction.query(requests: [HIDReadOnlyFeatureRequest(operation: operation, bytes: write.bytes)], intent: .userInitiatedWrite(intent), validate: accept)
        }
        #expect(result.commands[0].attempts[0].tx == write.bytes)
        #expect(result.commands[0].response == ack)
        await discovery.stop()
    }

    @Test func backupIdentityRequiresDedicatedIntentAndRedactsDiagnosticFrames() throws {
        let session = HIDFeatureSessionBinding(id: UUID(), physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let read = try typed(.readBackupIdentity)
        #expect(throws: (any Error).self) { try HIDFeatureQueryRunner.validateAllowlist(HIDFeatureQueryGroup(session: session, intent: .explicitRead, requests: [read])) }
        let backend = TestReportBackend()
        let serial = Array("SYNTHETIC-UNIT-123".utf8)
        var response = read.bytes; response[0] = 2; response[8..<(8 + serial.count)] = serial[...]; response[88] = response[2...87].reduce(0, ^)
        backend.replies = [response]
        let result = try HIDFeatureQueryRunner.run(HIDFeatureQueryGroup(session: session, intent: .backupIdentityRead, requests: [read]), backend: backend, clock: backend.clock, cancellation: HIDQueryCancellation(), validate: { _, _ in HIDReportValidation(valid: true, retryable: false, error: nil, checks: []) })
        #expect(result.commands[0].attempts[0].rx == nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.commands[0])) as? [String: Any])
        #expect(json["response"] == nil)
        #expect(result.commands[0].response == response) // In-memory hash parser input only.
    }

    @Test func stagePolicyNeedsActualScopedReadAndExplicitLayoutEvidenceAndPreservesOpaqueBytes() async throws {
        let backend = TestReportBackend()
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        let session = try await discovery.bindFeatureSession(physicalDeviceID: request().physicalDeviceID, registryEntryID: 101, profile: .razer00C5SettingsCandidate)
        let read = try typed(.readDPIStages(storage: 1))
        var original = read.bytes; original[0] = 2; original[9] = 1; original[10] = 2
        original[11...24] = [0, 3, 32, 6, 64, 0xA1, 0xB1, 1, 6, 64, 12, 128, 0xA2, 0xB2][...]
        original[87] = 0xCD; original[88] = original[2...87].reduce(0, ^)
        var payload = Array(original[8...87]); payload[4] = 4; payload[5] = 176
        let updatedPayload = payload
        let operation = HIDFeatureOperation.setDPIStages(payload: payload)
        var ack = try operation.canonicalBytes(); ack[0] = 2
        backend.replies = [original, ack]
        let written = try await discovery.withFeatureTransaction(session: session) { transaction in
            let accept: @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation = { _, _ in HIDReportValidation(valid: true, retryable: false, error: nil, checks: []) }
            #expect(throws: (any Error).self) { try transaction.confirmStageLayout(hardwareEvidenceReference: "synthetic offline layout assertion") }
            _ = try transaction.query(requests: [read], validate: accept)
            let evidence = try transaction.confirmStageLayout(hardwareEvidenceReference: "synthetic offline layout assertion; no real hardware")
            var corrupted = updatedPayload; corrupted[8] ^= 1
            let badOperation = HIDFeatureOperation.setDPIStages(payload: corrupted)
            let badIntent = try HIDFeatureWriteIntent(session: session, operation: badOperation, stageEvidence: evidence)
            #expect(throws: (any Error).self) { try transaction.query(requests: [HIDReadOnlyFeatureRequest(operation: badOperation, bytes: badOperation.canonicalBytes())], intent: .userInitiatedWrite(badIntent), validate: accept) }
            let intent = try HIDFeatureWriteIntent(session: session, operation: operation, stageEvidence: evidence)
            return try transaction.query(requests: [HIDReadOnlyFeatureRequest(operation: operation, bytes: operation.canonicalBytes())], intent: .userInitiatedWrite(intent), validate: accept).commands[0].response
        }
        #expect(written == ack)
        #expect(backend.phases.filter { $0.hasPrefix("set:") } == ["set:134", "set:6"])
        await discovery.stop()
    }

    @Test func processLockUsesRealFlockButOnlyAnIsolatedTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: HIDProcessQueryLock? = try HIDProcessQueryLock(directory: directory)
        #expect(first != nil)
        #expect(throws: (any Error).self) { try HIDProcessQueryLock(directory: directory) }
        first = nil
        let next = try HIDProcessQueryLock(directory: directory)
        withExtendedLifetime(next) {}
    }

    @Test func deviceLocksAllowDifferentHostsButExcludeSameHostAndLegacyProcesses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = PhysicalDeviceID(rawValue: "usb-parent:10")
        let secondID = PhysicalDeviceID(rawValue: "usb-path:/synthetic/receiver")
        do {
            let first = try HIDProcessQueryLock(physicalDeviceID: firstID, directory: directory)
            try withExtendedLifetime(first) {
                #expect(throws: (any Error).self) { try HIDProcessQueryLock(physicalDeviceID: firstID, directory: directory) }
                let second = try HIDProcessQueryLock(physicalDeviceID: secondID, directory: directory)
                withExtendedLifetime(second) {
                    #expect(throws: (any Error).self) { try HIDProcessQueryLock(directory: directory) }
                }
            }
        }
        // The failed acquisitions above must not leak a shared gate lock.
        do {
            let legacy = try HIDProcessQueryLock(directory: directory)
            withExtendedLifetime(legacy) {
                #expect(throws: (any Error).self) { try HIDProcessQueryLock(physicalDeviceID: firstID, directory: directory) }
                #expect(throws: (any Error).self) { try HIDProcessQueryLock(physicalDeviceID: secondID, directory: directory) }
            }
        }
        let released = try HIDProcessQueryLock(physicalDeviceID: firstID, directory: directory)
        withExtendedLifetime(released) {}
    }

    @Test func twoMouseRefreshesSucceedWhileOtherHostHasAnActiveTransaction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = HIDInterfaceDescriptor(registryEntryID: 999, usbParentRegistryEntryID: 99,
            vendorID: 0x046D, productID: 0xDEAD, product: "Synthetic receiver", transport: "USB",
            maxInputReportSize: 20, maxOutputReportSize: 20,
            reportDescriptor: [0x06,0x00,0xFF,0x09,1,0xA1,1,0x75,8,0x85,0x10,0x95,6,0x81,2,0x91,2,0x85,0x11,0x95,19,0x81,2,0x91,2,0xC0])
        let endpoint = try HIDInputOutputEndpoint(physicalDeviceID: PhysicalDeviceID(rawValue: "usb-parent:99"), descriptor: descriptor)
        let io = ConcurrentMouseIOBackend()
        let logitech = HIDInputOutputSession(endpoint: endpoint, backendFactory: { io }, lockFactory: { try HIDProcessQueryLock(physicalDeviceID: endpoint.physicalDeviceID, directory: directory) })
        let backend = TestReportBackend()
        let razer = HIDDiscovery(backendFactory: { backend }, processLockFactory: { try HIDProcessQueryLock(physicalDeviceID: $0, directory: directory) })
        let lease = try await logitech.acquireTransaction()
        // Refresh-all starts independent host reads together. Keep one receiver's
        // real transport lease active while the other mouse refreshes.
        do {
            let result = try await razer.queryGroup(request(), validate: Self.validate)
            #expect(result.commands.count == 2)
            #expect(result.commands.allSatisfy { $0.response != nil && $0.failure == nil })
        } catch {
            Issue.record("Second mouse refresh failed instead of producing a sample: \(error)")
        }
        let query = try HIDPPRequest(deviceIndex: 2, featureIndex: 9, command: .battery1000, softwareID: 1)
        let response = try await lease.exchange(query)
        #expect(response.bytes == query.message.bytes)
        await lease.finish()
        await logitech.close(); await razer.stop()
    }

    @Test func workerHoldsWholeGroupReservationAndStopWaitsForActualReturn() async throws {
        let backend = TestReportBackend(); backend.blockGet = true
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        let group = request()
        var entered = backend.getEntered.stream.makeAsyncIterator()
        let first = Task { try await discovery.queryGroup(group, validate: Self.validate) }
        _ = await entered.next()
        do { _ = try await discovery.queryGroup(group, validate: Self.validate); Issue.record("Overlapping group was accepted") }
        catch { #expect((error as? TelemetryFailure)?.category == .busy) }
        let stopped = Task { await discovery.stop() }
        first.cancel()
        #expect(!backend.phases.contains("close"))
        #expect(!backend.phases.contains("stop"))
        backend.releaseGet.signal()
        let result = try await first.value
        await stopped.value
        #expect(result.cancellationRequested)
        #expect(backend.phases.suffix(2) == ["close", "stop"])
        #expect(backend.threadIDs.count == 1)
        #expect(!backend.usesMainThread)
    }

    @Test func keyboardWrongPhysicalSelectorAndAuxiliaryEndpointsCannotSendReports() async {
        let mouse = TestReportBackend.mouse()
        let keyboard = TestReportBackend.mouse(201, parent: 20, vendor: 0x342D, product: 0xE51A)
        let auxiliary = HIDInterfaceDescriptor(registryEntryID: 102, usbParentRegistryEntryID: 10, vendorID: 0x1532, productID: 0xC5, product: "Synthetic auxiliary", transport: "USB", primaryUsage: .keyboard, usages: [.keyboard])
        let backend = TestReportBackend(interfaces: [mouse, keyboard, auxiliary])
        let discovery = HIDDiscovery(backendFactory: { backend }, processLockFactory: { _ in nil })
        for group in [request(endpoint: 201, parent: 20), request(endpoint: 102), request(parent: 999)] {
            do { _ = try await discovery.queryGroup(group, validate: Self.validate); Issue.record("Unsafe group was accepted") }
            catch {}
        }
        await discovery.stop()
        #expect(!backend.phases.contains("open"))
        #expect(!backend.phases.contains { $0.hasPrefix("set:") || $0.hasPrefix("get:") })
    }
}
