// SPDX-License-Identifier: GPL-3.0-or-later
// This file is linked only into the hardware-disabled offline executable.
import BazerCore
import BazerDrivers
@testable import BazerHID
import Foundation
import RazerProtocol

final class RazerSettingsFakeBackend: HIDDiscoveryBackend, HIDSynchronousReportBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var request: HIDReadOnlyFeatureRequest?
    private var sent: [[UInt8]] = []
    private var dpi: [UInt8] = [1, 3, 32, 3, 32] + Array(repeating: 0xA7, count: 75)
    private var stages: [UInt8] = [1, 2, 0xF0] + Array(repeating: 0xB6, count: 77)
    private var rate: UInt8 = 1
    private var unit = "OFFLINE-UNIT-123"
    private var firmware: UInt8 = 10
    var ignoreRateWrite = false
    var invalidDPIACK = false
    var linkDPIAndStages = false
    var ignoreSecondDPIWrite = false
    var ignoreXAtDPIWriteNumber: Int?
    var ignoreYAtDPIWriteNumber: Int?
    var onFirstSetting: (@Sendable () -> Void)?
    var frames: [[UInt8]] { lock.withLock { sent } }
    var settingFrames: [[UInt8]] { frames.filter { $0[7] < 0x80 } }
    var dpiValue: Int { lock.withLock { Int(dpi[1]) * 256 + Int(dpi[2]) } }
    var dpiSetting: DPISetting { lock.withLock { DPISetting(x: UInt16(dpi[1]) << 8 | UInt16(dpi[2]), y: UInt16(dpi[3]) << 8 | UInt16(dpi[4])) } }
    var rateValue: Int { lock.withLock { rate == 1 ? 1000 : rate == 2 ? 500 : 125 } }
    var stageBytes: [UInt8] { lock.withLock { stages } }
    static var descriptor: HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(registryEntryID: 101, usbParentRegistryEntryID: 10, vendorID: 0x1532, productID: 0x00C5,
            product: "Offline Razer fixture", transport: "USB", primaryUsage: .mouse, usages: [.mouse], maxFeatureReportSize: 90,
            reportDescriptor: [5, 1, 9, 2, 0xA1, 1, 0x75, 8, 0x95, 90, 0xB1, 1, 0xC0])
    }
    static var unrelatedLogitech: HIDInterfaceDescriptor {
        HIDInterfaceDescriptor(registryEntryID: 202, usbParentRegistryEntryID: 20, vendorID: 0x046D, productID: 0xC539,
            product: "Unrelated offline Logitech receiver", transport: "USB", reportDescriptor: [0x06, 0, 0xFF, 9, 1, 0xA1, 1, 0xC0])
    }
    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) {}
    func snapshot() -> HIDDiscoverySnapshot { HIDDiscoverySnapshot(capturedAt: Date(), interfaces: [Self.descriptor, Self.unrelatedLogitech]) }
    func inspectInterface(registryEntryID: UInt64) -> HIDInspectionResult { HIDInspectionResult(registryEntryID: registryEntryID, operations: []) }
    func stop() {}
    private func diagnostic(_ phase: String, _ id: UInt64, code: Int32 = 0) -> HIDOperationDiagnostic {
        precondition(id == 101, "The Razer-only runner accessed an unrelated HID endpoint")
        return HIDOperationDiagnostic(phase: phase, registryEntryID: id, rawIOReturn: code, message: "Offline fake only")
    }
    func openFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic { diagnostic("open", registryEntryID) }
    func closeFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic { diagnostic("close", registryEntryID) }
    func setFeature(registryEntryID: UInt64, request: HIDReadOnlyFeatureRequest) -> HIDOperationDiagnostic {
        var callback: (@Sendable () -> Void)?
        lock.withLock {
            self.request = request; sent.append(request.bytes)
            switch request.operation {
            case .setDPI:
                let writes = sent.filter { $0[6] == 4 && $0[7] == 5 }.count
                let previous = dpi
                if !(ignoreSecondDPIWrite && writes == 2) { dpi = Array(request.bytes[8...87]) }
                if ignoreXAtDPIWriteNumber == writes { dpi[1...2] = previous[1...2] }
                if ignoreYAtDPIWriteNumber == writes { dpi[3...4] = previous[3...4] }
                if linkDPIAndStages { stages[8] ^= 1 }
            case .setPollingRate: if !ignoreRateWrite { rate = request.bytes[8] }
            case .setDPIStages: preconditionFailure("Unknown stage writes are prohibited")
            default: break
            }
            if request.operation?.isWrite == true && sent.filter({ $0[7] < 0x80 }).count == 1 { callback = onFirstSetting }
        }
        callback?()
        return diagnostic("setFeature", registryEntryID)
    }
    func getFeature(registryEntryID: UInt64, reportID: UInt8, capacity: Int) -> HIDRawFeatureReport {
        lock.withLock {
            guard let request else { preconditionFailure("Fake request missing") }
            var bytes = request.bytes; bytes[0] = 2
            switch request.operation {
            case .readFirmware: bytes[8] = 1; bytes[9] = firmware
            case .readDPI: bytes[8...87] = dpi[...]
            case .readDPIStages: bytes[8...87] = stages[...]
            case .readPollingRate: bytes[8] = rate
            case .readBackupIdentity:
                let serial = Array(unit.utf8); bytes[8..<(8 + serial.count)] = serial[...]
            case .setDPI: if invalidDPIACK { bytes[0] = 5 }
            default: break
            }
            bytes[88] = bytes[2...87].reduce(0, ^)
            return HIDRawFeatureReport(operation: diagnostic("getFeature", registryEntryID), bytes: bytes, actualLength: bytes.count)
        }
    }
    func externalDPI(_ value: Int) { lock.withLock { dpi[1] = UInt8(value >> 8); dpi[2] = UInt8(value & 255); dpi[3] = dpi[1]; dpi[4] = dpi[2] } }
    func externalDPI(x: UInt16, y: UInt16) { lock.withLock { dpi[1] = UInt8(x >> 8); dpi[2] = UInt8(x & 255); dpi[3] = UInt8(y >> 8); dpi[4] = UInt8(y & 255) } }
    func externalRate(_ code: UInt8) { lock.withLock { rate = code } }
    func changeUnit() { lock.withLock { unit = "DIFFERENT-UNIT-456" } }
    func changeFirmware() { lock.withLock { firmware = 11 } }
}

enum RazerSettingsOfflineHarness {
    static let selector = "usb-parent:10/direct"
    static func factory(_ backend: RazerSettingsFakeBackend) -> RazerSettingsExperiment.ContextFactory {
        { selector in
            try await RazerExperimentContext.make(discovery: HIDDiscovery(backendFactory: { backend }, processLockFactory: { nil }), selector: selector)
        }
    }
    static func options(_ phase: String, output: URL, before: RazerExperimentFile? = nil, field: String = "dpi", original: String = "800", target: String = "1600", hold: Bool = false,
                        originalX: String = "800", originalY: String = "800", targetX: String = "800", targetY: String = "1600") throws -> RazerExperimentOptions {
        let flag = phase == "prepare" || phase == "verify" ? "--allow-hardware-read" : phase == "run" ? "--allow-setting-write-and-restore" : "--allow-original-value-write"
        var arguments = [phase, flag, "--device", selector, "--output-dir", output.path]
        if let before {
            arguments += ["--before", before.path, "--before-sha256", before.sha256, "--field", field]
            arguments += field == "xy" ? ["--original-x", originalX, "--original-y", originalY] : ["--original", original]
            if phase == "run" || phase == "verify" {
                arguments += field == "xy" ? ["--target-x", targetX, "--target-y", targetY] : ["--target", target]
            }
        }
        if hold { arguments.append("--hold-for-power-cycle") }
        return try RazerExperimentOptions.parse(arguments)
    }
    static func rejected(_ message: String, _ work: () async throws -> Void) async throws {
        var failed = false
        do { try await work() } catch { failed = true }
        try razerRequire(failed, message)
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bazer-razer-offline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func output(_ name: String) -> URL { root.appendingPathComponent(name + "-" + UUID().uuidString) }
        let backend = RazerSettingsFakeBackend()
        let prepare = try await RazerSettingsExperiment.execute(options("prepare", output: output("prepare")), factory: factory(backend))
        let before = prepare.receipt
        try razerRequire(backend.settingFrames.isEmpty && prepare.settingWrites == 0, "Prepare sent a setting")
        let original = try JSONDecoder().decode(RazerExperimentBefore.self, from: RazerExperimentFiles.privateData(URL(fileURLWithPath: before.path)))
        try razerRequire(original.backup.regions[0].bytes == backend.stageBytes && original.capture.observations[0].dpiResponse.count == 90 && original.capture.observations[0].stagesResponse.count == 90,
            "Unknown arbitrary count/IDs did not remain a full raw capture")
        checks += 1
        let unified = try await RazerSettingsExperiment.execute(options("run", output: output("dpi"), before: before), factory: factory(backend))
        try razerRequire(unified.originalRestored && unified.fullStageUnchanged && backend.dpiValue == 800 && backend.settingFrames.count == 2, "DPI write/read/restore was not exactly two setting reports")
        try razerRequire(backend.settingFrames.allSatisfy { $0[6] == 4 && $0[7] == 5 && $0[1] == 0x1F && $0[8] == 1 && Array($0[13...87]) == Array(repeating: 0xA7, count: 75) }, "DPI unknown bytes or typed envelope changed")
        checks += 1
        let rate = try await RazerSettingsExperiment.execute(options("run", output: output("rate"), before: before, field: "rate", original: "1000", target: "500"), factory: factory(backend))
        try razerRequire(rate.originalRestored && rate.fullStageUnchanged && backend.rateValue == 1000 && backend.settingFrames.count == 4
            && backend.settingFrames.suffix(2).map { $0[8] } == [2, 1], "Traditional rate code or restoration differs")
        checks += 1
        let held = try await RazerSettingsExperiment.execute(options("run", output: output("held"), before: before, hold: true), factory: factory(backend))
        try razerRequire(!held.originalRestored && backend.dpiValue == 1600 && backend.settingFrames.count == 5, "Hold wrote an automatic recovery")
        let verified = try await RazerSettingsExperiment.execute(options("verify", output: output("verify"), before: before), factory: factory(backend))
        try razerRequire(!verified.originalRestored && verified.settingWrites == 0 && backend.settingFrames.count == 5, "Fresh verify wrote settings")
        let recovered = try await RazerSettingsExperiment.execute(options("recover", output: output("recover"), before: before), factory: factory(backend))
        try razerRequire(recovered.originalRestored && backend.dpiValue == 800 && backend.settingFrames.count == 6, "One-way recover replayed the test value")
        checks += 1
        let writes = backend.settingFrames.count
        let badHash = RazerExperimentFile(path: before.path, sha256: String(repeating: "0", count: 64))
        let frames = backend.frames.count
        try await rejected("Bad evidence hash accepted") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("badhash"), before: badHash), factory: factory(backend)) }
        try razerRequire(backend.frames.count == frames, "Bad evidence reached HID")
        try await rejected("Invalid rate accepted") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("bad-rate"), before: before, field: "rate", original: "1000", target: "250"), factory: factory(backend)) }
        try await rejected("Mismatched explicit original accepted") { _ = try await RazerSettingsExperiment.execute(options("recover", output: output("bad-original"), before: before, original: "900"), factory: factory(backend)) }
        try razerRequire(backend.settingFrames.count == writes, "Bad arguments sent a setting")
        checks += 1
        backend.externalRate(2)
        try await rejected("Unrelated rate drift accepted") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("drift"), before: before), factory: factory(backend)) }
        backend.externalRate(1)
        try razerRequire(backend.settingFrames.count == writes, "Unrelated drift was overwritten")
        checks += 1
        let changedUnit = RazerSettingsFakeBackend(); changedUnit.changeUnit()
        try await rejected("Different strong unit accepted") { _ = try await RazerSettingsExperiment.execute(options("recover", output: output("unit"), before: before), factory: factory(changedUnit)) }
        try razerRequire(changedUnit.settingFrames.isEmpty, "Wrong unit received a restore")
        let changedFirmware = RazerSettingsFakeBackend(); changedFirmware.changeFirmware()
        try await rejected("Different firmware accepted") { _ = try await RazerSettingsExperiment.execute(options("recover", output: output("firmware"), before: before), factory: factory(changedFirmware)) }
        try razerRequire(changedFirmware.settingFrames.isEmpty, "Wrong firmware received a restore")
        checks += 1
        let linked = RazerSettingsFakeBackend(); linked.linkDPIAndStages = true
        let linkedResult = try await RazerSettingsExperiment.execute(options("run", output: output("linked"), before: before), factory: factory(linked))
        try razerRequire(linkedResult.originalRestored && !linkedResult.fullStageUnchanged && linked.dpiValue == 800 && linked.settingFrames.count == 2,
            "Linked stage difference was concealed or unknown stages were written")
        checks += 1
        let mismatch = RazerSettingsFakeBackend(); mismatch.ignoreRateWrite = true
        try await rejected("Rate mismatch promoted") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("mismatch"), before: before, field: "rate", original: "1000", target: "500"), factory: factory(mismatch)) }
        try razerRequire(mismatch.settingFrames.count == 1, "A failed rate write was retried or blindly recovered")
        checks += 1
        let unknown = RazerSettingsFakeBackend(); unknown.invalidDPIACK = true
        try await rejected("Malformed ACK was treated as verified") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("ack"), before: before), factory: factory(unknown)) }
        try razerRequire(unknown.settingFrames.count == 1 && unknown.dpiValue == 1600, "Unknown outcome was replayed")
        unknown.invalidDPIACK = false
        _ = try await RazerSettingsExperiment.execute(options("recover", output: output("ack-recovery"), before: before), factory: factory(unknown))
        try razerRequire(unknown.settingFrames.count == 2 && unknown.dpiValue == 800, "Explicit unknown-outcome recovery was not one-way")
        checks += 1
        let receiptFailure = RazerSettingsFakeBackend()
        let receiptOutput = output("receipt-failure")
        receiptFailure.onFirstSetting = {
            try? LocalPrivateFile(url: receiptOutput.appendingPathComponent("test-result.json")).writeNew(Data("offline occupied receipt".utf8))
        }
        try await rejected("A failed phase receipt was promoted") { _ = try await RazerSettingsExperiment.execute(options("run", output: receiptOutput, before: before), factory: factory(receiptFailure)) }
        try razerRequire(receiptFailure.dpiValue == 800 && receiptFailure.settingFrames.count == 2, "Receipt failure prevented the already-authorized original-field recovery")
        checks += 1
        let restoreFailure = RazerSettingsFakeBackend(); restoreFailure.ignoreSecondDPIWrite = true
        try await rejected("Failed original restore was promoted") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("restore-failure"), before: before), factory: factory(restoreFailure)) }
        try razerRequire(restoreFailure.dpiValue == 1600 && restoreFailure.settingFrames.count == 2, "Failed restore was retried or followed by another test")
        checks += 1
        let combined = RazerSettingsFakeBackend()
        _ = try await RazerSettingsExperiment.execute(options("run", output: output("combined-dpi"), before: before, hold: true), factory: factory(combined))
        let secondBefore = try await RazerSettingsExperiment.execute(options("prepare", output: output("combined-B")), factory: factory(combined))
        _ = try await RazerSettingsExperiment.execute(options("run", output: output("combined-rate"), before: secondBefore.receipt, field: "rate", original: "1000", target: "500", hold: true), factory: factory(combined))
        let fresh = try await RazerSettingsExperiment.execute(options("verify", output: output("combined-fresh"), before: secondBefore.receipt, field: "rate", original: "1000", target: "500"), factory: factory(combined))
        try razerRequire(fresh.currentDPI == DPISetting(1600) && fresh.pollingRateHz == 500 && combined.settingFrames.count == 2, "Combined held state was not read without writes")
        _ = try await RazerSettingsExperiment.execute(options("recover", output: output("combined-recover-rate"), before: secondBefore.receipt, field: "rate", original: "1000"), factory: factory(combined))
        let combinedFinal = try await RazerSettingsExperiment.execute(options("recover", output: output("combined-recover-dpi"), before: before), factory: factory(combined))
        try razerRequire(combinedFinal.originalRestored && combinedFinal.fullStageUnchanged && combined.dpiValue == 800 && combined.rateValue == 1000 && combined.settingFrames.count == 4,
            "Combined reverse-order single-field recovery failed")
        checks += 1
        let xy = RazerSettingsFakeBackend()
        let xyResult = try await RazerSettingsExperiment.execute(options("run", output: output("xy-y"), before: before, field: "xy"), factory: factory(xy))
        try razerRequire(xyResult.originalRestored && xyResult.fullStageUnchanged && xy.dpiSetting == DPISetting(800) && xy.settingFrames.count == 2
            && Array(xy.settingFrames[0][9...12]) == [3, 32, 6, 64] && Array(xy.settingFrames[1][9...12]) == [3, 32, 3, 32], "Independent Y changed a unified scalar, used the wrong pair, or did not restore both original axes")
        try razerRequire(RazerSettingsExperiment.operation(.xy) == .razer00C5IndependentXY && xy.rateValue == 1000
            && xy.settingFrames.allSatisfy { $0[6] == 4 && $0[7] == 5 && Array($0[13...87]) == Array(repeating: 0xA7, count: 75) }, "XY operation, unrelated rate or opaque DPI bytes changed")
        let xyReverse = try await RazerSettingsExperiment.execute(options("run", output: output("xy-x"), before: before, field: "xy", targetX: "1600", targetY: "800"), factory: factory(xy))
        try razerRequire(xyReverse.originalRestored && xy.dpiSetting == DPISetting(800) && xy.settingFrames.count == 4
            && Array(xy.settingFrames[2][9...12]) == [6, 64, 3, 32], "Independent X was replaced by unified DPI")
        checks += 1
        let asymmetric = RazerSettingsFakeBackend(); asymmetric.externalDPI(x: 800, y: 1200)
        let asymmetricBefore = try await RazerSettingsExperiment.execute(options("prepare", output: output("xy-asymmetric-original")), factory: factory(asymmetric))
        let asymmetricResult = try await RazerSettingsExperiment.execute(options("run", output: output("xy-asymmetric"), before: asymmetricBefore.receipt, field: "xy", originalX: "800", originalY: "1200", targetX: "1600", targetY: "2000"), factory: factory(asymmetric))
        try razerRequire(asymmetricResult.originalRestored && asymmetric.dpiSetting == DPISetting(x: 800, y: 1200) && asymmetric.settingFrames.count == 2
            && Array(asymmetric.settingFrames[1][9...12]) == [3, 32, 4, 176], "Asymmetric original was restored as unified DPI")
        let asymmetricFrames = asymmetric.frames.count
        try await rejected("Unified operation accepted an asymmetric original") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("xy-no-fallback"), before: asymmetricBefore.receipt), factory: factory(asymmetric)) }
        try await rejected("A mismatching explicit original axis was accepted") { _ = try await RazerSettingsExperiment.execute(options("recover", output: output("xy-wrong-original"), before: asymmetricBefore.receipt, field: "xy"), factory: factory(asymmetric)) }
        try await rejected("An invalid independent axis step was accepted") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("xy-invalid-axis"), before: asymmetricBefore.receipt, field: "xy", originalX: "800", originalY: "1200", targetX: "801", targetY: "1600"), factory: factory(asymmetric)) }
        try razerRequire(asymmetric.frames.count == asymmetricFrames, "Invalid original/axis reached HID")
        checks += 1
        for ignoreX in [false, true] {
            let axisMismatch = RazerSettingsFakeBackend()
            if ignoreX { axisMismatch.ignoreXAtDPIWriteNumber = 1 } else { axisMismatch.ignoreYAtDPIWriteNumber = 1 }
            try await rejected("A single matching axis was promoted as XY success") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("xy-one-axis"), before: before, field: "xy", targetX: "1600", targetY: "1200"), factory: factory(axisMismatch)) }
            try razerRequire(axisMismatch.settingFrames.count == 1 && axisMismatch.dpiSetting == (ignoreX ? DPISetting(x: 800, y: 1200) : DPISetting(x: 1600, y: 800)), "XY mismatch retried, downgraded, or ignored the observed failing axis")
            axisMismatch.ignoreXAtDPIWriteNumber = nil; axisMismatch.ignoreYAtDPIWriteNumber = nil
            let axisRecovered = try await RazerSettingsExperiment.execute(options("recover", output: output("xy-one-axis-recovery"), before: before, field: "xy"), factory: factory(axisMismatch))
            try razerRequire(axisRecovered.originalRestored && axisMismatch.settingFrames.count == 2 && axisMismatch.dpiSetting == DPISetting(800), "XY explicit recovery rewrote a test value")
        }
        checks += 1
        let axisRestoreFailure = RazerSettingsFakeBackend(); axisRestoreFailure.ignoreYAtDPIWriteNumber = 2
        try await rejected("A failed original Y restoration was promoted") { _ = try await RazerSettingsExperiment.execute(options("run", output: output("xy-restore-failure"), before: before, field: "xy", targetX: "1600", targetY: "1200"), factory: factory(axisRestoreFailure)) }
        try razerRequire(axisRestoreFailure.settingFrames.count == 2 && axisRestoreFailure.dpiSetting == DPISetting(x: 800, y: 1200), "XY failed restore was retried or collapsed to a scalar")
        axisRestoreFailure.ignoreYAtDPIWriteNumber = nil
        _ = try await RazerSettingsExperiment.execute(options("recover", output: output("xy-restore-explicit"), before: before, field: "xy"), factory: factory(axisRestoreFailure))
        try razerRequire(axisRestoreFailure.settingFrames.count == 3 && axisRestoreFailure.dpiSetting == DPISetting(800), "XY recovery did not restore the missing original axis once")
        checks += 1
        let xyCombined = RazerSettingsFakeBackend()
        _ = try await RazerSettingsExperiment.execute(options("run", output: output("xy-combined-held"), before: before, field: "xy", hold: true), factory: factory(xyCombined))
        try await rejected("Fresh verify accepted a different DPI axis pair") { _ = try await RazerSettingsExperiment.execute(options("verify", output: output("xy-wrong-held-pair"), before: before, field: "xy", targetX: "1600", targetY: "800"), factory: factory(xyCombined)) }
        try razerRequire(xyCombined.settingFrames.count == 1 && xyCombined.dpiSetting == DPISetting(x: 800, y: 1600), "Fresh verify wrote settings")
        let xyBeforeRate = try await RazerSettingsExperiment.execute(options("prepare", output: output("xy-combined-B")), factory: factory(xyCombined))
        _ = try await RazerSettingsExperiment.execute(options("run", output: output("xy-combined-rate-held"), before: xyBeforeRate.receipt, field: "rate", original: "1000", target: "500", hold: true), factory: factory(xyCombined))
        let xyFresh = try await RazerSettingsExperiment.execute(options("verify", output: output("xy-combined-fresh"), before: xyBeforeRate.receipt, field: "rate", original: "1000", target: "500"), factory: factory(xyCombined))
        try razerRequire(xyFresh.currentDPI == DPISetting(x: 800, y: 1600) && xyFresh.pollingRateHz == 500 && xyCombined.settingFrames.count == 2, "Fresh XY/rate pair did not persist in the fake across contexts")
        _ = try await RazerSettingsExperiment.execute(options("recover", output: output("xy-combined-recover-rate"), before: xyBeforeRate.receipt, field: "rate", original: "1000"), factory: factory(xyCombined))
        let xyCombinedFinal = try await RazerSettingsExperiment.execute(options("recover", output: output("xy-combined-recover-xy"), before: before, field: "xy"), factory: factory(xyCombined))
        try razerRequire(xyCombinedFinal.originalRestored && xyCombinedFinal.fullStageUnchanged && xyCombined.dpiSetting == DPISetting(800) && xyCombined.rateValue == 1000 && xyCombined.settingFrames.count == 4,
            "Reverse rate-then-XY recovery failed to restore both original axes")
        checks += 1
        for args in [["run"], ["prepare", "--device", selector, "--output-dir", output("invalid").path], ["recover", "--allow-setting-write-and-restore"]] {
            var failed = false
            do { _ = try RazerExperimentOptions.parse(args) } catch { failed = true }
            try razerRequire(failed, "Missing/wrong explicit hardware flag accepted")
        }
        checks += 1
        print("{\"state\":\"offlinePassed\",\"checks\":\(checks),\"hardwareAccess\":false,\"unknownStageWrites\":0,\"logitechAccess\":false}")
    }
}
