import AppKit
import HerdrClient
import Observation
import SwiftUI

@MainActor
final class NotchWindowController {
    private let viewModel: NotchViewModel
    private let settings: Settings
    private let panel: NotchPanel
    private let hostingView: NSHostingView<PlaceholderNotchView>

    /// The deliberate compact-island width used when the selected display has no notch.
    private let floatingBarWidth: CGFloat = 190
    private let collapsedHeight: CGFloat = 30
    private var renderedNotchWidth: CGFloat
    private var currentScreenNumber: NSNumber?
    private var pendingScreenNumber: NSNumber?
    private var pendingScreenSince: ContinuousClock.Instant?
    private var screenPollTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?

    init(viewModel: NotchViewModel, settings: Settings) {
        self.viewModel = viewModel
        self.settings = settings
        let screen = Self.preferredScreen(for: settings.displayPlacement)
        let width = Self.notchWidth(on: screen) ?? floatingBarWidth
        let frame = Self.frame(on: screen, width: width, height: collapsedHeight)
        panel = NotchPanel(contentRect: frame)
        hostingView = NSHostingView(rootView: PlaceholderNotchView(model: viewModel, notchWidth: width))
        renderedNotchWidth = width
        currentScreenNumber = Self.screenNumber(screen)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    func show() {
        applyPresentation()
        panel.orderFrontRegardless()
        observePresentation()
        observeScreenChanges()
        configureScreenPolling()
    }

    func tearDown() {
        screenPollTimer?.invalidate()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        panel.orderOut(nil)
    }

    private func observePresentation() {
        withObservationTracking {
            _ = viewModel.presentation
            _ = viewModel.selectedPaneID
            _ = viewModel.agentCount
            _ = settings.displayPlacement
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.configureScreenPolling()
                self?.screenSelectionMayHaveChanged()
                self?.applyPresentation()
                self?.observePresentation()
            }
        }
    }

    private func observeScreenChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A disconnected display can leave a panel at a now-invalid frame.
                // Re-resolve immediately and restore status-bar ordering.
                self.adoptPreferredScreenImmediately()
                self.applyPresentation()
                self.panel.orderFrontRegardless()
            }
        }
    }

    private func configureScreenPolling() {
        guard settings.displayPlacement != .notchDisplay else {
            screenPollTimer?.invalidate()
            screenPollTimer = nil
            return
        }
        guard screenPollTimer == nil else { return }

        // NSScreen.main follows keyboard focus but has no dedicated notification.
        // Follow modes poll cheaply and require a stable candidate before moving.
        screenPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.screenSelectionMayHaveChanged() }
        }
    }

    private func screenSelectionMayHaveChanged() {
        let candidate = Self.preferredScreen(for: settings.displayPlacement)
        let candidateNumber = Self.screenNumber(candidate)
        guard candidateNumber != currentScreenNumber else {
            pendingScreenNumber = nil
            pendingScreenSince = nil
            return
        }

        if pendingScreenNumber != candidateNumber {
            pendingScreenNumber = candidateNumber
            pendingScreenSince = .now
            return
        }

        guard let pendingScreenSince,
              ContinuousClock.now - pendingScreenSince >= .seconds(1)
        else { return }
        currentScreenNumber = candidateNumber
        pendingScreenNumber = nil
        self.pendingScreenSince = nil
        applyPresentation(on: candidate)
        panel.orderFrontRegardless()
    }

    private func adoptPreferredScreenImmediately() {
        let screen = Self.preferredScreen(for: settings.displayPlacement)
        currentScreenNumber = Self.screenNumber(screen)
        pendingScreenNumber = nil
        pendingScreenSince = nil
    }

    private func applyPresentation(on explicitScreen: NSScreen? = nil) {
        let screen = explicitScreen ?? Self.screen(
            numbered: currentScreenNumber) ?? Self.preferredScreen(for: settings.displayPlacement)
        let notchWidth = Self.notchWidth(on: screen) ?? floatingBarWidth
        let width = viewModel.isExpanded ? Self.expandedWidth(on: screen) : notchWidth
        let height = viewModel.isExpanded ? Self.expandedHeight(
            on: screen, agentCount: viewModel.agentCount,
            hasSelectedDetail: viewModel.selectedPaneID != nil) : collapsedHeight
        let targetFrame = Self.frame(on: screen, width: width, height: height)

        // The SwiftUI tree owns live content updates. Replacing its root view on
        // every observation callback tears down material/rendering state and can
        // produce a visible flash. Only rebuild if the physical notch width
        // changed (for example, after moving to a different display).
        if abs(renderedNotchWidth - notchWidth) > 0.5 {
            renderedNotchWidth = notchWidth
            hostingView.rootView = PlaceholderNotchView(
                model: viewModel, notchWidth: notchWidth)
        }

        if panel.isInteractive != viewModel.isExpanded {
            panel.isInteractive = viewModel.isExpanded
        }
        guard !NSEqualRects(panel.frame, targetFrame) else { return }
        panel.setFrame(
            targetFrame, display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private static func preferredScreen(for placement: DisplayPlacement) -> NSScreen {
        let fallback = NSScreen.main ?? NSScreen.screens[0]
        switch placement {
        case .notchDisplay:
            return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? fallback
        case .activeDisplay:
            return fallback
        case .ghosttyDisplay:
            return ghosttyScreen() ?? fallback
        }
    }

    private static func ghosttyScreen() -> NSScreen? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let ghosttyPIDs = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard GhosttyActivator.bundleIdentifiers.contains(app.bundleIdentifier ?? "")
                    || app.localizedName == "Ghostty"
            else { return nil }
            return app.processIdentifier
        })

        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ghosttyPIDs.contains(ownerPID),
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let quartzBounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary),
                  quartzBounds.width > 1, quartzBounds.height > 1
            else { continue }
            return screen(containingQuartzWindow: quartzBounds)
        }
        return nil
    }

    private static func screen(containingQuartzWindow quartzBounds: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaBounds = CGRect(
            x: quartzBounds.minX,
            y: primary.frame.maxY - quartzBounds.maxY,
            width: quartzBounds.width,
            height: quartzBounds.height)
        guard let bestMatch = NSScreen.screens.max(by: { lhs, rhs in
            lhs.frame.intersection(cocoaBounds).area < rhs.frame.intersection(cocoaBounds).area
        }), bestMatch.frame.intersection(cocoaBounds).area > 0 else { return nil }
        return bestMatch
    }

    private static func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private static func screen(numbered number: NSNumber?) -> NSScreen? {
        guard let number else { return nil }
        return NSScreen.screens.first { screenNumber($0) == number }
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

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
