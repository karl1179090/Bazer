// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import SwiftUI
import UserNotifications

enum NotificationAuthorization: Equatable {
    case unknown, notDetermined, denied, authorized, provisional
    var canDeliver: Bool { self == .authorized || self == .provisional }
    var text: String {
        switch self {
        case .unknown: "尚未读取系统授权"
        case .notDetermined: "尚未请求系统授权"
        case .denied: "系统通知授权已拒绝，可在系统设置中修改"
        case .authorized: "系统通知已授权"
        case .provisional: "系统允许静默通知"
        }
    }
}

@MainActor
protocol NotificationBackend: AnyObject {
    func authorization() async throws -> NotificationAuthorization
    func requestAuthorization() async throws
    func send(identifier: String, title: String, body: String) async throws
}

/// Creation is inert. UNUserNotificationCenter is only obtained in a running App.
@MainActor
final class SystemNotificationBackend: NotificationBackend {
    private let delegate = ForegroundNotificationDelegate()
    private var retainedCenter: UNUserNotificationCenter?
    private var center: UNUserNotificationCenter {
        if let retainedCenter { return retainedCenter }
        let value = UNUserNotificationCenter.current()
        value.delegate = delegate
        retainedCenter = value
        return value
    }
    func authorization() async throws -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        @unknown default: .unknown
        }
    }
    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }
    func send(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
final class NotificationService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var authorization: NotificationAuthorization = .unknown
    @Published private(set) var isChanging = false
    @Published private(set) var isSendingTest = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var testMessage: String?
    private let backend: any NotificationBackend
    private let persistence: any NotificationPreferencesPersisting
    private let now: () -> Date
    private var preferences = NotificationPreferences()
    private var latestSnapshot: DeviceStoreSnapshot?
    private var latestAudioSnapshot: BluetoothAudioSnapshot?
    private struct AudioEvent: Equatable { let session: BluetoothAudioSession; let version: UInt64; let epoch: UInt64; let requestID: UInt64 }
    private var handledAudio: [BluetoothAudioDeviceID: AudioEvent] = [:]
    private var pendingAudioRecoveryComponents: [String: Set<String>] = [:]
    private var handled: [DeviceSessionID: Date] = [:]
    private var handledLogical: [LogicalDeviceSessionID: Date] = [:]
    private var evaluationTask: Task<Void, Never>?
    private var hasStarted = false
    private var isSuspended = false
    private var revision = 0

    init(backend: any NotificationBackend = SystemNotificationBackend(),
        persistence: any NotificationPreferencesPersisting = FileNotificationPreferences(), now: @escaping () -> Date = Date.init) {
        self.backend = backend; self.persistence = persistence; self.now = now
        do { preferences = try persistence.load(); isEnabled = preferences.isEnabled }
        catch { errorMessage = "通知偏好载入失败：\(Self.describe(error))" }
    }

    var canSendTest: Bool { isEnabled && authorization.canDeliver && !isChanging && !isSendingTest }

    func start() async {
        guard !Task.isCancelled else { return }
        hasStarted = true
        await refreshAuthorization()
        scheduleEvaluation()
    }
    func refreshAuthorization() async {
        do { authorization = try await backend.authorization() }
        catch { authorization = .unknown; errorMessage = "读取通知授权失败：\(Self.describe(error))" }
    }
    func setEnabledByUser(_ enabled: Bool) async {
        revision += 1
        let operation = revision
        var proposed = preferences; proposed.isEnabled = enabled
        do { try commit(proposed); errorMessage = nil }
        catch {
            if !enabled {
                preferences.isEnabled = false; isEnabled = false; isChanging = false
                errorMessage = "本次运行已关闭通知，但设置保存失败，下次启动可能恢复此前设置：\(Self.describe(error))"
            } else { errorMessage = "通知偏好保存失败：\(Self.describe(error))" }
            return
        }
        guard enabled else { isChanging = false; return }
        isChanging = true
        defer { if operation == revision { isChanging = false } }
        do {
            authorization = try await backend.authorization()
            guard operation == revision, isEnabled else { return }
            if authorization == .notDetermined {
                try await backend.requestAuthorization()
                authorization = try await backend.authorization()
            }
        } catch { errorMessage = "请求通知授权失败：\(Self.describe(error))" }
        guard operation == revision, isEnabled else { return }
        isChanging = false
        scheduleEvaluation()
    }

    func sendTestByUser() async {
        guard canSendTest else { return }
        isSendingTest = true; testMessage = nil
        defer { isSendingTest = false }
        await refreshAuthorization()
        guard isEnabled, authorization.canDeliver else { return }
        do {
            try await backend.send(identifier: "bazer.test.\(UUID().uuidString)", title: "Bazer 测试通知",
                body: "这是一条由你手动发送的测试通知，用于检查系统通知显示。")
            testMessage = "测试通知已提交给系统。显示方式由系统通知设置决定。"
        } catch { errorMessage = "发送测试通知失败：\(Self.describe(error))" }
    }

    func consume(_ snapshot: DeviceStoreSnapshot) {
        latestSnapshot = snapshot
        scheduleEvaluation()
    }
    func setSuspended(_ suspended: Bool) { isSuspended = suspended; if !suspended { scheduleEvaluation() } }
    func consumeBluetoothAudio(_ snapshot: BluetoothAudioSnapshot) {
        if let latest = latestAudioSnapshot, snapshot.epoch < latest.epoch || (snapshot.epoch == latest.epoch && snapshot.requestID < latest.requestID) { return }
        latestAudioSnapshot = snapshot
        scheduleEvaluation()
    }
    private func scheduleEvaluation() {
        guard hasStarted, isEnabled, !isChanging, evaluationTask == nil else { return }
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            await self.evaluateLatest()
            self.evaluationTask = nil
        }
    }
    private func evaluateLatest() async {
        await refreshAuthorization()
        while hasStarted, !isSuspended, isEnabled, authorization.canDeliver, !Task.isCancelled {
            // Process one completed query, then reread latest state after every await.
            guard let input = nextEvaluation() else { break }
            let key = input.key
            let old = preferences.records[key] ?? LowBatteryRecord()
            var episodeRecord = old
            if let candidate = input.audio, !old.isArmed {
                // An episode can acquire another ear after its first notification.
                // Retain that obligation even if persistence fails this round.
                pendingAudioRecoveryComponents[key, default: []].formUnion(candidate.componentIDs)
                episodeRecord.recoveryComponents.formUnion(pendingAudioRecoveryComponents[key] ?? [])
                if episodeRecord != old {
                    var expanded = preferences; expanded.records[key] = episodeRecord
                    do { try commit(expanded) }
                    catch { errorMessage = "保存通知耳侧恢复状态失败，保持本次低电量抑制：\(Self.describe(error))"; continue }
                }
            }
            var proposed = preferences
            let decision = input.audio?.evaluate(record: episodeRecord, at: now()) ?? input.decision
            switch decision {
            case .none: continue
            case .rearm:
                proposed.records[key] = LowBatteryRecord(isArmed: true, lastNotifiedAt: old.lastNotifiedAt, recoveryComponents: episodeRecord.recoveryComponents)
                do { try commit(proposed); pendingAudioRecoveryComponents.removeValue(forKey: key) }
                catch { errorMessage = "保存通知恢复状态失败：\(Self.describe(error))" }
            case .notify(let percent):
                // Reserve durably before enqueue: a crash cannot cause a repeat on restart.
                // A definite enqueue error rolls back; uncertain crash outcomes stay suppressed.
                proposed.records[key] = LowBatteryRecord(isArmed: false, lastNotifiedAt: now(), recoveryComponents: input.audio?.componentIDs ?? [])
                do { try commit(proposed) }
                catch { errorMessage = "保存通知冷却失败，未发送通知：\(Self.describe(error))"; continue }
                do {
                    try await backend.send(identifier: "bazer.lowBattery.\(UUID().uuidString)", title: "\(input.name) 电量偏低",
                        body: input.audio.map { "系统报告剩余 \(percent)%（\($0.componentDescription)）。" } ?? "最近一次有效读取为 \(percent)%。")
                } catch {
                    var rollback = preferences; rollback.records[key] = old
                    let sendError = Self.describe(error)
                    do { try commit(rollback); errorMessage = "发送低电量通知失败：\(sendError)" }
                    catch { errorMessage = "发送失败：\(sendError)；冷却回滚失败，保留抑制状态：\(Self.describe(error))" }
                }
            }
        }
    }
    private struct EvaluationInput {
        let key: String
        let name: String
        let decision: LowBatteryDecision
        var audio: LowBatteryCandidate? = nil
    }
    private func nextEvaluation() -> EvaluationInput? {
        if let snapshot = latestAudioSnapshot {
            for device in snapshot.devices {
                let event = AudioEvent(session: device.session, version: device.eventVersion, epoch: snapshot.epoch, requestID: snapshot.requestID)
                guard handledAudio[device.id] != event,
                      let candidate = LowBatteryCandidate(device: device, snapshot: snapshot, at: now()) else { continue }
                handledAudio[device.id] = event
                return EvaluationInput(key: candidate.identity, name: candidate.name,
                    decision: candidate.evaluate(record: preferences.records[candidate.identity] ?? LowBatteryRecord(), at: now()), audio: candidate)
            }
        }
        guard let snapshot = latestSnapshot, snapshot.isMonitoring, !snapshot.isSuspended, snapshot.discoveryFailure == nil else { return nil }

        // A logical child owns its notification record. Mirrored direct-device
        // telemetry must not produce a second notification from its host row.
        for device in snapshot.logicalDevices where !device.isRefreshing {
            guard let finished = device.lastFinishedAt, handledLogical[device.sessionID] != finished else { continue }
            handledLogical[device.sessionID] = finished
            guard let key = device.descriptor.preferenceIdentity?.rawValue else { continue }
            let decision = LowBatteryPolicy().evaluate(device, at: now(), record: preferences.records[key] ?? LowBatteryRecord())
            return EvaluationInput(key: key, name: device.displayName, decision: decision)
        }
        let logicalHosts = Set(snapshot.logicalDevices.map { $0.sessionID.address.hostSessionID.physicalDeviceID })
        for device in snapshot.devices where !device.isRefreshing && !logicalHosts.contains(device.id) {
            guard let finished = device.lastFinishedAt, handled[device.sessionID] != finished else { continue }
            handled[device.sessionID] = finished
            guard let key = device.preferenceIdentity?.rawValue else { continue }
            let decision = LowBatteryPolicy().evaluate(device, at: now(), record: preferences.records[key] ?? LowBatteryRecord())
            return EvaluationInput(key: key, name: device.displayName, decision: decision)
        }
        return nil
    }
    private func commit(_ value: NotificationPreferences) throws {
        try persistence.save(value)
        preferences = value; isEnabled = value.isEnabled
    }
    func stop() async {
        hasStarted = false; revision += 1
        evaluationTask?.cancel(); await evaluationTask?.value; evaluationTask = nil
    }
    // Deterministic fake-service tests can drain work without timers or OS calls.
    func waitForEvaluation() async { await evaluationTask?.value }
    static func describe(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.localizedDescription)（\(value.domain) \(value.code)）"
    }
}
