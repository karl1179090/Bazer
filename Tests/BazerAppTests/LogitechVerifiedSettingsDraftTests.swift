// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation
import Testing
@testable import BazerApp

/// Draft routing only: no AppModel, live monitor, filesystem preferences or I/O.
struct LogitechVerifiedSettingsDraftTests {
    private var snapshot: DeviceSettingsSnapshot {
        let host=DeviceSessionID(physicalDeviceID:PhysicalDeviceID(rawValue:"synthetic-verified-scope"))
        let table=DPIStageTable(stages:[400,800,1600,3200,6400].enumerated().map {
            DPIStage(id:UInt8($0.offset),dpi:DPISetting(UInt16($0.element)))
        },activeStageID:2,opaqueBytes:[UInt8](repeating:0xA7,count:255),defaultStageID:1)
        return DeviceSettingsSnapshot(session:LogicalDeviceSessionID(address:.direct(host)),revision:7,capturedAt:Date(timeIntervalSince1970:100),
            settings:DeviceSettings(currentDPI:DPISetting(1600),pollingRateHz:1000,stages:table,activeProfileID:1,currentStageID:2))
    }
    private var capabilities: DeviceCapabilities {
        DeviceCapabilities(operations:[
            .stageSelect:OperationCapability(evidence:.writeVerified,constraints:CapabilityConstraints(allowedValues:[0,1,2,3,4],persistenceScopes:[.runtime])),
            .stagesWrite:OperationCapability(evidence:.writeVerified,constraints:CapabilityConstraints(minimum:100,maximum:25600,step:50,maximumStages:5,persistenceScopes:[.onboard])),
            .pollingRateWrite:OperationCapability(evidence:.writeVerified,constraints:CapabilityConstraints(allowedValues:[125,250,500,1000],persistenceScopes:[.onboard])),
            .onboardPersist:OperationCapability(evidence:.persistenceVerified,constraints:CapabilityConstraints(persistenceScopes:[.onboard])),
            .dpiWrite:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(minimum:100,maximum:25600,step:50,persistenceScopes:[.runtime])),
            .onboardWrite:OperationCapability(evidence:.discovered,constraints:CapabilityConstraints(allowedValues:[1,2,3],persistenceScopes:[.runtime]))
        ])
    }
    @Test func onboardRateOnlyDraftKeepsRateOnlyIntentAndDoesNotInventStageEdits() throws {
        let before=snapshot
        var draft=DeviceSettingsDraft(before,scope:.runtime); draft.rate="500"
        let request=try #require(draft.request(capabilities:capabilities,scope:.onboard))
        #expect(request.target == before.session); #expect(request.expectedRevision == before.revision)
        #expect(request.change.fields == [.pollingRate]); #expect(request.change.stages == nil)
        #expect(draft.request(capabilities:capabilities,scope:.runtime) == nil)
    }
    @Test func runtimeSelectionAndOnboardRateTableDefaultStaySeparateAndXYRemainsUnverified() throws {
        let before=snapshot
        var draft=DeviceSettingsDraft(before,scope:.runtime)
        draft.rate="500"; draft.stageValues[0] = .init(x:"450",y:"450"); draft.defaultStage="2"; draft.currentStage="3"
        draft.dpiX="1800"; draft.dpiY="1800"; draft.activeProfile="2"
        let runtime=try #require(draft.request(capabilities:capabilities,scope:.runtime))
        #expect(runtime.change.fields == [.currentStage]); #expect(runtime.change.currentStageID == 3)
        let onboard=try #require(draft.request(capabilities:capabilities,scope:.onboard))
        #expect(onboard.change.fields == [.pollingRate,.stages])
        #expect(onboard.change.stages?.activeStageID == 2); #expect(onboard.change.stages?.defaultStageID == 2)
        #expect(onboard.change.stages?.opaqueBytes == before.settings.stages?.opaqueBytes)
        #expect(onboard.change.currentStageID == nil); #expect(onboard.change.activeProfileID == nil); #expect(onboard.change.currentDPI == nil)
        draft.stageValues[0] = .init(x:"450",y:"500")
        #expect(draft.request(capabilities:capabilities,scope:.onboard) == nil)
    }
}
