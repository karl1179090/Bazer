// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import BazerApp

struct PanelPresentationTests {
    @Test func panelKeepsItsWidthAndAddsTwentyFivePercentHeightAcrossScreens() {
        for height: CGFloat in [480, 600, 720, 800, 1039, 1080, 1440] {
            let compact = BazerPanelMetrics.size(visibleScreenHeight: height)
            #expect(compact.width == 315)
            #expect(compact.width == BazerPanelMetrics.previousWidth * 0.75)
            #expect(compact.height == BazerPanelMetrics.previousHeight(visibleScreenHeight: height) * 0.5 * 1.25)
            #expect(BazerPanelMetrics.bodyHeight(panelHeight: compact.height) >= 158)
        }
        #expect(BazerPanelMetrics.size(visibleScreenHeight: 1080) == CGSize(width: 315, height: 425))
        #expect(BazerPanelMetrics.size(visibleScreenHeight: 600) == CGSize(width: 315, height: 330))
        #expect(BazerPanelMetrics.headerHeight == 50)
        #expect(BazerPanelMetrics.footerHeight == 40)
    }

    @Test func popoverAnchorUsesTheActualIconCentreWhenPercentageAddsButtonWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 24)
        let image = CGRect(x: 5, y: 4, width: 20, height: 16)
        let anchor = BazerPanelMetrics.positioningRect(buttonBounds: bounds, imageRect: image)
        #expect(anchor.midX == image.midX)
        #expect(anchor.midX != bounds.midX)
        #expect(anchor.width == 1)
        #expect(anchor.minY == bounds.minY)
        #expect(BazerPanelMetrics.positioningRect(buttonBounds: bounds, imageRect: .zero).midX == bounds.midX)
    }

    @Test func actualShowCreatesOneSessionAndReusedHiddenPanelGetsANewSession() throws {
        var lifecycle = PanelOpenSessionTracker()
        let initiallyClosed = lifecycle.didClose()
        #expect(!initiallyClosed)
        let firstCandidate = lifecycle.didShow()
        let first = try #require(firstCandidate)
        let duplicateShow = lifecycle.didShow()
        #expect(duplicateShow == nil)
        #expect(lifecycle.openSessionID == first)
        let firstClose = lifecycle.didClose()
        let duplicateClose = lifecycle.didClose()
        #expect(firstClose)
        #expect(!duplicateClose)
        let reusedCandidate = lifecycle.didShow()
        let reused = try #require(reusedCandidate)
        #expect(reused != first)
        let duplicateReusedShow = lifecycle.didShow()
        #expect(duplicateReusedShow == nil)
    }

    @Test func nativeModalAndMenuClicksKeepTheExistingOpenSession() throws {
        var lifecycle = PanelOpenSessionTracker()
        let candidate = lifecycle.didShow()
        let session = try #require(candidate)
        for flags in [(true, false, false, false), (false, true, false, false), (false, false, true, false), (false, false, false, true)] {
            #expect(!PanelOpenSessionTracker.shouldDismissForOutsideClick(
                isNativeModalPresented: flags.0, isInsidePanel: flags.1, isStatusItem: flags.2, isMenu: flags.3))
        }
        #expect(lifecycle.openSessionID == session)
        let duplicateShow = lifecycle.didShow()
        #expect(duplicateShow == nil)
        #expect(PanelOpenSessionTracker.shouldDismissForOutsideClick(
            isNativeModalPresented: false, isInsidePanel: false, isStatusItem: false, isMenu: false))
        let didClose = lifecycle.didClose()
        #expect(didClose)
        let reopenedCandidate = lifecycle.didShow()
        let reopened = try #require(reopenedCandidate)
        #expect(reopened != session)
    }
}
