import AppKit
import Observation
import SwiftUI

@MainActor
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let panel: NotchPanel
    private let hostingView: NSHostingView<PlaceholderNotchView>

    private let fallbackNotchWidth: CGFloat = 190
    private let expandedWidth: CGFloat = 420
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
        } onChange: { [weak self] in
            Task { @MainActor in self?.applyPresentation(); self?.observePresentation() }
        }
    }

    private func applyPresentation() {
        let screen = Self.notchScreen()
        let notchWidth = Self.notchWidth(on: screen) ?? fallbackNotchWidth
        let width = viewModel.isExpanded ? expandedWidth : notchWidth
        let height = viewModel.isExpanded
            ? min(680, max(480, screen.visibleFrame.height * 0.72))
            : collapsedHeight
        hostingView.rootView = PlaceholderNotchView(model: viewModel, notchWidth: notchWidth)
        panel.isInteractive = viewModel.isExpanded
        panel.setFrame(Self.frame(on: screen, width: width, height: height), display: true, animate: true)
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

    private static func frame(on screen: NSScreen, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }
}
