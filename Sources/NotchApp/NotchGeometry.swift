import AppKit

struct NotchScreenMetrics: Sendable, Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?

    init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect? = nil,
        auxiliaryTopRightArea: CGRect? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea)
    }

    var hasPhysicalNotch: Bool { safeAreaTop > 0 }
}

struct NotchGeometry: Sendable, Equatable {
    static let floatingCompactWidth: CGFloat = 190
    static let floatingCompactHeight: CGFloat = 30
    static let notchHorizontalSeam: CGFloat = 8
    static let notchChinHeight: CGFloat = 18
    static let preferredExpandedSize = CGSize(width: 520, height: 420)

    let compactSize: CGSize
    let expandedSize: CGSize
    let topContentInset: CGFloat

    init(metrics: NotchScreenMetrics) {
        let compactWidth = Self.physicalNotchWidth(metrics: metrics)
            .map { $0 + Self.notchHorizontalSeam }
            ?? Self.floatingCompactWidth
        let compactHeight = metrics.hasPhysicalNotch
            ? max(Self.floatingCompactHeight, metrics.safeAreaTop + Self.notchChinHeight)
            : Self.floatingCompactHeight
        let availableWidth = max(1, metrics.visibleFrame.width - 24)
        let availableHeight = max(1, metrics.visibleFrame.height * 0.72)

        compactSize = CGSize(width: compactWidth, height: compactHeight)
        expandedSize = CGSize(
            width: min(Self.preferredExpandedSize.width, availableWidth),
            height: min(Self.preferredExpandedSize.height, availableHeight))
        topContentInset = metrics.hasPhysicalNotch ? metrics.safeAreaTop : 0
    }

    static func physicalNotchWidth(metrics: NotchScreenMetrics) -> CGFloat? {
        guard metrics.hasPhysicalNotch,
              let left = metrics.auxiliaryTopLeftArea,
              let right = metrics.auxiliaryTopRightArea
        else { return nil }

        let gap = right.minX - left.maxX
        guard gap > 80, gap < 400 else { return nil }
        return gap
    }

    func panelFrame(on screenFrame: CGRect, expanded: Bool) -> CGRect {
        let size = expanded ? expandedSize : compactSize
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height)
    }
}
