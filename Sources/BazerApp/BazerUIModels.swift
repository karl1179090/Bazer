// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import Foundation

// MARK: - Unified Home Device Target & Navigation Route (Spec §2 & §12)

enum HomeDeviceTarget: Hashable, Codable, Sendable, Identifiable {
    case logical(LogicalDeviceID)
    case physical(PhysicalDeviceID)
    case bluetoothAudio(BluetoothAudioDeviceID)

    var id: String {
        switch self {
        case .logical(let id): return "logical:\(id.rawValue)"
        case .physical(let id): return "physical:\(id.rawValue)"
        case .bluetoothAudio(let id): return "bluetooth-audio:\(id.rawValue)"
        }
    }
}

enum BazerSettingsOrigin: Equatable, Sendable {
    case home
    case device(HomeDeviceTarget)
}

enum BazerRoute: Equatable, Sendable {
    case home
    case device(HomeDeviceTarget)
    case settings(origin: BazerSettingsOrigin)

    var isHome: Bool {
        if case .home = self { return true }
        return false
    }

    var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }
}

enum RouteTransitionDirection: Equatable, Sendable {
    case none
    case forwardHorizontal   // Home -> Detail
    case backwardHorizontal  // Detail -> Home
    case enterVertical       // -> Settings
    case exitVertical        // Settings -> Origin / Home
}

// MARK: - Overlay Definitions (Spec §2.1, §5, §6, §7)

enum QuickPresetTab: String, CaseIterable, Equatable, Sendable {
    case dpi
    case pollingRate

    var title: String {
        switch self {
        case .dpi: return "DPI"
        case .pollingRate: return "回报率"
        }
    }
}

enum OnboardEditableField: Equatable, Sendable {
    case activeProfile
    case defaultDPI

    var title: String {
        switch self {
        case .activeProfile: return "选择板载配置"
        case .defaultDPI: return "选择板载默认 DPI"
        }
    }
}

struct RestorePreviewItem: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let currentValue: String
    let backupValue: String
    var isChanged: Bool { currentValue != backupValue }
}

struct RestorePreviewModel: Equatable, Sendable {
    let deviceID: LogicalDeviceID
    let deviceName: String
    let backupFileName: String
    let backupCapturedAt: Date
    let formatSummary: String
    let rollbackURL: URL
    let request: SettingChangeRequest
    let items: [RestorePreviewItem]
}

enum BazerOverlay: Equatable, Sendable {
    case quickPresetEditor(deviceID: LogicalDeviceID, initialTab: QuickPresetTab)
    case onboardFieldPicker(deviceID: LogicalDeviceID, field: OnboardEditableField)
    case restorePreview(deviceID: LogicalDeviceID, preview: RestorePreviewModel)
    case primaryDevicePicker
}

// MARK: - Home Fold Undo Banner State (Spec §3.1)

struct FoldUndoBannerState: Equatable, Sendable {
    let id: UUID
    var target: HomeDeviceTarget
    let deviceName: String
    let wasFolded: Bool
    let isSessionOnly: Bool

    init(target: HomeDeviceTarget, deviceName: String, wasFolded: Bool, isSessionOnly: Bool) {
        self.id = UUID()
        self.target = target
        self.deviceName = deviceName
        self.wasFolded = wasFolded
        self.isSessionOnly = isSessionOnly
    }

    var message: String {
        let base = wasFolded ? "已折叠 \(deviceName)" : "已恢复 \(deviceName)"
        return isSessionOnly ? "\(base)（本次连接有效）" : base
    }
}

// MARK: - Parameter Switching & Onboard Transaction State (Spec §4.2, §4.3, §6.2)

enum OnboardSavePhase: String, Equatable, Sendable {
    case backingUp
    case writing
    case verifying

    var buttonTitle: String {
        switch self {
        case .backingUp: return "正在备份…"
        case .writing: return "正在写入…"
        case .verifying: return "正在核对…"
        }
    }
}

enum PendingParameterKind: Equatable, Sendable {
    case dpi(DPISetting)
    case pollingRate(Int)
    case onboardSave(OnboardSavePhase)
    case restoreBackup(OnboardSavePhase)
}

struct PendingParameterSwitch: Equatable, Sendable {
    let sessionID: LogicalDeviceSessionID
    var kind: PendingParameterKind
    let startedAt: Date
}

// MARK: - Quick Preset Editor Draft & Validation (Spec §5.1 & §5.2)

struct QuickPresetRowDraft: Equatable, Identifiable, Sendable {
    let id: UUID
    var rawText: String

    init(id: UUID = UUID(), rawText: String) {
        self.id = id
        self.rawText = rawText
    }

    mutating func normalizeWhitespace() {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2 {
                rawText = "\(parts[0])/\(parts[1])"
                return
            }
        }
        rawText = trimmed
    }

    static func formatDPI(_ dpi: DPISetting) -> String {
        dpi.x == dpi.y ? "\(dpi.x)" : "\(dpi.x)/\(dpi.y)"
    }
}

struct QuickPresetRowValidation: Equatable, Sendable {
    let rowID: UUID
    let error: String?
}

struct QuickPresetModalDraft: Equatable, Sendable {
    static let minCount = 1
    static let maxCount = 8

    var activeTab: QuickPresetTab
    var dpiRows: [QuickPresetRowDraft]
    var rateRows: [QuickPresetRowDraft]
    var saveError: String?

    init(activeTab: QuickPresetTab = .dpi, dpiPresets: [DPISetting], ratePresets: [Int]) {
        self.activeTab = activeTab
        self.dpiRows = (dpiPresets.isEmpty ? [DPISetting(800)] : Array(dpiPresets.prefix(Self.maxCount))).map {
            QuickPresetRowDraft(rawText: QuickPresetRowDraft.formatDPI($0))
        }
        self.rateRows = (ratePresets.isEmpty ? [1000] : Array(ratePresets.prefix(Self.maxCount))).map {
            QuickPresetRowDraft(rawText: String($0))
        }
        self.saveError = nil
    }

    var canAddDPIRow: Bool { dpiRows.count < Self.maxCount }
    var canRemoveDPIRow: Bool { dpiRows.count > Self.minCount }
    var canAddRateRow: Bool { rateRows.count < Self.maxCount }
    var canRemoveRateRow: Bool { rateRows.count > Self.minCount }

    mutating func addDPIRow(capabilities: DeviceCapabilities) {
        guard canAddDPIRow else { return }
        let existing = Set(dpiRows.compactMap { Self.parseDPI($0.rawText) }.map { Int($0.x) })
        let candidates = Self.suggestedDPICandidates(for: capabilities)
        let next = candidates.first(where: { !existing.contains($0) }) ?? 1600
        dpiRows.append(QuickPresetRowDraft(rawText: String(next)))
        saveError = nil
    }

    mutating func removeDPIRow(id: UUID) {
        guard canRemoveDPIRow else { return }
        dpiRows.removeAll { $0.id == id }
        saveError = nil
    }

    mutating func addRateRow(capabilities: DeviceCapabilities) {
        guard canAddRateRow else { return }
        let existing = Set(rateRows.compactMap { Self.parseRate($0.rawText) })
        let candidates = Self.suggestedRateCandidates(for: capabilities)
        let next = candidates.first(where: { !existing.contains($0) }) ?? 1000
        rateRows.append(QuickPresetRowDraft(rawText: String(next)))
        saveError = nil
    }

    mutating func removeRateRow(id: UUID) {
        guard canRemoveRateRow else { return }
        rateRows.removeAll { $0.id == id }
        saveError = nil
    }

    static func parseDPI(_ raw: String) -> DPISetting? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2,
                  let x = UInt16(parts[0]),
                  let y = UInt16(parts[1]),
                  x > 0, y > 0 else { return nil }
            return DPISetting(x: x, y: y)
        }
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return DPISetting(value)
    }

    static func parseRate(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    static func effectiveDPIConstraints(_ capabilities: DeviceCapabilities) -> CapabilityConstraints? {
        for op in [DeviceOperation.dpiWrite, .stagesWrite, .dpiRead, .stagesRead] {
            let c = capabilities[op].constraints
            if c.hasNumericDomain || c.allowedDPIPairs != nil { return c }
        }
        return nil
    }

    static func effectiveRateConstraints(_ capabilities: DeviceCapabilities) -> CapabilityConstraints? {
        for op in [DeviceOperation.pollingRateWrite, .pollingRateRead] {
            let c = capabilities[op].constraints
            if c.hasNumericDomain { return c }
        }
        return nil
    }

    static func suggestedDPICandidates(for capabilities: DeviceCapabilities) -> [Int] {
        let defaults = [400, 800, 1200, 1600, 2400, 3200, 6400, 12800]
        guard let constraints = effectiveDPIConstraints(capabilities) else { return defaults }
        let filtered = defaults.filter { constraints.accepts($0) }
        return filtered.isEmpty ? (constraints.allowedValues.isEmpty ? defaults : constraints.allowedValues) : filtered
    }

    static func suggestedRateCandidates(for capabilities: DeviceCapabilities) -> [Int] {
        let defaults = [125, 250, 500, 1000]
        guard let constraints = effectiveRateConstraints(capabilities) else { return [125, 500, 1000] }
        if !constraints.allowedValues.isEmpty { return constraints.allowedValues }
        let filtered = defaults.filter { constraints.accepts($0) }
        return filtered.isEmpty ? [125, 500, 1000] : filtered
    }

    func validateDPIRows(capabilities: DeviceCapabilities) -> [UUID: String] {
        var errors: [UUID: String] = [:]
        var seen: [String: Int] = [:]
        for row in dpiRows {
            if let dpi = Self.parseDPI(row.rawText) {
                seen["\(dpi.x):\(dpi.y)", default: 0] += 1
            }
        }
        let constraints = Self.effectiveDPIConstraints(capabilities)
        let allowsXY = capabilities.permits(.independentXY) || (constraints?.allowedDPIPairs?.contains(where: { $0.x != $0.y }) == true)

        for row in dpiRows {
            guard let dpi = Self.parseDPI(row.rawText) else {
                errors[row.id] = "请输入有效的整数 DPI"
                continue
            }
            if dpi.x != dpi.y && !allowsXY {
                errors[row.id] = "当前设备不支持独立 X/Y DPI"
                continue
            }
            if (seen["\(dpi.x):\(dpi.y)"] ?? 0) > 1 {
                errors[row.id] = "与同组其它快捷选项重复"
                continue
            }
            if let constraints {
                if let pairs = constraints.allowedDPIPairs, !pairs.contains(dpi) {
                    let allowedText = pairs.map(QuickPresetRowDraft.formatDPI).joined(separator: "、")
                    errors[row.id] = "不在设备支持的组合中（\(allowedText)）"
                    continue
                }
                if !constraints.allowedValues.isEmpty {
                    if !constraints.allowedValues.contains(Int(dpi.x)) || !constraints.allowedValues.contains(Int(dpi.y)) {
                        let list = constraints.allowedValues.prefix(8).map(String.init).joined(separator: " / ")
                        errors[row.id] = "当前设备仅支持 \(list) DPI"
                        continue
                    }
                }
                if let min = constraints.minimum, let max = constraints.maximum {
                    if Int(dpi.x) < min || Int(dpi.x) > max || Int(dpi.y) < min || Int(dpi.y) > max {
                        errors[row.id] = "超出设备支持范围（\(min)–\(max) DPI）"
                        continue
                    }
                }
                if let step = constraints.step, step > 0 {
                    let min = constraints.minimum ?? 0
                    if (Int(dpi.x) - min) % step != 0 || (Int(dpi.y) - min) % step != 0 {
                        errors[row.id] = "需为步进 \(step) DPI 的整数倍"
                        continue
                    }
                }
            }
        }
        return errors
    }

    func validateRateRows(capabilities: DeviceCapabilities) -> [UUID: String] {
        var errors: [UUID: String] = [:]
        var seen: [Int: Int] = [:]
        for row in rateRows {
            if let rate = Self.parseRate(row.rawText) {
                seen[rate, default: 0] += 1
            }
        }
        let constraints = Self.effectiveRateConstraints(capabilities)

        for row in rateRows {
            guard let rate = Self.parseRate(row.rawText) else {
                errors[row.id] = "请输入有效的整数回报率"
                continue
            }
            if (seen[rate] ?? 0) > 1 {
                errors[row.id] = "与同组其它快捷选项重复"
                continue
            }
            if let constraints {
                if !constraints.allowedValues.isEmpty && !constraints.allowedValues.contains(rate) {
                    let list = constraints.allowedValues.map { "\($0) Hz" }.joined(separator: " / ")
                    errors[row.id] = "当前设备仅支持 \(list)"
                    continue
                }
                if !constraints.accepts(rate) {
                    errors[row.id] = "超出当前设备支持的回报率范围"
                    continue
                }
            }
        }
        return errors
    }

    var parsedDPIs: [DPISetting]? {
        let parsed = dpiRows.compactMap { Self.parseDPI($0.rawText) }
        guard parsed.count == dpiRows.count, (Self.minCount...Self.maxCount).contains(parsed.count) else { return nil }
        return parsed
    }

    var parsedRates: [Int]? {
        let parsed = rateRows.compactMap { Self.parseRate($0.rawText) }
        guard parsed.count == rateRows.count, (Self.minCount...Self.maxCount).contains(parsed.count) else { return nil }
        return parsed
    }

    func canSave(comparedTo savedDPI: [DPISetting], savedRates: [Int], capabilities: DeviceCapabilities) -> Bool {
        guard (Self.minCount...Self.maxCount).contains(dpiRows.count),
              (Self.minCount...Self.maxCount).contains(rateRows.count),
              validateDPIRows(capabilities: capabilities).isEmpty,
              validateRateRows(capabilities: capabilities).isEmpty,
              let dpis = parsedDPIs,
              let rates = parsedRates else {
            return false
        }
        return dpis != savedDPI || rates != savedRates
    }
}
