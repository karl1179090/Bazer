import BazerCore
import Foundation
import BazerHID
@testable import HIDProbe
import Testing

struct ExpansionProbeOptionsTests {
    @Test func readCommandsRejectEverySettingFlagAndRequireLogicalSelection() throws {
        #expect(try ExpansionProbeOptions.parse(["capabilities"]).action == .capabilities)
        for prefix in [["settings", "read"], ["logitech", "features"]] {
            #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(prefix) }
            for flags in [["--dpi", "800"], ["--rate", "500"], ["--scope", "onboard"], ["--validation-operation", "razer00C5DPI"], ["--restore-original"]] {
                #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(prefix + ["--device", "usb-parent:10/direct"] + flags) }
            }
        }
    }
    @Test func firstValidationIsExactOperationAndRequiresOriginalRecovery() throws {
        let base = ["settings", "apply", "--device", "usb-parent:10/direct", "--dpi", "800", "--scope", "onboard", "--backup-output", "/tmp/new-backup.json"]
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(base + ["--validation-operation", "razer00C5DPI"]) }
        let options = try ExpansionProbeOptions.parse(base + ["--validation-operation", "razer00C5DPI", "--restore-original"])
        #expect(options.validationOperation?.rawValue == "razer00C5DPI"); #expect(options.restoreOriginal)
        for flags in [["--unsafe", "true"], ["--validation-operation", "all"], ["--raw-report", "00"], ["--dpi", "1600"]] {
            #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(base + flags) }
        }
    }
    @Test func invalidNumbersAndConflictingDPIAxesFailDuringParsing() {
        let base = ["settings", "preview", "--device", "usb-parent:10/direct", "--scope", "onboard"]
        for value in ["0", "-1", "65536", "nan", "1e300"] { #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(base + ["--dpi", value]) } }
        for value in ["0", "-1", "8001", "nan", "1e300"] { #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(base + ["--rate", value]) } }
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(base + ["--dpi", "800", "--dpi-y", "1600"]) }
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(base + ["--dpi-y", "1600", "--dpi", "800"]) }
    }
    @Test func axisChangesPreserveActualUneditedAxisAndRefuseUnknownBefore() throws {
        let options = try ExpansionProbeOptions.parse(["settings", "preview", "--device", "d", "--dpi-x", "1200", "--scope", "onboard"])
        let change = try options.change(from: DeviceSettings(currentDPI: DPISetting(x: 800, y: 1600)))
        #expect(change.currentDPI == DPISetting(x: 1200, y: 1600))
        #expect(throws: (any Error).self) { try options.change(from: DeviceSettings()) }
    }
    @Test func profileCommandsRequireExplicitFilesAndRecoveryOutput() throws {
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(["profiles", "export", "--device", "d"]) }
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(["profiles", "restore", "--device", "d", "--input", "/tmp/backup.json"]) }
        let options = try ExpansionProbeOptions.parse(["profiles", "restore", "--device", "d", "--input", "/tmp/backup.json", "--rollback-output", "/tmp/recovery.json"])
        #expect(options.action == .restore); #expect(options.rollbackOutput == "/tmp/recovery.json")
    }
    @Test func ordinarySettingsOutputOmitsOpaqueProfileBytes() throws {
        let secret = Array("SYNTHETIC-MACRO-DATA".utf8)
        let values = ProbeSettingsValues(DeviceSettings(stages: DPIStageTable(stages: [DPIStage(id: 7, dpi: DPISetting(800))], activeStageID: 7, opaqueBytes: secret)))
        let json = try #require(String(data: JSONEncoder().encode(values), encoding: .utf8))
        #expect(!json.contains("opaqueBytes")); #expect(!json.contains("SYNTHETIC")); #expect(json.contains("800"))
    }
    @Test func stageEditsKeepExistingIDsOrderOpaqueAndSeparateCurrentFromDefault() throws {
        let table = DPIStageTable(stages: [DPIStage(id: 7, dpi: DPISetting(800)), DPIStage(id: 9, dpi: DPISetting(1600))], activeStageID: 9, opaqueBytes: [0xA5, 0x5A], defaultStageID: 7)
        let before = DeviceSettings(stages: table, activeProfileID: 2, currentStageID: 9)
        let prefix = ["settings", "preview", "--device", "d", "--scope", "onboard"]
        let options = try ExpansionProbeOptions.parse(prefix + ["--dpi-stages", "7:1200:1400", "--default-stage", "9"])
        let change = try options.change(from: before)
        #expect(change.stages?.stages.map(\.id) == [7, 9]); #expect(change.stages?.stages[1].dpi == DPISetting(1600))
        #expect(change.stages?.opaqueBytes == table.opaqueBytes)
        #expect(change.stages?.defaultStageID == 9); #expect(change.stages?.activeStageID == 9); #expect(change.currentStageID == nil)
        let unknown = try ExpansionProbeOptions.parse(prefix + ["--dpi-stages", "8:800:800"])
        #expect(throws: (any Error).self) { try unknown.change(from: before) }
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(prefix + ["--dpi-stages", "7:800:800,7:1600:1600"]) }
        let current = try ExpansionProbeOptions.parse(["settings", "preview", "--device", "d", "--scope", "runtime", "--current-stage", "7", "--active-profile", "3"])
        let selected = try current.change(from: before)
        #expect(selected.currentStageID == 7); #expect(selected.activeProfileID == 3); #expect(selected.stages == nil)
    }
    @Test func onboardApplyRequiresNewBackupAndRecoverySelectsEveryRequestedOriginalField() throws {
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(["settings", "apply", "--device", "d", "--scope", "onboard", "--dpi", "800"]) }
        let table = DPIStageTable(stages: [DPIStage(id: 0, dpi: DPISetting(800))], activeStageID: 0, opaqueBytes: [1])
        let before = DeviceSettings(currentDPI: DPISetting(800), pollingRateHz: 500, stages: table, activeProfileID: 2, currentStageID: 0)
        let requested = DeviceSettingsChange(stages: table, activeProfileID: 3, persistence: .runtime, currentStageID: 1)
        let recovery = try ExpansionProbe.recoveryChange(before: before, requested: requested)
        #expect(Set(recovery.fields) == Set(requested.fields)); #expect(recovery.activeProfileID == 2); #expect(recovery.currentStageID == 0)
        #expect(recovery.currentDPI == nil); #expect(recovery.pollingRateHz == nil)
        #expect(throws: (any Error).self) { try ExpansionProbe.recoveryChange(before: DeviceSettings(), requested: requested) }
    }
    @Test func explicitControlTraceIsLimitedToReadOnlyCaptureCommands() throws {
        #expect(try ExpansionProbeOptions.parse(["capabilities", "--trace"]).trace)
        #expect(try ExpansionProbeOptions.parse(["logitech", "features", "--device", "d", "--trace"]).trace)
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(["settings", "read", "--device", "d", "--trace"]) }
    }
    @Test func layoutCaptureAcceptsOnlyReadOnlyArgumentsAndRequiresANewOutput() throws {
        #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(["profiles", "capture-layout", "--device", "d"]) }
        let prefix = ["profiles", "capture-layout", "--device", "d", "--output", "/tmp/new-capture.json"]
        #expect(try ExpansionProbeOptions.parse(prefix).action == .captureLayout)
        for flags in [["--dpi", "800"], ["--default-stage", "1"], ["--hardware-evidence-reference", "/tmp/known.json"], ["--validation-operation", "razer00C5Stages"], ["--restore-original"]] {
            #expect(throws: (any Error).self) { try ExpansionProbeOptions.parse(prefix + flags) }
        }
    }
    @Test func identityEnvelopeUsesActualHostProtocolFieldsAndOnlyAUnitHash() throws {
        let interface = HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10, vendorID: 0x046D, productID: 0xC539,
            product: "Synthetic receiver", transport: "USB", primaryUsage: .mouse, reportDescriptor: [5, 1, 9, 2])
        let physical = PhysicalDeviceGrouper.group([interface])[0]
        var store = DeviceStore()
        store.reconcile([IdentifiedDevice(descriptor: physical, kind: .other, capabilities: .identificationOnly, controlEndpointRegistryEntryID: 101, isReceiver: true)], at: Date(timeIntervalSince1970: 100))
        let host = try #require(store.devices[physical.id]?.sessionID)
        let target = LogicalDeviceDescriptor(address: DeviceAddress(hostSessionID: host, target: .receiver(index: 1,
            identity: LogicalPeripheralIdentity(vendorID: 0x046D, wirelessProductID: 0x4079, unitID: "SYNTHETIC-PRIVATE-UNIT", protocolVersion: "2.0", firmware: "1.2")), pairingGeneration: UUID()),
            product: "Synthetic child", kind: .mouse, capabilities: .identificationOnly, controlEndpointRegistryEntryID: 101)
        store.reconcileLogicalDevices([target], for: host)
        let child = try #require(store.logicalDevices[target.id])
        let received = Date(timeIntervalSince1970: 101)
        let report = LogicalProbeDevice(child, hosts: Array(store.devices.values), capturedAt: Date(timeIntervalSince1970: 102), identityReceivedAt: received)
        #expect(report.hostVendorID == 0x046D); #expect(report.hostProductID == 0xC539)
        #expect(report.deviceIndex == 1); #expect(report.wirelessProductID == 0x4079); #expect(report.protocolVersion == "2.0")
        #expect(report.firmware == "1.2"); #expect(report.identityReceivedAt == received)
        #expect(report.controlDescriptorSHA256 == interface.descriptorSHA256); #expect(report.unitIdentitySHA256?.count == 64)
        let encoded = try #require(String(data: JSONEncoder().encode(report), encoding: .utf8))
        #expect(!encoded.contains("SYNTHETIC-PRIVATE-UNIT")); #expect(!encoded.contains("opaqueBytes"))
        let direct = LogicalDeviceDescriptor(address: .direct(host), product: "Synthetic direct", kind: .mouse, capabilities: .identificationOnly,
            controlEndpointRegistryEntryID: 101, peripheralIdentity: target.peripheralIdentity)
        store.reconcileLogicalDevices([direct], for: host)
        let directState = try #require(store.logicalDevices[direct.id])
        let directReport = LogicalProbeDevice(directState, hosts: Array(store.devices.values), capturedAt: received)
        #expect(directReport.deviceIndex == 0xFF); #expect(directReport.protocolVersion == "2.0"); #expect(directReport.firmware == "1.2")
        #expect(directReport.unitIdentitySHA256 == report.unitIdentitySHA256)
        #expect(!(try #require(String(data: JSONEncoder().encode(directReport), encoding: .utf8))).contains("SYNTHETIC-PRIVATE-UNIT"))
    }
}
