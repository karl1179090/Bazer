// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct IntegrationSettingsView: View {
    @ObservedObject var notifications: NotificationService
    @ObservedObject var loginItem: LoginItemService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("低电量通知").font(.headline)
            Toggle("启用低电量通知", isOn: Binding(get: { notifications.isEnabled }, set: { enabled in
                Task { await notifications.setEnabledByUser(enabled) }
            })).disabled(notifications.isChanging)
            Text(notifications.authorization.text).font(.caption).foregroundStyle(.secondary)
            Text("有效电量不高于 20% 且明确未充电时提醒。回升到 25% 后重新启用，同一 USB 端口至少间隔 6 小时。")
                .font(.caption2).foregroundStyle(.secondary)
            Button(notifications.isSendingTest ? "正在发送测试通知…" : "发送测试通知") {
                Task { await notifications.sendTestByUser() }
            }.disabled(!notifications.canSendTest)
            if let message = notifications.testMessage { Text(message).font(.caption2).foregroundStyle(.secondary) }
            if let error = notifications.errorMessage { StatusNotice(title: "通知", detail: error) }
            Divider()
            HStack {
                Text("登录时启动").font(.headline)
                Spacer()
                Text(loginItem.status.text).font(.caption).foregroundStyle(.secondary)
            }
            Button(loginItem.status.isRegistered ? "关闭登录启动" : "开启登录启动") {
                loginItem.setEnabledByUser(!loginItem.status.isRegistered)
            }
            if loginItem.status == .requiresApproval {
                Button("打开系统登录项设置") { loginItem.openSettingsByUser() }
            }
            if let error = loginItem.errorMessage { StatusNotice(title: "登录启动操作失败", detail: error) }
            Button("重新读取系统状态") {
                loginItem.refresh()
                Task { await notifications.refreshAuthorization() }
            }.font(.caption)
        }
        .task { loginItem.refresh(); await notifications.refreshAuthorization() }
    }
}
