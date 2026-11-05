// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import SwiftUI

struct LogicalDeviceDetailView: View {
    @ObservedObject var model: AppModel
    let device: LogicalDeviceState
    var physicalFallback: DeviceState? = nil
    @Environment(\.bazerPalette) private var palette
    @State private var alias = ""
    @State private var showDiagnostics = false

    private var presentation: LogicalDevicePresentation {
        LogicalDevicePresentation(device, at: model.snapshot.capturedAt)
    }

    private var isPrimary: Bool {
        if model.snapshot.primaryLogicalDeviceID == device.id { return true }
        if let physicalFallback, model.snapshot.primaryDeviceID == physicalFallback.id { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceIdentityHeader

            if (device.hostPresence == .removed || device.peerPresence == .unreachable) {
                StatusNotice(
                    title: "设备连接已断开",
                    detail: "当前设备连接已断开，参数写入已禁用。重新连接后将自动核对身份并读取当前值。"
                )
            }

            telemetryAndParametersCard

            if let failure = device.batteryFailure ?? device.chargingFailure {
                StatusNotice(title: "设备遥测未完成 · \(DevicePresentation.failureTitle(failure))", detail: failureDetail(failure))
            }

            if device.capabilities.canReadSettings {
                DeviceSettingsView(model: model, device: device)
            } else {
                readOnlyDeviceNoticeCard
            }

            managementAndDiagnosticsSection
        }
        .onAppear {
            alias = device.alias ?? physicalFallback?.alias ?? ""
        }
    }

    // MARK: - 1. Device Identity Header (Spec §4.1 & 02-device-detail.png)

    private var deviceIdentityHeader: some View {
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
                        .lineLimit(1)
                    if isPrimary {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accent)
                            .accessibilityLabel("菜单栏主设备")
                    }
                }
                Text(presentation.brandAndTransportSubtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - 2. Telemetry & Current Parameters Summary Card

    private var telemetryAndParametersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Battery header + bar
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Text("电量")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        if presentation.chargingText == "充电中" {
                            Label("充电中", systemImage: "bolt.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.accentText)
                        }
                    }
                    Spacer()
                    Text(presentation.batteryText)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.textPrimary)
                }

                BazerBatteryBar(percent: presentation.batteryPercentageForBar)
            }

            Divider().overlay(palette.divider)

            // Two-column Current DPI | Polling Rate
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前 DPI")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                    Text(presentation.currentDPIText)
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.textPrimary)
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
                    Text(presentation.pollingRateText)
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.textPrimary)
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
    }

    private var readOnlyDeviceNoticeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("参数与连接说明")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Text("此设备当前支持连接识别与状态展示，暂不开放 DPI 或回报率配置。")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - 3. Collapsible Device Management & Diagnostics Section

    private var managementAndDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(BazerMotion.softSpring) {
                    showDiagnostics.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Text("设备管理与诊断详情")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textTertiary)
                        .rotationEffect(.degrees(showDiagnostics ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(palette.cardBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showDiagnostics {
                VStack(alignment: .leading, spacing: 12) {
                    // Alias & Primary Device
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义名称")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        HStack(spacing: 8) {
                            TextField("留空使用设备默认名称", text: $alias)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                                .onSubmit { model.setAlias(alias, for: device.id) }
                            Button("保存") {
                                model.setAlias(alias, for: device.id)
                            }
                            .disabled(model.isTerminating || device.descriptor.isIdentityAmbiguous)
                        }
                        Text(
                            device.descriptor.isIdentityAmbiguous
                                ? "设备身份存在歧义，不能持久保存此设备的名称。"
                                : (device.descriptor.preferenceIdentity == nil
                                    ? "尚无可靠设备身份，名称仅本次连接有效。"
                                    : "名称与偏好按已确认的设备身份保存。")
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)

                        HStack(spacing: 8) {
                            Button(isPrimary ? "当前菜单栏主设备" : "设为菜单栏主设备") {
                                model.setPrimaryLogical(device.id)
                            }
                            .disabled(isPrimary || model.isTerminating || (device.hostPresence == .removed || device.peerPresence == .unreachable))

                            if device.capabilities.canReadSettings {
                                Button("读取当前设置") {
                                    model.readSettings(device.id)
                                }
                                .disabled(
                                    model.settingsBusy.contains(device.id)
                                        || device.isReadingSettings
                                        || !device.canRefreshSettings
                                        || model.snapshot.isSuspended
                                        || model.isTerminating
                                )
                            }
                        }
                        .font(.system(size: 12))
                    }

                    if model.logicalDiscoveryHosts.contains(where: { $0.id == device.sessionID.address.hostSessionID.physicalDeviceID }) {
                        Divider().overlay(palette.divider)
                        LogicalDiscoveryControls(model: model, hostID: device.sessionID.address.hostSessionID.physicalDeviceID)
                    }

                    // Battery & Voltage History Diagnostics
                    if let sample = device.battery {
                        Divider().overlay(palette.divider)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("最近有效电量样本")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.textPrimary)
                            Text("读数：\(DevicePresentation.batteryText(sample)) · \(sample.receivedAt.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.textSecondary)
                            if let millivolts = sample.millivolts {
                                Text("原始电压：\(millivolts) mV")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            if let explanation = DevicePresentation.batteryEstimateExplanation(sample) {
                                Text(explanation)
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.textTertiary)
                                    .textSelection(.enabled)
                            }
                            if let estimate = sample.percentageEstimate {
                                Text("估算来源：\(estimate.source)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.textTertiary)
                                    .textSelection(.enabled)
                            }
                            Text("协议来源：\(sample.source)")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textTertiary)
                            if !sample.rawBytes.isEmpty {
                                Text("原始字段：\(sample.rawBytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(palette.textTertiary)
                                    .textSelection(.enabled)
                            }
                            if sample.isStale(at: model.snapshot.capturedAt) || (device.hostPresence == .removed || device.peerPresence == .unreachable) || presentation.hasFailure {
                                Text("历史样本不代表当前电量。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.warningText)
                            }
                        }
                    }
                }
                .padding(14)
                .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(palette.cardBorder, lineWidth: 1)
                )
            }
        }
    }

    private func failureDetail(_ failure: TelemetryFailure) -> String {
        var details = failure.message
        if let guidance = HIDAccessGuidance.message(for: failure, runningBundleURL: Bundle.main.bundleURL) {
            details += "\n\n\(guidance)"
        }
        return details
    }
}
