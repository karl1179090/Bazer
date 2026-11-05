// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit.ps
import CryptoKit
import Darwin
import BazerCore

public enum BluetoothAudioOpaqueIdentity {
    /// Source namespaces are retained; raw addresses/identifiers never escape to ordinary logs.
    public static func key(_ raw: String) -> String {
        "sha256:" + SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func discoveryKey(address: String) -> String {
        key("iobluetooth-address:" + address.filter(\.isHexDigit).lowercased())
    }
}

public struct AccessoryPowerSourceReader: Sendable {
    private let symbolAvailable: Bool
    private let verifiedAccessoryKeys: Set<String>
    public init(symbolAvailable: Bool = true, verifiedAccessoryKeys: Set<String> = []) {
        self.symbolAvailable = symbolAvailable; self.verifiedAccessoryKeys = verifiedAccessoryKeys
    }
    public func read(at date: Date = Date()) -> BluetoothAudioReadResult<BluetoothAudioPowerRecord> {
        guard symbolAvailable, let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) else {
            return .init(status: .unavailable, message: "系统配件电源接口不可用")
        }
        defer { dlclose(handle) }
        // Private Apple SPI. Dynamic resolution is intentionally confined to this adapter.
        // Apple IOPowerSourcesPrivate.h defines kIOPSSourceForAccessories = 4.
        typealias CopySources = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        guard let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else {
            return .init(status: .unavailable, message: "系统配件电源接口在此系统不可用")
        }
        let copy = unsafeBitCast(symbol, to: CopySources.self)
        guard let info = copy(4)?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .init(status: .failed, message: "系统配件电源读取失败")
        }
        var records: [BluetoothAudioPowerRecord] = []
        var malformed = false
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                malformed = true; continue
            }
            let typed = Self.typedValues(description)
            if let record = AccessoryPowerParser.parse(typed, observedAt: date, verifiedAccessoryKeys: verifiedAccessoryKeys,
                                                       opaqueKey: BluetoothAudioOpaqueIdentity.key) { records.append(record) }
            else if typed["Transport Type"] == .string("Bluetooth"), typed["Accessory Category"] == .string("Headset") { malformed = true }
        }
        return .init(records: records, status: malformed ? .partial : .success,
                     message: malformed ? "部分系统配件记录无法识别" : nil)
    }
    public static func typedValues(_ values: [String: Any]) -> [String: AccessoryPowerValue] {
        var result: [String: AccessoryPowerValue] = [:]
        for (key, value) in values {
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { result[key] = .boolean(number.boolValue) }
                else { result[key] = .number(number.doubleValue) }
            } else if let string = value as? String { result[key] = .string(string) }
            else if let date = value as? Date { result[key] = .date(date) }
        }
        return result
    }
}
