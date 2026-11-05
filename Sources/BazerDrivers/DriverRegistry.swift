// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import BazerHID
import Foundation

public struct LogicalDeviceTelemetryResult: Equatable, Sendable {
    public let session: LogicalDeviceSessionID
    public let update: DeviceTelemetryUpdate
    public init(session: LogicalDeviceSessionID, update: DeviceTelemetryUpdate) { self.session = session; self.update = update }
}

/// A receiver owns discovery and a shared transport; each child owns independent samples.
public protocol DeviceLogicalDriver: Sendable {
    func discoverTargets(host: PhysicalDeviceDescriptor, session: DeviceSessionID) async throws -> [LogicalDeviceDescriptor]
    func readTelemetry(target: LogicalDeviceDescriptor, session: LogicalDeviceSessionID) async -> LogicalDeviceTelemetryResult
    /// Invalidate only this host generation, draining/closing its input subscription safely.
    func invalidateHost(_ session: DeviceSessionID) async
    func discoveryEvents() async -> AsyncStream<DeviceSessionID>
    func stop() async
}
public extension DeviceLogicalDriver {
    func invalidateHost(_ session: DeviceSessionID) async {}
    func discoveryEvents() async -> AsyncStream<DeviceSessionID> { AsyncStream { $0.finish() } }
    func stop() async {}
}

public struct DeviceDriverRegistration: Sendable {
    public let id: String
    public let identify: @Sendable (PhysicalDeviceDescriptor) -> IdentifiedDevice?
    public let telemetryReader: (any DeviceTelemetryReading)?
    public let logicalDriver: (any DeviceLogicalDriver)?
    public let settingsAdapter: (any DeviceSettingsAdapter)?
    public let isFallback: Bool
    public init(id: String, identify: @escaping @Sendable (PhysicalDeviceDescriptor) -> IdentifiedDevice?,
                telemetryReader: (any DeviceTelemetryReading)? = nil, logicalDriver: (any DeviceLogicalDriver)? = nil, settingsAdapter: (any DeviceSettingsAdapter)? = nil, isFallback: Bool = false) {
        self.id = id; self.identify = identify; self.telemetryReader = telemetryReader; self.logicalDriver = logicalDriver; self.isFallback = isFallback; self.settingsAdapter = settingsAdapter
    }
}

/// Statically assembled at startup. Ambiguous registrations fail closed; no brand switches in the UI.
public struct DriverRegistry: DeviceTelemetryReading, Sendable {
    public let registrations: [DeviceDriverRegistration]
    public init(registrations: [DeviceDriverRegistration]) { self.registrations = registrations }
    private func registration(for device: PhysicalDeviceDescriptor) -> DeviceDriverRegistration? {
        let matches = registrations.filter { $0.identify(device) != nil }
        let specific = matches.filter { !$0.isFallback }
        let eligible = specific.isEmpty ? matches.filter(\.isFallback) : specific
        return eligible.count == 1 ? eligible[0] : nil
    }
    public func identify(_ device: PhysicalDeviceDescriptor) -> IdentifiedDevice? { registration(for: device)?.identify(device) }
    public func settingsAdapter(for device: PhysicalDeviceDescriptor) -> (any DeviceSettingsAdapter)? { registration(for: device)?.settingsAdapter }
    public func logicalDriver(for device: PhysicalDeviceDescriptor) -> (any DeviceLogicalDriver)? { registration(for: device)?.logicalDriver }
    public func read(device: PhysicalDeviceDescriptor) async -> DeviceTelemetryResult {
        guard let reader = registration(for: device)?.telemetryReader else {
            let now = Date(), failure = TelemetryFailure(category: .unsupported, message: "No unique registered telemetry adapter.", operation: "driverRegistry")
            return DeviceTelemetryResult(physicalDeviceID: device.id, endpointRegistryEntryID: nil, startedAt: now, finishedAt: now,
                                         battery: nil, batteryFailure: failure, charging: nil, chargingFailure: failure)
        }
        return await reader.read(device: device)
    }
    public func invalidateHost(_ session: DeviceSessionID, device: PhysicalDeviceDescriptor) async {
        await logicalDriver(for: device)?.invalidateHost(session)
    }
    public func stop() async {
        // Registrations are static. Adapters must make stop idempotent if shared across profiles.
        for registration in registrations { await registration.logicalDriver?.stop() }
    }
    public static func live(transport: any HIDFeatureGroupTransport) -> Self {
        Self(registrations: standardRegistrations(razerReader: RazerBatteryDriver(transport: transport),
            razerSettings: (transport as? HIDDiscovery).map { RazerMouseDriver(discovery: $0) }, logitech: LogitechReceiverDriver()))
    }
    public static let identification = Self(registrations: standardRegistrations())
    public static func standardRegistrations(razerReader: (any DeviceTelemetryReading)? = nil, razerSettings: (any DeviceSettingsAdapter)? = nil, logitech: LogitechReceiverDriver? = nil) -> [DeviceDriverRegistration] {
        [DeviceDriverRegistration(id: "razer.1532.00c5", identify: identifyRazer, telemetryReader: razerReader, settingsAdapter: razerSettings),
         DeviceDriverRegistration(id: "logitech.hidpp", identify: LogitechReceiverDriver.identify, logicalDriver: logitech, settingsAdapter: logitech),
         DeviceDriverRegistration(id: "catalog.passive-identification", identify: identifyCatalog, isFallback: true),
         DeviceDriverRegistration(id: "generic.keyboard.identification", identify: identifyKeyboard, isFallback: true)]
    }
    private static func isConsistentUSB(_ device: PhysicalDeviceDescriptor) -> Bool {
        guard device.isExternalUSB, let first = device.interfaces.first else { return false }
        return device.interfaces.allSatisfy { $0.vendorID == first.vendorID && $0.productID == first.productID }
    }
    private static func identifyRazer(_ device: PhysicalDeviceDescriptor) -> IdentifiedDevice? {
        guard isConsistentUSB(device), device.vendorID == 0x1532, device.productID == 0x00C5 else { return nil }
        let endpoint = InterfaceSelector.razerControlInterface(in: device).selected
        return IdentifiedDevice(descriptor: device, kind: .mouse,
            capabilities: DeviceCapabilities(battery: .candidate, chargingQuery: endpoint != nil, powerSource: .rechargeableBattery, operations: RazerMouseDriver.candidateReadCapabilities),
            controlEndpointRegistryEntryID: endpoint?.registryEntryID)
    }
    private static func identifyKeyboard(_ device: PhysicalDeviceDescriptor) -> IdentifiedDevice? {
        guard isConsistentUSB(device), !(device.vendorID == 0x1532 && device.productID == 0x00C5),
              device.vendorID.flatMap({ vendor in device.productID.flatMap { DeviceCatalog.matchUSB(vendorID: vendor, productID: $0) } }) == nil,
              (device.vendorID == 0x342D && device.productID == 0xE51A) || GenericKeyboardDriver.supports(device) else { return nil }
        return IdentifiedDevice(descriptor: device, kind: .keyboard, capabilities: .identificationOnly)
    }
    private static func identifyCatalog(_ device: PhysicalDeviceDescriptor) -> IdentifiedDevice? {
        guard isConsistentUSB(device), let vendor = device.vendorID, let product = device.productID,
              let match = DeviceCatalog.matchUSB(vendorID: vendor, productID: product) else { return nil }
        return IdentifiedDevice(descriptor: device, kind: match.entry.kind.deviceKind, capabilities: match.capabilities,
            isReceiver: match.entry.kind.isReceiver, catalogMatch: match)
    }

}
