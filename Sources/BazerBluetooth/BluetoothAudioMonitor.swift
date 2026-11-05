// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import BazerCore

public actor BluetoothAudioMonitor {
    private let backend: any BluetoothAudioBackend
    private let clock: @Sendable () -> Date
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval
    private var epoch: UInt64 = 0
    private var requestID: UInt64 = 0
    private var generation: UInt64 = 0
    private var lifecycleRevision: UInt64 = 0
    private var eventRevision: UInt64 = 0
    private var active = true
    private var pending = false
    private var worker: Task<BluetoothAudioSnapshot, Never>?
    private var poller: Task<Void, Never>?
    private var onUpdate: (@Sendable (BluetoothAudioSnapshot) async -> Void)?
    private var state = BluetoothAudioSnapshot()
    private var devices: [BluetoothAudioDeviceID: BluetoothAudioDevice] = [:]
    private var order: [BluetoothAudioDeviceID] = []
    private var mappings: [String: BluetoothAudioDeviceID] = [:]
    private struct Sources {
        var discovery: Set<String> = []
        var power: Set<String> = []
        var nameDiscovery: Set<String> = []
        var associationName: String?
    }
    private var sourceKeys: [BluetoothAudioDeviceID: Sources] = [:]
    private var blockedPower: [String: Set<String>] = [:]
    /// Presentation-only suppression after a revoked correlation. It cannot affect connection,
    /// identity, battery or tombstones, and ends with the accessory power-source session.
    private var suppressedDiscovery: [String: Set<String>] = [:]

    public init(backend: any BluetoothAudioBackend = SystemBluetoothAudioBackend(),
                clock: @escaping @Sendable () -> Date = Date.init, pollInterval: TimeInterval = 60, timeout: TimeInterval = 15) {
        self.backend = backend; self.clock = clock; self.pollInterval = max(0.01, pollInterval); self.timeout = max(0.01, timeout)
    }
    public func snapshot() -> BluetoothAudioSnapshot { state }
    public func start(onUpdate: @escaping @Sendable (BluetoothAudioSnapshot) async -> Void) async {
        self.onUpdate = onUpdate; active = true
        await backend.startEvents { [weak self] in Task { await self?.sourceChanged() } }
        startPolling()
        _ = await refresh()
    }
    @discardableResult public func refresh() async -> BluetoothAudioSnapshot {
        guard active else { return state }
        if let worker { pending = true; return await worker.value }
        let lifecycle = lifecycleRevision
        let task = Task { await self.drain(lifecycle: lifecycle) }
        worker = task
        return await task.value
    }
    public func suspend() async {
        active = false; invalidate(); poller?.cancel(); poller = nil
        await backend.stop()
        for id in order where devices[id]?.connection != .disconnected {
            devices[id]?.connection = .uncertain; devices[id]?.readStatus = .unavailable
            devices[id]?.statusMessage = "系统休眠，连接状态待确认"
        }
        await publish(startedAt: clock(), discovery: .unavailable, power: .unavailable, message: "系统休眠")
    }
    public func resume() async {
        active = true; invalidate()
        // A wake starts new connection generations; pre-sleep results can never qualify.
        for id in order where devices[id]?.connection != .disconnected {
            generation &+= 1; devices[id]?.session = .init(generation: generation)
            devices[id]?.batteryReadings = []
        }
        await backend.startEvents { [weak self] in Task { await self?.sourceChanged() } }
        startPolling(); _ = await refresh()
    }
    public func stop() async {
        active = false; invalidate(); poller?.cancel(); poller = nil; onUpdate = nil
        await backend.stop()
    }
    private func invalidate() { lifecycleRevision &+= 1; epoch &+= 1; pending = false; worker?.cancel(); worker = nil }
    private func sourceChanged() async {
        guard active else { return }
        // Reject the current cycle immediately, but retain its single worker. A burst only
        // asks that worker for one supplemental pass; events do not spawn parallel readers.
        eventRevision &+= 1; pending = true
        let joinedExistingWorker = worker != nil
        for id in order where devices[id]?.connection != .disconnected {
            devices[id]?.connection = .uncertain; devices[id]?.readStatus = .unavailable
            devices[id]?.batteryReadings = []; devices[id]?.statusMessage = "系统状态正在重新确认"
        }
        await publish(startedAt: clock(), discovery: .partial, power: .unavailable, message: "系统事件已到达，等待本轮重新确认")
        if !joinedExistingWorker && worker == nil { _ = await refresh() }
    }
    private func startPolling() {
        poller?.cancel()
        let interval = pollInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                _ = await self.refresh()
            }
        }
    }
    private func drain(lifecycle: UInt64) async -> BluetoothAudioSnapshot {
        for _ in 0...1 {
            pending = false
            await readCycle(lifecycle: lifecycle)
            if !pending || !active || lifecycleRevision != lifecycle || Task.isCancelled { break }
        }
        if lifecycleRevision == lifecycle { worker = nil }
        return state
    }
    private func readCycle(lifecycle: UInt64) async {
        requestID &+= 1
        let request = requestID, revision = eventRevision, started = clock(), backend = backend, timeout = timeout
        async let discovery = boundedBluetoothRead(seconds: timeout,
            fallback: BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>(status: .failed, message: "蓝牙发现超时或已取消")) { await backend.discover() }
        async let power = boundedBluetoothRead(seconds: timeout,
            fallback: BluetoothAudioReadResult<BluetoothAudioPowerRecord>(status: .failed, message: "系统电量读取超时或已取消")) { await backend.readPower() }
        let (rawDiscovery, rawPower) = await (discovery, power)
        guard active, lifecycleRevision == lifecycle, requestID == request, !Task.isCancelled else { return }
        guard eventRevision == revision else { pending = true; return }
        // A newly awakened epoch may join a non-cancellable OS call that started before
        // sleep. Reject that underlying observation too, not merely its old waiter task.
        let oldDiscovery = rawDiscovery.startedAt.map { $0 < started } ?? false
        let oldPower = (rawPower.startedAt.map { $0 < started } ?? false) || rawPower.records.contains { $0.observedAt < started }
        let d = oldDiscovery ? .init(status: .failed, message: "蓝牙发现属于较早请求，等待重新读取") : rawDiscovery
        let p = oldPower ? .init(status: .failed, message: "系统电量属于较早请求，等待重新读取") : rawPower
        if oldDiscovery || oldPower { pending = true }
        reconcile(discovery: d, power: p, at: clock())
        await publish(startedAt: started, discovery: d.status, power: p.status, message: [d.message, p.message].compactMap { $0 }.joined(separator: " · "))
    }
    private func reconcile(discovery: BluetoothAudioReadResult<BluetoothAudioDiscoveryRecord>,
                           power: BluetoothAudioReadResult<BluetoothAudioPowerRecord>, at date: Date) {
        let disconnectedKeys = Set(discovery.records.filter { !$0.isConnected }.map(\.key))
        let connectedKeys = Set(discovery.records.filter(\.isConnected).map(\.key))
        let absentPower = Set(power.records.filter { !$0.isPresent }.map(\.key))
        let presentPower = Set(power.records.filter(\.isPresent).map(\.key))
        let nativeNames = Dictionary(grouping: discovery.records.filter(\.isConnected), by: \.name)
        let powerNames = Dictionary(grouping: power.records.filter(\.isPresent), by: \.name)
        // Weak same-name aliases must be revalidated before they can retire a source. A
        // rename or collision removes the routing alias as well as its disconnect authority.
        for (id, original) in sourceKeys where !original.nameDiscovery.isEmpty {
            guard let name = original.associationName else { continue }
            let nativeRename = discovery.records.contains { original.nameDiscovery.contains($0.key) && $0.name != name }
            let powerRename = power.records.contains { original.power.contains($0.key) && $0.name != name }
            let powerGroups = Set((powerNames[name] ?? []).map { $0.groupKey.map { "group:" + $0 } ?? "power:" + $0.key })
            let collision = (nativeNames[name]?.count ?? 0) > 1 || powerGroups.count > 1
            if nativeRename || powerRename || collision {
                var revised = original
                revised.discovery.subtract(original.nameDiscovery)
                revised.nameDiscovery = []; revised.associationName = nil
                sourceKeys[id] = revised
                for key in original.nameDiscovery {
                    if mappings["d:" + key] == id { mappings.removeValue(forKey: "d:" + key) }
                    if !original.power.isDisjoint(with: presentPower) { suppressedDiscovery[key] = original.power }
                }
            }
        }
        if power.status == .success { suppressedDiscovery = suppressedDiscovery.filter { !$0.value.isDisjoint(with: presentPower) } }
        // Keep a session tombstone for stale present=true reports after an explicit native
        // disconnect. A successful fresh native reconnect, rather than a power cache, releases it.
        for (_, sources) in sourceKeys where !sources.discovery.isDisjoint(with: disconnectedKeys) {
            for key in sources.power { blockedPower[key] = sources.discovery }
        }
        blockedPower = blockedPower.filter { $0.value.isDisjoint(with: connectedKeys) }
        let effectivePower = power.records.filter { blockedPower[$0.key] == nil }
        let matches = BluetoothAudioMatcher.match(discovery: discovery.records, power: effectivePower,
                                                  suppressedDiscoveryKeys: Set(suppressedDiscovery.keys))
        var seen = Set<BluetoothAudioDeviceID>()
        for match in matches {
            let allKeys = [match.key] + match.discoveryKeys.map { "d:" + $0 } + match.powerKeys.map { "p:" + $0 }
            var existingID = allKeys.compactMap { mappings[$0] }.first
            if let preference = match.preferenceIdentity {
                existingID = order.first { devices[$0]?.preferenceIdentity == preference } ?? existingID
            }
            let id = existingID ?? BluetoothAudioDeviceID(rawValue: "audio-session:" + UUID().uuidString)
            // A source rename may leave the native cached name behind for one or more reads.
            // Its prior session alias must never overwrite the accessory card or its own ID.
            if seen.contains(id), match.power.isEmpty { continue }
            var device: BluetoothAudioDevice
            if var existing = devices[id] {
                if existing.connection == .disconnected || (existing.name != match.name && existing.identityQuality != .verified) {
                    generation &+= 1; existing.session = .init(generation: generation)
                    existing.batteryReadings = []; existing.lastReadings = []
                }
                device = existing
            } else {
                generation &+= 1
                device = .init(id: id, name: match.name, session: .init(generation: generation), lastSeenAt: date)
                order.append(id)
            }
            let components = match.power.map(\.component).filter { $0 != .unknown }
            let conflict = match.hasConflict || Set(components).count != components.count || (components.count > 1 && components.contains(.single))
            let priorSources = sourceKeys[id] ?? Sources()
            let nativeSaysDisconnected = !match.discoveryKeys.isDisjoint(with: disconnectedKeys) || !priorSources.discovery.isDisjoint(with: disconnectedKeys)
            let powerSaysAbsent = match.power.isEmpty && !priorSources.power.isDisjoint(with: absentPower)
            let disconnectedNames = discovery.records.filter { !$0.isConnected && $0.name == match.name }
            let initialContradiction = match.discoveryKeys.isEmpty && !match.power.isEmpty && disconnectedNames.count == 1
            device.name = match.name; device.identityQuality = match.quality; device.preferenceIdentity = match.preferenceIdentity
            device.connection = nativeSaysDisconnected ? .disconnected : powerSaysAbsent || initialContradiction ? .uncertain : .connected
            device.lastSeenAt = date; device.statusMessage = match.message
            device.readStatus = conflict ? .partial : power.status == .partial && !match.power.isEmpty ? .success : power.status
            if device.connection != .connected { device.readStatus = .unavailable; device.statusMessage = "系统连接与配件报告不一致，状态待确认" }
            let readings = match.power.map { item in BluetoothAudioBatteryReading(component: item.component, componentID: item.key, percent: item.percent,
                charging: item.charging, source: item.source, observedAt: item.observedAt, sourceUpdatedAt: item.sourceUpdatedAt,
                session: device.session, isPresent: item.isPresent) }
            if !readings.isEmpty && (power.status == .success || power.status == .partial) && !conflict && device.connection == .connected {
                // An event version describes content/session, not a repeated observation timestamp.
                let oldContent = device.lastReadings.filter { $0.session == device.session }
                    .map { "\($0.componentID):\($0.component):\($0.percent ?? -1):\($0.charging)" }.sorted()
                let newContent = readings.map { "\($0.componentID):\($0.component):\($0.percent ?? -1):\($0.charging)" }.sorted()
                if oldContent != newContent { device.eventVersion &+= 1 }
                device.batteryReadings = readings; device.lastReadings = readings
            } else { device.batteryReadings = [] }
            if power.status == .failed || power.status == .unavailable { device.statusMessage = power.message ?? "系统电量读取失败" }
            devices[id] = device; seen.insert(id)
            let retainedDiscovery = discovery.status != .success ? priorSources.discovery : []
            let nextDiscovery = match.discoveryKeys.union(retainedDiscovery)
            let retainedNames = priorSources.nameDiscovery.intersection(nextDiscovery)
            let nextNames = match.nameDiscoveryKeys.union(retainedNames)
            sourceKeys[id] = Sources(discovery: nextDiscovery,
                power: match.powerKeys.isEmpty ? priorSources.power : match.powerKeys,
                nameDiscovery: nextNames, associationName: nextNames.isEmpty ? nil : match.name)
            for key in priorSources.discovery.subtracting(nextDiscovery) where mappings["d:" + key] == id { mappings.removeValue(forKey: "d:" + key) }
            for key in allKeys { mappings[key] = id }
        }
        for id in order where !seen.contains(id) && devices[id]?.connection != .disconnected {
            let sources = sourceKeys[id] ?? Sources()
            let explicit = !sources.discovery.isDisjoint(with: disconnectedKeys) || !sources.power.isDisjoint(with: absentPower)
            if explicit || (discovery.status == .success && power.status == .success) {
                devices[id]?.connection = .disconnected; devices[id]?.statusMessage = "耳机已断开"
                devices[id]?.batteryReadings = []; devices[id]?.readStatus = .unavailable
                // Unverified identity cannot merge a new connection into this historical session.
                if devices[id]?.identityQuality != .verified { mappings = mappings.filter { $0.value != id } }
            } else {
                devices[id]?.connection = .uncertain; devices[id]?.readStatus = .failed
                devices[id]?.batteryReadings = []; devices[id]?.statusMessage = "连接状态待确认，系统读取未完成"
            }
        }
    }
    private func publish(startedAt: Date, discovery: BluetoothAudioReadStatus, power: BluetoothAudioReadStatus, message: String?) async {
        // Every publication gets a later epoch, so delayed application callbacks cannot
        // overwrite an event invalidation with a previously successful snapshot.
        epoch &+= 1
        state = .init(epoch: epoch, requestID: requestID, startedAt: startedAt, finishedAt: clock(),
                      devices: order.compactMap { devices[$0] }, discoveryStatus: discovery, powerStatus: power,
                      statusMessage: message?.isEmpty == false ? message : nil)
        await onUpdate?(state)
    }
}

private final class BluetoothReadRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var finished = false
    private var result: T?
    func set(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock(); let previous = result
        if !finished { self.continuation = continuation }; lock.unlock()
        if let previous { continuation.resume(returning: previous) }
    }
    func setTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock(); if !finished { self.tasks = tasks }; let done = finished; lock.unlock()
        if done { tasks.forEach { $0.cancel() } }
    }
    func finish(_ value: T) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true; result = value; let continuation = continuation; self.continuation = nil; let tasks = tasks; self.tasks = []; lock.unlock()
        tasks.forEach { $0.cancel() }; continuation?.resume(returning: value)
    }
}

private func boundedBluetoothRead<T: Sendable>(seconds: TimeInterval, fallback: T,
    operation: @escaping @Sendable () async -> T) async -> T {
    let race = BluetoothReadRace<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            race.set(continuation)
            let read = Task { race.finish(await operation()) }
            let timer = Task { do { try await Task.sleep(for: .seconds(seconds)); race.finish(fallback) } catch {} }
            race.setTasks([read, timer])
            if Task.isCancelled { race.finish(fallback) }
        }
    } onCancel: { race.finish(fallback) }
}
