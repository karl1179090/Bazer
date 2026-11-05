// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import SwiftUI

struct BluetoothAudioDetailView: View {
    @ObservedObject var model: AppModel
    let device: BluetoothAudioDevice
    @Environment(\.bazerPalette) private var palette

    private var presentation: BluetoothAudioPresentation { BluetoothAudioPresentation(device, at: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "headphones")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: 38, height: 38)
                    .background(palette.accentSoftBackground, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName(for: .bluetoothAudio(device.id)))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(presentation.connectionText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: 0)
            }

            if let detail = BluetoothAudioSourcePresentation(snapshot: model.bluetoothAudioSnapshot).noticeDetail {
                StatusNotice(title: "蓝牙耳机来源状态", detail: detail)
            }

            if device.connection != .connected {
                StatusNotice(title: presentation.connectionText, detail: "当前电量不可用，保留上次系统报告供查看。")
            } else if presentation.percentage == nil {
                StatusNotice(title: presentation.currentReadings.isEmpty ? presentation.statusText : "整体电量未知", detail: presentation.currentReadings.isEmpty ? "系统没有可用的当前电量读数。" : "系统提供了部件读数，尚无可确认的耳机整体电量。")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("系统报告")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                    Spacer(minLength: 4)
                    Text(presentation.batteryText)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
                BazerBatteryBar(percent: presentation.percentage)
                ForEach(presentation.currentReadings, id: \.componentID) { reading in
                    readingRow(reading)
                }
                if presentation.currentReadings.isEmpty {
                    Text("充电状态未知")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                }
                Text("电量由 macOS 提供；最近读取时间不代表耳机刚刚采样。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .audioCard(palette)

            if presentation.currentReadings.isEmpty, !presentation.historicalReadings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("上次系统报告 · \(presentation.historicalBatteryText)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    ForEach(presentation.historicalReadings, id: \.componentID) { reading in readingRow(reading) }
                }
                .audioCard(palette)
            }

            VStack(alignment: .leading, spacing: 8) {
                metadata("最近读取", value: presentation.lastObservedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "尚未读取")
                metadata("系统更新时间", value: presentation.sourceUpdatedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "系统未提供")
                metadata("数据来源", value: "macOS 系统报告")
                Text(presentation.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .audioCard(palette)

            VStack(alignment: .leading, spacing: 7) {
                Label("身份与低电量提醒", systemImage: "bell.badge")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(presentation.notificationCapabilityText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.notifications.isEnabled ? "提醒已开启 · 20% 阈值" : "提醒默认关闭，可在应用设置中开启。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }
            .audioCard(palette)
        }
    }

    private func readingRow(_ reading: BluetoothAudioBatteryReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(BluetoothAudioPresentation.componentTitle(reading.component))
                Spacer(minLength: 4)
                Text(BluetoothAudioPresentation.percentText(reading.percent))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            Text(DevicePresentation.chargingText(reading.charging))
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func metadata(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(palette.textSecondary)
            Text(value).foregroundStyle(palette.textPrimary)
        }
        .font(.system(size: 11.5))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func audioCard(_ palette: BazerPalette) -> some View {
        self.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.cardBorder, lineWidth: 1))
    }
}
