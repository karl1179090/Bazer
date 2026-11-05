// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

struct LogicalDevicePresentation {
    let device: LogicalDeviceState
    let date: Date
    init(_ device: LogicalDeviceState, at date: Date) { self.device = device; self.date = date }
    var batteryText: String { device.currentBattery(at: date).map { DevicePresentation.batteryText($0, showEstimate: DevicePresentation.canShowVoltageEstimate($0, charging: device.charging, hasFailure: hasFailure, at: date)) } ?? (device.capabilities.powerSource == .wired ? "不适用" : "--") }
    var hasFailure: Bool { device.batteryFailure != nil || device.chargingFailure != nil }
    var batteryPercentageForBar: Int? {
        guard !hasFailure, let sample = device.currentBattery(at: date) else { return nil }
        if let percent = sample.percent { return min(100, max(0, percent)) }
        if DevicePresentation.canShowVoltageEstimate(sample, charging: device.charging, hasFailure: hasFailure, at: date),
           let estimate = sample.percentageEstimate?.value {
            return min(100, max(0, estimate))
        }
        return nil
    }
    var deviceSymbol: String {
        switch device.descriptor.kind {
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .other: return "hifispeaker"
        }
    }
    var brandAndTransportSubtitle: String {
        switch device.descriptor.peripheralIdentity?.vendorID {
        case 0x1532:
            return "Razer · HyperSpeed"
        case 0x046D:
            if case .receiver = device.descriptor.address.target { return "Logitech · 2.4 GHz" }
            return "Logitech"
        default:
            if device.descriptor.product.localizedCaseInsensitiveContains("Razer") || device.descriptor.product.localizedCaseInsensitiveContains("DeathAdder") {
                return "Razer · HyperSpeed"
            }
            if device.descriptor.product.localizedCaseInsensitiveContains("Logitech") || device.descriptor.product.localizedCaseInsensitiveContains("PRO Wireless") {
                return "Logitech"
            }
            if case .receiver = device.descriptor.address.target { return "2.4 GHz 接收器" }
            return "USB"
        }
    }
    var connectionBadgeText: String {
        if device.hostPresence == .removed || device.peerPresence == .unreachable { return "已断开" }
        if case .receiver = device.descriptor.address.target { return "2.4 GHz" }
        if device.descriptor.peripheralIdentity?.vendorID == 0x1532 || device.descriptor.product.localizedCaseInsensitiveContains("HyperSpeed") {
            return "2.4 GHz"
        }
        return "USB"
    }
    var currentDPIText: String {
        guard device.hostPresence == .present, device.peerPresence != .unreachable, let dpi = device.settings?.settings.currentDPI else { return "--" }
        return dpi.x == dpi.y ? "\(dpi.x)" : "X \(dpi.x) / Y \(dpi.y)"
    }
    var pollingRateText: String {
        guard device.hostPresence == .present, device.peerPresence != .unreachable, let hz = device.settings?.settings.pollingRateHz else { return "--" }
        let prefix = (hz > 0 && 1_000_000 % hz == 0) ? "" : "约 "
        return "\(prefix)\(hz) Hz"
    }
    var chargingText: String {
        guard device.hostPresence == .present, device.peerPresence != .unreachable, device.chargingFailure == nil, let charging = device.charging,
              charging.receivedAt <= date, !charging.isStale(at: date) else { return DevicePresentation.chargingText(.unknown) }
        return DevicePresentation.chargingText(charging.state)
    }
    var batterySymbol: String {
        if hasFailure { return "exclamationmark.circle" }
        if device.charging?.state == .charging, device.chargingFailure == nil, device.charging?.isStale(at: date) == false { return "battery.100percent.bolt" }
        guard let sample = device.currentBattery(at: date), let percent = sample.percent ?? (DevicePresentation.canShowVoltageEstimate(sample, charging: device.charging, hasFailure: hasFailure, at: date) ? sample.percentageEstimate?.value : nil) else { return "battery.0percent" }
        switch percent { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"; case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"; default: return "battery.100percent" }
    }
    var statusText: String {
        if device.hostPresence == .removed || device.peerPresence == .unreachable { return "连接已断开" }
        if case .receiver = device.descriptor.address.target, device.peerPresence == .unknown { return "接收器已连接 · 外设状态待确认" }
        if let failure = device.batteryFailure ?? device.chargingFailure { return DevicePresentation.failureTitle(failure) }
        if device.isRefreshing { return "正在读取" }
        if let battery = device.battery, battery.isStale(at: date) { return "电量已过期" }
        if device.capabilities.powerSource == .wired { return "电量不适用" }
        return device.currentBattery(at: date) == nil ? "尚无有效电量" : "已读取电量"
    }
}
