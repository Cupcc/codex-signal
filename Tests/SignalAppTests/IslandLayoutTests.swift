import Foundation
import SwiftUI
import Testing
@testable import SignalApp

struct IslandLayoutTests {
    @Test func expandedPanelFitsMeasuredContentAndKeepsTopEdgeFixed() {
        let geometry = IslandScreenGeometry(screenWidth: 1920, safeAreaTop: 0,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 24)
        for contentHeight: CGFloat in [224, 292, 360, 428, 496, 274] {
            let layout = IslandLayout(geometry: geometry, availableWidth: 1896, availableHeight: 1000,
                                      contentHeight: contentHeight)
            let frame = layout.frame(expanded: true, centerX: 960, top: 1048, scale: 2)
            #expect(frame.height == contentHeight)
            #expect(frame.maxY == 1048)
            #expect(frame.midX == 960)
            #expect(frame.width == 404)
        }
    }

    @Test func fractionalContentHeightRoundsUpWithoutMovingTopEdge() {
        let geometry = IslandScreenGeometry(screenWidth: 1920, safeAreaTop: 0,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 24)
        let layout = IslandLayout(geometry: geometry, availableWidth: 1896, availableHeight: 1000,
                                  contentHeight: 231.3)
        let frame = layout.frame(expanded: true, centerX: 960, top: 1048, scale: 2)
        #expect(frame.height == 231.5)
        #expect(frame.maxY == 1048)
        #expect(frame.minY * 2 == (frame.minY * 2).rounded())
    }

    @Test func expandedHeightLimitPreservesNotchHeaderSpace() {
        for inset: CGFloat in [32, 40] {
            let geometry = IslandScreenGeometry(screenWidth: 1512, safeAreaTop: inset,
                                                auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660,
                                                menuBarHeight: inset)
            let maximumHeight = 530 + inset - 32
            let short = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900,
                                     contentHeight: 224 + inset - 32)
            let full = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900,
                                    contentHeight: 1200)
            let unmeasured = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900)
            #expect(short.expandedSize.height == 224 + inset - 32)
            #expect(full.expandedSize.height == maximumHeight)
            #expect(unmeasured.expandedSize.height == maximumHeight)
        }
    }

    @Test func measuredNotchLeavesRoomForBothWings() {
        let geometry = IslandScreenGeometry(screenWidth: 1512, safeAreaTop: 32,
                                            auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660,
                                            menuBarHeight: 32)
        let layout = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900, contentHeight: 458)
        #expect(geometry.width == 192)
        #expect(layout.topInset == 32)
        #expect(layout.compactSize.width - layout.notchWidth == 164)
        #expect(layout.expandedSize.width >= layout.compactSize.width)
        #expect(layout.headerUsesNotchSpace)
        #expect(layout.expandedSize.height >= 450)
        #expect(layout.expandedSize.height < 470)
    }

    @Test func floatingScreenDoesNotReserveNotchSpace() {
        let geometry = IslandScreenGeometry(screenWidth: 1920, safeAreaTop: 0,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 24)
        let layout = IslandLayout(geometry: geometry, availableWidth: 1896, availableHeight: 1000, contentHeight: 458)
        #expect(layout.notchWidth == 0)
        #expect(layout.topInset == 0)
        #expect(!layout.headerUsesNotchSpace)
        #expect(layout.compactSize == CGSize(width: 164, height: 32))
    }

    @Test func tinyDisplayClampsBothModesInsideAvailableArea() {
        let geometry = IslandScreenGeometry(screenWidth: 320, safeAreaTop: 32,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 32)
        let layout = IslandLayout(geometry: geometry, availableWidth: 296, availableHeight: 200, contentHeight: 1000)
        #expect(!layout.headerUsesNotchSpace)
        for expanded in [false, true] {
            let frame = layout.frame(expanded: expanded, centerX: 160, top: 220, scale: 2)
            #expect(frame.minX >= 12)
            #expect(frame.maxX <= 308)
            #expect(frame.minY >= 20)
            #expect(frame.maxY == 220)
        }
    }

    @Test func widerNotchLeavesEveryHeaderButtonOutsideCamera() {
        let geometry = IslandScreenGeometry(screenWidth: 1512, safeAreaTop: 32,
                                            auxiliaryLeftWidth: 636, auxiliaryRightWidth: 636,
                                            menuBarHeight: 32)
        let layout = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900, contentHeight: 458)
        let usableWingWidth = (layout.expandedSize.width - geometry.width) / 2 - IslandLayout.headerSideInset
        #expect(layout.headerUsesNotchSpace)
        #expect(usableWingWidth >= IslandLayout.headerControlsWidth)
    }

    @Test func expandingKeepsTopCenteredOnNegativeCoordinateDisplay() {
        let geometry = IslandScreenGeometry(screenWidth: 1728, safeAreaTop: 0,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 24)
        let layout = IslandLayout(geometry: geometry, availableWidth: 1704, availableHeight: 900, contentHeight: 458)
        let compact = layout.frame(expanded: false, centerX: -864, top: 1050, scale: 2)
        let expanded = layout.frame(expanded: true, centerX: -864, top: 1050, scale: 2)
        #expect(compact.maxY == expanded.maxY)
        #expect(compact.midX == expanded.midX)
        #expect(expanded.minX * 2 == (expanded.minX * 2).rounded())
    }

    @Test func transientNoticeStaysBelowCameraAndKeepsTopEdgeFixed() {
        for inset: CGFloat in [0, 32] {
            let geometry = IslandScreenGeometry(screenWidth: 1512, safeAreaTop: inset,
                                                auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660, menuBarHeight: 24)
            let layout = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900, contentHeight: 1000)
            let compact = layout.frame(expanded: false, centerX: 756, top: 900, scale: 2)
            let notice = layout.frame(expanded: false, alerting: true, centerX: 756, top: 900, scale: 2)
            #expect(notice.maxY == compact.maxY)
            #expect(notice.midX == compact.midX)
            #expect(notice.height == compact.height + 78)
            #expect(notice.width >= compact.width)
            #expect(notice.height < layout.expandedSize.height)
            #expect(layout.size(expanded: true, alerting: true) == layout.expandedSize)
        }
    }

    @Test func malformedScreenHintsFallBackToFiniteGeometry() {
        let geometry = IslandScreenGeometry(screenWidth: 1440, safeAreaTop: 32,
                                            auxiliaryLeftWidth: .nan, auxiliaryRightWidth: 1000,
                                            menuBarHeight: 32)
        #expect(geometry.width == IslandScreenGeometry.fallbackNotchWidth)
        let external = IslandScreenGeometry(screenWidth: 1440, safeAreaTop: .nan,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: -8)
        #expect(!external.hasNotch)
        #expect(external.height == 0)
    }

    @Test func notchShouldersStayInsideFrameAndLeaveCenterSolid() {
        let rect = CGRect(x: 0, y: 0, width: 404, height: 542)
        let path = IslandOutline(attached: true, radius: 22).path(in: rect)
        #expect(path.boundingRect == rect)
        #expect(path.contains(CGPoint(x: 202, y: 1)))
        #expect(path.contains(CGPoint(x: 202, y: 541)))
        #expect(!path.contains(CGPoint(x: 2, y: 20)))
        #expect(!path.contains(CGPoint(x: 402, y: 20)))
    }
}
