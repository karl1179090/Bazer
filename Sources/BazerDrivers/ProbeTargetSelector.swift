// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore

public struct RazerProbeTarget: Sendable {
    public let device: PhysicalDeviceDescriptor
    public let interface: HIDInterfaceDescriptor
}

public enum ProbeTargetSelectionError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedDevice
    case noPhysicalDevice
    case ambiguousPhysicalDevices([String])
    case sessionSelectorNotFound(String)
    case noControlInterface
    case ambiguousControlInterfaces

    public var description: String {
        switch self {
        case .unsupportedDevice: "Only the exact 1532:00C5 profile is authorized for access."
        case .noPhysicalDevice: "No physical device matches the requested VID/PID."
        case .ambiguousPhysicalDevices(let selectors): "Multiple physical devices match; supply --device with one session selector: \(selectors.joined(separator: ", "))."
        case .sessionSelectorNotFound(let selector): "Session selector '\(selector)' does not match a current device with the requested VID/PID."
        case .noControlInterface: "No control interface satisfies the exact mouse/90-byte Feature/Report ID 0 requirements; see interface rejection reasons."
        case .ambiguousControlInterfaces: "More than one control interface satisfies the profile; refusing to guess."
        }
    }
}

public enum ProbeTargetSelector {
    /// Shared by inspect and subsequent read-only telemetry commands.
    public static func select(in devices: [PhysicalDeviceDescriptor], vendorID: UInt16, productID: UInt16, sessionSelector: String? = nil) throws -> RazerProbeTarget {
        let profile = RazerDeviceProfile.deathAdderV3HyperSpeed
        guard vendorID == profile.vendorID, productID == profile.productID else { throw ProbeTargetSelectionError.unsupportedDevice }
        let matching = devices.filter { !$0.interfaces.isEmpty && $0.interfaces.allSatisfy { $0.vendorID == vendorID && $0.productID == productID } }
        guard !matching.isEmpty else { throw ProbeTargetSelectionError.noPhysicalDevice }
        let device: PhysicalDeviceDescriptor
        if let selector = sessionSelector {
            guard let selected = matching.first(where: { $0.id.rawValue == selector }) else { throw ProbeTargetSelectionError.sessionSelectorNotFound(selector) }
            device = selected
        } else {
            guard matching.count == 1 else { throw ProbeTargetSelectionError.ambiguousPhysicalDevices(matching.map { $0.id.rawValue }) }
            device = matching[0]
        }
        let selection = InterfaceSelector.razerControlInterface(in: device)
        guard let endpoint = selection.selected else {
            if selection.issue == .ambiguousCandidates { throw ProbeTargetSelectionError.ambiguousControlInterfaces }
            throw ProbeTargetSelectionError.noControlInterface
        }
        return RazerProbeTarget(device: device, interface: endpoint)
    }
}
