// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import BazerCore
import BazerBluetooth

/// Opt-in, read-only probe. Its default output contains only source-namespaced hashes.
@main struct BluetoothAudioProbe {
    static func main() async {
        let backend = SystemBluetoothAudioBackend(allowProfilerFallback: CommandLine.arguments.contains("--fallback"))
        let started = Date()
        async let discovery = timed { CommandLine.arguments.contains("--power-only") ? .init(status: .unavailable) : await backend.discover() }
        async let power = timed { await backend.readPower() }
        let (d, p) = await (discovery, power)
        let report: [String: Any] = [
            "schema": 1, "observedAt": ISO8601DateFormatter().string(from: started),
            "elapsedMilliseconds": Date().timeIntervalSince(started) * 1000,
            "discoveryStatus": d.value.status.rawValue, "powerStatus": p.value.status.rawValue,
            "discoveryElapsedMilliseconds": d.milliseconds, "powerElapsedMilliseconds": p.milliseconds,
            "discovery": d.value.records.map { ["sourceKey": $0.key, "name": $0.name, "connected": $0.isConnected] as [String: Any] },
            "power": p.value.records.map { record in [
                "sourceKey": record.key, "groupKey": record.groupKey as Any? ?? NSNull(),
                "identityKey": record.identityKey, "identifierKind": record.identifierKind as Any? ?? NSNull(),
                "name": record.name, "component": record.component.rawValue,
                "percent": record.percent as Any? ?? NSNull(), "charging": record.charging.rawValue,
                "present": record.isPresent, "source": record.source,
                "sourceUpdatedAt": record.sourceUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                "verifiedPreferenceIdentity": record.verifiedPreferenceIdentity as Any? ?? NSNull()
            ] as [String: Any] },
            "identityConclusion": "Source keys are hashed observations. Reconnect, rename, app restart and duplicate-name isolation must be verified before persistent notification identity is enabled."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) { print(string) }
        await backend.stop()
    }
    private static func timed<T: Sendable>(_ operation: @Sendable () async -> T) async -> (value: T, milliseconds: Double) {
        let started = ProcessInfo.processInfo.systemUptime
        let result = await operation()
        return (result, (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
