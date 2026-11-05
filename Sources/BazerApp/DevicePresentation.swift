// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

/// Pure projection shared by the menu bar, rows and diagnostic detail.
struct DevicePresentation {
    let device: DeviceState
    let date: Date
    init(_ device: DeviceState, at date: Date) { self.device = device; self.date = date }

    var batteryText: String { device.currentBattery(at: date).map { Self.batteryText($0, showEstimate: Self.canShowVoltageEstimate($0, charging: device.charging, hasFailure: hasFailure, at: date)) } ?? (device.capabilities.powerSource == .wired ? "不适用" : "--") }
    static func batteryText(_ sample: BatterySample, showEstimate: Bool = true) -> String {
        switch sample.value {
        case let .percentage(percent): "\(sample.isEstimated ? "约 " : "")\(percent)%"
        case let .voltageOnly(millivolts):
            if showEstimate, let estimate = sample.percentageEstimate { "约 \(estimate.value)%" }
            else { "\(millivolts) mV" }
        case let .approximateLevel(level):
            switch level { case .critical: "极低"; case .low: "低"; case .good: "良好"; case .full: "满"; case .unknown: "档位未知" }
        case .unknown: "--"
        case .notApplicable: "不适用"
        }
    }
    static func batteryEstimateExplanation(_ sample: BatterySample) -> String? {
        guard let estimate = sample.percentageEstimate else { return nil }
        return "电量估算 · \(estimate.resolution)"
    }
    static func canShowVoltageEstimate(_ sample: BatterySample, charging: ChargingSample?, hasFailure: Bool, at date: Date) -> Bool {
        guard sample.percentageEstimate != nil, !hasFailure, !sample.isStale(at: date),
              let charging, charging.state == .discharging, !charging.isStale(at: date),
              charging.receivedAt == sample.receivedAt else { return false }
        return true
    }
    var hasFailure: Bool { device.batteryFailure != nil || device.chargingFailure != nil }
    var batteryPercentageForBar: Int? {
        guard !hasFailure, let sample = device.currentBattery(at: date) else { return nil }
        if let percent = sample.percent { return min(100, max(0, percent)) }
        if Self.canShowVoltageEstimate(sample, charging: device.charging, hasFailure: hasFailure, at: date),
           let estimate = sample.percentageEstimate?.value {
            return min(100, max(0, estimate))
        }
        return nil
    }
    var brandSubtitle: String {
        if let brand = device.catalogMatch?.entry.brand {
            switch brand {
            case .razer: return "Razer"
            case .logitech: return "Logitech"
            }
        }
        switch device.descriptor.vendorID {
        case 0x1532: return "Razer"
        case 0x046D: return "Logitech"
        default: return device.capabilities.powerSource == .wired ? "USB" : "USB 外设"
        }
    }
    var connectionBadgeText: String {
        if device.hostPresence == .removed { return "已移除" }
        if device.managesLogicalTargets { return "2.4 GHz" }
        if device.descriptor.vendorID == 0x1532 && device.descriptor.productID == 0x00C5 {
            return "2.4 GHz"
        }
        return "USB"
    }
    var deviceSymbol: String {
        switch device.kind { case .mouse: "computermouse"; case .keyboard: "keyboard"; case .other: "hifispeaker" }
    }
    var batterySymbol: String {
        guard let sample = device.currentBattery(at: date) else { return "battery.0percent" }
        if device.currentCharging(at: date) == .charging { return "battery.100percent.bolt" }
        guard let percent = sample.percent ?? (Self.canShowVoltageEstimate(sample, charging: device.charging, hasFailure: hasFailure, at: date) ? sample.percentageEstimate?.value : nil) else { return "battery.0percent" }
        switch percent {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    var connectionText: String { device.hostPresence == .present ? "USB 已识别" : "USB 已移除" }
    var chargingText: String {
        Self.chargingText(device.currentCharging(at: date))
    }
    static func chargingText(_ state: ChargingState) -> String {
        switch state {
        case .charging: "充电中"
        case .notCharging: "未充电"
        case .discharging: "放电中"
        case .full: "已充满"
        case .notApplicable: "不适用"
        case .slow: "慢速充电"
        case .error: "充电异常"
        case .unknown: "充电状态未知"
        }
    }
    var statusText: String {
        if device.hostPresence == .removed { return "USB 已移除" }
        if let failure = device.batteryFailure { return "电量读取失败 · \(Self.failureTitle(failure))" }
        if let failure = device.chargingFailure { return "充电读取失败 · \(Self.failureTitle(failure))" }
        if device.capabilities.powerSource == .wired || device.battery?.value == .notApplicable { return "电量不适用" }
        if device.capabilities.battery == .unsupported { return "已识别 · 电量未知" }
        if device.isRefreshing { return "正在读取" }
        if let sample = device.battery, sample.isStale(at: date) { return "电量已过期" }
        if device.currentBattery(at: date) == nil { return "尚无有效电量" }
        return chargingText
    }
    static func failureTitle(_ failure: TelemetryFailure) -> String {
        switch failure.category {
        case .denied: "访问被拒绝"
        case .busy: "查询忙"
        case .timeout: "查询超时"
        case .removed: "设备已移除"
        case .transport: "通信错误"
        case .malformedResponse: "响应校验失败"
        case .unsupported: "无可用查询接口"
        case .cancelled: "查询已取消"
        case .deviceStatus:
            failure.protocolStatus.map { String(format: "设备状态 0x%02X", $0) } ?? "设备返回异常"
        }
    }
}
