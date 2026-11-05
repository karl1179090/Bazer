// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerDrivers
import Foundation
import LogitechHIDPP

/// An attempt contains only its returned update, never the monitor's retained cache.
/// Session values are deliberately not Encodable members: they contain private units.
struct TelemetryProbeSample: Encodable {
    let sequence: Int
    let startedAt: Date
    let finishedAt: Date
    let battery: BatterySample?
    let batteryFailure: TelemetryFailure?
    let charging: ChargingSample?
    let chargingFailure: TelemetryFailure?

    init(sequence: Int, update: DeviceTelemetryUpdate) {
        self.sequence = sequence; startedAt = update.startedAt; finishedAt = update.finishedAt
        battery = update.battery; batteryFailure = update.batteryFailure
        charging = update.charging; chargingFailure = update.chargingFailure
    }

    var succeeded: Bool { battery != nil && charging != nil && batteryFailure == nil && chargingFailure == nil }
}

struct TelemetryProbeReport: Encodable {
    let schemaVersion = 1
    let command = "telemetry"
    let source = "explicit current Logitech logical target reads"
    let automaticTelemetryRefresh = false
    let configurationCommandsSent = false
    let target: LogicalProbeDevice
    let requestedSamples: Int
    let intervalSeconds: Double
    let intervalMeaning = "delay after a sample completes, before the next attempt"
    let samples: [TelemetryProbeSample]
    let termination: TelemetryFailure?
    let controlTrace: HIDPPControlTraceSnapshot?
    let controlTraceFailure: TelemetryFailure?
    let controlTraceScope: String?

    var succeeded: Bool {
        termination == nil && controlTraceFailure == nil && samples.count == requestedSamples && samples.allSatisfy(\.succeeded)
    }
}

enum TelemetryProbe {
    static func capture(options: ExpansionProbeOptions, target: LogicalDeviceState, initialSnapshot: DeviceStoreSnapshot,
                        monitor: BatteryMonitor, driver: any DeviceLogicalDriver, identityReceivedAt: Date? = nil,
                        trace: (@Sendable () async throws -> HIDPPControlTraceSnapshot)? = nil,
                        sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> TelemetryProbeReport {
        let changed = TelemetryFailure(category: .removed,
            message: "The selected logical session changed; sampling stopped without following its slot or replacement.", operation: "telemetrySession")
        var samples: [TelemetryProbeSample] = [], termination: TelemetryFailure?
        for index in 0..<options.samples {
            try Task.checkCancellation()
            if index > 0 { try await sleep(options.interval) }
            guard await isCurrent(target, monitor: monitor) else { termination = changed; break }
            let result = await driver.readTelemetry(target: target.descriptor, session: target.sessionID)
            try Task.checkCancellation()
            guard result.session == target.sessionID, await isCurrent(target, monitor: monitor) else {
                // Keep the actual attempt times, but reject data from an invalidated session.
                samples.append(TelemetryProbeSample(sequence: index + 1, update: DeviceTelemetryUpdate(
                    startedAt: result.update.startedAt, finishedAt: result.update.finishedAt,
                    battery: nil, batteryFailure: changed, charging: nil, chargingFailure: changed)))
                termination = changed; break
            }
            samples.append(TelemetryProbeSample(sequence: index + 1, update: result.update))
        }
        var capturedTrace: HIDPPControlTraceSnapshot?, traceFailure: TelemetryFailure?
        if options.trace {
            if let trace {
                do { capturedTrace = try await trace() }
                catch { traceFailure = (error as? TelemetryFailure) ?? TelemetryFailure(category: .transport,
                    message: "The final bounded control trace is unavailable: \(error)", operation: "telemetryTrace") }
            } else { traceFailure = TelemetryFailure(category: .unsupported, message: "This logical driver has no control trace capture.", operation: "telemetryTrace") }
        }
        return TelemetryProbeReport(target: LogicalProbeDevice(target, hosts: initialSnapshot.devices,
            capturedAt: initialSnapshot.capturedAt, identityReceivedAt: identityReceivedAt), requestedSamples: options.samples,
            intervalSeconds: options.interval, samples: samples, termination: termination, controlTrace: capturedTrace,
            controlTraceFailure: traceFailure, controlTraceScope: options.trace ? "Final host session snapshot; includes initial discovery and selected-target reads. Capacity 128; inspect droppedCount/truncated. Sample sequence and actual timestamps identify attempts. No movement/key input is recorded." : nil)
    }

    private static func isCurrent(_ target: LogicalDeviceState, monitor: BatteryMonitor) async -> Bool {
        let snapshot = await monitor.snapshot()
        return snapshot.isMonitoring && !snapshot.isSuspended && snapshot.logicalDevices.contains {
            $0.id == target.id && $0.hostPresence == .present && $0.sessionID == target.sessionID
        }
    }
}
