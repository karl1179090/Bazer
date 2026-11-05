// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The compact shell keeps the 315 pt width and adds 25% to its original half-height.
/// The bars keep their own height; only the body and modal content scroll.
enum BazerPanelMetrics {
    static let previousWidth: CGFloat = 420
    static let widthScale: CGFloat = 0.75
    static let heightScale: CGFloat = 0.5 * 1.25
    static let width = previousWidth * widthScale
    static let headerHeight: CGFloat = 50
    static let footerHeight: CGFloat = 40
    static let pagePadding: CGFloat = 12
    static let overlayPadding: CGFloat = 10

    static func previousHeight(visibleScreenHeight: CGFloat) -> CGFloat {
        min(680, max(500, visibleScreenHeight - 72))
    }

    static func size(visibleScreenHeight: CGFloat) -> CGSize {
        CGSize(width: width, height: previousHeight(visibleScreenHeight: visibleScreenHeight) * heightScale)
    }

    static func positioningRect(buttonBounds: CGRect, imageRect: CGRect?) -> CGRect {
        let centreX = imageRect.flatMap { $0.isEmpty ? nil : $0.midX } ?? buttonBounds.midX
        return CGRect(x: centreX - 0.5, y: buttonBounds.minY, width: 1, height: buttonBounds.height)
    }

    static func bodyHeight(panelHeight: CGFloat) -> CGFloat {
        max(0, panelHeight - headerHeight - footerHeight - 2)
    }
}

/// Only a genuine hidden → shown transition creates an open session. Navigation,
/// view updates, application activation and a native modal returning do not enter it.
struct PanelOpenSessionTracker {
    private(set) var openSessionID: UUID?

    mutating func didShow() -> UUID? {
        guard openSessionID == nil else { return nil }
        let id = UUID()
        openSessionID = id
        return id
    }

    @discardableResult
    mutating func didClose() -> Bool {
        guard openSessionID != nil else { return false }
        openSessionID = nil
        return true
    }

    static func shouldDismissForOutsideClick(isNativeModalPresented: Bool, isInsidePanel: Bool, isStatusItem: Bool, isMenu: Bool) -> Bool {
        !isNativeModalPresented && !isInsidePanel && !isStatusItem && !isMenu
    }
}
