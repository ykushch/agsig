import AppKit
import Testing
@testable import NotchApp

@Suite("Adaptive notch surface", .serialized)
@MainActor
struct NotchSurfaceStateTests {
    private func geometry() -> NotchGeometry {
        NotchGeometry(metrics: NotchScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 950),
            safeAreaTop: 0))
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
}
