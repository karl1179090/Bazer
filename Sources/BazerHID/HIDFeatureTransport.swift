// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import CryptoKit
import Darwin
import Foundation

/// Transport permissions are selected by a typed operation, never by the legacy
/// request type's name or by accepting an arbitrary command byte.
public enum HIDFeatureOperation: Equatable, Codable, Sendable {
    case battery
    case charging
    case readFirmware
    case readBackupIdentity
    case readDPI(storage: UInt8)
    case setDPI(storage: UInt8, x: UInt16, y: UInt16)
    case readDPIStages(storage: UInt8)
    case setDPIStages(payload: [UInt8])
    case readPollingRate
    case setPollingRate(hertz: UInt16)

    public var isWrite: Bool {
        switch self {
        case .setDPI, .setDPIStages, .setPollingRate: true
        default: false
        }
    }

    var isTelemetry: Bool { self == .battery || self == .charging }

    /// Deliberately independent of the protocol target: this is the final access
    /// boundary's narrow, profile-specific canonical request validation.
    func canonicalBytes() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[1] = 0x1F
        switch self {
        case .battery: bytes[5] = 2; bytes[6] = 7; bytes[7] = 0x80
        case .charging: bytes[5] = 2; bytes[6] = 7; bytes[7] = 0x84
        case .readFirmware: bytes[5] = 2; bytes[7] = 0x81
        case .readBackupIdentity: bytes[5] = 0x16; bytes[7] = 0x82
        case .readDPI(let storage), .readDPIStages(let storage):
            guard storage == 1 else { throw HIDDiscoveryError.unsafeEndpoint("00C5 settings require the source-backed storage selector 1") }
            bytes[5] = self == .readDPI(storage: storage) ? 7 : 0x26
            bytes[6] = 4; bytes[7] = self == .readDPI(storage: storage) ? 0x85 : 0x86; bytes[8] = storage
        case .setDPI(let storage, let x, let y):
            guard storage == 1, (100...26000).contains(x), (100...26000).contains(y), x % 50 == 0, y % 50 == 0 else {
                throw HIDDiscoveryError.unsafeEndpoint("00C5 candidate DPI requires storage 1 and 100...26000 DPI in 50 DPI increments")
            }
            bytes[5] = 7; bytes[6] = 4; bytes[7] = 5
            bytes[8...12] = [storage, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255)][...]
        case .setDPIStages(let payload):
            try HIDFeatureQueryRunner.validateStagePayload(payload)
            bytes[5] = 0x26; bytes[6] = 4; bytes[7] = 6; bytes[8...87] = payload[...]
        case .readPollingRate: bytes[5] = 1; bytes[7] = 0x85
        case .setPollingRate(let hertz):
            let codes: [UInt16: UInt8] = [125: 8, 500: 2, 1000: 1]
            guard let code = codes[hertz] else { throw HIDDiscoveryError.unsafeEndpoint("00C5 traditional polling rate permits only 125, 500, or 1000 Hz") }
            bytes[5] = 1; bytes[7] = 5; bytes[8] = code
        }
        bytes[88] = bytes[2...87].reduce(0, ^)
        return bytes
    }
}

public enum HIDFeatureProfile: String, Equatable, Codable, Sendable {
    case razer00C5Telemetry
    /// Explicit opt-in for an exact-target validation workflow; not verified UI support.
    case razer00C5SettingsCandidate
}

/// Minted by the current discovery instance and invalidated by topology changes.
public struct HIDFeatureSessionBinding: Equatable, Codable, Sendable {
    public let id: UUID
    public let physicalDeviceID: PhysicalDeviceID
    public let registryEntryID: UInt64
    public let profile: HIDFeatureProfile
}

public struct HIDFeatureWriteIntent: Equatable, Codable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let operation: HIDFeatureOperation
    public let stageEvidence: HIDFeatureStageLayoutEvidence?
    public init(session: HIDFeatureSessionBinding, operation: HIDFeatureOperation, stageEvidence: HIDFeatureStageLayoutEvidence? = nil) throws {
        guard operation.isWrite else { throw HIDDiscoveryError.unsafeEndpoint("a write intent must name one exact typed setting operation") }
        id = UUID(); sessionID = session.id; self.operation = operation; self.stageEvidence = stageEvidence
    }
}

/// Minted only from a successful stage read inside one locked transaction.
/// The explicit reference records the operator's prior hardware confirmation of
/// the seven-byte layout and exact-ID active field, rather than guessing a base.
public struct HIDFeatureStageLayoutEvidence: Equatable, Codable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let readResponse: [UInt8]
    public let reference: String
}

public enum HIDFeatureIntent: Equatable, Codable, Sendable {
    case automaticRead
    case explicitRead
    case backupIdentityRead
    case userInitiatedWrite(HIDFeatureWriteIntent)
}

public struct HIDReadOnlyFeatureRequest: Equatable, Codable, Sendable {
    public let reportID: UInt8
    public let bytes: [UInt8]
    public let operation: HIDFeatureOperation?
    public init(reportID: UInt8, bytes: [UInt8]) {
        self.reportID = reportID; self.bytes = bytes
        // Compatibility only. Canonical bytes are still checked before I/O.
        operation = bytes.count > 7 && bytes[6] == 7 ? (bytes[7] == 0x80 ? .battery : bytes[7] == 0x84 ? .charging : nil) : nil
    }
    public init(operation: HIDFeatureOperation, reportID: UInt8 = 0, bytes: [UInt8]) {
        self.operation = operation; self.reportID = reportID; self.bytes = bytes
    }
    private enum CodingKeys: String, CodingKey { case reportID, bytes, operation }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let reportID = try container.decode(UInt8.self, forKey: .reportID)
        let bytes = try container.decode([UInt8].self, forKey: .bytes)
        if let operation = try container.decodeIfPresent(HIDFeatureOperation.self, forKey: .operation) {
            self.init(operation: operation, reportID: reportID, bytes: bytes)
        } else { self.init(reportID: reportID, bytes: bytes) }
    }
    public var commandID: UInt8? { bytes.count > 7 ? bytes[7] : nil }
}

public struct HIDFeatureQueryGroup: Equatable, Codable, Sendable {
    public let physicalDeviceID: PhysicalDeviceID
    public let registryEntryID: UInt64
    public let requests: [HIDReadOnlyFeatureRequest]
    public let session: HIDFeatureSessionBinding?
    public let intent: HIDFeatureIntent
    /// Only a scoped transaction may supply this, from its own successful read.
    var priorDPIResponse: [UInt8]? = nil
    public init(physicalDeviceID: PhysicalDeviceID, registryEntryID: UInt64, requests: [HIDReadOnlyFeatureRequest]) {
        self.physicalDeviceID = physicalDeviceID; self.registryEntryID = registryEntryID; self.requests = requests
        session = nil; intent = .automaticRead
    }
    public init(session: HIDFeatureSessionBinding, intent: HIDFeatureIntent, requests: [HIDReadOnlyFeatureRequest]) {
        physicalDeviceID = session.physicalDeviceID; registryEntryID = session.registryEntryID
        self.requests = requests; self.session = session; self.intent = intent
    }
    private enum CodingKeys: String, CodingKey { case physicalDeviceID, registryEntryID, requests, session, intent }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        physicalDeviceID = try container.decode(PhysicalDeviceID.self, forKey: .physicalDeviceID)
        registryEntryID = try container.decode(UInt64.self, forKey: .registryEntryID)
        requests = try container.decode([HIDReadOnlyFeatureRequest].self, forKey: .requests)
        session = try container.decodeIfPresent(HIDFeatureSessionBinding.self, forKey: .session)
        intent = try container.decodeIfPresent(HIDFeatureIntent.self, forKey: .intent) ?? .automaticRead
    }
}

public struct HIDReportValidationCheck: Equatable, Codable, Sendable {
    public let name: String
    public let expected: String
    public let actual: String
    public let passed: Bool
    public init(name: String, expected: String, actual: String, passed: Bool) {
        self.name = name; self.expected = expected; self.actual = actual; self.passed = passed
    }
}

public struct HIDReportValidation: Equatable, Codable, Sendable {
    public let valid: Bool
    public let retryable: Bool
    public let error: String?
    public let checks: [HIDReportValidationCheck]
    public let failureCategory: TelemetryFailureCategory?
    public let protocolStatus: UInt8?
    public init(valid: Bool, retryable: Bool, error: String?, checks: [HIDReportValidationCheck], failureCategory: TelemetryFailureCategory? = nil, protocolStatus: UInt8? = nil) {
        self.valid = valid; self.retryable = retryable; self.error = error; self.checks = checks
        self.failureCategory = failureCategory; self.protocolStatus = protocolStatus
    }
}

public struct HIDRawFeatureReport: Equatable, Codable, Sendable {
    public let operation: HIDOperationDiagnostic
    public let bytes: [UInt8]
    public let actualLength: Int
    public init(operation: HIDOperationDiagnostic, bytes: [UInt8], actualLength: Int) {
        self.operation = operation; self.bytes = bytes; self.actualLength = actualLength
    }
}

public struct HIDFeatureAttempt: Equatable, Codable, Sendable {
    public let number: Int
    public let startedAt: Date
    public let receivedAt: Date?
    public let elapsedMilliseconds: Double
    public let tx: [UInt8]
    public let rx: [UInt8]?
    public let actualLength: Int?
    public let operations: [HIDOperationDiagnostic]
    public let validation: HIDReportValidation?
    public let failure: TelemetryFailure?
    public let discardedAfterDeadline: Bool
}

public struct HIDFeatureCommandResult: Equatable, Codable, Sendable {
    public let commandID: UInt8
    public let response: [UInt8]?
    public let receivedAt: Date?
    public let attempts: [HIDFeatureAttempt]
    public let failure: TelemetryFailure?
    private enum CodingKeys: String, CodingKey { case commandID, response, receivedAt, attempts, failure }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandID, forKey: .commandID)
        // Backup identity is consumed in memory only. JSON diagnostics must
        // never serialize its raw serial response.
        if commandID != 0x82 { try container.encodeIfPresent(response, forKey: .response) }
        try container.encodeIfPresent(receivedAt, forKey: .receivedAt)
        try container.encode(attempts, forKey: .attempts)
        try container.encodeIfPresent(failure, forKey: .failure)
    }
}

public struct HIDFeatureGroupResult: Equatable, Codable, Sendable {
    public let physicalDeviceID: PhysicalDeviceID
    public let registryEntryID: UInt64
    public let startedAt: Date
    public let finishedAt: Date
    public let elapsedMilliseconds: Double
    public let budgetMilliseconds: Double
    public let budgetExceeded: Bool
    public let cancellationRequested: Bool
    public let synchronousCallCannotBeInterrupted: Bool
    public let operations: [HIDOperationDiagnostic]
    public let commands: [HIDFeatureCommandResult]
}

public protocol HIDFeatureGroupTransport: Sendable {
    func queryGroup(_ group: HIDFeatureQueryGroup, validate: @escaping @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation) async throws -> HIDFeatureGroupResult
}

/// A scoped synchronous transaction on the HID worker. The object cannot be
/// used on another thread or after its body returns. No raw backend is exposed.
public final class HIDFeatureTransaction {
    private let session: HIDFeatureSessionBinding
    private let backend: any HIDSynchronousReportBackend
    private let cancellation: HIDQueryCancellation
    private let consumeWrite: (UUID) throws -> Void
    private let owner = Thread.current
    private var active = true
    private var stageRead: [UInt8]?
    private var dpiRead: [UInt8]?
    private var stageEvidence: HIDFeatureStageLayoutEvidence?

    init(session: HIDFeatureSessionBinding, backend: any HIDSynchronousReportBackend, cancellation: HIDQueryCancellation, consumeWrite: @escaping (UUID) throws -> Void) {
        self.session = session; self.backend = backend; self.cancellation = cancellation; self.consumeWrite = consumeWrite
    }
    func finish() { active = false }

    /// Call only after the device/firmware's layout and active-ID semantics have
    /// been confirmed by a separate hardware validation. Ordinary reads never
    /// call this method and cannot grant stage-write permission automatically.
    public func confirmStageLayout(hardwareEvidenceReference: String) throws -> HIDFeatureStageLayoutEvidence {
        guard active, Thread.current === owner, !hardwareEvidenceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let stageRead else {
            throw HIDDiscoveryError.unsafeEndpoint("stage layout confirmation needs a successful read in this transaction and a hardware evidence reference")
        }
        let payload = Array(stageRead[8...87])
        try HIDFeatureQueryRunner.validateStagePayload(payload)
        let evidence = HIDFeatureStageLayoutEvidence(id: UUID(), sessionID: session.id, readResponse: stageRead, reference: hardwareEvidenceReference)
        stageEvidence = evidence
        return evidence
    }

    public func query(requests: [HIDReadOnlyFeatureRequest], intent: HIDFeatureIntent = .explicitRead, validate: @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation) throws -> HIDFeatureGroupResult {
        guard active, Thread.current === owner else { throw HIDDiscoveryError.unsafeEndpoint("feature transaction is no longer active on its owning worker") }
        var group = HIDFeatureQueryGroup(session: session, intent: intent, requests: requests)
        if requests.contains(where: { if case .setDPI = $0.operation { true } else { false } }) {
            guard let dpiRead else { throw HIDDiscoveryError.unsafeEndpoint("DPI writes require a successful complete read in the same transaction") }
            group.priorDPIResponse = dpiRead
        }
        try HIDFeatureQueryRunner.validateAllowlist(group)
        if case .userInitiatedWrite(let write) = intent {
            if case .setDPIStages = write.operation {
                guard let evidence = write.stageEvidence, evidence == stageEvidence, evidence.readResponse == stageRead else { throw HIDDiscoveryError.unsafeEndpoint("stage edit lacks this transaction's confirmed complete read image") }
            }
            try consumeWrite(write.id)
            dpiRead = nil; stageRead = nil; stageEvidence = nil
        }
        for request in requests {
            if case .readDPI = request.operation { dpiRead = nil }
            if case .readDPIStages = request.operation { stageRead = nil; stageEvidence = nil }
        }
        let result = try HIDFeatureQueryRunner.run(group, backend: backend, clock: SystemHIDQueryClock(), cancellation: cancellation, validate: validate)
        for (request, command) in zip(requests, result.commands) {
            if case .readDPIStages = request.operation, let response = command.response { stageRead = response; stageEvidence = nil }
            if case .readDPI = request.operation, let response = command.response { dpiRead = response }
        }
        return result
    }
}

/// Implementations and every call remain confined to the existing HID worker.
public protocol HIDSynchronousReportBackend: HIDDiscoveryBackend {
    func openFeatureInterface(registryEntryID: UInt64) throws -> HIDOperationDiagnostic
    func setFeature(registryEntryID: UInt64, request: HIDReadOnlyFeatureRequest) throws -> HIDOperationDiagnostic
    func getFeature(registryEntryID: UInt64, reportID: UInt8, capacity: Int) throws -> HIDRawFeatureReport
    func closeFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic
}

final class HIDQueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Reservation covers queueing and the complete Set/wait/Get/retry group.
final class HIDQueryReservations: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: Set<PhysicalDeviceID> = []
    func acquire(_ id: PhysicalDeviceID) -> Bool { lock.lock(); defer { lock.unlock() }; return devices.insert(id).inserted }
    func release(_ id: PhysicalDeviceID) { lock.lock(); devices.remove(id); lock.unlock() }
}

protocol HIDQueryClock {
    var monotonicSeconds: Double { get }
    var date: Date { get }
    func sleep(seconds: Double)
}

struct SystemHIDQueryClock: HIDQueryClock {
    var monotonicSeconds: Double { ProcessInfo.processInfo.systemUptime }
    var date: Date { Date() }
    func sleep(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

/// Cross-process exclusion for one physical host, held until real I/O returns.
/// A shared legacy gate lets different hosts run together while still excluding
/// older Bazer versions that take the original global lock exclusively.
final class HIDProcessQueryLock {
    private let descriptors: [Int32]
    init(physicalDeviceID: PhysicalDeviceID? = nil, directory testDirectory: URL? = nil) throws {
        let directory = testDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bazer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gate = try Self.acquire(directory.appendingPathComponent("hid-query.lock"), mode: physicalDeviceID == nil ? LOCK_EX : LOCK_SH)
        do {
            if let physicalDeviceID {
                // Physical IDs can contain USB paths. Hash to one stable, safe
                // filename shared by all processes, never Swift's random hashValue.
                let key = SHA256.hash(data: Data(physicalDeviceID.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
                let device = try Self.acquire(directory.appendingPathComponent("hid-query-\(key).lock"), mode: LOCK_EX)
                descriptors = [device, gate]
            } else {
                descriptors = [gate]
            }
        } catch {
            Self.release(gate)
            throw error
        }
    }
    private static func acquire(_ url: URL, mode: Int32) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TelemetryFailure(category: .transport, message: "Cannot open Bazer query lock: errno \(errno)", operation: "processLock") }
        guard flock(descriptor, mode | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw TelemetryFailure(category: .busy, message: "Another Bazer query holds this physical device or the legacy global HID lock (errno \(code)).", operation: "processLock")
        }
        return descriptor
    }
    private static func release(_ descriptor: Int32) { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    deinit { descriptors.forEach(Self.release) }
}

enum HIDFeatureQueryRunner {
    static func validateStagePayload(_ payload: [UInt8]) throws {
        guard payload.count == 80, payload[0] == 1, (1...5).contains(payload[2]) else { throw HIDDiscoveryError.unsafeEndpoint("unknown or incomplete 00C5 stage layout") }
        let ids = (0..<Int(payload[2])).map { payload[3 + $0 * 7] }
        guard Set(ids).count == ids.count, ids.contains(payload[1]) else { throw HIDDiscoveryError.unsafeEndpoint("stage IDs or exact-ID active semantics are not confirmed") }
        for stage in 0..<Int(payload[2]) {
            let offset = 3 + stage * 7
            for axis in [offset + 1, offset + 3] {
                let dpi = UInt16(payload[axis]) << 8 | UInt16(payload[axis + 1])
                guard (100...26000).contains(dpi), dpi % 50 == 0 else { throw HIDDiscoveryError.unsafeEndpoint("stage DPI outside conservative 00C5 candidate bounds") }
            }
        }
    }

    private static func validateStageEdit(_ payload: [UInt8], evidence: HIDFeatureStageLayoutEvidence, sessionID: UUID) throws {
        let bytes = evidence.readResponse
        guard evidence.sessionID == sessionID, !evidence.reference.isEmpty,
              bytes.count == 90, bytes[0] == 2, bytes[1] == 0x1F, bytes[2...4].allSatisfy({ $0 == 0 }), bytes[5] == 38, bytes[6] == 4, bytes[7] == 0x86, bytes[89] == 0,
              bytes[88] == bytes[2...87].reduce(0, ^) else { throw HIDDiscoveryError.unsafeEndpoint("invalid stage read evidence") }
        let before = Array(bytes[8...87]); try validateStagePayload(before); try validateStagePayload(payload)
        var editable: Set<Int> = [1]
        for stage in 0..<Int(before[2]) { for axisByte in 1...4 { editable.insert(3 + stage * 7 + axisByte) } }
        guard (0..<80).allSatisfy({ editable.contains($0) || before[$0] == payload[$0] }) else { throw HIDDiscoveryError.unsafeEndpoint("stage edit changes IDs, count, storage, reserved, unused, or trailing bytes") }
    }
    private static func validateEnvelope(_ bytes: [UInt8], request: HIDReadOnlyFeatureRequest) -> HIDReportValidation? {
        guard bytes.count == 90, bytes[1] == 0x1F, bytes[2...4].allSatisfy({ $0 == 0 }),
              bytes[5] == request.bytes[5], bytes[6] == request.bytes[6], bytes[7] == request.bytes[7],
              bytes[88] == bytes[2...87].reduce(0, ^), bytes[89] == 0 else {
            return HIDReportValidation(valid: false, retryable: true, error: "Invalid Razer frame length, association, structure, or checksum", checks: [], failureCategory: .malformedResponse)
        }
        guard bytes[0] == 2 else {
            return HIDReportValidation(valid: false, retryable: bytes[0] == 1, error: "Razer device status \(bytes[0])", checks: [], failureCategory: bytes[0] == 1 ? .busy : .malformedResponse, protocolStatus: bytes[0])
        }
        return nil
    }
    static func validateAllowlist(_ group: HIDFeatureQueryGroup) throws {
        guard !group.requests.isEmpty, group.requests.count <= 16 else { throw HIDDiscoveryError.unsafeEndpoint("a feature transaction needs 1...16 typed operations") }
        if let session = group.session {
            guard session.physicalDeviceID == group.physicalDeviceID, session.registryEntryID == group.registryEntryID else { throw HIDDiscoveryError.unsafeEndpoint("feature session target mismatch") }
        }
        if case .userInitiatedWrite(let intent) = group.intent {
            guard group.session?.id == intent.sessionID, group.requests.count == 1,
                  group.requests[0].operation == intent.operation, intent.operation.isWrite else {
                throw HIDDiscoveryError.unsafeEndpoint("write intent does not match this exact session and operation")
            }
            if case .setDPIStages(let payload) = intent.operation {
                guard let evidence = intent.stageEvidence else { throw HIDDiscoveryError.unsafeEndpoint("stage layout remains unverified for this session") }
                try validateStageEdit(payload, evidence: evidence, sessionID: intent.sessionID)
            }
        } else {
            guard group.requests.allSatisfy({ $0.operation?.isWrite == false }) else { throw HIDDiscoveryError.unsafeEndpoint("read paths cannot send setting commands") }
        }
        for request in group.requests {
            guard let operation = request.operation else { throw HIDDiscoveryError.unsafeEndpoint("untyped feature operation") }
            if !operation.isTelemetry {
                guard group.session?.profile == .razer00C5SettingsCandidate, group.intent != .automaticRead else {
                    throw HIDDiscoveryError.unsafeEndpoint("settings require a bound candidate profile and an explicit intent")
                }
            }
            if operation == .readBackupIdentity, group.intent != .backupIdentityRead {
                throw HIDDiscoveryError.unsafeEndpoint("unique identity reads require an explicit backup-only intent")
            }
            var expected = try operation.canonicalBytes()
            if case .setDPI(let storage, let x, let y) = operation {
                guard let before = group.priorDPIResponse,
                      validateEnvelope(before, request: HIDReadOnlyFeatureRequest(operation: .readDPI(storage: storage), bytes: try HIDFeatureOperation.readDPI(storage: storage).canonicalBytes())) == nil,
                      before[8] == storage else { throw HIDDiscoveryError.unsafeEndpoint("DPI write lacks a valid transaction-bound source image") }
                expected[8...87] = before[8...87]
                expected[9...12] = [UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255)][...]
                expected[88] = expected[2...87].reduce(0, ^)
            }
            guard request.reportID == 0, request.bytes == expected else {
                throw HIDDiscoveryError.unsafeEndpoint("request differs from its exact typed Report 0 / 90B / TID 1F operation, parameters, or checksum")
            }
        }
    }

    static func run(_ group: HIDFeatureQueryGroup, backend: any HIDSynchronousReportBackend, clock: any HIDQueryClock, cancellation: HIDQueryCancellation, validate: @Sendable (HIDReadOnlyFeatureRequest, [UInt8]) -> HIDReportValidation) throws -> HIDFeatureGroupResult {
        try validateAllowlist(group)
        let startedAt = clock.date
        let start = clock.monotonicSeconds
        let deadline = start + 2
        var groupOperations: [HIDOperationDiagnostic] = []
        var commands: [HIDFeatureCommandResult] = []
        let opened = try backend.openFeatureInterface(registryEntryID: group.registryEntryID)
        groupOperations.append(opened)
        var openedSuccessfully = opened.rawIOReturn == 0
        defer { if openedSuccessfully { _ = backend.closeFeatureInterface(registryEntryID: group.registryEntryID) } }

        func failure(_ category: TelemetryFailureCategory, _ message: String, operation: String? = nil, code: Int32? = nil) -> TelemetryFailure {
            TelemetryFailure(category: category, message: message, ioReturn: code, operation: operation, endpointRegistryEntryID: group.registryEntryID)
        }
        for request in group.requests {
            var attempts: [HIDFeatureAttempt] = []
            var response: [UInt8]?
            var receivedAt: Date?
            var lastFailure: TelemetryFailure?
            if opened.rawIOReturn != 0 { lastFailure = failure(category(opened.rawIOReturn), opened.message, operation: "open", code: opened.rawIOReturn) }
            else {
                // A write may have taken effect even when Set/Get times out or
                // its ACK is malformed. It is never automatically replayed.
                let attemptLimit = request.operation?.isWrite == true ? 1 : 3
                for number in 1...attemptLimit {
                    if cancellation.isCancelled { lastFailure = failure(.cancelled, "Cancellation requested; no further HID operation started."); break }
                    if clock.monotonicSeconds >= deadline { lastFailure = failure(.timeout, "The 2000 ms logical query budget expired."); break }
                    let attemptDate = clock.date
                    let attemptStart = clock.monotonicSeconds
                    var operations: [HIDOperationDiagnostic] = []
                    var raw: HIDRawFeatureReport?
                    var validation: HIDReportValidation?
                    var attemptFailure: TelemetryFailure?
                    do {
                        let set = try backend.setFeature(registryEntryID: group.registryEntryID, request: request)
                        operations.append(set)
                        if set.rawIOReturn != 0 { attemptFailure = failure(category(set.rawIOReturn), set.message, operation: "setFeature", code: set.rawIOReturn) }
                        else if cancellation.isCancelled { attemptFailure = failure(.cancelled, "Cancellation requested after SetReport; no GetReport started.") }
                        else if clock.monotonicSeconds >= deadline { attemptFailure = failure(.timeout, "SetReport returned after the logical budget expired; further operations suppressed.") }
                        else {
                            clock.sleep(seconds: min(0.031, max(0, deadline - clock.monotonicSeconds)))
                            if cancellation.isCancelled { attemptFailure = failure(.cancelled, "Cancellation requested during the settling interval.") }
                            else if clock.monotonicSeconds >= deadline { attemptFailure = failure(.timeout, "The logical budget expired during the settling interval.") }
                            else {
                                raw = try backend.getFeature(registryEntryID: group.registryEntryID, reportID: request.reportID, capacity: 90)
                                operations.append(raw!.operation)
                                if raw!.operation.rawIOReturn != 0 { attemptFailure = failure(category(raw!.operation.rawIOReturn), raw!.operation.message, operation: "getFeature", code: raw!.operation.rawIOReturn) }
                                else {
                                    validation = validateEnvelope(raw!.bytes, request: request) ?? validate(request, raw!.bytes)
                                    if raw!.actualLength != raw!.bytes.count {
                                        attemptFailure = failure(.malformedResponse, "Returned length \(raw!.actualLength) exceeds the 90-byte buffer or is invalid.", operation: "getFeature")
                                    } else if validation?.valid != true {
                                        attemptFailure = TelemetryFailure(category: validation?.failureCategory ?? .malformedResponse, message: validation?.error ?? "Invalid response", operation: "validate", endpointRegistryEntryID: group.registryEntryID, protocolStatus: validation?.protocolStatus)
                                    }
                                }
                            }
                        }
                    } catch let error as TelemetryFailure { attemptFailure = error }
                    catch { attemptFailure = failure(.transport, String(describing: error)) }
                    let late = clock.monotonicSeconds >= deadline
                    if late { attemptFailure = failure(.timeout, "Synchronous HID call returned after the 2000 ms logical budget; response discarded. The kernel call was not forcibly cancelled.") }
                    if cancellation.isCancelled { attemptFailure = failure(.cancelled, "Cancellation requested; returned response discarded after the synchronous call completed.") }
                    let date = raw == nil ? nil : clock.date
                    attempts.append(HIDFeatureAttempt(number: number, startedAt: attemptDate, receivedAt: date, elapsedMilliseconds: (clock.monotonicSeconds - attemptStart) * 1000, tx: request.bytes, rx: request.operation == .readBackupIdentity ? nil : raw?.bytes, actualLength: raw?.actualLength, operations: operations, validation: validation, failure: attemptFailure, discardedAfterDeadline: late))
                    lastFailure = attemptFailure
                    if attemptFailure == nil, let raw { response = raw.bytes; receivedAt = date; break }
                    if late || cancellation.isCancelled || attemptFailure?.category == .denied || attemptFailure?.category == .removed || attemptFailure?.category == .cancelled { break }
                    if let validation, !validation.valid && !validation.retryable { break }
                    if number < attemptLimit { clock.sleep(seconds: min(0.031, max(0, deadline - clock.monotonicSeconds))) }
                }
            }
            commands.append(HIDFeatureCommandResult(commandID: request.commandID!, response: response, receivedAt: receivedAt, attempts: attempts, failure: lastFailure))
        }
        if openedSuccessfully {
            groupOperations.append(backend.closeFeatureInterface(registryEntryID: group.registryEntryID))
            openedSuccessfully = false
        }
        return HIDFeatureGroupResult(physicalDeviceID: group.physicalDeviceID, registryEntryID: group.registryEntryID, startedAt: startedAt, finishedAt: clock.date, elapsedMilliseconds: (clock.monotonicSeconds - start) * 1000, budgetMilliseconds: 2000, budgetExceeded: clock.monotonicSeconds >= deadline, cancellationRequested: cancellation.isCancelled, synchronousCallCannotBeInterrupted: true, operations: groupOperations, commands: commands)
    }

    private static func category(_ code: Int32) -> TelemetryFailureCategory {
        switch UInt32(bitPattern: code) {
        case 0xE00002C1, 0xE00002E2: .denied
        case 0xE00002D6: .timeout
        case 0xE00002D7, 0xE00002D9, 0xE00002C0: .removed
        case 0xE00002C5, 0xE00002D5: .busy
        case 0xE00002EB: .cancelled
        default: .transport
        }
    }
}
