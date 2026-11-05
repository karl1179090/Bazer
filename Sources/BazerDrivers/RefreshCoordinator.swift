// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

public protocol MonitorClock: Sendable {
    var now: Date { get }
    /// Relative sleeping must use a monotonic clock in production.
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemMonitorClock: MonitorClock, Sendable {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, interval)))
    }
}

struct RefreshRequest: Equatable, Sendable {
    let id: UUID
    let session: DeviceSessionID
    let epoch: UUID
}

/// Explicit requests survive actor reentrancy and cancellation. An invalidated
/// synchronous HID call still owns its slot until it actually returns.
/// BatteryMonitor exclusively owns this value and its associated Task handles.
public struct RefreshCoordinator: Sendable {
    private var active: [PhysicalDeviceID: RefreshRequest] = [:]
    private var pending: [PhysicalDeviceID: DeviceSessionID] = [:]
    public init() {}

    mutating func request(_ session: DeviceSessionID, epoch: UUID) -> (request: RefreshRequest, isNew: Bool) {
        if let existing = active[session.physicalDeviceID] {
            if existing.session != session || existing.epoch != epoch { pending[session.physicalDeviceID] = session }
            return (existing, false)
        }
        let request = RefreshRequest(id: UUID(), session: session, epoch: epoch)
        active[session.physicalDeviceID] = request
        pending.removeValue(forKey: session.physicalDeviceID)
        return (request, true)
    }
    mutating func finish(_ request: RefreshRequest) -> DeviceSessionID? {
        guard active[request.session.physicalDeviceID]?.id == request.id else { return nil }
        active.removeValue(forKey: request.session.physicalDeviceID)
        return pending.removeValue(forKey: request.session.physicalDeviceID)
    }
    mutating func invalidate(_ session: DeviceSessionID) {
        if pending[session.physicalDeviceID] == session { pending.removeValue(forKey: session.physicalDeviceID) }
    }
    mutating func clearPending() { pending.removeAll() }
    func hasActive(physicalDeviceID: PhysicalDeviceID) -> Bool { active[physicalDeviceID] != nil }
    var requests: [RefreshRequest] { Array(active.values) }
}
