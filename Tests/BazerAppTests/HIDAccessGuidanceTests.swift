// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import Testing
@testable import BazerApp

@Suite("HID access guidance — offline")
struct HIDAccessGuidanceTests {
    @Test func openNotPermittedExplainsSystemAccessAndShowsTheRunningBundle() throws {
        let failure = TelemetryFailure(category: .denied, message: "not permitted",
            ioReturn: -536870174, operation: "open", endpointRegistryEntryID: 0x1000052DE)
        let bundle = URL(fileURLWithPath: "/Applications/Synthetic Bazer 测试.app", isDirectory: true)

        let message = try #require(HIDAccessGuidance.message(for: failure, runningBundleURL: bundle))

        #expect(message.contains("系统 HID 访问被拒绝"))
        #expect(message.contains("kIOReturnNotPermitted"))
        #expect(message.contains("输入监控"))
        #expect(message.contains("升级后可能需要重新授权"))
        #expect(message.contains("退出重开"))
        #expect(message.contains("当前运行的应用：/Applications/Synthetic Bazer 测试.app"))
        #expect(!message.contains("TCC"), "An IOReturn alone cannot identify a TCC grant or its stale field")
    }

    @Test func unrelatedDeniedPhasesAndCodesNeverSuggestInputMonitoring() {
        let bundle = URL(fileURLWithPath: "/Applications/Synthetic.app", isDirectory: true)
        let failures = [
            TelemetryFailure(category: .denied, message: "generic denial"),
            TelemetryFailure(category: .denied, message: "missing phase", ioReturn: -536870174),
            TelemetryFailure(category: .denied, message: "missing code", operation: "open"),
            TelemetryFailure(category: .denied, message: "set rejected", ioReturn: -536870174, operation: "setFeature"),
            TelemetryFailure(category: .denied, message: "get rejected", ioReturn: -536870174, operation: "getFeature"),
            TelemetryFailure(category: .unsupported, message: "endpoint selection", ioReturn: -536870174, operation: "selectEndpoint"),
            TelemetryFailure(category: .denied, message: "not the exact phase", ioReturn: -536870174, operation: "Open"),
            TelemetryFailure(category: .denied, message: "no privilege", ioReturn: Int32(bitPattern: 0xE00002C1), operation: "open"),
            TelemetryFailure(category: .timeout, message: "open timeout", ioReturn: Int32(bitPattern: 0xE00002D6), operation: "open"),
            TelemetryFailure(category: .removed, message: "no device", ioReturn: Int32(bitPattern: 0xE00002C0), operation: "open"),
            TelemetryFailure(category: .transport, message: "open succeeded", ioReturn: 0, operation: "open"),
            TelemetryFailure(category: .deviceStatus, message: "device status04", operation: "validate", protocolStatus: 4)
        ]

        for failure in failures {
            #expect(HIDAccessGuidance.message(for: failure, runningBundleURL: bundle) == nil,
                "Input Monitoring guidance must not replace the actual failure: \(failure)")
        }
    }

    @Test func rawOpenResultAndSuppliedBundlePathControlGuidance() throws {
        let firstBundle = URL(fileURLWithPath: "/Applications/First.app", isDirectory: true)
        let currentBundle = URL(fileURLWithPath: "/Users/synthetic/Applications/Current Bazer.app", isDirectory: true)
        let failure = TelemetryFailure(category: .transport, message: "uncategorized raw error",
            ioReturn: -536870174, operation: "open")

        let first = try #require(HIDAccessGuidance.message(for: failure, runningBundleURL: firstBundle))
        let current = try #require(HIDAccessGuidance.message(for: failure, runningBundleURL: currentBundle))

        #expect(first.contains("当前运行的应用：/Applications/First.app"))
        #expect(current.contains("当前运行的应用：/Users/synthetic/Applications/Current Bazer.app"))
        #expect(!current.contains(firstBundle.path), "The guidance must not cache or assume an installation path")
    }
}
