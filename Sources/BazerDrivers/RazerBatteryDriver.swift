// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import Foundation
import RazerProtocol

public struct DeviceTelemetryResult: Equatable, Codable, Sendable {
    public let physicalDeviceID: PhysicalDeviceID
    public let endpointRegistryEntryID: UInt64?
    public let startedAt: Date
    public let finishedAt: Date
    public let battery: BatterySample?
    public let batteryFailure: TelemetryFailure?
    public let charging: ChargingSample?
    public let chargingFailure: TelemetryFailure?
    public let diagnostics: HIDFeatureGroupResult?

    public init(physicalDeviceID: PhysicalDeviceID, endpointRegistryEntryID: UInt64?, startedAt: Date, finishedAt: Date, battery: BatterySample?, batteryFailure: TelemetryFailure?, charging: ChargingSample?, chargingFailure: TelemetryFailure?, diagnostics: HIDFeatureGroupResult? = nil) {
        self.physicalDeviceID = physicalDeviceID; self.endpointRegistryEntryID = endpointRegistryEntryID
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.battery = battery; self.batteryFailure = batteryFailure
        self.charging = charging; self.chargingFailure = chargingFailure; self.diagnostics = diagnostics
    }
}

public protocol DeviceTelemetryReading: Sendable {
    func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult
}

public struct RazerBatteryDriver: DeviceTelemetryReading, Sendable {
    private let transport: any HIDFeatureGroupTransport
    public init(transport: any HIDFeatureGroupTransport) { self.transport = transport }

    public func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult {
        let startedAt = Date()
        let selection = InterfaceSelector.razerControlInterface(in: device)
        guard let endpoint = selection.selected else {
            let failure = TelemetryFailure(category: .unsupported, message: "No unique authorized 1532:00C5 control endpoint (\(selection.issue?.rawValue ?? "unmatched")).", operation: "selectEndpoint")
            return DeviceTelemetryResult(physicalDeviceID: device.id, endpointRegistryEntryID: nil, startedAt: startedAt, finishedAt: Date(), battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure)
        }
        do {
            let requests = [RazerCommand.battery, .charging].map { HIDReadOnlyFeatureRequest(reportID: 0, bytes: RazerRequest(command: $0).bytes) }
            let group = HIDFeatureQueryGroup(physicalDeviceID: device.id, registryEntryID: endpoint.registryEntryID, requests: requests)
            let result = try await transport.queryGroup(group, validate: Self.validate)
            var battery: BatterySample?
            var charging: ChargingSample?
            let batteryResult = result.commands.first { $0.commandID == RazerCommand.battery.rawValue }
            let chargingResult = result.commands.first { $0.commandID == RazerCommand.charging.rawValue }
            var batteryFailure = batteryResult?.failure
            var chargingFailure = chargingResult?.failure
            if let bytes = batteryResult?.response, let receivedAt = batteryResult?.receivedAt {
                do {
                    let response = try RazerResponse.parse(bytes, for: RazerRequest(command: .battery))
                    battery = BatterySample(rawValue: response.rawValue, receivedAt: receivedAt, source: "razerFeature07/80")
                } catch { batteryFailure = Self.protocolFailure(error, endpoint: endpoint.registryEntryID) }
            }
            if let bytes = chargingResult?.response, let receivedAt = chargingResult?.receivedAt {
                do {
                    let response = try RazerResponse.parse(bytes, for: RazerRequest(command: .charging))
                    let state: ChargingState = switch response.charging!.state {
                    case .charging: .charging
                    case .notCharging: .notCharging
                    case .unknown: .unknown
                    }
                    charging = ChargingSample(state: state, rawValue: response.rawValue, receivedAt: receivedAt, source: "razerFeature07/84")
                } catch { chargingFailure = Self.protocolFailure(error, endpoint: endpoint.registryEntryID) }
            }
            if battery == nil && batteryFailure == nil { batteryFailure = TelemetryFailure(category: .transport, message: "No battery result was returned.") }
            if charging == nil && chargingFailure == nil { chargingFailure = TelemetryFailure(category: .transport, message: "No charging result was returned.") }
            return DeviceTelemetryResult(physicalDeviceID: device.id, endpointRegistryEntryID: endpoint.registryEntryID, startedAt: startedAt, finishedAt: result.finishedAt, battery: battery, batteryFailure: batteryFailure, charging: charging, chargingFailure: chargingFailure, diagnostics: result)
        } catch {
            let failure: TelemetryFailure
            if let error = error as? TelemetryFailure { failure = error }
            else if error is CancellationError { failure = TelemetryFailure(category: .cancelled, message: "Query cancelled before a synchronous report call started.") }
            else if case HIDDiscoveryError.missingInterface = error { failure = TelemetryFailure(category: .removed, message: String(describing: error)) }
            else { failure = TelemetryFailure(category: .transport, message: String(describing: error)) }
            return DeviceTelemetryResult(physicalDeviceID: device.id, endpointRegistryEntryID: endpoint.registryEntryID, startedAt: startedAt, finishedAt: Date(), battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure)
        }
    }

    private static func protocolFailure(_ error: any Error, endpoint: UInt64) -> TelemetryFailure {
        TelemetryFailure(category: .malformedResponse, message: String(describing: error), operation: "validate", endpointRegistryEntryID: endpoint)
    }

    /// Every check is recorded, while the shared strict parser decides acceptance.
    public static func validate(_ request: HIDReadOnlyFeatureRequest, _ bytes: [UInt8]) -> HIDReportValidation {
        var checks: [HIDReportValidationCheck] = []
        func check(_ name: String, _ expected: String, _ actual: String, _ passed: Bool) {
            checks.append(HIDReportValidationCheck(name: name, expected: expected, actual: actual, passed: passed))
        }
        check("length", "90", "\(bytes.count)", bytes.count == 90)
        if bytes.count == 90 {
            check("remainingPackets", "0000", String(format: "%02X%02X", bytes[2], bytes[3]), bytes[2] == 0 && bytes[3] == 0)
            check("protocolType", "00", String(format: "%02X", bytes[4]), bytes[4] == 0)
            check("payloadLength", "2", "\(bytes[5])", bytes[5] == 2)
            check("commandClass", "07", String(format: "%02X", bytes[6]), bytes[6] == 7)
            check("command", String(format: "%02X", request.commandID ?? 0), String(format: "%02X", bytes[7]), bytes[7] == request.commandID)
            check("transaction", "1F", String(format: "%02X", bytes[1]), bytes[1] == 0x1F)
            check("reserved", "00", String(format: "%02X", bytes[89]), bytes[89] == 0)
            let checksum = bytes[2...87].reduce(UInt8(0), ^)
            check("xor2Through87", String(format: "%02X", checksum), String(format: "%02X", bytes[88]), bytes[88] == checksum)
            check("status", "02", String(format: "%02X", bytes[0]), bytes[0] == 2)
        }
        guard let commandID = request.commandID, let command = RazerCommand(rawValue: commandID) else {
            return HIDReportValidation(valid: false, retryable: false, error: "Unsupported query command", checks: checks)
        }
        do {
            _ = try RazerResponse.parse(bytes, for: RazerRequest(command: command))
            return HIDReportValidation(valid: true, retryable: false, error: nil, checks: checks)
        } catch RazerProtocolError.busy {
            return HIDReportValidation(valid: false, retryable: true, error: "Device is busy (protocol status 0x01).", checks: checks, failureCategory: .busy, protocolStatus: 1)
        } catch RazerProtocolError.deviceStatus(let status) {
            return HIDReportValidation(valid: false, retryable: true, error: String(format: "Device returned failure status 0x%02X; peripheral state is unknown.", status), checks: checks, failureCategory: .deviceStatus, protocolStatus: status)
        } catch {
            return HIDReportValidation(valid: false, retryable: true, error: String(describing: error), checks: checks)
        }
    }
}
