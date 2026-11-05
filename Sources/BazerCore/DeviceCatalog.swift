// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum CatalogBrand: String, Codable, Sendable { case razer, logitech
    public var vendorID: UInt16 { self == .razer ? 0x1532 : 0x046D }
}
public enum CatalogDeviceKind: String, Codable, Sendable { case mouse, keyboard, headset, receiver, dock
    public var deviceKind: DeviceKind { switch self { case .mouse: .mouse; case .keyboard: .keyboard; default: .other } }
    public var isReceiver: Bool { self == .receiver || self == .dock }
}
public enum CatalogConnection: String, Codable, Sendable {
    case wiredUSB, usbReceiver, lightspeed, unifying, bolt, bluetooth, hyperPolling, chargingOnlyUSB
}
public enum CatalogIdentityStatus: String, Codable, Sendable { case catalogued, identityUnconfirmed }
public struct DeviceCatalogVariant: Equatable, Codable, Sendable {
    public let connection: CatalogConnection
    public let usbProductID: UInt16?
    public let powerSource: PowerSource
    public let sku: String?
    public init(connection: CatalogConnection, usbProductID: UInt16? = nil, powerSource: PowerSource, sku: String? = nil) {
        self.connection = connection; self.usbProductID = usbProductID; self.powerSource = powerSource; self.sku = sku
    }
}
public struct DeviceCatalogEntry: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let brand: CatalogBrand
    public let canonicalName: String
    public let matrixRow: String
    public let aliases: [String]
    public let kind: CatalogDeviceKind
    public let variants: [DeviceCatalogVariant]
    public let candidateOperations: Set<DeviceOperation>
    public let identityStatus: CatalogIdentityStatus
    public let limitations: [String]
    public let source: String
    /// A known product ceiling is diagnostic metadata, never a supported-value list.
    public let documentedPollingCeilingHz: Int?
}
public struct DeviceCatalogMatch: Equatable, Sendable {
    public let entry: DeviceCatalogEntry
    public let variant: DeviceCatalogVariant
    public var capabilities: DeviceCapabilities {
        var operations: [DeviceOperation: OperationCapability] = [:]
        for operation in entry.candidateOperations {
            if [.batteryRead, .chargingRead, .voltageRead].contains(operation), variant.powerSource == .wired { continue }
            if operation == .chargingRead, variant.powerSource == .replaceableBattery { continue }
            operations[operation] = OperationCapability(evidence: .catalogued, source: entry.source,
                failureReason: "Catalogued target; this exact endpoint, connection and operation have not been verified for transport.")
        }
        return DeviceCapabilities(battery: variant.powerSource == .wired || entry.kind.isReceiver ? .unsupported : .candidate,
            powerSource: variant.powerSource, operations: operations)
    }
}

/// Passive product knowledge. No name lookup, PID match or catalogue operation grants write authority.
public enum DeviceCatalog {
    public static func search(_ query: String) -> [DeviceCatalogEntry] {
        let key = normalized(query)
        guard !key.isEmpty else { return [] }
        return entries.filter { ([ $0.canonicalName, $0.matrixRow ] + $0.aliases).contains { normalized($0).contains(key) } }
    }
    public static func matchUSB(vendorID: UInt16, productID: UInt16) -> DeviceCatalogMatch? {
        let matches = entries.filter { $0.brand.vendorID == vendorID && $0.identityStatus == .catalogued }.flatMap { entry in
            entry.variants.filter { $0.usbProductID == productID && $0.connection != .bluetooth && $0.connection != .chargingOnlyUSB }.map { DeviceCatalogMatch(entry: entry, variant: $0) }
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
    private static let baseline = "docs/evidence/expansion-planning-baseline-2026-11-04.json; OpenRazer/Solaar snapshots; catalogue is not Mac transport evidence"
    private static func wired(_ pid: UInt16? = nil, sku: String? = nil) -> DeviceCatalogVariant { DeviceCatalogVariant(connection: .wiredUSB, usbProductID: pid, powerSource: .wired, sku: sku) }
    private static func wireless(_ pid: UInt16? = nil, power: PowerSource = .rechargeableBattery, connection: CatalogConnection = .usbReceiver, sku: String? = nil) -> DeviceCatalogVariant { DeviceCatalogVariant(connection: connection, usbProductID: pid, powerSource: power, sku: sku) }
    private static func charging(_ pid: UInt16? = nil) -> DeviceCatalogVariant { DeviceCatalogVariant(connection: .wiredUSB, usbProductID: pid, powerSource: .rechargeableBattery) }
    private static func bluetooth(_ power: PowerSource = .rechargeableBattery) -> DeviceCatalogVariant { DeviceCatalogVariant(connection: .bluetooth, powerSource: power) }
    private static func model(_ id: String, _ name: String, brand: CatalogBrand = .razer, row: String? = nil, aliases: [String] = [],
                              kind: CatalogDeviceKind = .mouse, variants: [DeviceCatalogVariant], status: CatalogIdentityStatus = .catalogued,
                              office: Bool = false, ceiling: Int? = nil, limitation: String) -> DeviceCatalogEntry {
        var operations: Set<DeviceOperation> = []
        if status != .identityUnconfirmed, !kind.isReceiver, variants.contains(where: { $0.powerSource != .wired }) { operations.formUnion([.batteryRead, .voltageRead]); if variants.contains(where: { $0.powerSource == .rechargeableBattery }) { operations.insert(.chargingRead) } }
        if kind == .mouse, status != .identityUnconfirmed {
            operations.formUnion([.dpiRead, .dpiWrite])
            if !office { operations.formUnion([.stagesRead, .stagesWrite, .pollingRateRead, .pollingRateWrite, .onboardRead, .onboardWrite, .onboardPersist]) }
        }
        return DeviceCatalogEntry(id: id, brand: brand, canonicalName: name, matrixRow: row ?? name, aliases: aliases, kind: kind,
            variants: variants, candidateOperations: operations, identityStatus: status,
            limitations: [limitation, "Candidate operations do not establish XY, 8K, persistent storage or firmware compatibility."], source: baseline,
            documentedPollingCeilingHz: ceiling)
    }
    public static let entries: [DeviceCatalogEntry] = [
        model("razer.deathadder-v3-hyperspeed", "DeathAdder V3 HyperSpeed", variants: [charging(0x00C4), wireless(0x00C5)], limitation: "Only 1532:00C5 battery/charging have existing Bazer hardware evidence; all settings and 00C4 remain unverified."),
        model("razer.deathadder-v3-pro", "DeathAdder V3 Pro", variants: [charging(0x00B6), wireless(0x00B7), charging(0x00C2), wireless(0x00C3)], limitation: "Original/alternate PID and firmware remain separate variants; HyperPolling support needs its own evidence."),
        model("razer.deathadder-v3-wired", "DeathAdder V3", row: "DeathAdder V3 有线 8K", aliases: ["DeathAdder V3 wired 8K"], variants: [wired(0x00B2)], limitation: "Wired without a battery. The 8K product name does not supply a supported settings list."),
        model("razer.deathadder-v2-pro", "DeathAdder V2 Pro", variants: [charging(0x007C), wireless(0x007D)], limitation: "Transaction ID, endpoint timing and storage require an independent transport profile."),
        model("razer.deathadder-v2-mini", "DeathAdder V2 Mini", variants: [wired(0x008C)], limitation: "Wired; never inherits V2 Pro battery or PID."),
        model("razer.deathadder-v4-hyperspeed", "DeathAdder V4 HyperSpeed", variants: [wireless(power: .unknown)], status: .identityUnconfirmed, limitation: "Product identity is unconfirmed. B007 is only a reference-project clue and is deliberately not assigned; no setting authorization."),
        model("razer.viper-v3-pro", "Viper V3 Pro", variants: [charging(0x00C0), wireless(0x00C1)], limitation: "Wired and wireless available rates, receiver and firmware must be verified separately."),
        model("razer.viper-v3-hyperspeed", "Viper V3 HyperSpeed", variants: [wireless(0x00B8, power: .replaceableBattery)], limitation: "Replaceable battery; no in-device USB charging claim. HyperSpeed does not imply 8K."),
        model("razer.viper-mini-signature", "Viper Mini Signature Edition", variants: [charging(0x009E), wireless(0x009F)], limitation: "Specific receiver and firmware are required before settings support can be promoted."),
        model("razer.viper-ultimate", "Viper Ultimate", variants: [charging(0x007A), wireless(0x007B)], limitation: "Mouse and charging dock identities are distinct."),
        model("razer.viper-8k", "Viper 8K", variants: [wired(0x0091)], limitation: "Wired without a battery; not a wireless Viper Ultimate variant."),
        model("razer.basilisk-v3-pro-35k", "Basilisk V3 Pro 35K", variants: [charging(0x00CC), wireless(0x00CD)], limitation: "Wired/wireless profiles and receiver rates require separate evidence."),
        model("razer.basilisk-v3-pro-35k-phantom", "Basilisk V3 Pro 35K Phantom Green Edition", row: "Basilisk V3 Pro 35K 幻影绿", aliases: ["Basilisk V3 Pro 35K 幻影绿"], variants: [charging(0x00D6), wireless(0x00D7)], limitation: "Keeps its own upstream PIDs and firmware identity; not a display-only alias."),
        model("razer.basilisk-v3-35k", "Basilisk V3 35K", variants: [wired(0x00CB)], limitation: "Wired without battery; never mapped to DeathAdder 00C4/00C5."),
        model("razer.basilisk-v3-pro", "Basilisk V3 Pro", variants: [charging(0x00AA), wireless(0x00AB)], limitation: "Distinct from the 35K revision; rates depend on the receiver."),
        model("razer.basilisk-ultimate", "Basilisk Ultimate", variants: [charging(0x0086), wireless(0x0088)], limitation: "Mouse and dock are separate identities."),
        model("razer.basilisk-x-hyperspeed", "Basilisk X HyperSpeed", variants: [wireless(0x0083, power: .replaceableBattery), bluetooth(.replaceableBattery)], limitation: "Replaceable battery, no in-device charging; USB receiver and Bluetooth require separate validation."),
        model("razer.naga-v2-pro", "Naga V2 Pro", variants: [charging(0x00A7), wireless(0x00A8)], limitation: "Side-button layout and key mapping are outside this implementation."),
        model("razer.naga-pro", "Naga Pro", variants: [charging(0x008F), wireless(0x0090)], limitation: "Does not share identity with Naga V2 Pro."),
        model("razer.cobra-pro", "Cobra Pro", variants: [charging(0x00AF), wireless(0x00B0)], limitation: "High report rates require the exact connection, receiver and firmware evidence."),
        model("razer.orochi-v2", "Orochi V2", variants: [wireless(0x0094, power: .replaceableBattery), DeviceCatalogVariant(connection: .bluetooth, usbProductID: 0x0095, powerSource: .replaceableBattery)], limitation: "Replaceable battery; USB and Bluetooth are distinct paths. A Bluetooth PID never authorizes USB transport."),
        model("razer.atheris", "Atheris", variants: [wireless(0x0062, power: .replaceableBattery), bluetooth(.replaceableBattery)], limitation: "Replaceable battery; legacy timing and DPI range are not copied from modern flagship profiles."),
        model("razer.mouse-dock-pro", "Mouse Dock Pro", kind: .dock, variants: [DeviceCatalogVariant(connection: .usbReceiver, powerSource: .wired)], limitation: "Dock is not a battery-powered mouse; PID is unassigned until authoritative identity evidence is available."),
        model("razer.hyperpolling-dongle", "HyperPolling Wireless Dongle", row: "HyperPolling Wireless Dongle（覆盖配套连接）", kind: .receiver, variants: [DeviceCatalogVariant(connection: .hyperPolling, usbProductID: 0x00B3, powerSource: .wired)], limitation: "00B3 identifies the receiver only; no paired mouse model, battery or 8K write is inferred."),
        model("logitech.pro-wireless", "PRO Wireless", brand: .logitech, row: "PRO Wireless / GPW 一代", aliases: ["G PRO Wireless", "GPW1", "GPW 一代"], variants: [charging(), wireless(connection: .lightspeed)], ceiling: 1000, limitation: "User has a GPW1 USB receiver. C539/4079/C088 remain unassigned candidate clues until runtime identity/feature discovery."),
        model("logitech.pro-x-superlight", "PRO X SUPERLIGHT", brand: .logitech, row: "PRO X SUPERLIGHT / 一代 SUPERLIGHT", aliases: ["一代 SUPERLIGHT"], variants: [charging(), wireless(connection: .lightspeed)], limitation: "Never inherits SUPERLIGHT 2 capabilities."),
        model("logitech.pro-x-superlight-2", "PRO X SUPERLIGHT 2", brand: .logitech, variants: [charging(), wireless(connection: .lightspeed)], limitation: "2202/8061 and 8K remain conditional on actual firmware, receiver and feature versions."),
        model("logitech.pro-x-superlight-2-dex", "PRO X SUPERLIGHT 2 DEX", brand: .logitech, variants: [charging(), wireless(connection: .lightspeed)], limitation: "Independent identity and onboard format, not an appearance alias."),
        model("logitech.pro-x-superlight-2c", "PRO X SUPERLIGHT 2c", brand: .logitech, variants: [charging(), wireless(connection: .lightspeed)], limitation: "Independent SKU and firmware matrix; no PID is guessed."),
        model("logitech.pro-x2-superstrike", "PRO X2 SUPERSTRIKE", brand: .logitech, aliases: ["SUPERSTRIKE"], variants: [charging(), wireless(connection: .lightspeed)], limitation: "Canonical X2 name. HITS, trigger points and haptics are outside scope; X3 is not accepted as a product identity."),
        model("logitech.pro-2-lightspeed", "PRO 2 LIGHTSPEED", brand: .logitech, variants: [charging(), wireless(connection: .lightspeed)], limitation: "No GPW generation alias grants 8K or an unobserved feature."),
        model("logitech.g502-lightspeed", "G502 LIGHTSPEED", brand: .logitech, variants: [charging(0xC08D), wireless(connection: .lightspeed)], limitation: "Upstream USB product identity only; distinct from wired HERO and Spectrum."),
        model("logitech.g502-hero", "G502 HERO", brand: .logitech, variants: [wired()], limitation: "Wired without battery. SE HERO PID is not borrowed for every HERO SKU."),
        model("logitech.g502-spectrum", "G502 Proteus Spectrum", brand: .logitech, variants: [wired(0xC332)], limitation: "Own upstream PID; protocol and onboard format do not inherit HERO feature versions."),
        model("logitech.g309-lightspeed", "G309 LIGHTSPEED", brand: .logitech, variants: [wireless(power: .replaceableBattery, connection: .lightspeed, sku: "AA mode"), wireless(power: .wired, connection: .lightspeed, sku: "external power mode")], limitation: "AA and externally powered modes differ; no USB charging is inferred."),
        model("logitech.g703", "G703", brand: .logitech, variants: [charging(), wireless(connection: .lightspeed)], limitation: "Sensor revision, receiver and firmware remain separate evidence dimensions."),
        model("logitech.g903", "G903", brand: .logitech, variants: [charging(), wireless(connection: .lightspeed)], limitation: "Product revision, receiver and firmware must be identified."),
        model("logitech.g604", "G604", brand: .logitech, variants: [wireless(power: .replaceableBattery, connection: .lightspeed), bluetooth(.replaceableBattery)], limitation: "Replaceable battery, no in-device charging; Bluetooth is not covered by LIGHTSPEED evidence."),
        model("logitech.g603", "G603", brand: .logitech, variants: [wireless(power: .replaceableBattery, connection: .lightspeed), bluetooth(.replaceableBattery)], limitation: "Replaceable battery; mode switches may affect available report rates."),
        model("logitech.g203", "G203", brand: .logitech, variants: [wired()], limitation: "Wired without battery; exact hardware revision remains to be identified."),
        model("logitech.g102", "G102", brand: .logitech, variants: [wired()], limitation: "Wired without battery; region naming alone does not merge G203 identity."),
        model("logitech.mx-master-3", "MX Master 3", brand: .logitech, variants: [wireless(connection: .unifying), bluetooth()], office: true, limitation: "Unifying/Bluetooth office device; no gaming onboard profile or LIGHTSPEED assumption."),
        model("logitech.mx-master-3s", "MX Master 3S", brand: .logitech, variants: [wireless(connection: .bolt), bluetooth()], office: true, limitation: "Specific Bolt/Bluetooth SKU required; no gaming report-rate or stage editor by default."),
        model("logitech.mx-anywhere-3", "MX Anywhere 3", brand: .logitech, variants: [wireless(connection: .unifying), bluetooth()], office: true, limitation: "Receiver variant must be observed; a charging cable is not a USB HID data target."),
        model("logitech.g913", "G913", brand: .logitech, kind: .keyboard, variants: [wireless(connection: .lightspeed)], limitation: "G915 family/region relationship requires identity evidence; no mouse DPI or keyboard scan-rate settings."),
        model("logitech.g913-tkl", "G913 TKL", brand: .logitech, kind: .keyboard, variants: [wireless(connection: .lightspeed)], limitation: "Separate from full-size G913; battery reads never switch host/onboard mode."),
        model("logitech.g915-x", "G915 X", brand: .logitech, kind: .keyboard, variants: [wired(sku: "wired SKU"), wireless(connection: .lightspeed, sku: "LIGHTSPEED SKU")], limitation: "Wired and LIGHTSPEED SKUs and dimensions remain distinct; series name cannot prove a battery."),
        model("logitech.g515-tkl", "G515 TKL", brand: .logitech, kind: .keyboard, variants: [wired(sku: "wired SKU"), wireless(connection: .lightspeed, sku: "LIGHTSPEED SKU")], limitation: "Wired and wireless SKUs have different power applicability; no inferred mouse controls."),
        model("logitech.pro-x-60", "G PRO X 60", brand: .logitech, kind: .keyboard, variants: [wireless(connection: .lightspeed)], limitation: "Telemetry only; preserves existing keyboard input and configuration."),
        model("logitech.mx-keys", "MX Keys", brand: .logitech, kind: .keyboard, variants: [wireless(connection: .unifying, sku: "Unifying revision"), wireless(connection: .bolt, sku: "Bolt revision"), bluetooth()], limitation: "Actual product revision selects Unifying/Bolt/Bluetooth; charging-only cable is not HID data."),
        model("logitech.mx-keys-mini", "MX Keys Mini", brand: .logitech, kind: .keyboard, variants: [wireless(connection: .bolt), bluetooth()], limitation: "Bolt and Bluetooth paths separate; charging cable never becomes a queryable USB keyboard by name."),
        model("logitech.g733", "G733", brand: .logitech, kind: .headset, variants: [wireless(0x0AB5)], limitation: "Upstream USB identity only; audio and HID collections separated, no audio capture or generic ADC curve."),
        model("logitech.g533", "G533", brand: .logitech, kind: .headset, variants: [wireless(0x0A66)], limitation: "Independent headset profile; does not borrow G733 commands or voltage curves."),
        model("logitech.g435", "G435", brand: .logitech, kind: .headset, variants: [wireless(power: .unknown), bluetooth(.unknown)], limitation: "Telemetry interface/protocol is unknown; Logitech branding does not establish HID++ battery support."),
        model("logitech.g935", "G935", brand: .logitech, kind: .headset, variants: [wireless(0x0A87)], limitation: "Independent upstream headset identity; no invented percentage when only voltage is reported.")
    ]
}
