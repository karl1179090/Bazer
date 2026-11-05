// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// One peripheral card after host/child de-duplication. History is a value snapshot,
/// never a source of current telemetry or write authority.
struct HomeDeviceProjection: Equatable, Identifiable, Sendable {
    let target: HomeDeviceTarget
    let stableUIID: String
    let name: String
    let subtitle: String
    let percentage: Int?
    let batteryText: String
    let status: String
    let symbol: String
    let isHistory: Bool
    let lastObservedAt: Date?
    let physical: DeviceState?
    let logical: LogicalDeviceState?
    let audio: BluetoothAudioDevice?
    var id: String { stableUIID }
    var identityKey: String? {
        logical?.descriptor.preferenceIdentity?.rawValue ?? physical?.preferenceIdentity?.rawValue ?? audio?.preferenceIdentity
    }
    /// Port topology is a legacy preference scope, not evidence that a replacement
    /// transport session is the same physical peripheral.
    var reliableIdentityKey: String? {
        if let logical { return logical.descriptor.preferenceIdentity?.rawValue }
        if let physical { return physical.preferenceIdentity.flatMap { $0.kind == .portTopology ? nil : $0.rawValue } }
        return audio.flatMap { $0.identityQuality == .verified ? $0.preferenceIdentity : nil }
    }
    func representsSamePeripheral(as other: Self) -> Bool {
        if sessionKey == other.sessionKey { return true }
        return reliableIdentityKey != nil && reliableIdentityKey == other.reliableIdentityKey
    }
    func historicalSnapshot() -> Self {
        let historicTarget: HomeDeviceTarget
        if let logical { historicTarget = .logical(.init(rawValue: "history:\(logical.sessionID.generation)")) }
        else if let physical { historicTarget = .physical(.init(rawValue: "history:\(physical.sessionID.generation)")) }
        else { historicTarget = .bluetoothAudio(.init(rawValue: "history-audio:\(sessionKey)")) }
        var historicalAudio = audio
        historicalAudio?.connection = .disconnected
        let retainedReadings = historicalAudio?.batteryReadings ?? []
        if historicalAudio?.lastReadings.isEmpty == true { historicalAudio?.lastReadings = retainedReadings }
        historicalAudio?.batteryReadings = []
        return Self(target: historicTarget, stableUIID: reliableIdentityKey == nil ? "history-session:\(sessionKey)" : stableUIID,
            name: name, subtitle: "已断开", percentage: percentage, batteryText: batteryText, status: "已断开", symbol: symbol,
            isHistory: true, lastObservedAt: lastObservedAt, physical: physical?.historicalSnapshot(),
            logical: logical?.historicalSnapshot(), audio: historicalAudio, charging: .unknown)
    }
    var sessionKey: String {
        if let logical { return logical.sessionID.generation.uuidString }
        if let physical { return physical.sessionID.generation.uuidString }
        return audio.map { "\($0.session.id):\($0.session.generation)" } ?? target.id
    }
    var isEstimated: Bool {
        if let sample = logical?.battery ?? physical?.battery { return sample.isEstimated || sample.percentageEstimate != nil }
        return false
    }
    var source: String? { logical?.battery?.source ?? physical?.battery?.source ?? audio?.batteryReadings.first?.source }
    var kind: DeviceKind { logical?.descriptor.kind ?? physical?.kind ?? .other }
    let charging: ChargingState

}

struct HomeDeviceProjector {
    static func project(_ snapshot: DeviceStoreSnapshot, audio: [BluetoothAudioDevice], at now: Date) -> [HomeDeviceProjection] {
        let hosts = snapshot.devices + snapshot.historicalDevices
        let logicalStates = (snapshot.logicalDevices + snapshot.historicalLogicalDevices).filter { child in
            if case .receiver = child.descriptor.address.target { return true }
            return hosts.contains { $0.id == child.sessionID.address.hostSessionID.physicalDeviceID && $0.managesLogicalTargets }
        }
        let managedHosts = Set(logicalStates.map { $0.sessionID.address.hostSessionID.physicalDeviceID })
        var result: [HomeDeviceProjection] = []
        for device in logicalStates {
            let history = device.hostPresence == .removed || device.peerPresence == .unreachable
            let retained = device.battery
            let current = history ? nil : device.currentBattery(at: now)
            let sample = history ? retained : current
            let failure = device.batteryFailure != nil || device.chargingFailure != nil
            let receiver: Bool = { if case .receiver = device.descriptor.address.target { return true }; return false }()
            let freshness = device.battery?.isStale(at: now) == true ? "已连接 · 电量已过期" : "已连接"
            let status = history ? "已断开" : (receiver && device.peerPresence == .unknown ? "接收器已连接 · 外设状态待确认" : (failure ? "状态待确认 · \(DevicePresentation.failureTitle(device.batteryFailure ?? device.chargingFailure!))" : freshness))
            let synthetic = snapshot.logicalDevices.contains { $0.sessionID == device.sessionID }
                ? device.id : LogicalDeviceID(rawValue: "history:\(device.sessionID.generation)")
            let identity = device.descriptor.preferenceIdentity?.rawValue
            result.append(HomeDeviceProjection(target: .logical(synthetic), stableUIID: identity.map { "identity:\($0)" } ?? "logical-session:\(device.sessionID.generation)",
                name: device.displayName, subtitle: status, percentage: history ? (sample?.percent ?? sample?.percentageEstimate?.value) : (sample?.percent ?? LogicalDevicePresentation(device, at: now).batteryPercentageForBar),
                batteryText: history ? text(sample) : LogicalDevicePresentation(device, at: now).batteryText, status: status, symbol: device.descriptor.kind == .mouse ? "computermouse.fill" : (device.descriptor.kind == .keyboard ? "keyboard.fill" : "hifispeaker.fill"),
                isHistory: history, lastObservedAt: sample?.receivedAt ?? device.lastFinishedAt,
                physical: nil, logical: device, audio: nil, charging: history || device.chargingFailure != nil || device.charging?.isStale(at: now) != false || (device.charging?.receivedAt ?? .distantFuture) > now ? .unknown : (device.charging?.state ?? .unknown)))
        }
        for device in snapshot.devices + snapshot.historicalDevices where !managedHosts.contains(device.id) {
            let history = device.hostPresence == .removed
            let sample = history ? device.battery : device.currentBattery(at: now)
            let freshness = device.battery?.isStale(at: now) == true ? "已连接 · 电量已过期" : "已连接"
            let status = history ? "已断开" : (device.managesLogicalTargets ? "接收器已连接 · 外设状态待确认" : (device.batteryFailure != nil || device.chargingFailure != nil ? "状态待确认 · \(DevicePresentation.failureTitle(device.batteryFailure ?? device.chargingFailure!))" : freshness))
            let target = snapshot.devices.contains { $0.sessionID == device.sessionID } ? device.id : PhysicalDeviceID(rawValue: "history:\(device.sessionID.generation)")
            result.append(HomeDeviceProjection(target: .physical(target), stableUIID: device.preferenceIdentity.map { "identity:\($0.rawValue)" } ?? "physical-session:\(device.sessionID.generation)",
                name: device.displayName, subtitle: status, percentage: history ? (sample?.percent ?? sample?.percentageEstimate?.value) : (sample?.percent ?? DevicePresentation(device, at: now).batteryPercentageForBar), batteryText: history ? text(sample) : DevicePresentation(device, at: now).batteryText, status: status,
                symbol: device.kind == .mouse ? "computermouse.fill" : (device.kind == .keyboard ? "keyboard.fill" : "antenna.radiowaves.left.and.right"),
                isHistory: history, lastObservedAt: sample?.receivedAt ?? device.lastFinishedAt, physical: device, logical: nil, audio: nil, charging: history ? .unknown : device.currentCharging(at: now)))
        }
        for device in audio {
            let history = device.connection == .disconnected
            let readings = history ? (device.lastReadings.isEmpty ? device.batteryReadings : device.lastReadings) : device.currentReadings(at: now)
            let percentage = readings.first(where: { $0.component == .single })?.percent ?? readings.filter { $0.component == .left || $0.component == .right }.compactMap(\.percent).min()
            let presentation = BluetoothAudioPresentation(device, at: now)
            let status = history ? "已断开" : presentation.statusText
            result.append(HomeDeviceProjection(target: .bluetoothAudio(device.id), stableUIID: device.preferenceIdentity.map { "identity:\($0)" } ?? "audio-session:\(device.session.id):\(device.session.generation)",
                name: device.name, subtitle: status, percentage: percentage, batteryText: history ? presentation.historicalBatteryText : presentation.batteryText, status: status, symbol: "headphones", isHistory: history,
                lastObservedAt: readings.map(\.observedAt).max() ?? device.lastSeenAt, physical: nil, logical: nil, audio: device, charging: history ? .unknown : (readings.first?.charging ?? .unknown)))
        }
        // A current connection wins over its process history; within a partition the
        // latest observation wins. No display-name or receiver-slot identity guessing.
        var unique: [String: HomeDeviceProjection] = [:]
        var order: [String] = []
        for item in result {
            if let old = unique[item.id] {
                if old.isHistory && !item.isHistory || old.isHistory == item.isHistory && (item.lastObservedAt ?? .distantPast) > (old.lastObservedAt ?? .distantPast) { unique[item.id] = item }
            } else { order.append(item.id); unique[item.id] = item }
        }
        return order.compactMap { unique[$0] }
    }
    private static func text(_ sample: BatterySample?) -> String {
        guard let sample, let percent = sample.percent ?? sample.percentageEstimate?.value else { return "--" }
        return "\(sample.isEstimated || sample.percentageEstimate != nil ? "约 " : "")\(percent)%"
    }
}
