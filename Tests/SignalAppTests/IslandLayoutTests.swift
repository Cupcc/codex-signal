import Foundation
import SwiftUI
import Testing
@testable import SignalApp

struct IslandLayoutTests {
    @Test func measuredNotchLeavesRoomForBothWings() {
        let geometry = IslandScreenGeometry(screenWidth: 1512, safeAreaTop: 32,
                                            auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660,
                                            menuBarHeight: 32)
        let layout = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900, sessionCount: 3)
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
        let layout = IslandLayout(geometry: geometry, availableWidth: 1896, availableHeight: 1000, sessionCount: 3)
        #expect(layout.notchWidth == 0)
        #expect(layout.topInset == 0)
        #expect(!layout.headerUsesNotchSpace)
        #expect(layout.compactSize == CGSize(width: 164, height: 32))
    }

    @Test func tinyDisplayClampsBothModesInsideAvailableArea() {
        let geometry = IslandScreenGeometry(screenWidth: 320, safeAreaTop: 32,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 32)
        let layout = IslandLayout(geometry: geometry, availableWidth: 296, availableHeight: 200, sessionCount: 12)
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
        let layout = IslandLayout(geometry: geometry, availableWidth: 1488, availableHeight: 900, sessionCount: 3)
        let usableWingWidth = (layout.expandedSize.width - geometry.width) / 2 - IslandLayout.headerSideInset
        #expect(layout.headerUsesNotchSpace)
        #expect(usableWingWidth >= IslandLayout.headerControlsWidth)
    }

    @Test func expandingKeepsTopCenteredOnNegativeCoordinateDisplay() {
        let geometry = IslandScreenGeometry(screenWidth: 1728, safeAreaTop: 0,
                                            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
                                            menuBarHeight: 24)
        let layout = IslandLayout(geometry: geometry, availableWidth: 1704, availableHeight: 900, sessionCount: 3)
        let compact = layout.frame(expanded: false, centerX: -864, top: 1050, scale: 2)
        let expanded = layout.frame(expanded: true, centerX: -864, top: 1050, scale: 2)
        #expect(compact.maxY == expanded.maxY)
        #expect(compact.midX == expanded.midX)
        #expect(expanded.minX * 2 == (expanded.minX * 2).rounded())
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
