// SPDX-License-Identifier: GPL-3.0-or-later
import BazerCore
import SwiftUI

// MARK: - Nonlinear Motion Specification (Spec §8 & §12)

enum BazerMotion {
    /// cubic-bezier(0.22, 1, 0.36, 1), 240 ms — page, toast, modal enter
    static let enter = Animation.timingCurve(
        0.22, 1.00, 0.36, 1.00, duration: 0.24
    )
    /// cubic-bezier(0.40, 0, 1, 1), 160 ms — page, toast exit
    static let exit = Animation.timingCurve(
        0.40, 0.00, 1.00, 1.00, duration: 0.16
    )
    /// cubic-bezier(0.40, 0, 0.20, 1), 180 ms — color, opacity, theme transitions
    static let standard = Animation.timingCurve(
        0.40, 0.00, 0.20, 1.00, duration: 0.18
    )
    /// High-damping spring for folding height, modal displacement, card stowage
    static let softSpring = Animation.spring(
        response: 0.34, dampingFraction: 0.90, blendDuration: 0.10
    )
    /// Compact high-damping spring for radio dot & tab pill selection
    static let selectSpring = Animation.spring(
        response: 0.26, dampingFraction: 0.88, blendDuration: 0.06
    )
    /// Reduced motion fallback (80–120 ms opacity fade only, no spatial travel)
    static let reduced = Animation.easeOut(duration: 0.10)

    /// Specific action durations from Spec §9
    static let cardPress = Animation.timingCurve(0.40, 0.00, 0.20, 1.00, duration: 0.08)
    static let detailReturnExit = Animation.timingCurve(0.40, 0.00, 1.00, 1.00, duration: 0.18)
    static let detailReturnEnter = Animation.timingCurve(0.22, 1.00, 0.36, 1.00, duration: 0.22)
    static let settingsEnter = Animation.timingCurve(0.22, 1.00, 0.36, 1.00, duration: 0.22)
    static let headerCrossfade = Animation.timingCurve(0.40, 0.00, 0.20, 1.00, duration: 0.12)
    static let batteryFill = Animation.timingCurve(0.40, 0.00, 0.20, 1.00, duration: 0.22)
    static let toastEnter = Animation.timingCurve(0.22, 1.00, 0.36, 1.00, duration: 0.18)
    static let toastExit = Animation.timingCurve(0.40, 0.00, 1.00, 1.00, duration: 0.12)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

// MARK: - Comfortable Nordic Slate & Ocean Blue Palette (Spec §1 & §7)

struct BazerPalette: Equatable, Sendable {
    let isDark: Bool
    let panelBackground: Color
    let barBackground: Color
    let cardBackground: Color
    let cardHoverBackground: Color
    let subtleSurface: Color
    let inputSurface: Color
    let foldedContainerBackground: Color
    let foldedContainerBorder: Color
    let cardBorder: Color
    let cardHoverBorder: Color
    let divider: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let accentStrong: Color
    let accentText: Color
    let accentSoftBackground: Color
    let accentSoftBorder: Color
    let focusRing: Color
    let warningText: Color
    let warningBackground: Color
    let warningBorder: Color
    let dangerText: Color
    let dangerBackground: Color
    let dangerBorder: Color
    let backdropOverlay: Color

    /// Eye-friendly Nordic Slate Mist & Ocean Cobalt light theme
    static let light = BazerPalette(
        isDark: false,
        panelBackground: Color(red: 0.953, green: 0.965, blue: 0.980),        // #F3F6FA
        barBackground: Color(red: 0.973, green: 0.980, blue: 0.990),          // #F8FAFC
        cardBackground: Color(red: 1.000, green: 1.000, blue: 1.000),         // #FFFFFF
        cardHoverBackground: Color(red: 0.965, green: 0.978, blue: 1.000),    // #F6F9FF
        subtleSurface: Color(red: 0.925, green: 0.945, blue: 0.969),          // #ECF1F7
        inputSurface: Color(red: 0.949, green: 0.965, blue: 0.984),           // #F2F6FB
        foldedContainerBackground: Color(red: 0.918, green: 0.949, blue: 0.988), // #EAF2FC
        foldedContainerBorder: Color(red: 0.780, green: 0.859, blue: 0.965),  // #C7DBF6
        cardBorder: Color(red: 0.882, green: 0.910, blue: 0.945),             // #E1E8F1
        cardHoverBorder: Color(red: 0.545, green: 0.725, blue: 0.969),        // #8BB9F7
        divider: Color(red: 0.898, green: 0.922, blue: 0.953),                // #E5EBF3
        textPrimary: Color(red: 0.102, green: 0.141, blue: 0.204),            // #1A2434
        textSecondary: Color(red: 0.345, green: 0.408, blue: 0.494),          // #58687E
        textTertiary: Color(red: 0.506, green: 0.569, blue: 0.651),           // #8191A6
        accent: Color(red: 0.145, green: 0.388, blue: 0.922),                 // #2563EB
        accentStrong: Color(red: 0.000, green: 0.404, blue: 0.812),           // #0067CF
        accentText: Color(red: 0.000, green: 0.380, blue: 0.776),             // #0061C6 (WCAG AA+ on white/soft blue)
        accentSoftBackground: Color(red: 0.929, green: 0.957, blue: 1.000),   // #EDF4FF
        accentSoftBorder: Color(red: 0.200, green: 0.486, blue: 0.949),       // #337CF2
        focusRing: Color(red: 0.008, green: 0.518, blue: 0.780),              // #0284C7 (Distinct keyboard focus ring)
        warningText: Color(red: 0.686, green: 0.310, blue: 0.043),            // #AF4F0B
        warningBackground: Color(red: 0.996, green: 0.957, blue: 0.878),      // #FEF4E0
        warningBorder: Color(red: 0.976, green: 0.847, blue: 0.608),          // #F9D89B
        dangerText: Color(red: 0.725, green: 0.110, blue: 0.110),             // #B91C1C
        dangerBackground: Color(red: 0.996, green: 0.925, blue: 0.925),       // #FEECEC
        dangerBorder: Color(red: 0.973, green: 0.749, blue: 0.749),           // #F8BFBF
        backdropOverlay: Color.black.opacity(0.12)
    )

    /// Comfortable Deep Slate & Luminous Ocean Blue dark theme (replaces legacy neon green)
    static let dark = BazerPalette(
        isDark: true,
        panelBackground: Color(red: 0.078, green: 0.098, blue: 0.133),        // #141922
        barBackground: Color(red: 0.094, green: 0.118, blue: 0.161),          // #181E29
        cardBackground: Color(red: 0.118, green: 0.145, blue: 0.196),         // #1E2532
        cardHoverBackground: Color(red: 0.145, green: 0.180, blue: 0.247),    // #252E3F
        subtleSurface: Color(red: 0.157, green: 0.192, blue: 0.259),          // #283142
        inputSurface: Color(red: 0.098, green: 0.122, blue: 0.169),           // #191F2B
        foldedContainerBackground: Color(red: 0.102, green: 0.145, blue: 0.224), // #1A2539
        foldedContainerBorder: Color(red: 0.192, green: 0.290, blue: 0.447),  // #314A72
        cardBorder: Color(red: 0.176, green: 0.216, blue: 0.286),             // #2D3749
        cardHoverBorder: Color(red: 0.310, green: 0.514, blue: 0.929),        // #4F83ED
        divider: Color(red: 0.157, green: 0.192, blue: 0.255),                // #283141
        textPrimary: Color(red: 0.945, green: 0.961, blue: 0.976),            // #F1F5F9
        textSecondary: Color(red: 0.608, green: 0.675, blue: 0.769),          // #9BACc4
        textTertiary: Color(red: 0.435, green: 0.502, blue: 0.600),           // #6F8099
        accent: Color(red: 0.231, green: 0.510, blue: 0.965),                 // #3B82F6
        accentStrong: Color(red: 0.145, green: 0.388, blue: 0.922),           // #2563EB
        accentText: Color(red: 0.420, green: 0.675, blue: 0.992),             // #6BACFD
        accentSoftBackground: Color(red: 0.129, green: 0.200, blue: 0.333),   // #213355
        accentSoftBorder: Color(red: 0.345, green: 0.600, blue: 0.976),       // #5899F9
        focusRing: Color(red: 0.220, green: 0.741, blue: 0.973),              // #38BDF8
        warningText: Color(red: 0.984, green: 0.749, blue: 0.141),            // #FBBF24
        warningBackground: Color(red: 0.227, green: 0.173, blue: 0.086),      // #3A2C16
        warningBorder: Color(red: 0.459, green: 0.325, blue: 0.106),          // #75531B
        dangerText: Color(red: 0.973, green: 0.443, blue: 0.443),             // #F87171
        dangerBackground: Color(red: 0.235, green: 0.114, blue: 0.133),       // #3C1D22
        dangerBorder: Color(red: 0.498, green: 0.188, blue: 0.220),           // #7F3038
        backdropOverlay: Color.black.opacity(0.40)
    )

    static func resolve(mode: BazerAppearanceMode, systemScheme: ColorScheme) -> BazerPalette {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemScheme == .dark ? .dark : .light
        }
    }
}

private struct BazerPaletteKey: EnvironmentKey {
    static let defaultValue: BazerPalette = .light
}

extension EnvironmentValues {
    var bazerPalette: BazerPalette {
        get { self[BazerPaletteKey.self] }
        set { self[BazerPaletteKey.self] = newValue }
    }
}

// MARK: - Shared Visual Components

/// Battery progress bar with strict spec compliance (Spec §9.7):
/// - First appearance draws directly at current value (no 0 → value sweep).
/// - Known updates animate width with `standard 220 ms` (or immediate in Reduce Motion).
/// - Becoming unknown (`nil`) fades out fill in `100 ms` while keeping track (never animates to 0%).
struct BazerBatteryBar: View {
    let percent: Int?
    @Environment(\.bazerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedFraction: CGFloat = 0
    @State private var isFillVisible: Bool = false
    @State private var hasAppeared: Bool = false

    private var clampedFraction: CGFloat? {
        guard let percent else { return nil }
        return CGFloat(min(100, max(0, percent))) / 100.0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.subtleSurface)
                    .frame(height: 6)

                if isFillVisible {
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: max(6, geo.size.width * displayedFraction), height: 6)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 6)
        .onAppear {
            if let fraction = clampedFraction {
                displayedFraction = fraction
                isFillVisible = fraction > 0
            } else {
                isFillVisible = false
            }
            hasAppeared = true
        }
        .onChange(of: percent) { newValue in
            guard hasAppeared else { return }
            if let newPercent = newValue {
                let target = CGFloat(min(100, max(0, newPercent))) / 100.0
                if !isFillVisible {
                    displayedFraction = target
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) {
                        isFillVisible = target > 0
                    }
                } else if reduceMotion {
                    displayedFraction = target
                    isFillVisible = target > 0
                } else {
                    withAnimation(BazerMotion.batteryFill) {
                        displayedFraction = target
                        isFillVisible = target > 0
                    }
                }
            } else {
                // Fade out in 100ms without animating width to 0%
                withAnimation(.easeOut(duration: 0.10)) {
                    isFillVisible = false
                }
            }
        }
    }
}

/// Shows native indefinite progress only if still active after 150 ms (Spec §3.2 & §9.6),
/// and uses a static indicator when Reduce Motion is active (Spec §11).
struct BazerDelayedProgressView: View {
    let isActive: Bool
    var reduceMotionText: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bazerPalette) private var palette
    @State private var showDelayed = false
    @State private var delayTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isActive && showDelayed {
                if reduceMotion {
                    HStack(spacing: 4) {
                        Image(systemName: "ellipsis.circle")
                            .font(.caption)
                            .foregroundStyle(palette.accentText)
                        if let text = reduceMotionText {
                            Text(text)
                                .font(.caption2)
                                .foregroundStyle(palette.textSecondary)
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .onAppear { updateState(isActive) }
        .onChange(of: isActive) { active in updateState(active) }
        .onDisappear {
            delayTask?.cancel()
            delayTask = nil
        }
    }

    private func updateState(_ active: Bool) {
        delayTask?.cancel()
        delayTask = nil
        if active {
            delayTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                showDelayed = true
            }
        } else {
            showDelayed = false
        }
    }
}

/// Single-select radio circle indicator (Spec §4.2 & §9.6)
struct BazerRadioIndicator: View {
    enum State: Equatable {
        case unselected
        case confirmed
        case pending
    }

    let state: State
    @Environment(\.bazerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    state == .unselected ? palette.textTertiary.opacity(0.65) : palette.accent,
                    lineWidth: state == .unselected ? 1.5 : 1.75
                )
                .frame(width: 16, height: 16)

            if state == .confirmed {
                Circle()
                    .fill(palette.accent)
                    .frame(width: 8.5, height: 8.5)
                    .scaleEffect(1.0)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.80).combined(with: .opacity))
            } else if state == .pending {
                Circle()
                    .strokeBorder(palette.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 9, height: 9)
            }
        }
        .animation(reduceMotion ? BazerMotion.reduced : BazerMotion.selectSpring, value: state)
    }
}

/// Button style for device card body: scales to 0.99 on press (80 ms standard), no scale when Reduce Motion is enabled.
struct BazerCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1.0)
            .animation(reduceMotion ? nil : BazerMotion.cardPress, value: configuration.isPressed)
    }
}
