// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct DeviceSessionID: Hashable, Codable, Sendable {
    public let physicalDeviceID: PhysicalDeviceID
    public let generation: UUID
    public init(physicalDeviceID: PhysicalDeviceID, generation: UUID = UUID()) {
        self.physicalDeviceID = physicalDeviceID; self.generation = generation
    }
}

public struct IdentifiedDevice: Equatable, Sendable {
    public let descriptor: PhysicalDeviceDescriptor
    public let kind: DeviceKind
    public let capabilities: DeviceCapabilities
    public let controlEndpointRegistryEntryID: UInt64?
    public let isReceiver: Bool
    public let catalogMatch: DeviceCatalogMatch?
    public init(descriptor: PhysicalDeviceDescriptor, kind: DeviceKind, capabilities: DeviceCapabilities, controlEndpointRegistryEntryID: UInt64? = nil, isReceiver: Bool = false, catalogMatch: DeviceCatalogMatch? = nil) {
        self.isReceiver = isReceiver; self.catalogMatch = catalogMatch
        self.descriptor = descriptor; self.kind = kind; self.capabilities = capabilities
        self.controlEndpointRegistryEntryID = controlEndpointRegistryEntryID
    }
}

public struct RefreshPolicy: Equatable, Sendable {
    public let regularInterval: TimeInterval
    public let maximumSampleAge: TimeInterval
    public let wakeDelay: TimeInterval
    public let discoveryCoalescingDelay: TimeInterval
    public init(regularInterval: TimeInterval = 60, maximumSampleAge: TimeInterval = 180, wakeDelay: TimeInterval = 2, discoveryCoalescingDelay: TimeInterval = 0.1) {
        precondition(regularInterval.isFinite && regularInterval > 0 && maximumSampleAge.isFinite && maximumSampleAge > 0)
        precondition(wakeDelay.isFinite && wakeDelay >= 0 && discoveryCoalescingDelay.isFinite && discoveryCoalescingDelay >= 0)
        self.regularInterval = regularInterval; self.maximumSampleAge = maximumSampleAge
        self.wakeDelay = wakeDelay; self.discoveryCoalescingDelay = discoveryCoalescingDelay
    }
    public func interval(afterConsecutiveFailures count: Int) -> TimeInterval {
        switch count { case ...1: regularInterval; case 2: regularInterval * 2; default: regularInterval * 5 }
    }
}

public struct DeviceState: Equatable, Sendable, Identifiable {
    public var id: PhysicalDeviceID { descriptor.id }
    public internal(set) var sessionID: DeviceSessionID
    public internal(set) var descriptor: PhysicalDeviceDescriptor
    public internal(set) var kind: DeviceKind
    public internal(set) var capabilities: DeviceCapabilities
    public internal(set) var catalogMatch: DeviceCatalogMatch? = nil
    public internal(set) var managesLogicalTargets = false
    public internal(set) var controlEndpointRegistryEntryID: UInt64?
    public internal(set) var hostPresence: HostPresence = .present
    public internal(set) var access: AccessState = .untested
    public let peerPresence: PeerPresence = .unknown
    public internal(set) var alias: String?
    public internal(set) var preferenceIdentity: DevicePreferenceIdentity?
    public internal(set) var battery: BatterySample?
    public internal(set) var charging: ChargingSample?
    public internal(set) var batteryFailure: TelemetryFailure?
    public internal(set) var chargingFailure: TelemetryFailure?
    public internal(set) var lastAttemptedAt: Date?
    public internal(set) var lastFinishedAt: Date?
    public internal(set) var consecutiveFailures = 0
    public internal(set) var nextRefreshAt: Date?
    public internal(set) var isRefreshing = false
    public var displayName: String { alias ?? catalogMatch?.entry.canonicalName ?? descriptor.product }
    /// Frozen UI history has no current telemetry or settings authority.
    public func historicalSnapshot() -> Self {
        var copy = self; copy.hostPresence = .removed; copy.isRefreshing = false; copy.nextRefreshAt = nil
        return copy
    }
    public var canRefresh: Bool { canRefreshTelemetry }
    public var canRefreshTelemetry: Bool { hostPresence == .present && controlEndpointRegistryEntryID != nil && (capabilities.battery != .unsupported || capabilities.chargingQuery || capabilities.permits(.voltageRead)) }
    public var canRefreshSettings: Bool { hostPresence == .present && controlEndpointRegistryEntryID != nil && capabilities.canReadSettings }
    public func currentBattery(at date: Date, maximumAge: TimeInterval = 180) -> BatterySample? {
        guard hostPresence == .present, batteryFailure == nil, let battery, !battery.isStale(at: date, maximumAge: maximumAge) else { return nil }
        return battery
    }
    public func currentCharging(at date: Date, maximumAge: TimeInterval = 180) -> ChargingState {
        guard hostPresence == .present, chargingFailure == nil, let charging,
              !charging.isStale(at: date, maximumAge: maximumAge) else { return .unknown }
        return charging.state
    }
}

public struct DeviceStoreSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let devices: [DeviceState]
    public let logicalDevices: [LogicalDeviceState]
    public let historicalDevices: [DeviceState]
    public let historicalLogicalDevices: [LogicalDeviceState]
    public let primaryDeviceID: PhysicalDeviceID?
    public let primaryLogicalDeviceID: LogicalDeviceID?
    public let isMonitoring: Bool
    public let isSuspended: Bool
    public let discoveryFailure: String?
    public let preferencesFailure: String?
    public let preferences: DevicePreferences
    public var primaryLogicalDevice: LogicalDeviceState? { logicalDevices.first { $0.id == primaryLogicalDeviceID } }
    public var primaryDevice: DeviceState? { devices.first { $0.id == primaryDeviceID } }
    public init(capturedAt: Date, devices: [DeviceState], primaryDeviceID: PhysicalDeviceID?, isMonitoring: Bool, isSuspended: Bool, discoveryFailure: String?, preferencesFailure: String?, logicalDevices: [LogicalDeviceState] = [], primaryLogicalDeviceID: LogicalDeviceID? = nil, preferences: DevicePreferences = DevicePreferences(), historicalDevices: [DeviceState] = [], historicalLogicalDevices: [LogicalDeviceState] = []) {
        self.historicalDevices = historicalDevices; self.historicalLogicalDevices = historicalLogicalDevices
        self.logicalDevices = logicalDevices; self.primaryLogicalDeviceID = primaryLogicalDeviceID
        self.capturedAt = capturedAt; self.devices = devices; self.primaryDeviceID = primaryDeviceID
        self.isMonitoring = isMonitoring; self.isSuspended = isSuspended
        self.discoveryFailure = discoveryFailure; self.preferencesFailure = preferencesFailure
        self.preferences = preferences
    }
}

public struct DeviceReconciliation: Sendable {
    public let added: [DeviceSessionID]
    public let invalidated: [DeviceSessionID]
}

public struct DeviceTelemetryUpdate: Equatable, Sendable {
    public let startedAt: Date
    public let finishedAt: Date
    public let battery: BatterySample?
    public let batteryFailure: TelemetryFailure?
    public let charging: ChargingSample?
    public let chargingFailure: TelemetryFailure?
    public init(startedAt: Date, finishedAt: Date, battery: BatterySample?, batteryFailure: TelemetryFailure?, charging: ChargingSample?, chargingFailure: TelemetryFailure?) {
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.battery = battery
        self.batteryFailure = batteryFailure; self.charging = charging; self.chargingFailure = chargingFailure
    }
}

/// Value state owned by BatteryMonitor's actor. There is one mutable isolation
/// domain, so removal and completion cannot interleave across another actor await.
public struct DeviceStore: Sendable {
    public private(set) var devices: [PhysicalDeviceID: DeviceState] = [:]
    public private(set) var preferences: DevicePreferences
    public private(set) var logicalDevices: [LogicalDeviceID: LogicalDeviceState] = [:]
    public private(set) var historicalDevices: [DeviceState] = []
    public private(set) var historicalLogicalDevices: [LogicalDeviceState] = []
    private var transientPrimary: PhysicalDeviceID?
    private var transientPrimaryLogical: LogicalDeviceID?
    private var logicalPreferenceCandidates: [LogicalDeviceID: DevicePreferenceIdentity] = [:]
    public init(preferences: DevicePreferences = DevicePreferences()) { self.preferences = preferences }

    @discardableResult
    public mutating func reconcile(_ identified: [IdentifiedDevice], at date: Date) -> DeviceReconciliation {
        let incoming = Dictionary(identified.map { ($0.descriptor.id, $0) }, uniquingKeysWith: { first, _ in first })
        let identities = incoming.mapValues { DevicePreferenceIdentity.derive(from: $0.descriptor) }
        let counts = Dictionary(identities.values.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        var added: [DeviceSessionID] = [], invalidated: [DeviceSessionID] = []
        for id in Array(devices.keys) where incoming[id] == nil {
            guard var state = devices[id], state.hostPresence == .present else { continue }
            invalidated.append(state.sessionID); state.hostPresence = .removed
            state.isRefreshing = false; state.nextRefreshAt = nil; devices[id] = state
        }
        for (id, item) in incoming {
            let candidateIdentity = identities[id] ?? nil
            let identity = candidateIdentity.flatMap { counts[$0] == 1 ? $0 : nil }
            let old = devices[id]
            let sameEndpoint = old?.descriptor.vendorID == item.descriptor.vendorID
                && old?.descriptor.productID == item.descriptor.productID
                && old?.controlEndpointRegistryEntryID == item.controlEndpointRegistryEntryID
                && old?.descriptor.interfaces.first(where: { $0.registryEntryID == item.controlEndpointRegistryEntryID })?.descriptorSHA256
                == item.descriptor.interfaces.first(where: { $0.registryEntryID == item.controlEndpointRegistryEntryID })?.descriptorSHA256
            if var state = old, state.hostPresence == .present, sameEndpoint {
                state.descriptor = item.descriptor; state.kind = item.kind; state.catalogMatch = item.catalogMatch; state.managesLogicalTargets = item.isReceiver
                var capabilities = item.capabilities
                capabilities.preserveReadEvidence(from: state.capabilities)
                if state.capabilities.battery == .verified { capabilities.recordBatteryRead() }
                state.capabilities = capabilities
                if state.preferenceIdentity != identity {
                    state.alias = identity.flatMap { preferences.aliases[$0.rawValue] }
                } else if let identity { state.alias = preferences.aliases[identity.rawValue] }
                state.preferenceIdentity = identity
                devices[id] = state
            } else {
                if let old, old.hostPresence == .present { invalidated.append(old.sessionID) }
                if var previous = old { previous.hostPresence = .removed; previous.isRefreshing = false; historicalDevices.append(previous) }
                let session = DeviceSessionID(physicalDeviceID: id)
                var state = DeviceState(sessionID: session, descriptor: item.descriptor, kind: item.kind,
                    capabilities: item.capabilities, catalogMatch: item.catalogMatch, managesLogicalTargets: item.isReceiver, controlEndpointRegistryEntryID: item.controlEndpointRegistryEntryID,
                    alias: identity.flatMap { preferences.aliases[$0.rawValue] }, preferenceIdentity: identity)
                if state.canRefresh { state.nextRefreshAt = date }
                devices[id] = state; added.append(session)
            }
        }
        // Direct peripherals retain their existing physical projection and gain a logical target.
        // Receiver children are supplied by their driver after an identity handshake.
        for item in incoming.values {
            guard let host = devices[item.descriptor.id] else { continue }
            if !item.isReceiver {
                let child = LogicalDeviceDescriptor(address: .direct(host.sessionID), product: item.catalogMatch?.entry.canonicalName ?? item.descriptor.product,
                    kind: item.kind, capabilities: host.capabilities, controlEndpointRegistryEntryID: item.controlEndpointRegistryEntryID,
                    preferenceIdentity: host.preferenceIdentity)
                _ = reconcileLogicalDevices([child], for: host.sessionID)
            }
        }
        for id in Array(logicalDevices.keys) {
            guard var child = logicalDevices[id], !isCurrent(child.descriptor.address.hostSessionID) else { continue }
            child.hostPresence = .removed; child.isReadingSettings = false; child.isRefreshing = false; child.nextRefreshAt = nil; logicalDevices[id] = child
        }
        return DeviceReconciliation(added: added, invalidated: invalidated)
    }

    public func isCurrent(_ session: DeviceSessionID) -> Bool {
        devices[session.physicalDeviceID].map { $0.hostPresence == .present && $0.sessionID == session } ?? false
    }
    @discardableResult public mutating func begin(_ session: DeviceSessionID, at date: Date) -> Bool {
        guard isCurrent(session), var state = devices[session.physicalDeviceID], state.canRefresh else { return false }
        state.isRefreshing = true; state.lastAttemptedAt = date; state.nextRefreshAt = nil
        devices[state.id] = state
        if let child = logicalDevices[.direct(state.id)] { _ = beginTelemetry(child.sessionID, at: date) }
        return true
    }
    @discardableResult public mutating func apply(_ update: DeviceTelemetryUpdate, to session: DeviceSessionID, policy: RefreshPolicy = RefreshPolicy()) -> Bool {
        guard isCurrent(session), var state = devices[session.physicalDeviceID] else { return false }
        state.isRefreshing = false; state.lastAttemptedAt = update.startedAt; state.lastFinishedAt = update.finishedAt
        state.batteryFailure = update.batteryFailure; state.chargingFailure = update.chargingFailure
        if let battery = update.battery {
            state.battery = battery; state.consecutiveFailures = 0
            state.capabilities.recordBatteryRead()
        } else { state.consecutiveFailures += 1 }
        if let charging = update.charging { state.charging = charging }
        let failures = [update.batteryFailure, update.chargingFailure].compactMap { $0 }
        if failures.contains(where: { $0.category == .denied }) { state.access = .denied }
        else if update.battery != nil || update.charging != nil || failures.contains(where: { [.deviceStatus, .malformedResponse].contains($0.category) }) { state.access = .ready }
        else if failures.contains(where: { $0.category == .busy }) { state.access = .busy }
        else { state.access = .failed }
        state.nextRefreshAt = update.finishedAt.addingTimeInterval(policy.interval(afterConsecutiveFailures: state.consecutiveFailures))
        devices[state.id] = state
        if let child = logicalDevices[.direct(state.id)], child.descriptor.address.hostSessionID == session {
            _ = apply(update, to: child.sessionID, policy: policy)
        }
        return true
    }
    public mutating func pause() {
        for id in Array(devices.keys) { devices[id]?.isRefreshing = false; devices[id]?.nextRefreshAt = nil }
        for id in Array(logicalDevices.keys) { logicalDevices[id]?.isReadingSettings = false; logicalDevices[id]?.isRefreshing = false; logicalDevices[id]?.nextRefreshAt = nil }
    }
    public mutating func setAlias(_ alias: String?, for id: PhysicalDeviceID) {
        guard var state = devices[id] else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        state.alias = value; devices[id] = state
        if let identity = state.preferenceIdentity { preferences.aliases[identity.rawValue] = value }
        if let child = logicalDevices[.direct(id)], child.descriptor.address.hostSessionID == state.sessionID {
            setAlias(value, for: child.id)
        }
    }
    public mutating func setPrimary(_ id: PhysicalDeviceID?) {
        guard id == nil || devices[id!]?.hostPresence == .present else { return }
        transientPrimary = id; transientPrimaryLogical = id.map(LogicalDeviceID.direct)
        preferences.primaryIdentity = id.flatMap { devices[$0]?.preferenceIdentity?.rawValue }
    }
    public mutating func setPrimaryIdentity(_ key: String?) { preferences.primaryIdentity = key }
    public mutating func setAliasIdentity(_ alias: String?, identityKey: String) {
        let value = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.aliases[identityKey] = value.flatMap { $0.isEmpty ? nil : $0 }
    }
    public var primaryDeviceID: PhysicalDeviceID? {
        let present = devices.values.filter { $0.hostPresence == .present }
        if let key = preferences.primaryIdentity, let preferred = present.first(where: { $0.preferenceIdentity?.rawValue == key }) { return preferred.id }
        if let transientPrimary, present.contains(where: { $0.id == transientPrimary }) { return transientPrimary }
        return present.sorted {
            func rank(_ d: DeviceState) -> Int {
                if d.kind == .mouse && d.capabilities.battery == .verified { return 0 }
                if d.canRefresh { return 1 }; return 2
            }
            return rank($0) == rank($1) ? $0.id < $1.id : rank($0) < rank($1)
        }.first?.id
    }

    /// Reconcile the complete child list for exactly one live receiver session.
    /// Address, pairing epoch, endpoint or identity changes always discard prior samples and drafts.
    @discardableResult
    public mutating func reconcileLogicalDevices(_ identified: [LogicalDeviceDescriptor], for host: DeviceSessionID) -> LogicalDeviceReconciliation {
        guard isCurrent(host), identified.allSatisfy({ $0.address.hostSessionID == host }) else {
            return LogicalDeviceReconciliation(added: [], invalidated: [])
        }
        let incoming = Dictionary(grouping: identified, by: \.id)
        // Duplicate slots are ambiguous. Invalidate rather than select an arbitrary target.
        let unique = incoming.compactMapValues { $0.count == 1 ? $0[0] : nil }
        var added: [LogicalDeviceSessionID] = [], invalidated: [LogicalDeviceSessionID] = []
        for id in Array(logicalDevices.keys) {
            guard var state = logicalDevices[id], state.descriptor.address.hostSessionID.physicalDeviceID == host.physicalDeviceID,
                  state.hostPresence == .present, unique[id] == nil else { continue }
            invalidated.append(state.sessionID); state.hostPresence = .removed; state.isReadingSettings = false; state.isRefreshing = false; state.nextRefreshAt = nil
            logicalDevices[id] = state
        }
        for (id, candidate) in unique {
            let identity = candidate.preferenceIdentity
            if candidate.isIdentityAmbiguous, let reported = candidate.peripheralIdentity.flatMap(DevicePreferenceIdentity.confirmedLogicalUnit) {
                logicalPreferenceCandidates[id] = reported; preferences.ambiguousIdentityKeys.insert(reported.rawValue)
            } else { logicalPreferenceCandidates[id] = identity }
            let descriptor = LogicalDeviceDescriptor(address: candidate.address, product: candidate.product, kind: candidate.kind,
                capabilities: candidate.capabilities, controlEndpointRegistryEntryID: candidate.controlEndpointRegistryEntryID,
                preferenceIdentity: identity, derivePreferenceIdentity: false, peripheralIdentity: candidate.peripheralIdentity, isIdentityAmbiguous: candidate.isIdentityAmbiguous, peerPresence: candidate.peerPresence)
            if var state = logicalDevices[id], state.hostPresence == .present, state.descriptor.address == descriptor.address,
               state.descriptor.controlEndpointRegistryEntryID == descriptor.controlEndpointRegistryEntryID {
                state.descriptor = descriptor
                // A successful battery read must not be demoted by repeated catalogue discovery.
                var capabilities = descriptor.capabilities
                capabilities.preserveReadEvidence(from: state.capabilities)
                if state.capabilities.battery == .verified { capabilities.recordBatteryRead() }
                state.capabilities = capabilities
                state.alias = identity.flatMap { preferences.aliases[$0.rawValue] }
                logicalDevices[id] = state
            } else {
                if let old = logicalDevices[id], old.hostPresence == .present { invalidated.append(old.sessionID) }
                if var previous = logicalDevices[id] { previous.hostPresence = .removed; previous.isRefreshing = false; previous.isReadingSettings = false; historicalLogicalDevices.append(previous) }
                let session = LogicalDeviceSessionID(address: descriptor.address)
                logicalDevices[id] = LogicalDeviceState(descriptor: descriptor, sessionID: session, capabilities: descriptor.capabilities,
                    alias: identity.flatMap { preferences.aliases[$0.rawValue] })
                added.append(session)
            }
        }
        resolveLogicalPreferenceCollisions()
        return LogicalDeviceReconciliation(added: added, invalidated: invalidated)
    }
    private mutating func resolveLogicalPreferenceCollisions() {
        let present = logicalDevices.values.filter { isCurrent($0.sessionID) }
        let counts = Dictionary(present.compactMap { logicalPreferenceCandidates[$0.id] }.map { ($0.rawValue, 1) }, uniquingKeysWith: +)
        for (key, count) in counts where count > 1 {
            preferences.ambiguousIdentityKeys.insert(key)
            preferences.foldedIdentities.remove(key)
            preferences.quickPresets.removeValue(forKey: key)
        }
        if let primary = preferences.primaryIdentity, preferences.ambiguousIdentityKeys.contains(primary) { preferences.primaryIdentity = nil }
        for child in present {
            guard var state = logicalDevices[child.id] else { continue }
            let candidate = logicalPreferenceCandidates[child.id]
            let original = state.descriptor
            let ambiguous = original.isIdentityAmbiguous || (candidate.map { preferences.ambiguousIdentityKeys.contains($0.rawValue) } ?? false)
            let resolved = ambiguous ? nil : candidate
            state.descriptor = LogicalDeviceDescriptor(address: original.address, product: original.product, kind: original.kind,
                capabilities: original.capabilities, controlEndpointRegistryEntryID: original.controlEndpointRegistryEntryID,
                preferenceIdentity: resolved, derivePreferenceIdentity: false, peripheralIdentity: original.peripheralIdentity, isIdentityAmbiguous: ambiguous, peerPresence: original.peerPresence)
            state.alias = resolved.flatMap { preferences.aliases[$0.rawValue] }
            logicalDevices[child.id] = state
        }
    }
    public func isCurrent(_ session: LogicalDeviceSessionID) -> Bool {
        isCurrent(session.address.hostSessionID) && logicalDevices[session.deviceID].map {
            $0.hostPresence == .present && $0.peerPresence != .unreachable && $0.sessionID == session
        } == true
    }
    @discardableResult public mutating func beginTelemetry(_ session: LogicalDeviceSessionID, at date: Date) -> Bool {
        guard isCurrent(session), var state = logicalDevices[session.deviceID], state.canRefreshTelemetry else { return false }
        state.isRefreshing = true; state.lastAttemptedAt = date; state.nextRefreshAt = nil; logicalDevices[state.id] = state; return true
    }
    @discardableResult public mutating func apply(_ update: DeviceTelemetryUpdate, to session: LogicalDeviceSessionID, policy: RefreshPolicy = RefreshPolicy()) -> Bool {
        guard isCurrent(session), var state = logicalDevices[session.deviceID] else { return false }
        state.isRefreshing = false; state.lastAttemptedAt = update.startedAt; state.lastFinishedAt = update.finishedAt
        if let battery = update.battery { state.battery = battery; state.capabilities.recordBatteryRead(); state.consecutiveFailures = 0 }
        else { state.consecutiveFailures += 1 }
        if let charging = update.charging { state.charging = charging }
        state.batteryFailure = update.batteryFailure; state.chargingFailure = update.chargingFailure
        let failures = [update.batteryFailure, update.chargingFailure].compactMap { $0 }
        if failures.contains(where: { $0.category == .denied }) { state.access = .denied }
        else if update.battery != nil || update.charging != nil || failures.contains(where: { [.deviceStatus, .malformedResponse].contains($0.category) }) { state.access = .ready }
        else if failures.contains(where: { $0.category == .busy }) { state.access = .busy }
        else { state.access = .failed }
        state.nextRefreshAt = update.finishedAt.addingTimeInterval(policy.interval(afterConsecutiveFailures: state.consecutiveFailures))
        logicalDevices[state.id] = state; return true
    }
    @discardableResult public mutating func beginSettingsRead(_ session: LogicalDeviceSessionID, at date: Date) -> Bool {
        guard isCurrent(session), var state = logicalDevices[session.deviceID], state.canRefreshSettings else { return false }
        state.isReadingSettings = true; state.lastSettingsAttemptedAt = date; logicalDevices[state.id] = state; return true
    }
    @discardableResult public mutating func applySettings(_ snapshot: DeviceSettingsSnapshot, failure: TelemetryFailure? = nil,
                                                       capabilityUpdates: [DeviceOperation: OperationCapability] = [:]) -> Bool {
        guard isCurrent(snapshot.session), var state = logicalDevices[snapshot.session.deviceID],
              state.settings.map({ snapshot.revision > $0.revision && snapshot.capturedAt >= $0.capturedAt }) ?? true else { return false }
        state.settings = snapshot; state.settingsFailure = failure; state.isReadingSettings = false
        var operations: [DeviceOperation] = []
        if snapshot.settings.currentDPI != nil { operations.append(.dpiRead) }
        if snapshot.settings.pollingRateHz != nil { operations.append(.pollingRateRead) }
        if snapshot.settings.stages != nil { operations.append(.stagesRead) }
        if snapshot.settings.activeProfileID != nil { operations.append(.onboardRead) }
        for operation in operations {
            let prior = state.capabilities[operation]
            if ![.writeVerified, .persistenceVerified].contains(prior.evidence) {
                state.capabilities.record(OperationCapability(evidence: .readVerified, constraints: prior.constraints, source: prior.source), for: operation)
            }
        }
        for (operation, capability) in capabilityUpdates where operation.isWrite { state.capabilities.record(capability, for: operation) }
        state.lastSettingsFinishedAt = snapshot.capturedAt; logicalDevices[state.id] = state; return true
    }
    @discardableResult public mutating func failSettingsRead(_ failure: TelemetryFailure, session: LogicalDeviceSessionID, at date: Date,
                                                          capabilityUpdates: [DeviceOperation: OperationCapability] = [:]) -> Bool {
        guard isCurrent(session), var state = logicalDevices[session.deviceID] else { return false }
        state.settingsFailure = failure; state.isReadingSettings = false; state.lastSettingsFinishedAt = date
        for (operation, capability) in capabilityUpdates where operation.isWrite { state.capabilities.record(capability, for: operation) }
        logicalDevices[state.id] = state; return true
    }
    @discardableResult public mutating func applySettingChange(_ result: SettingChangeResult, capabilityUpdates: [DeviceOperation: OperationCapability] = [:]) -> Bool {
        guard isCurrent(result.request.target), var state = logicalDevices[result.request.target.deviceID] else { return false }
        if let observed = result.observed, observed.session == result.request.target,
           state.settings.map({ observed.revision > $0.revision }) ?? true {
            state.settings = observed
        }
        for (operation, capability) in capabilityUpdates where operation.isWrite { state.capabilities.record(capability, for: operation) }
        state.lastSettingChange = result; logicalDevices[state.id] = state; return true
    }
    public mutating func setAlias(_ alias: String?, for id: LogicalDeviceID) {
        guard var state = logicalDevices[id] else { return }
        let value = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.alias = value.flatMap { $0.isEmpty ? nil : $0 }; logicalDevices[id] = state
        if let identity = state.descriptor.preferenceIdentity { preferences.aliases[identity.rawValue] = state.alias }
    }

    public mutating func setPrimaryLogical(_ id: LogicalDeviceID?) {
        guard id == nil || logicalDevices[id!].map({ isCurrent($0.sessionID) }) == true else { return }
        transientPrimaryLogical = id
        transientPrimary = id.flatMap { logicalDevices[$0]?.descriptor.address.hostSessionID.physicalDeviceID }
        preferences.primaryIdentity = id.flatMap { logicalDevices[$0]?.descriptor.preferenceIdentity?.rawValue }
    }
    public var primaryLogicalDeviceID: LogicalDeviceID? {
        let present = logicalDevices.values.filter { isCurrent($0.sessionID) }
        if let preferred = preferences.primaryIdentity, let child = present.first(where: { $0.descriptor.preferenceIdentity?.rawValue == preferred }) { return child.id }
        if let transientPrimaryLogical, present.contains(where: { $0.id == transientPrimaryLogical }) { return transientPrimaryLogical }
        return present.sorted {
            func rank(_ child: LogicalDeviceState) -> Int {
                if child.descriptor.kind == .mouse && child.capabilities.battery == .verified { return 0 }
                if child.canRefreshTelemetry { return 1 }; return 2
            }
            return rank($0) == rank($1) ? $0.id < $1.id : rank($0) < rank($1)
        }.first?.id
    }

    public mutating func setDeviceFolded(_ folded: Bool, identityKey: String) {
        guard !identityKey.isEmpty, !preferences.ambiguousIdentityKeys.contains(identityKey) else { return }
        guard preferences.rememberFoldedDevices else { return }
        if folded {
            preferences.foldedIdentities.insert(identityKey)
        } else {
            preferences.foldedIdentities.remove(identityKey)
        }
    }

    public mutating func setRememberFoldedDevices(_ remember: Bool, activeFoldedKeys: Set<String>) {
        preferences.rememberFoldedDevices = remember
        if remember {
            let validKeys = activeFoldedKeys.filter { !$0.isEmpty && !preferences.ambiguousIdentityKeys.contains($0) }
            preferences.foldedIdentities = validKeys
        } else {
            preferences.foldedIdentities.removeAll()
        }
    }

    public mutating func setQuickPresets(_ presets: DeviceQuickPresets?, for identityKey: String) {
        guard !identityKey.isEmpty, !preferences.ambiguousIdentityKeys.contains(identityKey) else { return }
        if let presets, !presets.isEmpty {
            preferences.quickPresets[identityKey] = presets
        } else {
            preferences.quickPresets.removeValue(forKey: identityKey)
        }
    }

    public mutating func setShowMenuBarPercentage(_ show: Bool) {
        preferences.showMenuBarPercentage = show
    }

    public mutating func setAppearanceMode(_ mode: BazerAppearanceMode) {
        preferences.appearanceMode = mode
    }

}
