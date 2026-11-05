// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@preconcurrency import IOBluetooth
import CoreBluetooth
import Darwin
import notify
import BazerCore

public actor SystemBluetoothAudioBackend: BluetoothAudioBackend {
    private var events: BluetoothAudioNativeEvents?
    private let allowProfilerFallback: Bool
    private let verifiedAccessoryKeys: Set<String>
    private let identityRegistry: BluetoothAudioIdentityEvidenceRegistry?
    private var discoveryTask: Task<BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>, Never>?
    private var powerTask: Task<BluetoothAudioReadResult<BluetoothAudioPowerRecord>, Never>?
    private var discoveryRun: UUID?
    private var powerRun: UUID?
    private let discoveryOperation: (@Sendable () async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>)?
    private let powerOperation: (@Sendable () async -> BluetoothAudioReadResult<BluetoothAudioPowerRecord>)?
    public init(allowProfilerFallback: Bool = true, verifiedAccessoryKeys: Set<String> = [],
                identityRegistry: BluetoothAudioIdentityEvidenceRegistry? = BluetoothAudioIdentityEvidenceRegistry(),
                discoveryOperation: (@Sendable () async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>)? = nil,
                powerOperation: (@Sendable () async -> BluetoothAudioReadResult<BluetoothAudioPowerRecord>)? = nil) {
        self.allowProfilerFallback = allowProfilerFallback; self.verifiedAccessoryKeys = verifiedAccessoryKeys; self.identityRegistry = identityRegistry
        self.discoveryOperation = discoveryOperation; self.powerOperation = powerOperation
    }

    public func discover() async -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        if let discoveryTask {
            let run = discoveryRun, result = await discoveryTask.value
            if discoveryRun == run { self.discoveryTask = nil; discoveryRun = nil }
            return result
        }
        let run = UUID(), fallbackAllowed = allowProfilerFallback, operation = discoveryOperation
        discoveryRun = run
        let task = Task.detached(priority: .utility) {
            if let operation { return await operation() }
            let started = Date()
            let native = Self.nativeDiscovery()
            guard native.status != .success, fallbackAllowed, !Task.isCancelled else {
                return .init(records: native.records, status: native.status, message: native.message, startedAt: started)
            }
            let fallback = await BluetoothAudioProfiler.read()
            // A profiler report is always partial: exit 0 does not prove exhaustiveness.
            let result = fallback.records.isEmpty ? native : fallback
            return .init(records: result.records, status: result.status, message: result.message, startedAt: started)
        }
        discoveryTask = task
        let result = await task.value
        if discoveryRun == run { discoveryTask = nil; discoveryRun = nil }
        return result
    }
    public func readPower() async -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> {
        if let powerTask {
            let run = powerRun, result = await powerTask.value
            if powerRun == run { self.powerTask = nil; powerRun = nil }
            return result
        }
        let run = UUID(), verified = verifiedAccessoryKeys.union(identityRegistry?.loadVerifiedKeys() ?? []), operation = powerOperation
        powerRun = run
        let task = Task.detached(priority: .utility) {
            if let operation { return await operation() }
            let started = Date(), result = AccessoryPowerSourceReader(verifiedAccessoryKeys: verified).read()
            return .init(records: result.records, status: result.status, message: result.message, startedAt: started)
        }
        powerTask = task
        let result = await task.value
        if powerRun == run { powerTask = nil; powerRun = nil }
        return result
    }
    public func startEvents(_ onChange: @escaping @Sendable () -> Void) async {
        guard discoveryOperation == nil && powerOperation == nil else { return }
        if let events { await events.stop() }
        events = await BluetoothAudioNativeEvents(onChange: onChange)
        await events?.start()
    }
    public func stop() async {
        discoveryTask?.cancel(); powerTask?.cancel()
        // Keep in-flight slots until synchronous native calls actually return. Resume must
        // never spawn another native reader while an uncooperative OS call is still alive.
        if let events { await events.stop() }; events = nil
    }

    private nonisolated static func nativeDiscovery() -> BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord> {
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            return .init(status: .unavailable, message: "蓝牙访问未获授权；键鼠读取不受影响")
        }
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return .init(status: .failed, message: "无法读取已配对蓝牙设备")
        }
        var result: [BluetoothAudioDiscoveryRecord] = []
        for device in paired {
            guard device.deviceClassMajor == 4, [1, 2, 6].contains(Int(device.deviceClassMinor)),
                  let address = device.addressString, let name = device.name, !name.isEmpty else { continue }
            // Includes explicit disconnected evidence only for already paired audio devices.
            // No inquiry, remote name request, SDP query, connection, pairing or audio routing.
            result.append(.init(key: BluetoothAudioOpaqueIdentity.discoveryKey(address: address),
                                name: name, isConnected: device.isConnected()))
        }
        return .init(records: result, status: .success)
    }
}

@MainActor private final class BluetoothAudioNativeEvents: NSObject {
    private let onChange: @Sendable () -> Void
    private var connect: IOBluetoothUserNotification?
    private var disconnects: [ObjectIdentifier: IOBluetoothUserNotification] = [:]
    private var observers: [NSObjectProtocol] = []
    private var powerTokens: [Int32] = []
    private var active = false
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func start() {
        active = true
        connect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(changed(_:device:)))
        // SDK-documented device notifications cover existing connections too. Enumeration is
        // confined to the single-flight background discovery, never repeated on the UI thread.
        for name in ["IOBluetoothDeviceConnected", "IOBluetoothDeviceDisconnected", "IOBluetoothDeviceNameChanged", "IOBluetoothDeviceServicesChanged"] {
            observers.append(NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) { [onChange] _ in onChange() })
        }
        for name in ["com.apple.system.accpowersources.attach", "com.apple.system.accpowersources.timeremaining", "com.apple.system.accpowersources.source"] {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { [onChange] _ in onChange() }
            if status == NOTIFY_STATUS_OK { powerTokens.append(token) }
        }
    }
    func stop() {
        active = false
        connect?.unregister(); connect = nil
        disconnects.values.forEach { $0.unregister() }; disconnects.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        powerTokens.forEach { notify_cancel($0) }; powerTokens.removeAll()
    }
    @objc private func changed(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard active else { return }
        let key = ObjectIdentifier(device)
        if device.isConnected(), disconnects[key] == nil {
            disconnects[key] = device.register(forDisconnectNotification: self, selector: #selector(changed(_:device:)))
        } else if !device.isConnected() { disconnects.removeValue(forKey: key)?.unregister() }
        onChange()
    }
}
