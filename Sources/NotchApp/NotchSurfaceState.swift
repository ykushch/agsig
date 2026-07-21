import Observation
import SwiftUI

@Observable
@MainActor
final class NotchSurfaceState {
    var presentation: NotchPresentation = .compact
    var geometry: NotchGeometry
    var reduceMotion: Bool
    var compactIndicatorMode: CompactIndicatorMode
    private(set) var isCompactHovered = false
    private(set) var requestedExpandedHeight: CGFloat
    private(set) var renderedExpandedHeight: CGFloat

    private var sizingIdentity = ""
    private var focusedContentFloor: CGFloat = 0

    private var hoverCollapseTask: Task<Void, Never>?

    init(
        geometry: NotchGeometry,
        reduceMotion: Bool,
        compactIndicatorMode: CompactIndicatorMode = .revealOnHover
    ) {
        self.geometry = geometry
        self.reduceMotion = reduceMotion
        self.compactIndicatorMode = compactIndicatorMode
        requestedExpandedHeight = geometry.minimumOverviewHeight
        renderedExpandedHeight = geometry.minimumOverviewHeight
    }

    var visibleSize: CGSize {
        presentation.isExpanded
            ? geometry.expandedSize(requestedHeight: renderedExpandedHeight)
            : geometry.compactSize(revealed: isCompactIndicatorRevealed)
    }

    var isCompactIndicatorRevealed: Bool {
        compactIndicatorMode == .alwaysShow || isCompactHovered
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

    func updateCompactIndicatorMode(_ mode: CompactIndicatorMode) {
        guard compactIndicatorMode != mode else { return }
        hoverCollapseTask?.cancel()
        isCompactHovered = false
        compactIndicatorMode = mode
    }

    func setCompactHovering(_ hovering: Bool) {
        guard presentation == .compact, compactIndicatorMode == .revealOnHover else { return }
        hoverCollapseTask?.cancel()
        if hovering {
            withAnimation(animation) { isCompactHovered = true }
            return
        }
        hoverCollapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            withAnimation(self.animation) { self.isCompactHovered = false }
        }
    }

    func clearCompactHover() {
        hoverCollapseTask?.cancel()
        isCompactHovered = false
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
