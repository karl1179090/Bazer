// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import BazerCore
import SwiftUI

struct BazerPanel: View {
    @ObservedObject var model: AppModel
    var panelSize = BazerPanelMetrics.size(visibleScreenHeight: 800)
    var onClosePanel: () -> Void = {}
    var presentationID = UUID()
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isUndoButtonFocused: Bool
    @State private var isHistoryExpanded = false
    @StateObject private var focusCoordinator = BazerFocusCoordinator()

    private var palette: BazerPalette {
        BazerPalette.resolve(mode: model.appearanceMode, systemScheme: systemColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        BazerOverlayHost(model: model) {
            VStack(spacing: 0) {
                if !model.route.isHome {
                    headerBar
                    Rectangle()
                        .fill(palette.divider)
                        .frame(height: 1)
                }

                ZStack {
                    pageBody
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                footerBar
            }
            .background(palette.panelBackground)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .environment(\.bazerPalette, palette)
        .environment(\.bazerFocusCoordinator, focusCoordinator)
        .preferredColorScheme(preferredColorScheme)
        .animation(reduceMotion ? BazerMotion.reduced : BazerMotion.standard, value: model.appearanceMode)
        .onChange(of: model.route) { route in
            Task { @MainActor in
                await Task.yield()
                guard model.route == route else { return }
                switch route {
                case .device(let target): focusCoordinator.move(to: .heading(target))
                case .home:
                    if let target = model.lastVisitedDeviceTarget { focusCoordinator.move(to: .card(target)) }
                case .settings: break
                }
            }
        }
        .onChange(of: presentationID) { _ in
            isHistoryExpanded = false
            focusCoordinator.reset()
        }
        .background(
            PanelKeyboardAndWindowBridge(
                onEscape: {
                    if !model.handleEscapeKey() {
                        onClosePanel()
                    }
                },
                onBackShortcut: {
                    guard model.activeOverlay == nil, !model.isPresentingNativeModal else { return }
                    switch model.route {
                    case .home:
                        break
                    case .device:
                        withRouteAnimation(for: .backwardHorizontal) {
                            model.navigateToHome()
                        }
                    case .settings:
                        withRouteAnimation(for: .exitVertical) {
                            model.navigateBackFromSettings()
                        }
                    }
                },
                onRefreshShortcut: {
                    guard model.activeOverlay == nil, !model.isPresentingNativeModal else { return }
                    triggerContextualRefresh()
                }
            )
        )
    }

    // MARK: - 1. Fixed Top Header Bar (Spec §2.1 & §9.1–§9.3)

    private var headerBar: some View {
        HStack(spacing: 10) {
            switch model.route {
            case .home:
                homeHeaderContent
            case .device(let target):
                detailHeaderContent(for: target)
            case .settings(let origin):
                settingsHeaderContent(for: origin)
            }
        }
        .padding(.horizontal, BazerPanelMetrics.pagePadding)
        .frame(height: BazerPanelMetrics.headerHeight)
        .background(palette.barBackground)
        .animation(reduceMotion ? BazerMotion.reduced : BazerMotion.headerCrossfade, value: model.route)
    }

    @ViewBuilder
    private var homeHeaderContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.accentSoftBackground)
                .frame(width: 34, height: 34)
            Image(systemName: "computermouse")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 1) {
            Text("Bazer")
                .font(.system(size: 16.5, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            Text("设备概览")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textSecondary)
        }

        Spacer()

        if model.isTerminating {
            BazerDelayedProgressView(isActive: true, reduceMotionText: "正在退出")
            Text("正在退出…")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textSecondary)
        } else if model.snapshot.isSuspended {
            Label("已暂停", systemImage: "pause.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.textSecondary)
        }

        Button {
            triggerContextualRefresh()
        } label: {
            ZStack {
                if model.isRefreshing {
                    BazerDelayedProgressView(isActive: true)
                }
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(model.canRefresh ? palette.textPrimary : palette.textTertiary)
                    .opacity(model.isRefreshing ? 0.35 : 1.0)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(BazerCardButtonStyle())
        .disabled(!model.canRefresh || model.isRefreshing)
        .accessibilityLabel("刷新所有设备")

        Rectangle()
            .fill(palette.divider)
            .frame(width: 1, height: 16)

        Button {
            withRouteAnimation(for: .enterVertical) {
                model.navigateToSettings()
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(BazerCardButtonStyle())
        .accessibilityLabel("打开应用设置")
    }

    @ViewBuilder
    private func detailHeaderContent(for target: HomeDeviceTarget) -> some View {
        Button {
            withRouteAnimation(for: .backwardHorizontal) {
                model.navigateToHome()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
            }
            .frame(width: 24, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回设备列表")

        Text("设备详情")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(palette.textPrimary)
            .accessibilityLabel("设备详情，\(model.displayName(for: target))")
            .accessibilityAddTraits(.isHeader)
            .bazerRestorableFocus(.heading(target))

        Spacer()

        Button {
            triggerContextualRefresh()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(BazerCardButtonStyle())
        .disabled(model.isTerminating || model.snapshot.isSuspended)
        .accessibilityLabel("刷新当前设备")

        Rectangle()
            .fill(palette.divider)
            .frame(width: 1, height: 16)

        Menu {
            if let logical = model.associatedLogicalDevice(for: target) {
                if logical.capabilities.canReadSettings {
                    Button("读取当前设置") {
                        model.readSettings(logical.id)
                    }
                    .disabled(model.settingsBusy.contains(logical.id) || logical.isReadingSettings || (logical.hostPresence == .removed || logical.peerPresence == .unreachable))
                }
                Button(model.isPrimary(for: target) ? "已是菜单栏主设备" : "设为菜单栏主设备") {
                    model.setPrimaryLogical(logical.id)
                }
                .disabled(model.isPrimary(for: target) || (logical.hostPresence == .removed || logical.peerPresence == .unreachable))

                if logical.capabilities.canReadSettings && !logical.descriptor.isIdentityAmbiguous {
                    Divider()
                    Button("备份配置…") {
                        model.exportBackupByUser(for: logical)
                    }
                    .disabled(model.settingsBusy.contains(logical.id) || (logical.hostPresence == .removed || logical.peerPresence == .unreachable))

                    Button("恢复备份…") {
                        focusCoordinator.remember(.menu(target))
                        model.beginRestoreBackupByUser(for: logical)
                    }
                    .disabled(model.settingsBusy.contains(logical.id) || (logical.hostPresence == .removed || logical.peerPresence == .unreachable))
                }
            } else if let physical = model.associatedPhysicalDevice(for: target) {
                Button(model.isPrimary(for: target) ? "已是菜单栏主设备" : "设为菜单栏主设备") {
                    model.setPrimary(physical.id)
                }
                .disabled(model.isPrimary(for: target) || physical.hostPresence == .removed)
            } else if let audio = model.associatedBluetoothAudioDevice(for: target) {
                Button(model.isPrimary(for: target) ? "已是菜单栏主设备" : "设为菜单栏主设备") {
                    model.setPrimaryTarget(target)
                }
                .disabled(model.isPrimary(for: target) || audio.connection == .disconnected)
            }

            Divider()
            Button(model.isDeviceFolded(target) ? "移回常用设备" : "收纳至已折叠设备") {
                model.toggleDeviceFolded(target)
            }
            Button("打开应用设置") {
                withRouteAnimation(for: .enterVertical) {
                    model.navigateToSettings()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .bazerRestorableFocus(.menu(target))
        .accessibilityLabel("更多设备操作")
    }

    @ViewBuilder
    private func settingsHeaderContent(for origin: BazerSettingsOrigin) -> some View {
        let backAccessibilityLabel: String = {
            switch origin {
            case .home:
                return "返回设备列表"
            case .device(let target):
                return "返回 \(model.displayName(for: target)) 详情"
            }
        }()

        Button {
            withRouteAnimation(for: .exitVertical) {
                model.navigateBackFromSettings()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text("设置")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.textPrimary)
                if case .device(let target) = origin {
                    Text("· 返回 \(model.displayName(for: target))")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(backAccessibilityLabel)

        Spacer()

        Image(systemName: "gearshape")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(palette.textSecondary)
            .accessibilityHidden(true)
    }

    // MARK: - 2. Clipped Page Body Container & Nonlinear Transitions (Spec §9)

    @ViewBuilder
    private var pageBody: some View {
        switch model.route {
        case .home:
            ScrollViewReader { proxy in
                ScrollView {
                    homeDeviceList
                        .padding(.horizontal, BazerPanelMetrics.pagePadding)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(presentationID)
                .onAppear {
                    if let anchor = model.lastVisitedDeviceTarget {
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
            .transition(pageTransition(isHome: true))

        case .device(let target):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailPageView(for: target)
                }
                .padding(.horizontal, BazerPanelMetrics.pagePadding)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(pageTransition(isHome: false))

        case .settings:
            ScrollView {
                SettingsView(model: model)
                    .padding(.horizontal, BazerPanelMetrics.pagePadding)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .offset(y: 12).combined(with: .opacity),
                        removal: .offset(y: 12).combined(with: .opacity)
                    )
            )
        }
    }

    private func pageTransition(isHome: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch model.routeDirection {
        case .forwardHorizontal:
            return isHome
                ? .asymmetric(insertion: .offset(x: -14).combined(with: .opacity), removal: .offset(x: -14).combined(with: .opacity))
                : .asymmetric(insertion: .offset(x: 28).combined(with: .opacity), removal: .offset(x: 28).combined(with: .opacity))
        case .backwardHorizontal:
            return isHome
                ? .asymmetric(insertion: .offset(x: -14).combined(with: .opacity), removal: .offset(x: -14).combined(with: .opacity))
                : .asymmetric(insertion: .offset(x: 28).combined(with: .opacity), removal: .offset(x: 28).combined(with: .opacity))
        case .enterVertical, .exitVertical, .none:
            return .opacity
        }
    }

    @ViewBuilder
    private func detailPageView(for target: HomeDeviceTarget) -> some View {
        if let history = model.historyHomeDevices.first(where: { $0.target == target }), history.audio == nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("上次电量 · \(history.batteryText)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                if let date = history.lastObservedAt {
                    Text("最近读取 \(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSecondary)
                }
                Text("设备已断开，此处保留历史报告。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 10))
        }

        switch target {
        case .logical(let id):
            if let device = model.associatedLogicalDevice(for: .logical(id)) {
                LogicalDeviceDetailView(model: model, device: device)
                    .id(device.sessionID)
            } else {
                disconnectedPlaceholderView(for: target)
            }
        case .physical(let id):
            if let device = model.associatedPhysicalDevice(for: .physical(id)) {
                DeviceDetailView(model: model, device: device)
                    .id(device.sessionID)
            } else {
                disconnectedPlaceholderView(for: target)
            }
        case .bluetoothAudio:
            if let device = model.associatedBluetoothAudioDevice(for: target) {
                BluetoothAudioDetailView(model: model, device: device)
                    .id(device.session)
            } else {
                disconnectedPlaceholderView(for: target)
            }
        }
    }

    private func disconnectedPlaceholderView(for target: HomeDeviceTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.displayName(for: target))
                .font(.system(size: 16.5, weight: .bold))
                .foregroundStyle(palette.textPrimary)
            StatusNotice(title: "设备连接已断开", detail: "该设备当前已移除或断开连接，你可以返回设备列表或进入设置。")
        }
    }

    // MARK: - 3. Home Device List & Folded Group (Spec §3 & §9.4)

    private var homeDeviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.snapshot.discoveryFailure {
                StatusNotice(title: "设备发现失败", detail: error)
            }
            if let error = model.snapshot.preferencesFailure {
                StatusNotice(title: "偏好保存失败", detail: error)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("已连接设备")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("· \(model.connectedHomeDevices.count)")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)

                    Spacer(minLength: 6)

                    if let banner = model.foldUndoBanner {
                        HStack(spacing: 6) {
                            Text(banner.message)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(1)
                            Button("撤销") {
                                withAnimation(reduceMotion ? nil : BazerMotion.softSpring) { model.undoLastFoldAction() }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.accentText)
                            .focused($isUndoButtonFocused)
                            .onChange(of: isUndoButtonFocused) { model.isFoldUndoFocused = $0 }
                        }
                        .onHover { model.isFoldUndoHovered = $0 }
                        .transition(.opacity)
                    } else if model.isTerminating {
                        HStack(spacing: 4) {
                            BazerDelayedProgressView(isActive: true, reduceMotionText: "正在退出")
                            Text("正在退出…")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                        }
                    } else if model.snapshot.isSuspended {
                        Label("已暂停", systemImage: "pause.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
                .padding(.horizontal, 2)

                if let detail = BluetoothAudioSourcePresentation(snapshot: model.bluetoothAudioSnapshot).noticeDetail {
                    StatusNotice(title: "蓝牙耳机来源状态", detail: detail)
                }

                if model.currentHomeTargets.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 22))
                            .foregroundStyle(palette.textTertiary)
                        Text(model.snapshot.isMonitoring ? "未发现已连接设备" : "正在发现设备…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("连接外设或蓝牙耳机后会自动更新。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if model.regularHomeTargets.isEmpty {
                    Text("设备已收纳到下方")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 2)
                }

                ForEach(model.regularHomeTargets) { target in
                    deviceCard(for: target, folded: false)
                }
                if !model.foldedHomeTargets.isEmpty { foldedDevicesSection }

                // Receivers with no child remain diagnostic controls within this
                // section, rather than becoming another mouse battery card.
                let emptyReceivers = model.logicalDiscoveryHosts.filter { host in
                    !model.managedLogicalDevices.contains { $0.sessionID.address.hostSessionID.physicalDeviceID == host.id }
                }
                ForEach(emptyReceivers) { host in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("接收器诊断 · \(host.displayName)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                        LogicalDiscoveryControls(model: model, hostID: host.id)
                    }
                    .padding(10)
                    .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            if !model.historyHomeDevices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(reduceMotion ? nil : BazerMotion.softSpring) { isHistoryExpanded.toggle() }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .rotationEffect(.degrees(isHistoryExpanded ? 90 : 0))
                                .animation(reduceMotion ? nil : BazerMotion.standard, value: isHistoryExpanded)
                            Text("历史设备 · \(model.historyHomeDevices.count)")
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(palette.textSecondary)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("历史设备，\(model.historyHomeDevices.count) 台，\(isHistoryExpanded ? "已展开" : "已收起")")

                    if isHistoryExpanded {
                        ForEach(model.historyHomeDevices) { item in
                            HomeDeviceCard(model: model, target: item.target, isFoldedCard: false, isHistorical: true,
                                onSelectCard: {
                                    withRouteAnimation(for: .forwardHorizontal) { model.navigateToDevice(item.target) }
                                }, onToggleFold: {})
                                .id(item.target)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(palette.subtleSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .animation(reduceMotion ? nil : BazerMotion.softSpring, value: model.regularHomeTargets)
        .animation(reduceMotion ? nil : BazerMotion.softSpring, value: model.foldedHomeTargets)
    }

    private func deviceCard(for target: HomeDeviceTarget, folded: Bool) -> some View {
        HomeDeviceCard(model: model, target: target, isFoldedCard: folded,
            onSelectCard: { withRouteAnimation(for: .forwardHorizontal) { model.navigateToDevice(target) } },
            onToggleFold: {
                withAnimation(reduceMotion ? nil : BazerMotion.softSpring) { model.setDeviceFolded(!folded, for: target) }
            })
            .id(target)
            .transition(reduceMotion ? .opacity : .offset(y: 6).combined(with: .opacity))
    }

    private var foldedDevicesSection: some View {
        let isExpanded = model.isFoldedSectionExpanded
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : BazerMotion.softSpring) {
                    model.isFoldedSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isExpanded ? palette.accentText : palette.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : BazerMotion.standard, value: isExpanded)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("已折叠设备")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("· \(model.foldedHomeTargets.count)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        ForEach(model.foldedHomeTargets.prefix(3)) { target in
                            Image(systemName: symbol(for: target))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(palette.accent)
                                .frame(width: 22, height: 22)
                                .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("已折叠设备，\(model.foldedHomeTargets.count) 台，\(isExpanded ? "已展开" : "已收起")")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.foldedHomeTargets) { target in
                        HomeDeviceCard(
                            model: model,
                            target: target,
                            isFoldedCard: true,
                            onSelectCard: {
                                withRouteAnimation(for: .forwardHorizontal) {
                                    model.navigateToDevice(target)
                                }
                            },
                            onToggleFold: {
                                withAnimation(reduceMotion ? nil : BazerMotion.softSpring) {
                                    model.setDeviceFolded(false, for: target)
                                }
                            }
                        )
                        .id(target)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            isExpanded ? palette.foldedContainerBackground : palette.cardBackground.opacity(0.85),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isExpanded ? palette.foldedContainerBorder : palette.cardBorder,
                    lineWidth: 1
                )
        )
        .clipped()
    }

    private func symbol(for target: HomeDeviceTarget) -> String {
        if let logical = model.associatedLogicalDevice(for: target) {
            return LogicalDevicePresentation(logical, at: model.snapshot.capturedAt).deviceSymbol
        }
        if let physical = model.associatedPhysicalDevice(for: target) {
            return DevicePresentation(physical, at: model.snapshot.capturedAt).deviceSymbol
        }
        if model.associatedBluetoothAudioDevice(for: target) != nil { return "headphones" }
        return "computermouse"
    }

    // MARK: - 4. Fixed Bottom Footer Bar (Spec §2.1 & Apple HIG Alignment)

    private var footerBar: some View {
        HStack(spacing: 8) {
            switch model.route {
            case .home, .device:
                Button {
                    triggerContextualRefresh()
                } label: {
                    HStack(spacing: 5) {
                        if model.isRefreshing {
                            BazerDelayedProgressView(isActive: true)
                                .scaleEffect(0.75)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        Text(refreshButtonTitle)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(model.canRefresh ? palette.textPrimary : palette.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(BazerCardButtonStyle())
                .disabled(!model.canRefresh || model.isRefreshing)
                .accessibilityLabel("刷新所有设备")

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    Button {
                        withRouteAnimation(for: .enterVertical) {
                            model.navigateToSettings()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("设置")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(palette.cardBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(BazerCardButtonStyle())
                    .accessibilityLabel("打开 Bazer 设置")

                    quitFooterButton
                }

            case .settings:
                Button {
                    withRouteAnimation(for: .exitVertical) {
                        model.navigateFromSettingsToDeviceList()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回设备列表")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.cardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(BazerCardButtonStyle())
                .accessibilityLabel("返回设备列表")

                Spacer(minLength: 6)

                quitFooterButton
            }
        }
        .padding(.horizontal, BazerPanelMetrics.pagePadding)
        .frame(height: BazerPanelMetrics.footerHeight)
        .background(palette.barBackground)
    }

    private var quitFooterButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                Text(model.isTerminating ? "退出中…" : "退出")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(BazerCardButtonStyle())
        .disabled(model.isTerminating)
        .keyboardShortcut("q", modifiers: .command)
        .accessibilityLabel("退出 Bazer")
    }

    private var refreshButtonTitle: String {
        if model.isRefreshing { return "刷新中…" }
        if model.snapshot.isSuspended { return "已暂停" }
        return "刷新"
    }

    private func triggerContextualRefresh() {
        switch model.route {
        case .home, .settings:
            model.refreshAllDeviceInformation()
        case .device(let target):
            switch target {
            case .logical(let id):
                model.refreshLogical(id)
                if let logical = model.snapshot.logicalDevices.first(where: { $0.id == id }),
                   logical.canRefreshSettings,
                   !model.settingsBusy.contains(id) {
                    model.readSettings(id)
                }
            case .physical(let id):
                model.refresh(id)
                if let logical = model.associatedLogicalDevice(for: .physical(id)),
                   logical.canRefreshSettings,
                   !model.settingsBusy.contains(logical.id) {
                    model.readSettings(logical.id)
                }
            case .bluetoothAudio:
                model.refreshAllDeviceInformation()
            }
        }
    }

    private func withRouteAnimation(for direction: RouteTransitionDirection, _ action: () -> Void) {
        if reduceMotion {
            withAnimation(BazerMotion.reduced) {
                action()
            }
            return
        }
        let animation: Animation
        switch direction {
        case .forwardHorizontal:
            animation = BazerMotion.enter
        case .backwardHorizontal:
            animation = BazerMotion.detailReturnEnter
        case .enterVertical:
            animation = BazerMotion.settingsEnter
        case .exitVertical:
            animation = BazerMotion.exit
        case .none:
            animation = BazerMotion.standard
        }
        withAnimation(animation) {
            action()
        }
    }
}

// MARK: - Home Device Card Component (Spec §3.1 & 01-home.png)

struct HomeDeviceCard: View {
    @ObservedObject var model: AppModel
    let target: HomeDeviceTarget
    let isFoldedCard: Bool
    var isHistorical = false
    let onSelectCard: () -> Void
    let onToggleFold: () -> Void
    @Environment(\.bazerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringCard = false

    private var projection: HomeDeviceProjection? {
        (model.connectedHomeDevices + model.historyHomeDevices).first { $0.target == target }
    }
    private var displayName: String { projection?.name ?? model.displayName(for: target) }
    private var isAudio: Bool { if case .bluetoothAudio = target { return true }; return false }
    private var logical: LogicalDeviceState? { model.associatedLogicalDevice(for: target) }
    private var showsMouseParameters: Bool {
        !isHistorical && (logical?.descriptor.kind == .mouse || model.associatedPhysicalDevice(for: target)?.kind == .mouse)
    }
    private var dpi: String { logical.map { LogicalDevicePresentation($0, at: model.snapshot.capturedAt).currentDPIText } ?? "--" }
    private var rate: String { logical.map { LogicalDevicePresentation($0, at: model.snapshot.capturedAt).pollingRateText } ?? "--" }

    private var isReadingMouseSettings: Bool {
        guard let logical else { return false }
        return logical.isReadingSettings || model.settingsBusy.contains(logical.id)
    }
    private var dpiDisplayText: String {
        if dpi == "--", isReadingMouseSettings { return "读取中…" }
        return dpi
    }
    private var rateDisplayText: String {
        if rate == "--", isReadingMouseSettings { return "读取中…" }
        return rate
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelectCard) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: projection?.symbol ?? "computermouse")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isAudio ? palette.accent : palette.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(displayName)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if model.isPrimary(for: target) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            Text(projection?.subtitle ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !isHistorical { Color.clear.frame(width: 28, height: 28) }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(isHistorical ? "上次电量" : (isAudio ? "系统报告" : "电量"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                        Spacer(minLength: 0)
                        Text(projection?.batteryText ?? "--")
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                            .multilineTextAlignment(.trailing)
                    }
                    BazerBatteryBar(percent: projection?.percentage)
                    if showsMouseParameters {
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Text("DPI")
                                    .foregroundStyle(palette.textTertiary)
                                Text(dpiDisplayText)
                                    .foregroundStyle(palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                            HStack(spacing: 4) {
                                Text("回报率")
                                    .foregroundStyle(palette.textTertiary)
                                Text(rateDisplayText)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    } else {
                        Text(projection?.status ?? "状态待确认")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if isHistorical, let date = projection?.lastObservedAt {
                        Text("最近读取 \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.textTertiary)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHoveringCard ? palette.cardHoverBackground : palette.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isHoveringCard ? palette.cardHoverBorder : palette.cardBorder, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(BazerCardButtonStyle())
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : BazerMotion.standard) { isHoveringCard = hovering }
            }
            .accessibilityLabel("\(displayName)，\(isHistorical ? "历史设备，上次电量" : "电量") \(projection?.batteryText ?? "未知")，\(projection?.status ?? "状态待确认")")
            .bazerRestorableFocus(.card(target))
            .accessibilityHint("查看设备详情")

            if !isHistorical {
                Button(action: onToggleFold) {
                    Image(systemName: isFoldedCard ? "tray.and.arrow.up" : "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .frame(width: 28, height: 28)
                        .background(palette.subtleSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(BazerCardButtonStyle())
                .padding(11)
                .help(isFoldedCard ? "移回常用设备" : "折叠收纳此设备")
                .accessibilityLabel(isFoldedCard ? "将 \(displayName) 移回常用设备" : "折叠 \(displayName)")
            }
        }
    }
}

// MARK: - Status Notice Banner

struct StatusNotice: View {
    let title: String
    let detail: String
    @Environment(\.bazerPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
        }
        .foregroundStyle(palette.warningText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(palette.warningBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(palette.warningBorder, lineWidth: 1)
        )
    }
}

// MARK: - Keyboard Shortcut & Window Close Bridge (Spec §2.2 & §11)

private struct PanelKeyboardAndWindowBridge: NSViewRepresentable {
    let onEscape: () -> Void
    let onBackShortcut: () -> Void
    let onRefreshShortcut: () -> Void

    func makeNSView(context: Context) -> BridgeNSView {
        let view = BridgeNSView()
        view.onEscape = onEscape
        view.onBackShortcut = onBackShortcut
        view.onRefreshShortcut = onRefreshShortcut
        return view
    }

    func updateNSView(_ nsView: BridgeNSView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onBackShortcut = onBackShortcut
        nsView.onRefreshShortcut = onRefreshShortcut
    }

    static func dismantleNSView(_ nsView: BridgeNSView, coordinator: ()) {
        nsView.cleanup()
    }

    final class BridgeNSView: NSView {
        var onEscape: (() -> Void)?
        var onBackShortcut: (() -> Void)?
        var onRefreshShortcut: (() -> Void)?
        private var keyMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            cleanup()
            guard let window else { return }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow else { return event }
                if event.keyCode == 53 { // Escape
                    self.onEscape?()
                    return nil
                }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
                    if chars == "r" {
                        self.onRefreshShortcut?()
                        return nil
                    }
                    if chars == "[" {
                        self.onBackShortcut?()
                        return nil
                    }
                }
                return event
            }
        }

        func cleanup() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }

        }
    }
}
