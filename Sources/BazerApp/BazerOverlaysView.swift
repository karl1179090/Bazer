// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import SwiftUI

// MARK: - Overlay Host Container (Spec §5, §6, §7, §9.5)

struct BazerOverlayHost<Content: View>: View {
    @ObservedObject var model: AppModel
    let content: Content
    @Environment(\.bazerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bazerFocusCoordinator) private var focusCoordinator

    init(model: AppModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .disabled(model.activeOverlay != nil)
                .allowsHitTesting(model.activeOverlay == nil)
                .accessibilityHidden(model.activeOverlay != nil)

            if let overlay = model.activeOverlay {
                palette.backdropOverlay
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissOverlayByBackdrop(overlay)
                    }
                    .transition(.opacity)
                    .zIndex(10)

                overlayView(for: overlay)
                    .padding(BazerPanelMetrics.overlayPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .offset(y: 8).combined(with: .scale(scale: 0.98)).combined(with: .opacity),
                                removal: .offset(y: 6).combined(with: .scale(scale: 0.99)).combined(with: .opacity)
                            )
                    )
                    .zIndex(11)
            }
        }
        .onChange(of: model.activeOverlay) { overlay in
            if overlay != nil {
                focusCoordinator?.modalDidOpen()
            } else {
                Task { @MainActor in
                    await Task.yield()
                    guard model.activeOverlay == nil else { return }
                    focusCoordinator?.modalDidClose()
                }
            }
        }
        .animation(reduceMotion ? BazerMotion.reduced : BazerMotion.softSpring, value: model.activeOverlay)
    }

    private func dismissOverlayByBackdrop(_ overlay: BazerOverlay) {
        switch overlay {
        case .quickPresetEditor(let deviceID, _):
            // Spec §5.2: Clicking backdrop closes modal and keeps unsaved draft in current panel session
            model.closeQuickPresetEditorKeepingDraft(for: deviceID)
        case .onboardFieldPicker, .restorePreview, .primaryDevicePicker:
            model.activeOverlay = nil
        }
    }

    @ViewBuilder
    private func overlayView(for overlay: BazerOverlay) -> some View {
        switch overlay {
        case .quickPresetEditor(let deviceID, _):
            if let device = model.snapshot.logicalDevices.first(where: { $0.id == deviceID }) {
                QuickPresetEditorModal(model: model, device: device)
            }
        case .onboardFieldPicker(let deviceID, let field):
            if let device = model.snapshot.logicalDevices.first(where: { $0.id == deviceID }) {
                OnboardFieldPickerModal(model: model, device: device, field: field)
            }
        case .restorePreview(_, let preview):
            RestorePreviewModal(model: model, preview: preview)
        case .primaryDevicePicker:
            PrimaryDevicePickerModal(model: model)
        }
    }
}

// MARK: - 1. Quick Preset Editor Modal (Spec §5 & §9.5)

struct QuickPresetEditorModal: View {
    @ObservedObject var model: AppModel
    let device: LogicalDeviceState
    @Environment(\.bazerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: String?

    private var draft: QuickPresetModalDraft {
        model.sessionQuickPresetDrafts[device.id] ?? QuickPresetModalDraft(
            activeTab: .dpi,
            dpiPresets: model.dpiPresets(for: device),
            ratePresets: model.pollingRatePresets(for: device)
        )
    }

    private var dpiErrors: [UUID: String] {
        draft.validateDPIRows(capabilities: device.capabilities)
    }

    private var rateErrors: [UUID: String] {
        draft.validateRateRows(capabilities: device.capabilities)
    }

    private var canSave: Bool {
        draft.canSave(
            comparedTo: model.dpiPresets(for: device),
            savedRates: model.pollingRatePresets(for: device),
            capabilities: device.capabilities
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Fixed Modal Header
            HStack(alignment: .center) {
                Text("编辑快捷选项")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    model.closeQuickPresetEditorKeepingDraft(for: device.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(palette.subtleSurface.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "close")
                .accessibilityLabel("关闭快捷选项弹窗")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
            // Spec §5.2 required subtitle
            Text("这里只编辑快捷值，保存后点击选项切换参数。")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)

            // Segmented Tabs (DPI | 回报率)
            tabSelector

            VStack(alignment: .leading, spacing: 10) {
                    if draft.activeTab == .dpi {
                        dpiRowsList
                    } else {
                        rateRowsList
                    }
            }
            .padding(.vertical, 2)

            // Add Option Button
            addButton

            // Helper Footer Caption
            Text(helperCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textSecondary)

            if let saveError = draft.saveError {
                Text(saveError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.dangerText)
            }

            if device.descriptor.preferenceIdentity == nil || device.descriptor.isIdentityAmbiguous {
                Text("当前设备尚无稳定偏好身份，保存的快捷值本次连接有效。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textTertiary)
            }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            // Fixed Bottom Action Buttons
            HStack(spacing: 10) {
                Button {
                    model.cancelQuickPresetEditor(for: device.id)
                } label: {
                    Text("取消")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(palette.cardBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "cancel")
                .accessibilityLabel("取消并丢弃草稿")

                Button {
                    submitSave()
                } label: {
                    Text("保存选项")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            canSave ? palette.accentStrong : palette.accentStrong.opacity(0.38),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "save")
                .disabled(!canSave)
                .accessibilityLabel("保存快捷选项")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(palette.isDark ? 0.45 : 0.14), radius: 22, x: 0, y: 10)
        .modifier(BazerModalFocusScope(focus: $focusedControl, order: focusOrder, initial: firstFieldFocus))
    }

    private var firstFieldFocus: String? {
        (draft.activeTab == .dpi ? draft.dpiRows : draft.rateRows).first.map { "field:\($0.id)" }
    }
    private var focusOrder: [String] {
        var order = ["close"] + QuickPresetTab.allCases.map { "tab:\($0.rawValue)" }
        let isDPI = draft.activeTab == .dpi
        for row in isDPI ? draft.dpiRows : draft.rateRows {
            order.append("field:\(row.id)")
            if isDPI ? draft.canRemoveDPIRow : draft.canRemoveRateRow { order.append("remove:\(row.id)") }
        }
        if isDPI ? draft.canAddDPIRow : draft.canAddRateRow { order.append("add") }
        order.append("cancel")
        if canSave { order.append("save") }
        return order
    }

    private var tabSelector: some View {
        HStack(spacing: 4) {
            ForEach(QuickPresetTab.allCases, id: \.self) { tab in
                let isSelected = draft.activeTab == tab
                Button {
                    withAnimation(reduceMotion ? BazerMotion.reduced : BazerMotion.selectSpring) {
                        var copy = draft
                        copy.activeTab = tab
                        model.sessionQuickPresetDrafts[device.id] = copy
                    }
                    focusFirstField(for: tab)
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? palette.accentText : palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(palette.accentSoftBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(palette.accentSoftBorder, lineWidth: 1.2)
                                        )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.title)快捷选项标签")
                .focusable()
                .focused($focusedControl, equals: "tab:\(tab.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var dpiRowsList: some View {
        let errors = dpiErrors
        return ForEach(Array(draft.dpiRows.enumerated()), id: \.element.id) { index, row in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("选项 \(index + 1)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 48, alignment: .leading)

                    HStack(spacing: 6) {
                        TextField("整数", text: dpiRowBinding(for: row.id))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                            .focused($focusedControl, equals: "field:\(row.id)")
                            .onSubmit {
                                normalizeDPIRow(id: row.id)
                                if canSave { submitSave() }
                            }

                        Text("DPI")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(palette.inputSurface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                errors[row.id] != nil ? palette.dangerBorder : (focusedControl == "field:\(row.id)" ? palette.focusRing : palette.cardBorder),
                                lineWidth: focusedControl == "field:\(row.id)" ? 1.5 : 1
                            )
                    )

                    Button {
                        withAnimation(reduceMotion ? nil : BazerMotion.softSpring) {
                            var copy = draft
                            copy.removeDPIRow(id: row.id)
                            model.sessionQuickPresetDrafts[device.id] = copy
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(draft.canRemoveDPIRow ? palette.textSecondary : palette.textTertiary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .focusable()
                .focused($focusedControl, equals: "remove:\(row.id)")
                .disabled(!draft.canRemoveDPIRow)
                    .accessibilityLabel("删除选项 \(index + 1)")
                }

                if let error = errors[row.id] {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.dangerText)
                        .padding(.leading, 58)
                        .transition(.opacity)
                }
            }
        }
    }

    private var rateRowsList: some View {
        let errors = rateErrors
        return ForEach(Array(draft.rateRows.enumerated()), id: \.element.id) { index, row in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("选项 \(index + 1)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .frame(width: 48, alignment: .leading)

                    HStack(spacing: 6) {
                        TextField("整数", text: rateRowBinding(for: row.id))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                            .focused($focusedControl, equals: "field:\(row.id)")
                            .onSubmit {
                                normalizeRateRow(id: row.id)
                                if canSave { submitSave() }
                            }

                        Text("Hz")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(palette.inputSurface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                errors[row.id] != nil ? palette.dangerBorder : (focusedControl == "field:\(row.id)" ? palette.focusRing : palette.cardBorder),
                                lineWidth: focusedControl == "field:\(row.id)" ? 1.5 : 1
                            )
                    )

                    Button {
                        withAnimation(reduceMotion ? nil : BazerMotion.softSpring) {
                            var copy = draft
                            copy.removeRateRow(id: row.id)
                            model.sessionQuickPresetDrafts[device.id] = copy
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(draft.canRemoveRateRow ? palette.textSecondary : palette.textTertiary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .focusable()
                .focused($focusedControl, equals: "remove:\(row.id)")
                .disabled(!draft.canRemoveRateRow)
                    .accessibilityLabel("删除回报率选项 \(index + 1)")
                }

                if let error = errors[row.id] {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.dangerText)
                        .padding(.leading, 58)
                        .transition(.opacity)
                }
            }
        }
    }

    private var addButton: some View {
        let isDPI = draft.activeTab == .dpi
        let canAdd = isDPI ? draft.canAddDPIRow : draft.canAddRateRow
        return Button {
            withAnimation(reduceMotion ? nil : BazerMotion.softSpring) {
                var copy = draft
                if isDPI {
                    copy.addDPIRow(capabilities: device.capabilities)
                    model.sessionQuickPresetDrafts[device.id] = copy
                    focusedControl = copy.dpiRows.last.map { "field:\($0.id)" }
                } else {
                    copy.addRateRow(capabilities: device.capabilities)
                    model.sessionQuickPresetDrafts[device.id] = copy
                    focusedControl = copy.rateRows.last.map { "field:\($0.id)" }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("添加选项")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(canAdd ? palette.textPrimary : palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedControl, equals: "add")
        .disabled(!canAdd)
        .accessibilityLabel("添加快捷选项")
    }

    private var helperCaption: String {
        if draft.activeTab == .dpi {
            return "回报率选项也可在上方切换后编辑（每组最多 8 个快捷选项）"
        } else {
            let candidates = QuickPresetModalDraft.suggestedRateCandidates(for: device.capabilities)
            return "支持回报率：\(candidates.map { "\($0) Hz" }.joined(separator: " / "))"
        }
    }

    private func dpiRowBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { draft.dpiRows.first(where: { $0.id == id })?.rawText ?? "" },
            set: { newValue in
                var copy = draft
                if let idx = copy.dpiRows.firstIndex(where: { $0.id == id }) {
                    copy.dpiRows[idx].rawText = newValue
                    copy.saveError = nil
                    model.sessionQuickPresetDrafts[device.id] = copy
                }
            }
        )
    }

    private func rateRowBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { draft.rateRows.first(where: { $0.id == id })?.rawText ?? "" },
            set: { newValue in
                var copy = draft
                if let idx = copy.rateRows.firstIndex(where: { $0.id == id }) {
                    copy.rateRows[idx].rawText = newValue
                    copy.saveError = nil
                    model.sessionQuickPresetDrafts[device.id] = copy
                }
            }
        )
    }

    private func normalizeDPIRow(id: UUID) {
        var copy = draft
        if let idx = copy.dpiRows.firstIndex(where: { $0.id == id }) {
            copy.dpiRows[idx].normalizeWhitespace()
            model.sessionQuickPresetDrafts[device.id] = copy
        }
    }

    private func normalizeRateRow(id: UUID) {
        var copy = draft
        if let idx = copy.rateRows.firstIndex(where: { $0.id == id }) {
            copy.rateRows[idx].normalizeWhitespace()
            model.sessionQuickPresetDrafts[device.id] = copy
        }
    }

    private func focusFirstField(for tab: QuickPresetTab? = nil) {
        let targetTab = tab ?? draft.activeTab
        if targetTab == .dpi {
            focusedControl = draft.dpiRows.first.map { "field:\($0.id)" }
        } else {
            focusedControl = draft.rateRows.first.map { "field:\($0.id)" }
        }
    }

    private func submitSave() {
        Task {
            _ = await model.saveQuickPresetDraft(for: device)
        }
    }
}

// MARK: - 2. Onboard Field Picker Overlay (Spec §6.1)

struct OnboardFieldPickerModal: View {
    @ObservedObject var model: AppModel
    let device: LogicalDeviceState
    let field: OnboardEditableField
    @Environment(\.bazerPalette) private var palette
    @FocusState private var focusedControl: String?

    private var draft: DeviceSettingsDraft? {
        model.onboardDraft(for: device)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(field.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    model.activeOverlay = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(palette.subtleSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
            Text("选择后先更新板载草稿，点击详情页“保存到设备”才会真正写入。")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)

            if let currentDraft = draft {
                switch field {
                case .activeProfile:
                    activeProfileContent(currentDraft)
                case .defaultDPI:
                    defaultDPIContent(currentDraft)
                }
            } else {
                Text("请先读取设备当前配置。")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Button {
                model.activeOverlay = nil
            } label: {
                Text("完成")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(palette.accentStrong, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedControl, equals: "done")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .modifier(BazerModalFocusScope(focus: $focusedControl, order: focusOrder, initial: focusOrder.dropFirst().first))
        .shadow(color: Color.black.opacity(palette.isDark ? 0.45 : 0.14), radius: 20, x: 0, y: 8)
    }

    private var focusOrder: [String] {
        var order = ["close"]
        if draft != nil {
            switch field {
            case .activeProfile:
                let allowed = device.capabilities[.onboardWrite].constraints.allowedValues
                let options = allowed.isEmpty ? (device.settings?.settings.activeProfileID.map { [$0] } ?? [1]) : allowed
                order += options.map { "profile:\($0)" }
            case .defaultDPI:
                if let table = device.settings?.settings.stages, !table.stages.isEmpty {
                    for stage in table.stages {
                        order.append("stage:\(stage.id)")
                        if device.capabilities.permits(.stagesWrite) { order.append("stage-value:\(stage.id)") }
                    }
                } else if device.capabilities.permits(.dpiWrite) {
                    order += model.dpiPresets(for: device).map { "preset:\($0.x):\($0.y)" }
                }
            }
        }
        return order + ["done"]
    }

    @ViewBuilder
    private func activeProfileContent(_ currentDraft: DeviceSettingsDraft) -> some View {
        let allowed = device.capabilities[.onboardWrite].constraints.allowedValues
        let options = allowed.isEmpty ? (device.settings?.settings.activeProfileID.map { [$0] } ?? [1]) : allowed
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { profileID in
                let isSelected = currentDraft.activeProfile == String(profileID)
                Button {
                    var updated = currentDraft
                    updated.activeProfile = String(profileID)
                    model.updateOnboardDraft(updated, for: device.id)
                } label: {
                    HStack {
                        BazerRadioIndicator(state: isSelected ? .confirmed : .unselected)
                        Text("配置 \(profileID)")
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? palette.accentText : palette.textPrimary)
                        Spacer()
                        if device.settings?.settings.activeProfileID == profileID {
                            Text("当前生效")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textTertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        isSelected ? palette.accentSoftBackground : palette.subtleSurface.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? palette.accentSoftBorder : palette.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "profile:\(profileID)")
            }
        }
    }

    @ViewBuilder
    private func defaultDPIContent(_ currentDraft: DeviceSettingsDraft) -> some View {
        if let table = device.settings?.settings.stages, !table.stages.isEmpty {
            let usesDefaultField = table.defaultStageID != nil
            let selectedID = usesDefaultField ? currentDraft.defaultStage : currentDraft.tableActiveStage
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(table.stages, id: \.id) { stage in
                        let idText = String(stage.id)
                        let isSelected = selectedID == idText
                        let stageDraft = currentDraft.stageValues[stage.id]
                        let dpiLabel = stageDraft.map { $0.x == $0.y ? "\($0.x) DPI" : "\($0.x)/\($0.y) DPI" } ?? "\(stage.dpi.x) DPI"

                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                var updated = currentDraft
                                if usesDefaultField {
                                    updated.defaultStage = idText
                                } else {
                                    updated.tableActiveStage = idText
                                }
                                model.updateOnboardDraft(updated, for: device.id)
                            } label: {
                                HStack {
                                    BazerRadioIndicator(state: isSelected ? .confirmed : .unselected)
                                    Text("档位 \(stage.id) · \(dpiLabel)")
                                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                        .foregroundStyle(isSelected ? palette.accentText : palette.textPrimary)
                                    Spacer()
                                    if (table.defaultStageID ?? table.activeStageID) == stage.id {
                                        Text("已读回默认")
                                            .font(.system(size: 11))
                                            .foregroundStyle(palette.textTertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .focusable()
                            .focused($focusedControl, equals: "stage:\(stage.id)")

                            if device.capabilities.permits(.stagesWrite) {
                                HStack(spacing: 8) {
                                    Text("档位数值")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(palette.textSecondary)
                                    TextField("DPI", text: Binding(
                                        get: { currentDraft.stageValues[stage.id]?.x ?? String(stage.dpi.x) },
                                        set: { val in
                                            var updated = currentDraft
                                            var entry = updated.stageValues[stage.id] ?? .init(x: String(stage.dpi.x), y: String(stage.dpi.y))
                                            entry.x = val
                                            if !device.capabilities.permits(.independentXY) { entry.y = val }
                                            updated.stageValues[stage.id] = entry
                                            model.updateOnboardDraft(updated, for: device.id)
                                        }
                                    ))
                                    .focused($focusedControl, equals: "stage-value:\(stage.id)")
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .rounded))
                                }
                            }
                        }
                        .padding(10)
                        .background(
                            isSelected ? palette.accentSoftBackground : palette.subtleSurface.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(isSelected ? palette.accentSoftBorder : palette.cardBorder, lineWidth: 1)
                        )
                    }
                }
            }
            .frame(maxHeight: 240)
        } else if device.capabilities.permits(.dpiWrite) {
            let presets = model.dpiPresets(for: device)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(presets, id: \.x) { preset in
                    let isSelected = currentDraft.dpiX == String(preset.x) && currentDraft.dpiY == String(preset.y)
                    Button {
                        var updated = currentDraft
                        updated.dpiX = String(preset.x)
                        updated.dpiY = String(preset.y)
                        model.updateOnboardDraft(updated, for: device.id)
                    } label: {
                        HStack {
                            BazerRadioIndicator(state: isSelected ? .confirmed : .unselected)
                            Text("\(QuickPresetRowDraft.formatDPI(preset)) DPI")
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? palette.accentText : palette.textPrimary)
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            isSelected ? palette.accentSoftBackground : palette.subtleSurface.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedControl, equals: "preset:\(preset.x):\(preset.y)")
                }
            }
        }
    }
}

// MARK: - 3. Restore Preview & Confirmation Overlay (Spec §6.3)

struct RestorePreviewModal: View {
    @ObservedObject var model: AppModel
    let preview: RestorePreviewModel
    @Environment(\.bazerPalette) private var palette
    @FocusState private var focusedControl: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("恢复配置备份预览")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    model.activeOverlay = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(palette.subtleSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("目标设备：\(preview.deviceName)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text("备份文件：\(preview.backupFileName)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
                Text("备份时间：\(preview.backupCapturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                    ForEach(preview.items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Text(item.isChanged ? "将覆盖" : "保持不变")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(item.isChanged ? palette.accentText : palette.textTertiary)
                            }
                            HStack(spacing: 6) {
                                Text("当前：\(item.currentValue)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.textSecondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.textTertiary)
                                Text("备份：\(item.backupValue)")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(palette.textPrimary)
                            }
                        }
                        .padding(10)
                        .background(palette.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                    }
            }

            Text("恢复前已自动保存当前状态备份；若写入中断，将按实际读回展示结果，不自动回滚。")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                Button {
                    model.activeOverlay = nil
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "cancel")

                Button {
                    model.confirmRestorePreview(preview)
                } label: {
                    Text("恢复到设备")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(palette.accentStrong, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "restore")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .modifier(BazerModalFocusScope(focus: $focusedControl, order: ["close", "cancel", "restore"], initial: "cancel"))
        .shadow(color: Color.black.opacity(palette.isDark ? 0.45 : 0.14), radius: 22, x: 0, y: 10)
    }
}

// MARK: - 4. Primary Device Single-Select Overlay (Spec §7)

struct PrimaryDevicePickerModal: View {
    @ObservedObject var model: AppModel
    @Environment(\.bazerPalette) private var palette
    @FocusState private var focusedControl: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("菜单栏主设备")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Button {
                    model.activeOverlay = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(palette.subtleSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
            Text("选择显示在 macOS 菜单栏的设备，不会改变设备主页卡片排序。")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.setPrimaryTarget(nil)
                    model.activeOverlay = nil
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(palette.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("重新自动选择")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.textPrimary)
                            Text("首次优先选择鼠标，断开后保留上次读数")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        palette.subtleSurface.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedControl, equals: "automatic")

                ForEach(model.currentHomeTargets) { target in
                    let isSelected = model.isPrimary(for: target)
                    Button {
                        model.setPrimaryTarget(target)
                        model.activeOverlay = nil
                    } label: {
                        HStack {
                            BazerRadioIndicator(state: isSelected ? .confirmed : .unselected)
                            Text(model.displayName(for: target))
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? palette.accentText : palette.textPrimary)
                            Spacer()
                            if isSelected {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .padding(10)
                        .background(
                            isSelected ? palette.accentSoftBackground : palette.subtleSurface.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedControl, equals: "device:\(target.id)")
                }
            }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
        .modifier(BazerModalFocusScope(focus: $focusedControl, order: ["close", "automatic"] + model.currentHomeTargets.map { "device:\($0.id)" }, initial: model.currentHomeTargets.first(where: { model.isPrimary(for: $0) }).map { "device:\($0.id)" } ?? "automatic"))
        .shadow(color: Color.black.opacity(palette.isDark ? 0.45 : 0.14), radius: 20, x: 0, y: 8)
    }
}
