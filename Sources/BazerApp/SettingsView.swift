// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import BazerCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var notifications: NotificationService
    @ObservedObject private var loginItem: LoginItemService
    @Environment(\.bazerFocusCoordinator) private var focusCoordinator
    @Environment(\.bazerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        self.notifications = model.notifications
        self.loginItem = model.loginItem
    }

    private var primaryDeviceSummary: String { model.menuBarSelectedDeviceName }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            menuBarSection
            generalSection
            deviceDisplaySection
            notificationSection
            appearanceSection
            aboutCard

            if let error = model.snapshot.preferencesFailure {
                StatusNotice(title: "设备偏好存储失败", detail: error)
            }
        }
        .task {
            loginItem.refresh()
            await notifications.refreshAuthorization()
        }
    }

    // MARK: - 1. 通用 (General)

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("通用")

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录时启动")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        if loginItem.status == .requiresApproval {
                            Text("等待系统批准")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.warningText)
                        } else if loginItem.status == .notFound {
                            Text(loginItem.status.text)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                    Spacer()
                    if loginItem.status == .requiresApproval {
                        Button("系统设置") {
                            loginItem.openSettingsByUser()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.accentText)
                    }
                    Toggle("", isOn: Binding(
                        get: { loginItem.status.isRegistered },
                        set: { enabled in loginItem.setEnabledByUser(enabled) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    .accessibilityLabel("登录时启动")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if let error = loginItem.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.dangerText)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                Divider().overlay(palette.divider).padding(.horizontal, 14)

                // Read-only policy row (Spec §7: no editable chevron)
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 20)
                    Text("自动刷新")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    Text("每 60 秒")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                Divider().overlay(palette.divider).padding(.horizontal, 14)

                Text("每次打开菜单时刷新；正常每 60 秒更新，失败后逐步延长。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - 2. 状态栏与菜单栏 (Status Bar & Menu Bar)

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("状态栏显示")

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "percent")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在状态栏显示数字电量")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        Text("开启后在菜单栏图标旁显示电量数字")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.showMenuBarPercentage },
                        set: { show in model.setShowMenuBarPercentage(show) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    .disabled(model.isTerminating)
                    .accessibilityLabel("在状态栏显示数字电量")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                Divider().overlay(palette.divider).padding(.horizontal, 14)

                Button {
                    focusCoordinator?.remember(.primaryPicker)
                    model.activeOverlay = .primaryDevicePicker
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "star")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                            .frame(width: 20)
                        Text("状态栏主设备")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        Spacer()
                        Text(primaryDeviceSummary)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .bazerRestorableFocus(.primaryPicker)
                .disabled(model.isTerminating)
                .accessibilityLabel("状态栏主设备，当前 \(primaryDeviceSummary)")
            }
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - 3. 设备显示 (Device Display)

    private var deviceDisplaySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("设备显示")

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("记住设备折叠状态")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.rememberFoldedDevices },
                        set: { remember in model.setRememberFoldedDevices(remember) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    .disabled(model.isTerminating)
                    .accessibilityLabel("记住设备折叠状态")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                Divider().overlay(palette.divider).padding(.horizontal, 14)

                Text("已折叠设备仍会刷新，点击折叠栏查看")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - 4. 通知 (Notifications)

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("通知")

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bell")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("低电量提醒")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                        if notifications.isEnabled && notifications.authorization == .denied {
                            Text(notifications.authorization.text)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.warningText)
                        }
                    }
                    Spacer()
                    if notifications.isChanging {
                        BazerDelayedProgressView(isActive: true)
                    }
                    Toggle("", isOn: Binding(
                        get: { notifications.isEnabled && notifications.authorization != .denied },
                        set: { enabled in
                            Task { await notifications.setEnabledByUser(enabled) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(palette.accent)
                    .disabled(notifications.isChanging || model.isTerminating)
                    .accessibilityLabel("低电量提醒")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                Divider().overlay(palette.divider).padding(.horizontal, 14)

                HStack {
                    Text("电量低于 20% 时提醒（估算电量不触发提醒）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                    Spacer()
                    if notifications.authorization == .denied {
                        Button("系统通知设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.accentText)
                    } else if notifications.canSendTest {
                        Button(notifications.isSendingTest ? "发送中…" : "测试通知") {
                            Task { await notifications.sendTestByUser() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.accentText)
                        .disabled(!notifications.canSendTest)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                if let testMsg = notifications.testMessage {
                    Text(testMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                if let errMsg = notifications.errorMessage {
                    Text(errMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.dangerText)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - 5. 外观 (Appearance)

    private var appearanceSection: some View {
        let modes: [(BazerAppearanceMode, String)] = [
            (.system, "跟随系统"),
            (.light, "浅色"),
            (.dark, "深色")
        ]
        return VStack(alignment: .leading, spacing: 7) {
            sectionHeader("外观")

            HStack(spacing: 6) {
                ForEach(modes, id: \.0) { mode, title in
                    let isSelected = model.appearanceMode == mode
                    Button {
                        withAnimation(reduceMotion ? BazerMotion.reduced : BazerMotion.standard) {
                            model.setAppearanceMode(mode)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            BazerRadioIndicator(state: isSelected ? .confirmed : .unselected)
                            Text(title)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? palette.accentText : palette.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            isSelected ? palette.accentSoftBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(
                                    isSelected ? palette.accentSoftBorder : Color.clear,
                                    lineWidth: 1.25
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("外观：\(title)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(6)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - 6. 关于卡片 (About Card)

    private var aboutCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(palette.subtleSurface)
                    .frame(width: 36, height: 36)
                Image(systemName: "computermouse")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Bazer")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Text("菜单栏设备管理工具")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer()
            Text("版本 \(appVersion)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 2)
    }
}
