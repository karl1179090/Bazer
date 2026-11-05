// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import SwiftUI

/// A draft keeps the session and revision it was based on, so a later refresh or
/// reconnect cannot silently turn old edits into a write against new state.
struct DeviceSettingsDraft: Equatable {
    struct Stage: Equatable { var x: String; var y: String }
    let snapshot: DeviceSettingsSnapshot
    var dpiX: String
    var dpiY: String
    var rate: String
    var scope: SettingPersistence
    var stageValues: [UInt8: Stage]
    var tableActiveStage: String
    var defaultStage: String
    var currentStage: String
    var activeProfile: String
    init(_ snapshot: DeviceSettingsSnapshot, scope: SettingPersistence) {
        self.snapshot = snapshot; dpiX = snapshot.settings.currentDPI.map { String($0.x) } ?? ""
        dpiY = snapshot.settings.currentDPI.map { String($0.y) } ?? ""
        rate = snapshot.settings.pollingRateHz.map(String.init) ?? ""; self.scope = scope
        stageValues = Dictionary(uniqueKeysWithValues: (snapshot.settings.stages?.stages ?? []).map { ($0.id, Stage(x: String($0.dpi.x), y: String($0.dpi.y))) })
        tableActiveStage = snapshot.settings.stages.map { String($0.activeStageID) } ?? ""
        defaultStage = snapshot.settings.stages?.defaultStageID.map(String.init) ?? ""
        currentStage = snapshot.settings.currentStageID.map(String.init) ?? ""
        activeProfile = snapshot.settings.activeProfileID.map(String.init) ?? ""
    }
    func request(capabilities: DeviceCapabilities, scope requestedScope: SettingPersistence? = nil) -> SettingChangeRequest? {
        let actualScope = requestedScope ?? scope
        func enabled(_ operation: DeviceOperation) -> Bool { capabilities.permits(operation) && capabilities[operation].constraints.persistenceScopes.contains(actualScope) }
        var dpi: DPISetting?, hz: Int?, table: DPIStageTable?, selectedStage: UInt8?, profile: Int?
        if enabled(.dpiWrite), let x = UInt16(dpiX), let y = UInt16(dpiY), x > 0, y > 0 {
            let value = DPISetting(x: x, y: y)
            if value != snapshot.settings.currentDPI { dpi = value }
        } else if enabled(.dpiWrite), dpiX != (snapshot.settings.currentDPI.map { String($0.x) } ?? "") || dpiY != (snapshot.settings.currentDPI.map { String($0.y) } ?? "") { return nil }
        if enabled(.pollingRateWrite) {
            guard let value = Int(rate) else { return nil }
            if value != snapshot.settings.pollingRateHz { hz = value }
        }
        if enabled(.stagesWrite) {
            guard let original = snapshot.settings.stages, !original.stages.isEmpty, !original.opaqueBytes.isEmpty,
                  Set(stageValues.keys) == Set(original.stages.map(\.id)) else { return nil }
            var stages: [DPIStage] = []
            for item in original.stages {
                guard let text = stageValues[item.id], let x = UInt16(text.x), let y = UInt16(text.y), x > 0, y > 0 else { return nil }
                stages.append(DPIStage(id: item.id, dpi: DPISetting(x: x, y: y)))
            }
            let newTable: DPIStageTable
            if original.defaultStageID != nil {
                guard let id = UInt8(defaultStage), stages.contains(where: { $0.id == id }) else { return nil }
                newTable = DPIStageTable(stages: stages, activeStageID: original.activeStageID, opaqueBytes: original.opaqueBytes, defaultStageID: id)
            } else {
                guard let id = UInt8(tableActiveStage), stages.contains(where: { $0.id == id }) else { return nil }
                newTable = DPIStageTable(stages: stages, activeStageID: id, opaqueBytes: original.opaqueBytes)
            }
            if newTable != original { table = newTable }
        }
        if enabled(.stageSelect) {
            guard snapshot.settings.currentStageID != nil, let id = UInt8(currentStage) else { return nil }
            if id != snapshot.settings.currentStageID { selectedStage = id }
        }
        if enabled(.onboardWrite) {
            guard snapshot.settings.activeProfileID != nil, let id = Int(activeProfile), id >= 0 else { return nil }
            if id != snapshot.settings.activeProfileID { profile = id }
        }
        let change = DeviceSettingsChange(currentDPI: dpi, pollingRateHz: hz, stages: table, activeProfileID: profile, persistence: actualScope, currentStageID: selectedStage)
        guard change.validate(capabilities: capabilities).isEmpty else { return nil }
        return SettingChangeRequest(target: snapshot.session, expectedRevision: snapshot.revision, change: change)
    }
}

enum DeviceSettingsPresentation {
    static func exactDPIPairsText(_ capabilities: DeviceCapabilities) -> String? {
        guard let pairs = capabilities[.dpiWrite].constraints.allowedDPIPairs,
              pairs.contains(where: { $0.x != $0.y }) else { return nil }
        return "已验证 X/Y 组合：" + pairs.map { "\($0.x)/\($0.y)" }.joined(separator: "、")
    }
    static func onboardActionTitle(_ capabilities: DeviceCapabilities) -> String {
        capabilities[.onboardPersist].evidence == .writeVerified ? "写入设备" : "保存到板载"
    }
    static func persistenceText(_ result: SettingChangeResult, capabilities: DeviceCapabilities) -> String {
        if result.persistence == .runtime { return "本次应用范围：当前运行状态。" }
        if result.persistence == .unknown {
            return result.status == .verified ? "已读回当前值；本值的断电保持尚未确认。" : "保存范围尚未确认。"
        }
        if capabilities[.onboardPersist].evidence == .writeVerified {
            return "该值组合已有断电保持实测证据；本次写入结果以独立读回为准。"
        }
        return "应用范围：设备板载配置。断电保持仍需单独确认。"
    }
}

// MARK: - Redesigned Interactive Settings Sections (Spec §4, §5, §6)

struct DeviceSettingsView: View {
    @ObservedObject var model: AppModel
    let device: LogicalDeviceState
    @Environment(\.bazerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bazerFocusCoordinator) private var focusCoordinator
    private enum PresetFocus: Hashable { case dpi(Int), rate(Int) }
    @FocusState private var focusedPreset: PresetFocus?

    private var busy: Bool {
        model.settingsBusy.contains(device.id) || device.isReadingSettings
    }
    private var isDisconnected: Bool {
        device.hostPresence == .removed || device.peerPresence == .unreachable
    }
    private var isWriteLocked: Bool {
        busy || isDisconnected || model.isTerminating || model.snapshot.isSuspended || model.requiresReadbackCheck.contains(device.id)
    }
    private var dpiPresets: [DPISetting] {
        model.dpiPresets(for: device)
    }
    private var ratePresets: [Int] {
        model.pollingRatePresets(for: device)
    }
    private var currentDraft: DeviceSettingsDraft? {
        model.onboardDraft(for: device)
    }
    private var onboardRequest: SettingChangeRequest? {
        guard let draft = currentDraft,
              draft.snapshot.session == device.sessionID,
              draft.snapshot.revision == device.settings?.revision else { return nil }
        let scope: SettingPersistence = device.capabilities.permits(.onboardPersist) ? .onboard : .runtime
        return draft.request(capabilities: device.capabilities, scope: scope)
    }
    private var onboardChangeCount: Int {
        onboardRequest?.change.fields.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusAndResultBanners
            dpiCard
            pollingRateCard
            onboardCard
        }
        .background(BazerKeyEventBridge(isEnabled: model.activeOverlay == nil && !model.isPresentingNativeModal, onKey: handlePresetKey))
        .onChange(of: model.activeOverlay) { if $0 != nil { focusedPreset = nil } }
    }

    private func handlePresetKey(_ input: BazerKeyInput) -> Bool {
        guard model.activeOverlay == nil, !model.isPresentingNativeModal,
              case .device(let target) = model.route,
              model.associatedLogicalDevice(for: target)?.sessionID == device.sessionID,
              let focusedPreset else { return false }
        let index: Int
        let count: Int
        let canActivate: Bool
        switch focusedPreset {
        case .dpi(let value):
            index = value; count = dpiPresets.count
            canActivate = !isWriteLocked && model.canWriteDPI(for: device) && device.settings != nil
        case .rate(let value):
            index = value; count = ratePresets.count
            canActivate = !isWriteLocked && model.canWritePollingRate(for: device) && device.settings != nil
        }
        switch PresetKeyboardInteraction.effect(input: input, focusedIndex: index, count: count, canActivate: canActivate) {
        case .unhandled: return false
        case .consumed: return true
        case .moveFocus(let next):
            self.focusedPreset = { if case .dpi = focusedPreset { return .dpi(next) }; return .rate(next) }()
        case .activate(let candidate):
            switch focusedPreset {
            case .dpi: model.selectDPIPreset(dpiPresets[candidate], for: device)
            case .rate: model.selectPollingRatePreset(ratePresets[candidate], for: device)
            }
        }
        return true
    }

    // MARK: - 1. DPI Single-Select Radio Group Card (Spec §4.2)

    private var dpiCard: some View {
        let confirmedDPI = device.settings?.settings.currentDPI
        let presets = dpiPresets
        let isOutOfPreset = confirmedDPI.map { !presets.contains($0) } ?? false

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("DPI")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    focusCoordinator?.remember(.presets(device.id, .dpi))
                    model.openQuickPresetEditor(for: device, tab: .dpi)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("编辑选项")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .bazerRestorableFocus(.presets(device.id, .dpi))
                .disabled(isDisconnected || model.isTerminating)
                .accessibilityLabel("编辑 DPI 快捷选项")
            }

            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(2, max(1, presets.count)))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                    let isConfirmed = confirmedDPI == preset
                    let isPending: Bool = {
                        if case .dpi(let target) = model.pendingParameterSwitches[device.id]?.kind {
                            return target == preset
                        }
                        return false
                    }()
                    let isHighlighted = isConfirmed || isPending
                    let isCandidateFocused = focusedPreset == .dpi(index)

                    Button {
                        focusedPreset = .dpi(index)
                        model.selectDPIPreset(preset, for: device)
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 4) {
                                BazerRadioIndicator(
                                    state: isConfirmed ? .confirmed : (isPending ? .pending : .unselected)
                                )
                                if isPending {
                                    BazerDelayedProgressView(isActive: true)
                                }
                            }
                            Text(QuickPresetRowDraft.formatDPI(preset))
                                .font(.system(size: 13.5, weight: isHighlighted ? .bold : .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isHighlighted ? palette.accentText : palette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if isPending {
                                Text("正在切换")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(palette.accentText)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .background(
                            isHighlighted ? palette.accentSoftBackground : palette.cardBackground,
                            in: RoundedRectangle(cornerRadius: 11)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .strokeBorder(
                                    isCandidateFocused ? palette.focusRing : (isHighlighted ? palette.accentSoftBorder : palette.cardBorder),
                                    lineWidth: isHighlighted || isCandidateFocused ? 1.5 : 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(BazerCardButtonStyle())
                    .focusable()
                    .focused($focusedPreset, equals: .dpi(index))
                    .disabled(isWriteLocked || !model.canWriteDPI(for: device) || device.settings == nil)
                    .accessibilityLabel("\(QuickPresetRowDraft.formatDPI(preset)) DPI，\(isConfirmed ? "当前已选" : (isPending ? "正在切换" : "点击切换"))")
                }
            }

            if isOutOfPreset, let actual = confirmedDPI {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.accentText)
                    Text("当前：\( actual.x == actual.y ? "\(actual.x) DPI" : "X \(actual.x) / Y \(actual.y)" )（不在快捷选项中）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            if let exactPairs = DeviceSettingsPresentation.exactDPIPairsText(device.capabilities) {
                Text(exactPairs)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }

            Text(dpiScopeCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(14)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }

    private var dpiScopeCaption: String {
        if isDisconnected { return "设备连接已断开，当前不可修改 DPI" }
        if device.descriptor.isIdentityAmbiguous { return "设备身份存在歧义，当前仅提供只读展示" }
        if device.settings == nil { return "读取设备当前设置后可切换 DPI" }
        guard let scope = model.dpiWriteScope(for: device) else {
            return "此设备的 DPI 写入尚待实机验证，当前仅提供只读"
        }
        switch scope {
        case .runtime:
            return "点击选项立即切换"
        case .onboard:
            return "点击选项立即切换 · 切换时写入板载并自动备份"
        case .unknown:
            return "点击选项立即切换"
        }
    }

    // MARK: - 2. Polling Rate Single-Select Radio Group Card (Spec §4.2)

    private var pollingRateCard: some View {
        let confirmedHz = device.settings?.settings.pollingRateHz
        let presets = ratePresets
        let isOutOfPreset = confirmedHz.map { !presets.contains($0) } ?? false

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("回报率")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    focusCoordinator?.remember(.presets(device.id, .pollingRate))
                    model.openQuickPresetEditor(for: device, tab: .pollingRate)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("编辑选项")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .bazerRestorableFocus(.presets(device.id, .pollingRate))
                .disabled(isDisconnected || model.isTerminating)
                .accessibilityLabel("编辑回报率快捷选项")
            }

            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(2, max(1, presets.count)))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, hz in
                    let isConfirmed = confirmedHz == hz
                    let isPending: Bool = {
                        if case .pollingRate(let target) = model.pendingParameterSwitches[device.id]?.kind {
                            return target == hz
                        }
                        return false
                    }()
                    let isHighlighted = isConfirmed || isPending
                    let isCandidateFocused = focusedPreset == .rate(index)

                    Button {
                        focusedPreset = .rate(index)
                        model.selectPollingRatePreset(hz, for: device)
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 4) {
                                BazerRadioIndicator(
                                    state: isConfirmed ? .confirmed : (isPending ? .pending : .unselected)
                                )
                                if isPending {
                                    BazerDelayedProgressView(isActive: true)
                                }
                            }
                            Text("\(hz) Hz")
                                .font(.system(size: 13.5, weight: isHighlighted ? .bold : .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isHighlighted ? palette.accentText : palette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if isPending {
                                Text("正在切换")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(palette.accentText)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .background(
                            isHighlighted ? palette.accentSoftBackground : palette.cardBackground,
                            in: RoundedRectangle(cornerRadius: 11)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .strokeBorder(
                                    isCandidateFocused ? palette.focusRing : (isHighlighted ? palette.accentSoftBorder : palette.cardBorder),
                                    lineWidth: isHighlighted || isCandidateFocused ? 1.5 : 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(BazerCardButtonStyle())
                    .focusable()
                    .focused($focusedPreset, equals: .rate(index))
                    .disabled(isWriteLocked || !model.canWritePollingRate(for: device) || device.settings == nil)
                    .accessibilityLabel("\(hz) Hz，\(isConfirmed ? "当前已选" : (isPending ? "正在切换" : "点击切换"))")
                }
            }

            if isOutOfPreset, let actualHz = confirmedHz {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.accentText)
                    Text("当前：\(actualHz) Hz（不在快捷选项中）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            Text(pollingRateScopeCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textSecondary)
        }
        .padding(14)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }

    private var pollingRateScopeCaption: String {
        if isDisconnected { return "设备连接已断开，当前不可修改回报率" }
        if device.descriptor.isIdentityAmbiguous { return "设备身份存在歧义，当前仅提供只读展示" }
        if device.settings == nil { return "读取设备当前设置后可切换回报率" }
        guard let scope = model.pollingRateWriteScope(for: device) else {
            return "选项可按设备支持范围调整 · 当前设备回报率只读"
        }
        switch scope {
        case .runtime:
            return "选项可按设备支持范围调整"
        case .onboard:
            return "选项可按设备支持范围调整 · 切换时写入板载并自动备份"
        case .unknown:
            return "选项可按设备支持范围调整"
        }
    }

    // MARK: - 3. Onboard Configuration, Backup & Restore Card (Spec §6)

    private var onboardCard: some View {
        let canEditProfile = !isDisconnected && !device.descriptor.isIdentityAmbiguous && device.capabilities.permits(.onboardWrite) && device.settings?.settings.activeProfileID != nil
        let canEditDefaultDPI = !isDisconnected && !device.descriptor.isIdentityAmbiguous && device.settings != nil && (
            (device.capabilities.permits(.stagesWrite) && device.settings?.settings.stages?.stages.isEmpty == false)
            || device.capabilities.permits(.dpiWrite)
        )
        let profileModified = currentDraft.map { draft in
            draft.activeProfile != (device.settings?.settings.activeProfileID.map(String.init) ?? "")
        } ?? false
        let defaultDPIModified = currentDraft.map { draft in
            let origDefault = device.settings?.settings.stages?.defaultStageID.map(String.init) ?? ""
            let origActive = device.settings?.settings.stages.map { String($0.activeStageID) } ?? ""
            let origDPI = device.settings?.settings.currentDPI
            let stagesChanged = draft.stageValues != Dictionary(uniqueKeysWithValues: (device.settings?.settings.stages?.stages ?? []).map { ($0.id, DeviceSettingsDraft.Stage(x: String($0.dpi.x), y: String($0.dpi.y))) })
            return draft.defaultStage != origDefault || draft.tableActiveStage != origActive || stagesChanged || (origDPI.map { draft.dpiX != String($0.x) || draft.dpiY != String($0.y) } ?? false)
        } ?? false
        let canSaveBoard = onboardRequest != nil && !isWriteLocked

        return VStack(alignment: .leading, spacing: 11) {
            // Card + Save / Backup / Restore
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text("板载配置")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Spacer()
                    onboardStatusBadge
                }
                .padding(.bottom, 10)

                Divider().overlay(palette.divider)

                // Row 1: 当前配置 / 目标配置
                Button {
                    if canEditProfile {
                        focusCoordinator?.remember(.onboard(device.id, .activeProfile))
                        model.activeOverlay = .onboardFieldPicker(deviceID: device.id, field: .activeProfile)
                    }
                } label: {
                    HStack {
                        Text(profileModified ? "目标配置（未保存）" : "当前配置")
                            .font(.system(size: 13))
                            .foregroundStyle(profileModified ? palette.accentText : palette.textSecondary)
                        Spacer()
                        Text(profileValueText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        if canEditProfile {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .bazerRestorableFocus(.onboard(device.id, .activeProfile))
                .disabled(!canEditProfile || isWriteLocked)

                Divider().overlay(palette.divider)

                // Row 2: 默认 DPI
                Button {
                    if canEditDefaultDPI {
                        focusCoordinator?.remember(.onboard(device.id, .defaultDPI))
                        model.activeOverlay = .onboardFieldPicker(deviceID: device.id, field: .defaultDPI)
                    }
                } label: {
                    HStack {
                        Text(defaultDPIModified ? "默认 DPI（未保存）" : "默认 DPI")
                            .font(.system(size: 13))
                            .foregroundStyle(defaultDPIModified ? palette.accentText : palette.textSecondary)
                        Spacer()
                        Text(defaultDPIValueText)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                        if canEditDefaultDPI {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .bazerRestorableFocus(.onboard(device.id, .defaultDPI))
                .disabled(!canEditDefaultDPI || isWriteLocked)
            }
            .padding(14)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )

            // Primary Board Action Button: 保存到设备 (Spec §6.2)
            Button {
                model.saveOnboardDraft(for: device)
            } label: {
                HStack(spacing: 7) {
                    if case .onboardSave = model.pendingParameterSwitches[device.id]?.kind {
                        BazerDelayedProgressView(isActive: true)
                    } else {
                        Image(systemName: "cpu")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(onboardSaveButtonTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(canSaveBoard ? palette.accentText : palette.accentText.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    canSaveBoard ? palette.accentSoftBackground : palette.cardBackground,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            canSaveBoard ? palette.accentSoftBorder : palette.accentSoftBorder.opacity(0.45),
                            lineWidth: 1.25
                        )
                )
            }
            .buttonStyle(BazerCardButtonStyle())
            .disabled(!canSaveBoard)
            .accessibilityLabel(onboardSaveButtonTitle)

            // Secondary Backup & Restore Buttons (Spec §6.3)
            let canBackupOrRestore = !isDisconnected && !device.descriptor.isIdentityAmbiguous && !isWriteLocked && device.capabilities.canReadSettings
            HStack(spacing: 10) {
                Button {
                    model.exportBackupByUser(for: device)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("备份配置")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(canBackupOrRestore ? palette.textPrimary : palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(palette.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(BazerCardButtonStyle())
                .disabled(!canBackupOrRestore)

                Button {
                    focusCoordinator?.remember(.restore(device.id))
                    model.beginRestoreBackupByUser(for: device)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("恢复备份")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(canBackupOrRestore ? palette.textPrimary : palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(palette.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(BazerCardButtonStyle())
                .bazerRestorableFocus(.restore(device.id))
                .disabled(!canBackupOrRestore)
            }

            // Backup file feedback + "在 Finder 中显示" (Spec §6.3)
            if let exportedURL = model.exportedBackupURLs[device.id] {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.accent)
                    Text("已备份：\(exportedURL.lastPathComponent)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button("在 Finder 中显示") {
                        model.revealBackupInFinder(for: device.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.accentText)
                }
                .padding(.horizontal, 4)
            } else if let autoBackupPath = model.settingsBackupPaths[device.id] {
                HStack(spacing: 6) {
                    Text("最近自动备份：\(URL(fileURLWithPath: autoBackupPath).lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("在 Finder 中显示") {
                        model.revealBackupInFinder(for: device.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.accentText)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private var onboardStatusBadge: some View {
        if onboardChangeCount > 0 {
            Text("未保存 · \(onboardChangeCount) 项")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(palette.accentSoftBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(palette.accentSoftBorder.opacity(0.6), lineWidth: 1)
                )
        } else if device.settings != nil && !isDisconnected {
            Text("已同步")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(palette.accentSoftBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(palette.accentSoftBorder.opacity(0.5), lineWidth: 1)
                )
        } else {
            Text(isDisconnected ? "已断开" : "待读取")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var profileValueText: String {
        if let draft = currentDraft, !draft.activeProfile.isEmpty {
            return "配置 \(draft.activeProfile)"
        }
        if let profile = device.settings?.settings.activeProfileID {
            return "配置 \(profile)"
        }
        if device.settings != nil, device.capabilities.permits(.onboardPersist) {
            return "板载槽位 1"
        }
        return "--"
    }

    private var defaultDPIValueText: String {
        if let draft = currentDraft, let table = device.settings?.settings.stages, !table.stages.isEmpty {
            let targetIDStr = table.defaultStageID != nil ? draft.defaultStage : draft.tableActiveStage
            if let id = UInt8(targetIDStr), let stage = draft.stageValues[id] {
                return stage.x == stage.y ? stage.x : "\(stage.x)/\(stage.y)"
            }
        }
        if let table = device.settings?.settings.stages, !table.stages.isEmpty {
            let targetID = table.defaultStageID ?? table.activeStageID
            if let stage = table.stages.first(where: { $0.id == targetID }) {
                return QuickPresetRowDraft.formatDPI(stage.dpi)
            }
        }
        if let draft = currentDraft, !draft.dpiX.isEmpty {
            return draft.dpiX == draft.dpiY ? draft.dpiX : "\(draft.dpiX)/\(draft.dpiY)"
        }
        if let dpi = device.settings?.settings.currentDPI {
            return QuickPresetRowDraft.formatDPI(dpi)
        }
        return "--"
    }

    private var onboardSaveButtonTitle: String {
        if case .onboardSave(let phase) = model.pendingParameterSwitches[device.id]?.kind {
            return phase.buttonTitle
        }
        if case .restoreBackup(let phase) = model.pendingParameterSwitches[device.id]?.kind {
            return phase.buttonTitle
        }
        return "保存到设备"
    }

    // MARK: - 4. Real-Time Result & Status Banners (Spec §4.3 & §9.6)

    @ViewBuilder
    private var statusAndResultBanners: some View {
        // Short-lived verified feedback (blue checkmark, ~1.5s)
        if let verifiedText = model.verifiedBannerMessages[device.id] {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verifiedText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.accentText)
                    if let lastResult = device.lastSettingChange {
                        Text(DeviceSettingsPresentation.persistenceText(lastResult, capabilities: device.capabilities))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(11)
            .background(palette.accentSoftBackground, in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(palette.accentSoftBorder.opacity(0.6), lineWidth: 1)
            )
            .transition(reduceMotion ? .opacity : .offset(y: 6).combined(with: .opacity))
        }

        // Preflight rejection banner
        if let rejection = model.parameterRejectionMessages[device.id] {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.warningText)
                Text(rejection)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.warningText)
                Spacer()
                Button("知道了") {
                    model.parameterRejectionMessages.removeValue(forKey: device.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.accentText)
            }
            .padding(11)
            .background(palette.warningBackground, in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(palette.warningBorder, lineWidth: 1)
            )
        }

        // Non-verified transaction outcomes from SettingChangeResult (Spec §4.3)
        if let result = device.lastSettingChange, result.status != .verified {
            resultStateBanner(result)
        }

        if let failure = device.settingsFailure {
            StatusNotice(title: "设置读取失败", detail: failure.message)
        }
        if let error = model.settingsErrors[device.id] {
            StatusNotice(title: "设置操作未完成", detail: error)
        }
        if busy {
            HStack(spacing: 8) {
                BazerDelayedProgressView(isActive: true, reduceMotionText: "正在处理")
                Text("正在执行设备事务…")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Button("取消等待") {
                    model.cancelSettings(device.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.accentText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func resultStateBanner(_ result: SettingChangeResult) -> some View {
        let (title, detail, needsReadback): (String, String, Bool) = {
            switch result.status {
            case .verified:
                return ("已确认", "", false)
            case .rejected:
                return ("当前设备不支持此值", result.message ?? "请求未通过设备能力校验，已保留原确认值。", false)
            case .outcomeUnknown:
                return ("尚未确认结果，请读取当前值", result.message ?? "写入结果未知，已暂停新的写入操作；请先读取当前值完成核对，不会自动重写。", true)
            case .readbackMismatch:
                let actualDesc: String
                if let dpi = result.observed?.settings.currentDPI {
                    actualDesc = "设备返回 \(QuickPresetRowDraft.formatDPI(dpi)) DPI，与请求值不同。"
                } else if let hz = result.observed?.settings.pollingRateHz {
                    actualDesc = "设备返回 \(hz) Hz，与请求值不同。"
                } else {
                    actualDesc = result.message ?? "独立读回值与请求值不同。"
                }
                return ("读回值与请求不一致", actualDesc, false)
            case .superseded:
                return ("连接或设置已变化，请重新读取", result.message ?? "原请求已失效，请读取当前值后再操作。", true)
            case .partialFailure:
                return ("部分设置已确认，其余尚未确认", result.message ?? "已按字段更新确认项，未确认字段需重新读取核对。", true)
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.warningText)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.warningText)
                Spacer()
                if needsReadback {
                    Button("读取当前值") {
                        model.readSettings(device.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.accentText)
                    .disabled(busy || isDisconnected)
                }
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                    .textSelection(.enabled)
            }
            Text(DeviceSettingsPresentation.persistenceText(result, capabilities: device.capabilities))
                .font(.system(size: 11))
                .foregroundStyle(palette.textTertiary)
        }
        .padding(12)
        .background(palette.warningBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(palette.warningBorder, lineWidth: 1)
        )
    }
}
