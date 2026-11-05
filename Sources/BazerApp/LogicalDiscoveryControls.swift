// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import SwiftUI

struct LogicalDiscoveryControls: View {
    @ObservedObject var model: AppModel
    let hostID: PhysicalDeviceID
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button("重新发现设备") { model.rediscoverLogicalDevices(hostID) }
                    .disabled(!model.canRediscoverLogicalDevices(hostID))
                if model.logicalDiscoveryBusy.contains(hostID) {
                    ProgressView().controlSize(.small)
                    Text("正在重新发现…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("外设上线通常由连接通知更新；若未出现，可手动重新发现。此操作只读取设备信息，不重放设置更改。")
                .font(.caption2).foregroundStyle(.secondary)
            if let message = model.logicalDiscoveryMessages[hostID] {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            if let error = model.logicalDiscoveryErrors[hostID] {
                StatusNotice(title: "监测诊断信息", detail: error)
            }
        }
    }
}
