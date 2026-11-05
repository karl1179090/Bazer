// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import CoreFoundation
import Foundation
import IOKit
import IOKit.hid

/// Constructed and used only by HIDRunLoopWorker. No input callbacks are registered.
final class IOKitDiscoveryBackend: HIDSynchronousReportBackend {
    private var manager: IOHIDManager?
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var descriptors: [UInt64: HIDInterfaceDescriptor] = [:]
    private var evidence: [UInt64: HIDRegistryEvidence] = [:]
    private var onChange: ((HIDDiscoveryEvent) -> Void)?

    func start(onChange: @escaping (HIDDiscoveryEvent) -> Void) throws {
        self.onChange = onChange
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<IOKitDiscoveryBackend>.fromOpaque(context).takeUnretainedValue().add(device, notify: true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<IOKitDiscoveryBackend>.fromOpaque(context).takeUnretainedValue().remove(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        // Intentionally no IOHIDManagerOpen, device scheduling, or input subscription.
        for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] { add(device, notify: false) }
    }

    func snapshot() -> HIDDiscoverySnapshot {
        HIDDiscoverySnapshot(capturedAt: Date(), interfaces: Array(descriptors.values), registryEvidence: Array(evidence.values))
    }

    func inspectInterface(registryEntryID: UInt64) throws -> HIDInspectionResult {
        guard let device = devices[registryEntryID] else { throw HIDDiscoveryError.missingInterface(registryEntryID) }
        // Options 0 is nonexclusive. No seize/exclusive path exists in this module.
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        var operations = [diagnostic("open", id: registryEntryID, result: opened)]
        if opened == kIOReturnSuccess {
            operations.append(diagnostic("close", id: registryEntryID, result: IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))))
        }
        return HIDInspectionResult(registryEntryID: registryEntryID, operations: operations)
    }

    func openFeatureInterface(registryEntryID: UInt64) throws -> HIDOperationDiagnostic {
        guard let device = devices[registryEntryID] else { throw HIDDiscoveryError.missingInterface(registryEntryID) }
        return diagnostic("open", id: registryEntryID, result: IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)))
    }

    func setFeature(registryEntryID: UInt64, request: HIDReadOnlyFeatureRequest) throws -> HIDOperationDiagnostic {
        guard let device = devices[registryEntryID] else { throw HIDDiscoveryError.missingInterface(registryEntryID) }
        let result = request.bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(request.reportID), $0.baseAddress!, $0.count)
        }
        return diagnostic("setFeature", id: registryEntryID, result: result)
    }

    func getFeature(registryEntryID: UInt64, reportID: UInt8, capacity: Int) throws -> HIDRawFeatureReport {
        guard let device = devices[registryEntryID] else { throw HIDDiscoveryError.missingInterface(registryEntryID) }
        var buffer = [UInt8](repeating: 0, count: capacity)
        var length = CFIndex(capacity)
        let result = buffer.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), $0.baseAddress!, &length)
        }
        return HIDRawFeatureReport(operation: diagnostic("getFeature", id: registryEntryID, result: result), bytes: Array(buffer.prefix(max(0, min(capacity, length)))), actualLength: length)
    }

    func closeFeatureInterface(registryEntryID: UInt64) -> HIDOperationDiagnostic {
        guard let device = devices[registryEntryID] else { return diagnostic("close", id: registryEntryID, result: kIOReturnNoDevice) }
        return diagnostic("close", id: registryEntryID, result: IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)))
    }

    func stop() {
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        devices.removeAll()
        descriptors.removeAll()
        evidence.removeAll()
        onChange = nil
    }

    private func add(_ device: IOHIDDevice, notify: Bool) {
        let service = IOHIDDeviceGetService(device)
        var id: UInt64 = 0
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == kIOReturnSuccess else { return }
        let ancestry = readAncestry(service: service, interfaceID: id)
        let primary: HIDUsage?
        if let page = number(device, kIOHIDPrimaryUsagePageKey), let usage = number(device, kIOHIDPrimaryUsageKey) {
            primary = HIDUsage(page: page.uint32Value, usage: usage.uint32Value)
        } else { primary = nil }
        let usagePairs = property(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] ?? []
        let usages = usagePairs.compactMap { pair -> HIDUsage? in
            guard let page = pair[kIOHIDDeviceUsagePageKey] as? NSNumber, let usage = pair[kIOHIDDeviceUsageKey] as? NSNumber else { return nil }
            return HIDUsage(page: page.uint32Value, usage: usage.uint32Value)
        }
        let rawDescriptor = property(device, kIOHIDReportDescriptorKey) as? Data ?? Data()
        let descriptor = HIDInterfaceDescriptor(
            registryEntryID: id,
            usbParentRegistryEntryID: ancestry.nearestUSBParent.flatMap { $0.registryEntryID == 0 ? nil : $0.registryEntryID },
            usbParentPath: ancestry.nearestUSBParent?.path,
            vendorID: number(device, kIOHIDVendorIDKey)?.uint16Value ?? 0,
            productID: number(device, kIOHIDProductIDKey)?.uint16Value ?? 0,
            product: property(device, kIOHIDProductKey) as? String ?? "Unknown HID device",
            manufacturer: property(device, kIOHIDManufacturerKey) as? String,
            transport: property(device, kIOHIDTransportKey) as? String,
            locationID: number(device, kIOHIDLocationIDKey)?.uint32Value,
            isBuiltIn: number(device, kIOHIDBuiltInKey)?.boolValue == true || !ancestry.internalEvidence.isEmpty,
            primaryUsage: primary, usages: usages,
            maxInputReportSize: number(device, kIOHIDMaxInputReportSizeKey)?.intValue ?? 0,
            maxOutputReportSize: number(device, kIOHIDMaxOutputReportSizeKey)?.intValue ?? 0,
            maxFeatureReportSize: number(device, kIOHIDMaxFeatureReportSizeKey)?.intValue ?? 0,
            reportDescriptor: Array(rawDescriptor)
        )
        let previous = descriptors.updateValue(descriptor, forKey: id)
        devices[id] = device
        evidence[id] = ancestry
        if notify, previous != descriptor {
            onChange?(HIDDiscoveryEvent(kind: previous == nil ? .added : .changed, interfaceRegistryEntryID: id, snapshot: snapshot()))
        }
    }

    private func remove(_ device: IOHIDDevice) {
        var id: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0 { _ = IORegistryEntryGetRegistryEntryID(service, &id) }
        if id == 0 { id = devices.first(where: { $0.value === device })?.key ?? 0 }
        guard descriptors.removeValue(forKey: id) != nil else { return }
        devices.removeValue(forKey: id)
        evidence.removeValue(forKey: id)
        onChange?(HIDDiscoveryEvent(kind: .removed, interfaceRegistryEntryID: id, snapshot: snapshot()))
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> AnyObject? { IOHIDDeviceGetProperty(device, key as CFString) }
    private func number(_ device: IOHIDDevice, _ key: String) -> NSNumber? { property(device, key) as? NSNumber }

    private func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func readAncestry(service: io_registry_entry_t, interfaceID: UInt64) -> HIDRegistryEvidence {
        var current = service
        _ = IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        var nodes: [HIDRegistryNode] = []
        var internalEvidence: [String] = []
        var diagnostics: [HIDOperationDiagnostic] = []
        var parentNode: HIDRegistryNode?
        for _ in 0..<64 {
            var id: UInt64 = 0
            let idResult = IORegistryEntryGetRegistryEntryID(current, &id)
            if idResult != kIOReturnSuccess { diagnostics.append(diagnostic("registryEntryID", id: interfaceID, result: idResult)) }
            var registryClass = [CChar](repeating: 0, count: 128)
            let classResult = IOObjectGetClass(current, &registryClass)
            if classResult != kIOReturnSuccess { diagnostics.append(diagnostic("registryClass", id: interfaceID, result: classResult)) }
            var path = [CChar](repeating: 0, count: 4096)
            let pathResult = IORegistryEntryGetPath(current, kIOServicePlane, &path)
            if pathResult != kIOReturnSuccess { diagnostics.append(diagnostic("registryPath", id: interfaceID, result: pathResult)) }
            let node = HIDRegistryNode(registryEntryID: id, registryClass: cString(registryClass), path: pathResult == kIOReturnSuccess ? cString(path) : nil)
            nodes.append(node)
            if (registryProperty(current, "Built-In") as? NSNumber)?.boolValue == true { internalEvidence.append("\(id):Built-In=true") }
            if let flag = registryProperty(current, "AAPL,device-internal"), flagIsTrue(flag) { internalEvidence.append("\(id):AAPL,device-internal=true") }
            if (registryProperty(current, "USBPortType") as? NSNumber)?.intValue == 2 { internalEvidence.append("\(id):USBPortType=2(internal)") }
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 || IOObjectConformsTo(current, "IOUSBDevice") != 0 {
                parentNode = node
                break
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard result == kIOReturnSuccess, parent != 0 else {
                if result != kIOReturnSuccess { diagnostics.append(diagnostic("usbParentTraversal", id: interfaceID, result: result)) }
                break
            }
            IOObjectRelease(current)
            current = parent
        }
        return HIDRegistryEvidence(interfaceRegistryEntryID: interfaceID, nearestUSBParent: parentNode, ancestry: nodes, internalEvidence: internalEvidence, diagnostics: diagnostics)
    }

    private func flagIsTrue(_ value: AnyObject) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let data = value as? Data { return data.contains { $0 != 0 } }
        return false
    }

    private func cString(_ bytes: [CChar]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func diagnostic(_ phase: String, id: UInt64, result: IOReturn) -> HIDOperationDiagnostic {
        HIDOperationDiagnostic(phase: phase, registryEntryID: id, rawIOReturn: result, message: String(cString: mach_error_string(result)))
    }
}
