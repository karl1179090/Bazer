// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import BazerHID
import Darwin
import Foundation

struct ProbeOptions {
    enum Command: String { case list, watch, inspect, battery, capabilities, settings, logitech, profiles, telemetry }
    let command: Command
    var json = false
    var duration: Double = 30
    var vendorID: UInt16?
    var productID: UInt16?
    var sessionSelector: String?
    var samples = 1
    var interval: Double = 2
    var expansion: ExpansionProbeOptions?

    static let usage = """
    Usage:
      HIDProbe list [--json]
      HIDProbe watch [--duration 30] [--json]
      HIDProbe inspect --vid 1532 --pid 00C5 [--device usb-parent:<id>] [--json]
      HIDProbe battery --vid 1532 --pid 00C5 [--device usb-parent:<id>] [--samples 10] [--interval 2] [--json]
      HIDProbe capabilities [--device <logical-selector>] [--trace] [--json]
      HIDProbe telemetry --device <logical-selector> [--samples 10] [--interval 2] [--trace] [--json]
      HIDProbe settings read --device <logical-selector> [--json]
      HIDProbe settings preview|apply --device <logical-selector> [--dpi <value>] [--rate <Hz>] [--current-stage <id>] [--active-profile <id>] [--dpi-stages id:x:y,...] [--default-stage <id>] --scope runtime|onboard [--backup-output <new-file>] [--hardware-evidence-reference <verified-reference>] [--validation-operation <exact-operation>] [--restore-original] [--json]
      HIDProbe logitech features --device <logical-selector> [--trace] [--json]
      HIDProbe profiles export --device <logical-selector> --output <new-file> [--hardware-evidence-reference <confirmed-local-file>] [--json]
      HIDProbe profiles capture-layout --device <logical-selector> --output <new-unconfirmed-file> [--json]
      HIDProbe profiles restore --device <logical-selector> --input <backup-file> --rollback-output <new-file> [--validation-operation <exact-operation>] [--hardware-evidence-reference <verified-reference>] [--json]

    list/watch are passive: no device open, input subscription, or reports.
    inspect only opens/closes the exact 1532:00C5 control interface nonexclusively.
    Session selectors are temporary and must not be saved as durable identities.
    Onboard apply requires a new --backup-output file. Candidate stage writes also
    require confirmed hardware layout evidence through the exact adapter.
    First-validation apply requires --validation-operation and --restore-original.
    capture-layout is read-only and never confirms a layout or authorizes a write.
    telemetry reads only the selected current Logitech logical target after discovery.
    It stops if that session changes; --interval is the delay between sample attempts.
    Expansion commands discover all supported Logitech hosts before selecting --device.

    Examples (replace selectors and values using current capabilities):
      HIDProbe settings preview --device usb-parent:123/direct --dpi 800 --scope onboard --json
      HIDProbe settings apply --device usb-parent:123/direct --dpi 800 --scope onboard --backup-output ./before-dpi.json --validation-operation razer00C5DPI --restore-original --json
      HIDProbe settings apply --device usb-parent:123/direct --dpi-stages 0:800:800,1:1600:1600 --default-stage 1 --scope onboard --backup-output ./before-stages.json --hardware-evidence-reference ./confirmed-stage-layout.json --validation-operation razer00C5Stages --restore-original --json
      HIDProbe settings apply --device usb-parent:456/receiver-slot:1 --current-stage 1 --scope runtime --validation-operation logitechHIDPP8100Profile --restore-original --json
    """

    static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let command = Command(rawValue: first) else { throw ProbeCLIError.arguments(usage) }
        var result = Self(command: command)
        if [.capabilities, .settings, .logitech, .profiles, .telemetry].contains(command) {
            let expansion = try ExpansionProbeOptions.parse(arguments)
            result.expansion = expansion; result.json = expansion.json
            return result
        }
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            if option == "--json" { result.json = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw ProbeCLIError.arguments("Missing value for \(option).") }
            let value = arguments[index + 1]
            switch option {
            case "--duration":
                guard command == .watch, let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 86400 else { throw ProbeCLIError.arguments("--duration requires seconds in (0, 86400] and the watch command.") }
                result.duration = seconds
            case "--vid", "--pid":
                guard command == .inspect || command == .battery, let number = hexID(value) else { throw ProbeCLIError.arguments("\(option) requires a 16-bit hexadecimal identifier and inspect/battery.") }
                if option == "--vid" { result.vendorID = number } else { result.productID = number }
            case "--device", "--selector":
                guard command == .inspect || command == .battery, !value.isEmpty else { throw ProbeCLIError.arguments("--device requires an inspect/battery session selector.") }
                result.sessionSelector = value
            case "--samples":
                guard command == .battery, let count = Int(value), (1...1000).contains(count) else { throw ProbeCLIError.arguments("--samples requires an integer in 1...1000 and battery.") }
                result.samples = count
            case "--interval":
                guard command == .battery, let seconds = Double(value), seconds.isFinite, seconds >= 0.1, seconds <= 3600 else { throw ProbeCLIError.arguments("--interval requires seconds in [0.1, 3600] and battery.") }
                result.interval = seconds
            default: throw ProbeCLIError.arguments("Unknown option \(option).\n\(usage)")
            }
            index += 2
        }
        if command == .inspect || command == .battery, result.vendorID == nil || result.productID == nil {
            throw ProbeCLIError.arguments("inspect/battery requires explicit --vid and --pid in hexadecimal.")
        }
        return result
    }

    private static func hexID(_ text: String) -> UInt16? {
        let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt16(digits, radix: 16)
    }
}

enum ProbeCLIError: Error, CustomStringConvertible {
    case arguments(String)
    case inspectionFailed
    var description: String {
        switch self {
        case .arguments(let message): message
        case .inspectionFailed: "The nonexclusive open/close inspection failed; see raw IOReturn and operation phase."
        }
    }
}

struct ProbeInterface: Encodable {
    let registryEntryID: UInt64
    let vendorID: String
    let productID: String
    let product: String
    let manufacturer: String?
    let transport: String?
    let isBuiltIn: Bool
    let locationID: UInt32?
    let primaryUsage: HIDUsage?
    let deviceUsagePairs: [HIDUsage]
    let allApplicationUsages: [HIDUsage]
    let maxInputReportSize: Int
    let maxOutputReportSize: Int
    let maxFeatureReportSize: Int
    let descriptorLength: Int
    let reportDescriptorHex: String
    let reportDescriptorSHA256: String
    let descriptorSummary: HIDReportDescriptorSummary?
    let descriptorParseError: String?
    let registryEvidence: HIDRegistryEvidence?

    init(_ descriptor: HIDInterfaceDescriptor, evidence: HIDRegistryEvidence?) {
        registryEntryID = descriptor.registryEntryID
        vendorID = String(format: "%04X", descriptor.vendorID)
        productID = String(format: "%04X", descriptor.productID)
        product = descriptor.product
        manufacturer = descriptor.manufacturer
        transport = descriptor.transport
        isBuiltIn = descriptor.isBuiltIn
        locationID = descriptor.locationID
        primaryUsage = descriptor.primaryUsage
        deviceUsagePairs = descriptor.usages
        allApplicationUsages = descriptor.allUsages.sorted()
        maxInputReportSize = descriptor.maxInputReportSize
        maxOutputReportSize = descriptor.maxOutputReportSize
        maxFeatureReportSize = descriptor.maxFeatureReportSize
        descriptorLength = descriptor.reportDescriptor.count
        reportDescriptorHex = descriptor.reportDescriptor.map { String(format: "%02x", $0) }.joined()
        reportDescriptorSHA256 = descriptor.descriptorSHA256
        do {
            descriptorSummary = try HIDReportDescriptorParser.parse(descriptor.reportDescriptor)
            descriptorParseError = nil
        } catch {
            descriptorSummary = nil
            descriptorParseError = String(describing: error)
        }
        registryEvidence = evidence
    }
}

struct ProbeInterfaceSelection: Encodable {
    let selectedRegistryEntryID: UInt64?
    let candidateRegistryEntryIDs: [UInt64]
    let rejections: [InterfaceRejection]
    let issue: InterfaceSelectionIssue?

    init(_ selection: InterfaceSelection) {
        selectedRegistryEntryID = selection.selected?.registryEntryID
        candidateRegistryEntryIDs = selection.candidates.map(\.registryEntryID)
        rejections = selection.rejections
        issue = selection.issue
    }
}

struct ProbeDevice: Encodable {
    let sessionSelector: String
    let product: String
    let vendorID: String?
    let productID: String?
    let classification: String
    let identificationReasons: [String]
    let groupingBasis: String
    let batterySupport: String
    let controlInterfaceSelection: ProbeInterfaceSelection
    let interfaces: [ProbeInterface]

    var isIdentified: Bool { classification != "excluded" }

    init(_ device: PhysicalDeviceDescriptor, evidence: [UInt64: HIDRegistryEvidence]) {
        sessionSelector = device.id.rawValue
        product = device.product
        vendorID = device.vendorID.map { String(format: "%04X", $0) }
        productID = device.productID.map { String(format: "%04X", $0) }
        if RazerDeviceProfile.deathAdderV3HyperSpeed.matches(device) {
            classification = "razerMouse"
            identificationReasons = ["exact1532:00C5PhysicalMouseProfile"]
            batterySupport = "candidate"
        } else if LogitechReceiverDriver.identify(device) != nil {
            classification = "receiverCandidate"
            identificationReasons = ["descriptorConfirmedControlEndpoint", "receiverOrDirectPeripheralPendingProtocolHandshake"]
            batterySupport = "unknown"
        } else if GenericKeyboardDriver.supports(device) {
            classification = "externalUSBKeyboard"
            identificationReasons = ["externalUSBPhysicalDevice", "keyboardUsage", "identificationOnly"]
            batterySupport = "unsupported"
        } else if let identified = DeviceIdentifier.identify(device) {
            classification = identified.isReceiver ? "receiverCandidate" : "cataloguedDevice"
            identificationReasons = identified.catalogMatch == nil ? ["descriptorConfirmedControlEndpoint", "protocolIdentityNotYetQueried"] : ["staticCatalogIdentity", "catalogueDoesNotAuthorizeReports"]
            batterySupport = identified.capabilities.battery == .unsupported ? "unsupported" : "candidate"
        } else {
            classification = "excluded"
            var reasons: [String] = []
            if !device.interfaces.allSatisfy({ $0.transport?.caseInsensitiveCompare("USB") == .orderedSame }) { reasons.append("notUSB") }
            if device.interfaces.contains(where: \.isBuiltIn) { reasons.append("builtInOrInternal") }
            if device.interfaces.contains(where: { !$0.hasPhysicalUSBParent }) { reasons.append("noPhysicalUSBParent") }
            if reasons.isEmpty { reasons.append("noSupportedPhysicalDeviceProfile") }
            identificationReasons = reasons
            batterySupport = "unsupported"
        }
        groupingBasis = device.id.rawValue.hasPrefix("usb-parent:") ? "nearestUSBPhysicalParentRegistryEntryID" : (device.id.rawValue.hasPrefix("usb-path:") ? "nearestUSBPhysicalParentPath" : "isolatedInterfaceNoUSBParent")
        controlInterfaceSelection = ProbeInterfaceSelection(InterfaceSelector.razerControlInterface(in: device))
        interfaces = device.interfaces.map { ProbeInterface($0, evidence: evidence[$0.registryEntryID]) }
    }
}

private struct ProbeReport: Encodable {
    let schemaVersion = 1
    let command: String
    let event: String
    let capturedAt: Date
    let passive: Bool
    let reportsSent = false
    let inputSubscribed = false
    let registryIDsAreSessionOnly = true
    let changedInterfaceRegistryEntryID: UInt64?
    let devices: [ProbeDevice]
    let excludedDevices: [ProbeDevice]
    let inspection: HIDInspectionResult?
    let inspectionSucceeded: Bool?
    let error: String?

    init(command: String, event: String = "snapshot", snapshot: HIDDiscoverySnapshot, changedID: UInt64? = nil, inspection: HIDInspectionResult? = nil, error: String? = nil) {
        self.command = command
        self.event = event
        capturedAt = snapshot.capturedAt
        passive = command != "inspect"
        changedInterfaceRegistryEntryID = changedID
        let evidence = Dictionary(uniqueKeysWithValues: snapshot.registryEvidence.map { ($0.interfaceRegistryEntryID, $0) })
        let all = snapshot.devices.map { ProbeDevice($0, evidence: evidence) }
        devices = all.filter(\.isIdentified)
        excludedDevices = all.filter { !$0.isIdentified }
        self.inspection = inspection
        inspectionSucceeded = inspection?.succeeded
        self.error = error
    }
}

@main
private struct HIDProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
            print(ProbeOptions.usage)
            return
        }
        let options: ProbeOptions
        do { options = try ProbeOptions.parse(arguments) }
        catch { writeError(String(describing: error), json: arguments.contains("--json")); exit(2) }
        let discovery = HIDDiscovery()
        var lastSnapshot: HIDDiscoverySnapshot?
        do {
            switch options.command {
            case .capabilities, .settings, .logitech, .profiles, .telemetry:
                if !(try await ExpansionProbe.run(try requireExpansion(options), discovery: discovery)) {
                    await discovery.stop()
                    exit(1)
                }
            case .list:
                let snapshot = try await discovery.snapshot()
                lastSnapshot = snapshot
                try output(ProbeReport(command: "list", snapshot: snapshot), options: options)
            case .inspect:
                let snapshot = try await discovery.snapshot()
                lastSnapshot = snapshot
                let target = try ProbeTargetSelector.select(in: snapshot.devices, vendorID: options.vendorID!, productID: options.productID!, sessionSelector: options.sessionSelector)
                let result = try await discovery.inspectControlInterface(registryEntryID: target.interface.registryEntryID)
                try output(ProbeReport(command: "inspect", snapshot: snapshot, inspection: result), options: options)
                await discovery.stop()
                if !result.succeeded { exit(1) }
                return
            case .watch:
                let stream = try await discovery.events()
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(options.duration)) }
                    catch { return }
                    await discovery.stop()
                }
                for await event in stream {
                    lastSnapshot = event.snapshot
                    try output(ProbeReport(command: "watch", event: event.kind.rawValue, snapshot: event.snapshot, changedID: event.interfaceRegistryEntryID), options: options)
                }
                timer.cancel()
            case .battery:
                let snapshot = try await discovery.snapshot()
                lastSnapshot = snapshot
                let target = try ProbeTargetSelector.select(in: snapshot.devices, vendorID: options.vendorID!, productID: options.productID!, sessionSelector: options.sessionSelector)
                let driver = RazerBatteryDriver(transport: discovery)
                var results: [DeviceTelemetryResult] = []
                for index in 0..<options.samples {
                    if index > 0 { try await Task.sleep(for: .seconds(options.interval)) }
                    results.append(await driver.read(device: target.device))
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let report = BatteryProbeReport(device: target.device, results: results)
                if options.json { FileHandle.standardOutput.write(try encoder.encode(report) + Data([0x0A])) }
                else {
                    for result in results {
                        print("battery \(result.battery.map { $0.percent.map { "\($0)%" } ?? "--" } ?? "--") | charging \(result.charging?.state.rawValue ?? "unknown") | \(result.batteryFailure?.message ?? "validated")")
                    }
                }
                await discovery.stop()
                if results.contains(where: { $0.battery == nil || $0.charging == nil || $0.diagnostics?.operations.contains(where: { $0.rawIOReturn != 0 }) == true }) { exit(1) }
                return
            }
            await discovery.stop()
        } catch {
            await discovery.stop()
            if let snapshot = lastSnapshot {
                try? output(ProbeReport(command: options.command.rawValue, event: "error", snapshot: snapshot, error: String(describing: error)), options: options)
            } else { writeError(String(describing: error), json: options.json) }
            exit(1)
        }
    }

    private static func requireExpansion(_ options: ProbeOptions) throws -> ExpansionProbeOptions {
        guard let expansion = options.expansion else { throw ProbeCLIError.arguments(ProbeOptions.usage) }
        return expansion
    }

    private static func output(_ report: ProbeReport, options: ProbeOptions) throws {
        if options.json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = options.command == .watch ? [.sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(report)
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
            return
        }
        print("\(report.event): \(report.devices.count) identified physical device(s), \(report.excludedDevices.count) excluded group(s)")
        for device in report.devices {
            print("\(device.vendorID ?? "----"):\(device.productID ?? "----") \(device.product) [\(device.classification)]")
            print("  --device \(device.sessionSelector) | \(device.interfaces.count) interface(s) | \(device.groupingBasis)")
            if let selected = device.controlInterfaceSelection.selectedRegistryEntryID { print("  control interface \(selected): Feature 90 bytes, report ID 0") }
            for rejection in device.controlInterfaceSelection.rejections {
                print("  rejected \(rejection.registryEntryID): \(rejection.reasons.map(\.rawValue).joined(separator: ", "))")
            }
        }
        for operation in report.inspection?.operations ?? [] { print("\(operation.phase) \(operation.registryEntryID): \(operation.rawIOReturn) \(operation.ioReturnHex) \(operation.message)") }
        if let error = report.error { print("error: \(error)") }
    }

    private static func writeError(_ message: String, json: Bool) {
        if json, let data = try? JSONEncoder().encode(["error": message]) {
            FileHandle.standardOutput.write(data + Data([0x0A]))
        } else { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    }
}

private struct BatteryProbeReport: Encodable {
    let schemaVersion = 1
    let command = "battery"
    let synthetic = false
    let reportID = 0
    let frameLength = 90
    let transactionID = "1F"
    let allowedCommands = ["07/80", "07/84"]
    let inputSubscribed = false
    let configurationCommandsSent = false
    let queryMode = "synchronousDedicatedHIDThread"
    let reportsSent: Bool
    let hostPresence = "presentAtSelection"
    let peerPresence = "unknown"
    let note = "Receiver response does not prove peripheral awake/online. Synchronous calls cannot be forcibly interrupted; late results are discarded. No configuration writes or input subscriptions."
    let device: PhysicalDeviceDescriptor
    let results: [DeviceTelemetryResult]

    init(device: PhysicalDeviceDescriptor, results: [DeviceTelemetryResult]) {
        self.device = device
        self.results = results
        reportsSent = results.contains { result in
            result.diagnostics?.commands.contains { $0.attempts.contains { $0.operations.contains { $0.phase == "setFeature" } } } == true
        }
    }
}
