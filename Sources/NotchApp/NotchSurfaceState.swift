import Observation
import SwiftUI

@Observable
@MainActor
final class NotchSurfaceState {
    var presentation: NotchPresentation = .compact
    var geometry: NotchGeometry
    var reduceMotion: Bool
    private(set) var requestedExpandedHeight: CGFloat
    private(set) var renderedExpandedHeight: CGFloat

    private var sizingIdentity = ""
    private var focusedContentFloor: CGFloat = 0

    init(geometry: NotchGeometry, reduceMotion: Bool) {
        self.geometry = geometry
        self.reduceMotion = reduceMotion
        requestedExpandedHeight = geometry.minimumOverviewHeight
        renderedExpandedHeight = geometry.minimumOverviewHeight
    }

    var visibleSize: CGSize {
        presentation.isExpanded
            ? geometry.expandedSize(requestedHeight: renderedExpandedHeight)
            : geometry.compactSize
    }

    var animation: Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.34, dampingFraction: 0.86)
    }

    var requestedExpandedSize: CGSize {
        geometry.expandedSize(requestedHeight: requestedExpandedHeight)
    }

    func updateGeometry(_ newGeometry: NotchGeometry) {
        geometry = newGeometry
        requestedExpandedHeight = min(requestedExpandedHeight, newGeometry.maximumExpandedHeight)
        renderedExpandedHeight = min(renderedExpandedHeight, newGeometry.maximumExpandedHeight)
    }

    func prepareOverview(estimatedHeight: CGFloat) {
        guard sizingIdentity != "overview" else { return }
        sizingIdentity = "overview"
        focusedContentFloor = 0
        seedExpandedHeight(geometry.clampOverviewHeight(estimatedHeight))
    }

    func prepareFocused(identity: String, estimatedHeight: CGFloat) {
        let identity = "focused:\(identity)"
        guard sizingIdentity != identity else { return }
        sizingIdentity = identity
        focusedContentFloor = 0
        seedExpandedHeight(geometry.clampFocusedHeight(estimatedHeight))
    }

    func reportOverviewHeight(_ naturalHeight: CGFloat) {
        guard sizingIdentity == "overview" else { return }
        updateRequestedHeight(geometry.clampOverviewHeight(naturalHeight))
    }

    func reportFocusedHeight(
        chromeAndContentHeight: CGFloat,
        shelfHeight: CGFloat,
        identity: String
    ) {
        guard sizingIdentity == "focused:\(identity)" else { return }
        focusedContentFloor = max(focusedContentFloor, chromeAndContentHeight)
        updateRequestedHeight(geometry.clampFocusedHeight(focusedContentFloor + shelfHeight))
    }

    func setRenderedExpandedHeight(_ height: CGFloat) {
        renderedExpandedHeight = min(geometry.maximumExpandedHeight, max(1, height))
    }

    private func seedExpandedHeight(_ height: CGFloat) {
        requestedExpandedHeight = height
        renderedExpandedHeight = height
    }

    private func updateRequestedHeight(_ height: CGFloat) {
        guard NotchGeometry.materiallyDifferent(height, requestedExpandedHeight) else { return }
        requestedExpandedHeight = height
    }
}
