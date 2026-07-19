import AppKit
import Observation
import SwiftUI

@MainActor
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let panel: NotchPanel
    private let hostingView: NSHostingView<PlaceholderNotchView>

    private let fallbackNotchWidth: CGFloat = 190
    private let collapsedHeight: CGFloat = 30

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        let screen = Self.notchScreen()
        let width = Self.notchWidth(on: screen) ?? fallbackNotchWidth
        let frame = Self.frame(on: screen, width: width, height: collapsedHeight)
        panel = NotchPanel(contentRect: frame)
        hostingView = NSHostingView(rootView: PlaceholderNotchView(model: viewModel, notchWidth: width))
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    func show() {
        applyPresentation()
        panel.orderFrontRegardless()
        observePresentation()
    }

    func tearDown() { panel.orderOut(nil) }

    private func observePresentation() {
        withObservationTracking {
            _ = viewModel.presentation
            _ = viewModel.selectedPaneID
            _ = viewModel.agentCount
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyPresentation(); self?.observePresentation() }
        }
    }

    private func applyPresentation() {
        let screen = Self.notchScreen()
        let notchWidth = Self.notchWidth(on: screen) ?? fallbackNotchWidth
        let width = viewModel.isExpanded ? Self.expandedWidth(on: screen) : notchWidth
        let height = viewModel.isExpanded ? Self.expandedHeight(
            on: screen, agentCount: viewModel.agentCount,
            hasSelectedDetail: viewModel.selectedPaneID != nil) : collapsedHeight
        hostingView.rootView = PlaceholderNotchView(model: viewModel, notchWidth: notchWidth)
        panel.isInteractive = viewModel.isExpanded
        panel.setFrame(
            Self.frame(on: screen, width: width, height: height),
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panel.orderFrontRegardless()
    }

    private static func notchScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func notchWidth(on screen: NSScreen) -> CGFloat? {
        let frame = screen.frame
        let safe = screen.visibleFrame
        let left = safe.minX - frame.minX
        let right = frame.maxX - safe.maxX
        let value = frame.width - left - right
        return value > 80 && value < 400 ? value : nil
    }

    private static func expandedWidth(on screen: NSScreen) -> CGFloat {
        min(520, max(380, screen.visibleFrame.width * 0.38))
    }

    private static func expandedHeight(
        on screen: NSScreen, agentCount: Int, hasSelectedDetail: Bool
    ) -> CGFloat {
        let rows = CGFloat(min(max(agentCount, 1), 6)) * 58
        let detail: CGFloat = hasSelectedDetail ? 290 : 110
        let estimate = 110 + rows + detail
        return min(max(360, estimate), screen.visibleFrame.height * 0.74)
    }

    private static func frame(on screen: NSScreen, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }
}
