// Adapted from Coucou b1bc09de7f7c24a80bd8eca5729b8bee60f66402.
// Copyright (c) 2026 Louis Raillé. MIT license in ThirdParty/Coucou-LICENSE.txt.
import Foundation

struct IslandScreenGeometry {
    static let fallbackNotchWidth: CGFloat = 184
    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat,
         auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
         menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop.isFinite && safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth,
               left >= 0, right >= 0 {
                let measured = screenWidth - left - right
                width = measured.isFinite && measured > 0 && measured < screenWidth ? measured : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = 0
            height = menuBarHeight.isFinite ? min(24, max(0, menuBarHeight)) : 24
        }
    }
}

/// One sizing policy shared by the window and its fixed-width content. Keep the
/// top edge stationary and leave room for a selected row plus three sessions.
struct IslandLayout: Equatable {
    static let headerSideInset: CGFloat = 14
    // Three 28-point buttons and two 2-point gaps must fit beside the camera.
    static let headerControlsWidth: CGFloat = 88
    var notchWidth: CGFloat = 0
    var topInset: CGFloat = 0
    var compactSize = CGSize(width: 164, height: 32)
    var expandedSize = CGSize(width: 404, height: 458)
    var noticeSize = CGSize(width: 360, height: 110)

    var headerUsesNotchSpace: Bool {
        topInset > 0 && expandedSize.width >= notchWidth + 2 * (Self.headerSideInset + Self.headerControlsWidth)
    }

    init() {}

    init(geometry: IslandScreenGeometry, availableWidth: CGFloat, availableHeight: CGFloat, sessionCount: Int) {
        notchWidth = geometry.hasNotch ? geometry.width : 0
        topInset = geometry.hasNotch ? geometry.height : 0
        let widthLimit = max(1, availableWidth)
        let heightLimit = max(1, availableHeight)
        compactSize = CGSize(width: min(widthLimit, notchWidth + 164),
                             height: min(heightLimit, max(32, topInset)))
        expandedSize.width = min(widthLimit, max(404, notchWidth + 2 * (Self.headerSideInset + Self.headerControlsWidth)))
        let contentHeight = sessionCount == 0 ? 274 : 242 + CGFloat(min(4, max(1, sessionCount))) * 72
        let extraHeaderHeight = headerUsesNotchSpace ? max(0, topInset - 32) : topInset
        expandedSize.height = min(heightLimit, contentHeight + extraHeaderHeight)
        noticeSize = CGSize(width: min(widthLimit, max(360, compactSize.width)),
                            height: min(heightLimit, compactSize.height + 78))
    }

    func size(expanded: Bool, alerting: Bool = false) -> CGSize { expanded ? expandedSize : alerting ? noticeSize : compactSize }

    func frame(expanded: Bool, alerting: Bool = false, centerX: CGFloat, top: CGFloat, scale: CGFloat) -> CGRect {
        let size = size(expanded: expanded, alerting: alerting)
        let pixelScale = max(1, scale)
        // Align to physical pixels; a fractional left edge makes the border fuzzy.
        return CGRect(x: ((centerX - size.width / 2) * pixelScale).rounded() / pixelScale,
                      y: ((top - size.height) * pixelScale).rounded() / pixelScale,
                      width: size.width, height: size.height)
    }
}
