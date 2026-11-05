// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// Process-only display state. Retained percentages never become telemetry samples.
struct MenuBarDisplayState: Equatable, Sendable {
    private var lastPreferredIdentity: String?
    private(set) var selectedUIID: String?
    private(set) var selectedTarget: HomeDeviceTarget?
    private(set) var selectedIdentity: String?
    private(set) var selectedSession: String?
    private(set) var name = "设备"
    private(set) var percent: Int?
    private(set) var isEstimated = false
    private(set) var observedAt: Date?
    private(set) var source: String?
    private(set) var connectionText = "未发现设备"
    private(set) var isCurrent = false
    private(set) var charging: ChargingState = .unknown

    mutating func select(_ target: HomeDeviceProjection?) {
        selectedUIID = target?.stableUIID; selectedTarget = target?.target
        selectedIdentity = target?.identityKey; selectedSession = target?.sessionKey
        name = target?.name ?? "设备"; percent = nil; observedAt = nil; source = nil; isEstimated = false
        connectionText = target?.status ?? "未发现设备"; isCurrent = false; charging = .unknown
        if let target { update(target) }
    }
    mutating func reconcile(_ devices: [HomeDeviceProjection], preferredIdentity: String?, fallback: HomeDeviceTarget?) {
        if let preferredIdentity, selectedUIID == nil || preferredIdentity != lastPreferredIdentity {
            if let preferred = devices.first(where: { $0.identityKey == preferredIdentity && !$0.isHistory }) {
                if preferred.stableUIID != selectedUIID { select(preferred) }
            } else if preferredIdentity != selectedIdentity {
                select(nil)
                selectedIdentity = preferredIdentity; selectedUIID = "identity:\(preferredIdentity)"
                connectionText = "状态待确认"
            }
        }
        lastPreferredIdentity = preferredIdentity
        if selectedUIID == nil {
            let first = devices.first(where: { $0.target == fallback && !$0.isHistory })
                ?? devices.first(where: { $0.kind == .mouse && !$0.isHistory }) ?? devices.first(where: { !$0.isHistory })
            if let first { select(first) }
        }
        guard let selectedUIID else { return }
        guard let target = devices.first(where: { $0.stableUIID == selectedUIID }) else {
            isCurrent = false; charging = .unknown; connectionText = "状态待确认"; return
        }
        // Only the authoritative current projection reaches here. Late telemetry
        // cannot replace a new session because DeviceStore rejects stale generations.
        selectedTarget = target.target; selectedSession = target.sessionKey; name = target.name
        update(target)
    }
    private mutating func update(_ target: HomeDeviceProjection) {
        connectionText = target.status
        isCurrent = !target.isHistory && target.percentage != nil && !target.status.contains("待确认") && !target.status.contains("失败")
        charging = isCurrent ? target.charging : .unknown
        // Unknown, failure, expired and history snapshots may never overwrite cache.
        guard !target.isHistory, let value = target.percentage else { return }
        percent = value; isEstimated = target.isEstimated; observedAt = target.lastObservedAt; source = target.source
    }
    mutating func markUncertain(_ message: String) { connectionText = message; isCurrent = false; charging = .unknown }
    var title: String { percent.map { "\(isEstimated ? "约 " : "")\($0)%" } ?? "--" }
    var symbol: String {
        if isCurrent && [.charging, .full].contains(charging) { return "battery.100percent.bolt" }
        guard let percent else { return "battery.0percent" }
        switch percent { case 0...10: return "battery.0percent"; case 11...35: return "battery.25percent"; case 36...60: return "battery.50percent"; case 61...85: return "battery.75percent"; default: return "battery.100percent" }
    }
    var accessibilityLabel: String {
        guard let percent else { return "Bazer，\(name)，\(connectionText)，电量未知" }
        let value = "\(isEstimated ? "约 " : "")\(percent)%"
        let time = observedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "未知时间"
        let qualifier = isCurrent ? "电量" : "上次电量"
        return "Bazer，\(name)，\(connectionText)，\(qualifier) \(value)，最近读取 \(time)"
    }
}
