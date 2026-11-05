// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import SwiftUI

struct DeviceDetailView: View {
    @ObservedObject var model: AppModel
    let device: DeviceState
    @Environment(\.bazerPalette) private var palette
    @State private var alias = ""
    @State private var showDiagnostics = true

    private var presentation: DevicePresentation {
        DevicePresentation(device, at: model.snapshot.capturedAt)
    }

    /// If this physical device has a direct logical target that supports settings (e.g., Razer 1532:00C5),
    /// render the unified LogicalDeviceDetailView so DPI, Polling Rate, Onboard & Backups work seamlessly.
    private var directLogicalWithSettings: LogicalDeviceState? {
        if let managed = model.managedDirectLogicalDevice(for: device.id) { return managed }
        if let direct = model.snapshot.logicalDevices.first(where: { $0.id == .direct(device.id) }),
           direct.capabilities.canReadSettings {
            return direct
        }
        return nil
    }

    var body: some View {
        Group {
            if let logical = directLogicalWithSettings {
                LogicalDeviceDetailView(model: model, device: logical, physicalFallback: device)
                    .id(logical.sessionID)
            } else {
                physicalBody
            }
        }
    }

    private var physicalBody: some View {
        let isPrimary = model.snapshot.primaryDeviceID == device.id
        return VStack(alignment: .leading, spacing: 12) {
            // Identity Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(palette.subtleSurface)
                        .frame(width: 40, height: 40)
                    Image(systemName: presentation.deviceSymbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(device.displayName)
                            .font(.system(size: 16.5, weight: .bold))
                            .foregroundStyle(palette.textPrimary)
                        if isPrimary {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.accent)
                                .accessibilityLabel("菜单栏主设备")
                        }
                    }
                    Text("\(presentation.brandSubtitle) · \(presentation.connectionBadgeText)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
            }

            if device.hostPresence == .removed {
                StatusNotice(title: "设备连接已断开", detail: "USB 设备已移除；以下显示最近保留的诊断信息。")
            }

            // Telemetry & Status Summary Card
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("电量")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text(presentation.batteryText)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                    }
                    BazerBatteryBar(percent: presentation.batteryPercentageForBar)
                }

                Divider().overlay(palette.divider)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前 DPI")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.textSecondary)
                        Text("--")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(palette.divider)
                        .frame(width: 1, height: 32)
                        .padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("回报率")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.textSecondary)
                        Text("--")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )

            if let failure = device.batteryFailure { failureView("电量读取失败", failure) }
            if let failure = device.chargingFailure { failureView("充电读取失败", failure) }

            // Connection & History Card
            VStack(alignment: .leading, spacing: 8) {
                Text("连接状态与偏好")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(palette.textPrimary)

                detailRow("主机连接", presentation.connectionText)
                detailRow("最近状态", presentation.statusText)
                if device.capabilities.chargingQuery {
                    detailRow("当前充电", presentation.chargingText)
                }

                if device.hostPresence == .present {
                    if device.managesLogicalTargets {
                        Divider().overlay(palette.divider)
                        LogicalDiscoveryControls(model: model, hostID: device.id)
                    }

                    Divider().overlay(palette.divider)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义名称")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        HStack {
                            TextField("留空使用设备名称", text: $alias)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("设备自定义名称")
                                .onSubmit(saveAlias)
                            Button("保存", action: saveAlias)
                                .disabled(model.isTerminating)
                        }
                        Text(
                            device.preferenceIdentity == nil
                                ? "本次连接有效（尚无稳定端口身份）。"
                                : "设置按 USB 端口保存；换口可能需重设。"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)

                        Button {
                            model.setPrimary(device.id)
                        } label: {
                            Label(isPrimary ? "当前菜单栏主设备" : "设为菜单栏主设备", systemImage: "star")
                        }
                        .disabled(isPrimary || model.isTerminating)
                    }
                }
            }
            .padding(14)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )

            // Diagnostics Card
            DisclosureGroup(isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 7) {
                    if let sample = device.battery {
                        detailRow("历史电量", DevicePresentation.batteryText(sample))
                        if !sample.rawBytes.isEmpty {
                            detailRow("原始电量", sample.rawBytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                        }
                        dateRow("电量采样", sample.receivedAt)
                    }
                    detailRow("VID:PID", String(format: "%04X:%04X", device.descriptor.vendorID ?? 0, device.descriptor.productID ?? 0))
                    detailRow("接口数", "\(device.descriptor.interfaces.count)")
                    detailRow("接口访问", accessText)
                    detailRow("电量能力", supportText)
                    Text("会话选择器：\(device.id.rawValue)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textTertiary)
                        .textSelection(.enabled)
                }
                .padding(.top, 8)
            } label: {
                Text("诊断与历史样本")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(14)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
        .onAppear { alias = device.alias ?? "" }
    }

    private func failureView(_ title: String, _ failure: TelemetryFailure) -> some View {
        var details = failure.message
        if let phase = failure.operation { details += "\n操作：\(phase)" }
        if let code = failure.ioReturn { details += String(format: "\nIOReturn：%d (0x%08X)", code, UInt32(bitPattern: code)) }
        if let endpoint = failure.endpointRegistryEntryID { details += String(format: "\n接口：0x%llX", endpoint) }
        if let guidance = HIDAccessGuidance.message(for: failure, runningBundleURL: Bundle.main.bundleURL) {
            details += "\n\n\(guidance)"
        }
        return StatusNotice(title: "\(title) · \(DevicePresentation.failureTitle(failure))", detail: details)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(palette.textSecondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(palette.textPrimary).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func dateRow(_ label: String, _ date: Date) -> some View {
        detailRow(label, date.formatted(date: .abbreviated, time: .standard))
    }

    private func saveAlias() {
        model.setAlias(alias, for: device.id)
    }

    private var accessText: String {
        switch device.access {
        case .untested: "尚未访问"
        case .ready: "可访问"
        case .denied: "访问被拒绝"
        case .busy: "忙"
        case .failed: "访问失败"
        }
    }

    private var supportText: String {
        switch device.capabilities.battery {
        case .unsupported: "仅身份识别"
        case .candidate: "待有效采样"
        case .verified: "已有有效采样"
        }
    }
}
