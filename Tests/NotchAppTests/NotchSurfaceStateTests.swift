import AppKit
import Testing
@testable import NotchApp

@Suite("Adaptive notch surface", .serialized)
@MainActor
struct NotchSurfaceStateTests {
    private func geometry(safeAreaTop: CGFloat = 0) -> NotchGeometry {
        NotchGeometry(metrics: NotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 950),
            safeAreaTop: safeAreaTop,
            auxiliaryTopLeftArea: safeAreaTop > 0
                ? CGRect(x: 0, y: 950, width: 656, height: 32) : nil,
            auxiliaryTopRightArea: safeAreaTop > 0
                ? CGRect(x: 856, y: 950, width: 656, height: 32) : nil))
    }

    private func compactState(
        mode: CompactIndicatorMode = .revealOnHover,
        reduceMotion: Bool = true
    ) -> NotchSurfaceState {
        NotchSurfaceState(
            geometry: geometry(safeAreaTop: 32),
            reduceMotion: reduceMotion,
            compactIndicatorMode: mode)
    }

    @Test("Overview measurements resize only for material changes")
    func overviewMeasurementThreshold() {
        let state = NotchSurfaceState(geometry: geometry(), reduceMotion: false)
        state.prepareOverview(estimatedHeight: 250)

        state.reportOverviewHeight(252)
        #expect(state.requestedExpandedHeight == 250)

        state.reportOverviewHeight(254)
        #expect(state.requestedExpandedHeight == 254)
    }

    @Test("Focused content stays stable while the explicit shelf can close")
    func focusedContentFloor() {
        let state = NotchSurfaceState(geometry: geometry(), reduceMotion: false)
        state.prepareFocused(identity: "pane-1", estimatedHeight: 330)

        state.reportFocusedHeight(
            chromeAndContentHeight: 260,
            shelfHeight: 60,
            identity: "pane-1")
        #expect(state.requestedExpandedHeight == 320)

        state.reportFocusedHeight(
            chromeAndContentHeight: 230,
            shelfHeight: 100,
            identity: "pane-1")
        #expect(state.requestedExpandedHeight == 360)

        state.reportFocusedHeight(
            chromeAndContentHeight: 230,
            shelfHeight: 60,
            identity: "pane-1")
        #expect(state.requestedExpandedHeight == 320)
    }

    @Test("A new interaction in the same pane resets the content floor")
    func changedInteractionResetsContentFloor() {
        let state = NotchSurfaceState(geometry: geometry(), reduceMotion: false)
        state.prepareFocused(identity: "pane-1:first", estimatedHeight: 330)
        state.reportFocusedHeight(
            chromeAndContentHeight: 360,
            shelfHeight: 60,
            identity: "pane-1:first")
        #expect(state.requestedExpandedHeight == 420)

        state.prepareFocused(identity: "pane-1:second", estimatedHeight: 310)
        #expect(state.requestedExpandedHeight == 310)
    }

    @Test("Reduce Motion disables shell animation")
    func reduceMotion() {
        let state = NotchSurfaceState(geometry: geometry(), reduceMotion: true)
        #expect(state.animation == nil)
    }

    @Test("Hover mode starts minimal and reveals on entry")
    func hoverReveal() {
        let state = compactState()
        #expect(!state.isCompactIndicatorRevealed)
        #expect(state.visibleSize.height == 35)

        state.setCompactHovering(true)
        #expect(state.isCompactIndicatorRevealed)
        #expect(state.visibleSize.height == 44)
    }

    @Test("Always-show mode stays revealed")
    func alwaysShow() {
        let state = compactState(mode: .alwaysShow)
        #expect(state.isCompactIndicatorRevealed)
        #expect(state.visibleSize.height == 44)

        state.setCompactHovering(false)
        #expect(state.isCompactIndicatorRevealed)
    }

    @Test("Hover exit is delayed and a repeated entry cancels collapse")
    func delayedHoverExit() async throws {
        let state = compactState()
        state.setCompactHovering(true)
        state.setCompactHovering(false)
        try await Task.sleep(for: .milliseconds(100))
        state.setCompactHovering(true)
        try await Task.sleep(for: .milliseconds(320))
        #expect(state.isCompactIndicatorRevealed)

        state.setCompactHovering(false)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!state.isCompactIndicatorRevealed)
    }

    @Test("Expanded presentation ignores compact hover")
    func expandedIgnoresHover() {
        let state = compactState()
        state.presentation = .overview
        state.setCompactHovering(true)
        #expect(!state.isCompactHovered)
        #expect(state.visibleSize == state.geometry.expandedSize(
            requestedHeight: state.renderedExpandedHeight))
    }
}
