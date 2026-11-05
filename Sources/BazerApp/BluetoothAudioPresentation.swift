// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// Presentation preserves the difference between a system observation and a
/// hardware sample. Case readings never stand in for an ear-side summary.
struct BluetoothAudioPresentation {
    let device: BluetoothAudioDevice
    let date: Date
    init(_ device: BluetoothAudioDevice, at date: Date) { self.device = device; self.date = date }

    var currentReadings: [BluetoothAudioBatteryReading] { device.currentReadings(at: date) }
    var historicalReadings: [BluetoothAudioBatteryReading] {
        device.lastReadings.isEmpty ? device.batteryReadings : device.lastReadings
    }
    var batteryText: String { Self.summary(currentReadings) }
    var historicalBatteryText: String { Self.summary(historicalReadings) }
    var percentage: Int? { device.currentPercent(at: date) }
    var connectionText: String {
        switch device.connection {
        case .connected: "蓝牙已连接"
        case .disconnected: "已断开"
        case .uncertain: "连接状态待确认"
        }
    }
    var statusText: String {
        if let message = device.statusMessage { return message }
        if device.connection != .connected { return connectionText }
        switch device.readStatus {
        case .failed: return "系统电量读取失败"
        case .unavailable: return "系统电量来源不可用"
        case .partial: return "系统报告尚不完整"
        case .success:
            if currentReadings.isEmpty {
                return device.batteryReadings.isEmpty ? "系统未提供电量" : "系统报告已过期"
            }
            return "系统报告"
        }
    }
    var lastObservedAt: Date? { (device.batteryReadings + device.lastReadings).map(\.observedAt).max() }
    var sourceUpdatedAt: Date? { currentReadings.compactMap(\.sourceUpdatedAt).max() }
    var notificationCapabilityText: String {
        switch device.identityQuality {
        case .verified where device.preferenceIdentity != nil:
            "已确认设备身份；有效系统报告可参与低电量提醒。"
        case .ambiguous:
            "设备身份有歧义，低电量提醒暂不可用。"
        case .verified, .sessionOnly:
            "当前仅能确认本次连接，低电量提醒暂不可用。"
        }
    }

    static func componentTitle(_ component: BluetoothAudioComponent) -> String {
        switch component { case .single: "整机"; case .left: "左耳"; case .right: "右耳"; case .case: "充电盒"; case .unknown: "未识别部件" }
    }
    static func percentText(_ percent: Int?) -> String { percent.map { "\($0)%" } ?? "--" }
    static func summary(_ readings: [BluetoothAudioBatteryReading]) -> String {
        if let single = readings.first(where: { $0.component == .single }) { return percentText(single.percent) }
        return [BluetoothAudioComponent.left, .right].compactMap { component in
            readings.first(where: { $0.component == component }).map { "\(component == .left ? "左" : "右") \(percentText($0.percent))" }
        }.joined(separator: " · ").nilIfEmpty ?? "--"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Each provider has its own result: native discovery can fail while a valid
/// accessory power report remains readable (and vice versa).
struct BluetoothAudioSourcePresentation {
    let snapshot: BluetoothAudioSnapshot
    var noticeDetail: String? {
        guard snapshot.finishedAt != .distantPast || snapshot.statusMessage != nil else { return nil }
        guard snapshot.discoveryStatus != .success || snapshot.powerStatus != .success || snapshot.statusMessage != nil else { return nil }
        var lines = [
            "蓝牙连接发现：\(Self.status(snapshot.discoveryStatus))",
            "系统配件电源：\(Self.status(snapshot.powerStatus))"
        ]
        if let message = snapshot.statusMessage, !message.isEmpty { lines.append(message) }
        return lines.joined(separator: "\n")
    }
    private static func status(_ value: BluetoothAudioReadStatus) -> String {
        switch value {
        case .success: "可用"
        case .partial: "仅有部分报告"
        case .failed: "读取失败"
        case .unavailable: "不可用"
        }
    }
}
