// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import Testing
@testable import BazerApp

struct BluetoothAudioPresentationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = BluetoothAudioSession(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, generation: 1)

    @Test func oneSystemReadingDoesNotInventEarOrCaseValuesOrHardwareTime() {
        let value = device(readings: [reading(.single, 30)])
        let projection = BluetoothAudioPresentation(value, at: now)
        #expect(projection.batteryText == "30%")
        #expect(projection.percentage == 30)
        #expect(projection.currentReadings.count == 1)
        #expect(projection.lastObservedAt == now)
        #expect(projection.sourceUpdatedAt == nil)
        #expect(projection.notificationCapabilityText.contains("暂不可用"))
    }

    @Test func multipleComponentsKeepEarLabelsAndExcludeCaseFromSummary() {
        let value = device(readings: [reading(.left, 35), reading(.right, 50), reading(.case, 90)])
        let projection = BluetoothAudioPresentation(value, at: now)
        #expect(projection.batteryText == "左 35% · 右 50%")
        #expect(projection.percentage == 35)
        #expect(projection.currentReadings.count == 3)
        let caseOnly = BluetoothAudioPresentation(device(readings: [reading(.case, 100)]), at: now)
        #expect(caseOnly.batteryText == "--")
        #expect(caseOnly.percentage == nil)
    }

    @Test func unknownPercentAndChargingStayUnknownWhileZeroRemainsValid() {
        let unknown = reading(.single, nil)
        #expect(unknown.charging == .unknown)
        #expect(BluetoothAudioPresentation(device(readings: [unknown]), at: now).batteryText == "--")
        #expect(BluetoothAudioPresentation(device(readings: [reading(.single, 0)]), at: now).batteryText == "0%")
    }

    @Test func disconnectedAndExpiredReadingsAppearOnlyAsExplicitHistory() {
        var value = device(readings: [reading(.single, 30)])
        value.connection = .disconnected
        value.lastReadings = value.batteryReadings
        let history = BluetoothAudioPresentation(value, at: now)
        #expect(history.batteryText == "--")
        #expect(history.percentage == nil)
        #expect(history.historicalBatteryText == "30%")
        #expect(history.connectionText == "已断开")
        value.connection = .connected
        let expired = BluetoothAudioPresentation(value, at: now.addingTimeInterval(181))
        #expect(expired.batteryText == "--")
        #expect(expired.statusText == "系统报告已过期")
        #expect(expired.historicalBatteryText == "30%")
    }

    @Test func readFailureDoesNotDisplayThePreviousReadingAsCurrent() {
        var value = device(readings: [reading(.single, 30)])
        value.readStatus = .failed
        let failed = BluetoothAudioPresentation(value, at: now)
        #expect(failed.batteryText == "--")
        #expect(failed.statusText == "系统电量读取失败")
        #expect(failed.connectionText == "蓝牙已连接")
    }

    @Test func providerFailureNoticeSeparatesDiscoveryFromAvailablePowerReports() throws {
        let deniedDiscovery = BluetoothAudioSnapshot(finishedAt: now, discoveryStatus: .unavailable, powerStatus: .success, statusMessage: "蓝牙访问未获批准")
        let detail = try #require(BluetoothAudioSourcePresentation(snapshot: deniedDiscovery).noticeDetail)
        #expect(detail.contains("蓝牙连接发现：不可用"))
        #expect(detail.contains("系统配件电源：可用"))
        #expect(detail.contains("蓝牙访问未获批准"))
        let failedPower = BluetoothAudioSnapshot(finishedAt: now, discoveryStatus: .success, powerStatus: .failed)
        #expect(BluetoothAudioSourcePresentation(snapshot: failedPower).noticeDetail == "蓝牙连接发现：可用\n系统配件电源：读取失败")
    }

    @Test func successfulProvidersWithoutMessagesAndUnattemptedInitialStateHaveNoNotice() {
        let success = BluetoothAudioSnapshot(finishedAt: now, discoveryStatus: .success, powerStatus: .success)
        #expect(BluetoothAudioSourcePresentation(snapshot: success).noticeDetail == nil)
        #expect(BluetoothAudioSourcePresentation(snapshot: BluetoothAudioSnapshot()).noticeDetail == nil)
    }

    @Test func unknownPartsRemainVisibleAsDistinctReportsWithoutAnInventedWholeDeviceValue() {
        let first = BluetoothAudioBatteryReading(component: .unknown, componentID: "synthetic-part-a", percent: 20, source: "synthetic", observedAt: now, session: session)
        let second = BluetoothAudioBatteryReading(component: .unknown, componentID: "synthetic-part-b", percent: 60, source: "synthetic", observedAt: now, session: session)
        let presentation = BluetoothAudioPresentation(device(readings: [first, second]), at: now)
        #expect(presentation.currentReadings.map(\.componentID) == ["synthetic-part-a", "synthetic-part-b"])
        #expect(presentation.currentReadings.compactMap(\.percent) == [20, 60])
        #expect(presentation.batteryText == "--")
        #expect(presentation.percentage == nil)
        #expect(BluetoothAudioPresentation.componentTitle(.unknown) == "未识别部件")
    }

    private func reading(_ component: BluetoothAudioComponent, _ percent: Int?) -> BluetoothAudioBatteryReading {
        BluetoothAudioBatteryReading(component: component, percent: percent, source: "synthetic-system-report", observedAt: now, session: session)
    }
    private func device(readings: [BluetoothAudioBatteryReading]) -> BluetoothAudioDevice {
        BluetoothAudioDevice(id: .init(rawValue: "synthetic:audio"), name: "Synthetic Audio", session: session, batteryReadings: readings, lastSeenAt: now)
    }
}
