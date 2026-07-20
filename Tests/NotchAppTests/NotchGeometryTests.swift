import AppKit
import Testing
@testable import NotchApp

@Suite("Notch geometry")
struct NotchGeometryTests {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)

    @Test("Physical notch uses the auxiliary-area gap")
    func physicalNotchGap() {
        let metrics = NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 950),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32))

        let geometry = NotchGeometry(metrics: metrics)

        #expect(NotchGeometry.physicalNotchWidth(metrics: metrics) == 200)
        #expect(geometry.compactSize.width == 208)
        #expect(geometry.compactSize.height == 50)
        #expect(geometry.topContentInset == 32)
    }

    @Test("A side Dock does not alter physical-notch width")
    func sideDockDoesNotAlterNotch() {
        let metrics = NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: CGRect(x: 80, y: 0, width: 1_432, height: 950),
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32))

        #expect(NotchGeometry(metrics: metrics).compactSize.width == 208)
    }

    @Test("External displays use the compact floating fallback")
    func externalDisplayFallback() {
        let metrics = NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 23, width: 1_512, height: 959),
            safeAreaTop: 0)

        let geometry = NotchGeometry(metrics: metrics)

        #expect(geometry.compactSize == CGSize(width: 190, height: 30))
        #expect(geometry.topContentInset == 0)
    }

    @Test("Compact and expanded frames stay top-centered")
    func topAnchoredFrames() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaTop: 0))

        let compact = geometry.panelFrame(on: screenFrame, expanded: false)
        let expanded = geometry.panelFrame(on: screenFrame, expanded: true)

        #expect(compact.maxY == screenFrame.maxY)
        #expect(expanded.maxY == screenFrame.maxY)
        #expect(compact.midX == screenFrame.midX)
        #expect(expanded.midX == screenFrame.midX)
    }

    @Test("Expanded canvas clamps to a small visible frame")
    func expandedCanvasClamps() {
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 420, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 420, height: 400),
            safeAreaTop: 0))

        #expect(geometry.expandedSize.width == 396)
        #expect(geometry.expandedSize.height == 288)
    }
}
