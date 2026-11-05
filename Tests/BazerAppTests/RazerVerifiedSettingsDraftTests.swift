// SPDX-License-Identifier: GPL-3.0-or-later
@testable import BazerApp
import BazerCore
import Foundation
import Testing

@Suite("Ordinary current-settings UI evidence and drafts")
struct RazerVerifiedSettingsDraftTests {
    private func capabilities(_ evidence: CapabilityEvidence = .writeVerified) -> DeviceCapabilities {
        DeviceCapabilities(operations: [
            .dpiWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [400, 800, 1600, 3200], persistenceScopes: [.onboard])),
            .pollingRateWrite: OperationCapability(evidence: .writeVerified, constraints: CapabilityConstraints(allowedValues: [125, 500, 1000], persistenceScopes: [.onboard])),
            .onboardPersist: OperationCapability(evidence: evidence, constraints: CapabilityConstraints(persistenceScopes: [.onboard]))
        ])
    }
    private var snapshot: DeviceSettingsSnapshot {
        let session = LogicalDeviceSessionID(address: .direct(DeviceSessionID(physicalDeviceID: PhysicalDeviceID(rawValue: "synthetic:UI"))))
        return DeviceSettingsSnapshot(session: session, revision: 7, capturedAt: Date(), settings: DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 1000))
    }
    @Test func unifiedCurrentDraftUsesOnlyTestedValuesAndDeviceStorageScope() throws {
        let before = snapshot
        var draft = DeviceSettingsDraft(before, scope: .onboard)
        draft.dpiX = "1600"; draft.dpiY = "1600"; draft.rate = "500"
        let request = try #require(draft.request(capabilities: capabilities()))
        #expect(request.change.fields == [.currentDPI, .pollingRate])
        #expect(request.change.persistence == .onboard)
        #expect(request.target == before.session); #expect(request.expectedRevision == 7)
        #expect(draft.request(capabilities: capabilities(), scope: .runtime) == nil)
        draft.dpiX = "850"; draft.dpiY = "850"
        #expect(draft.request(capabilities: capabilities()) == nil)
        draft.dpiX = "800"; draft.dpiY = "1600"
        #expect(draft.request(capabilities: capabilities()) == nil)
        draft.dpiY = "800"; draft.rate = "8000"
        #expect(draft.request(capabilities: capabilities()) == nil)
    }
    @Test func deviceStorageWriteAndEstablishedOnboardActionsHaveDistinctLabels() {
        #expect(DeviceSettingsPresentation.onboardActionTitle(capabilities()) == "写入设备")
        #expect(DeviceSettingsPresentation.onboardActionTitle(capabilities(.persistenceVerified)) == "保存到板载")
        let before = snapshot
        let request = SettingChangeRequest(target: before.session, expectedRevision: before.revision,
            change: DeviceSettingsChange(currentDPI: DPISetting(1600), persistence: .onboard))
        func result(_ persistence: SettingPersistence, status: SettingChangeStatus = .verified) -> SettingChangeResult {
            SettingChangeResult(request: request, before: before, observed: nil, persistence: persistence, status: status, finishedAt: Date())
        }
        #expect(DeviceSettingsPresentation.persistenceText(result(.unknown), capabilities: capabilities()) == "已读回当前值；本值的断电保持尚未确认。")
        #expect(DeviceSettingsPresentation.persistenceText(result(.unknown, status: .outcomeUnknown), capabilities: capabilities()) == "保存范围尚未确认。")
        #expect(DeviceSettingsPresentation.persistenceText(result(.onboard), capabilities: capabilities()).contains("该值组合已有断电保持实测证据"))
        #expect(DeviceSettingsPresentation.persistenceText(result(.onboard), capabilities: capabilities(.persistenceVerified)) == "应用范围：设备板载配置。断电保持仍需单独确认。")
    }
    @Test func independentXYDraftExposesOnlyExactTestedPairs() throws {
        var caps = capabilities()
        caps.record(OperationCapability(evidence: .writeVerified), for: .independentXY)
        caps.record(OperationCapability(evidence: .writeVerified,
            constraints: CapabilityConstraints(allowedValues: [400, 800, 1600, 3200], persistenceScopes: [.onboard],
                allowedDPIPairs: [DPISetting(800), DPISetting(x: 800, y: 1600), DPISetting(x: 1600, y: 800)])), for: .dpiWrite)
        var draft = DeviceSettingsDraft(snapshot, scope: .onboard)
        draft.dpiX = "800"; draft.dpiY = "1600"
        #expect(try #require(draft.request(capabilities: caps)).change.currentDPI == DPISetting(x: 800, y: 1600))
        draft.dpiX = "1600"; draft.dpiY = "800"
        #expect(try #require(draft.request(capabilities: caps)).change.currentDPI == DPISetting(x: 1600, y: 800))
        draft.dpiX = "400"; draft.dpiY = "1600"
        #expect(draft.request(capabilities: caps) == nil)
        #expect(DeviceSettingsPresentation.exactDPIPairsText(caps) == "已验证 X/Y 组合：800/800、800/1600、1600/800")
        #expect(DeviceSettingsPresentation.exactDPIPairsText(capabilities()) == nil)
    }
}
