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
    private let surfaceState: NotchSurfaceState

    private var currentScreenNumber: NSNumber?
    private var pendingScreenNumber: NSNumber?
    private var pendingScreenSince: ContinuousClock.Instant?
    private var screenPollTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var transitionRevision = 0

    init(viewModel: NotchViewModel, settings: Settings) {
        self.viewModel = viewModel
        self.settings = settings
        let screen = Self.preferredScreen(for: settings.displayPlacement)
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(screen: screen))
        let frame = geometry.panelFrame(on: screen.frame, expanded: false)
        let surfaceState = NotchSurfaceState(
            geometry: geometry,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        self.surfaceState = surfaceState
        panel = NotchPanel(contentRect: frame)
        hostingView = NSHostingView(rootView: PlaceholderNotchView(
            model: viewModel, surface: surfaceState))
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
        observeAccessibilityOptions()
        configureScreenPolling()
    }

    func tearDown() {
        screenPollTimer?.invalidate()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        panel.orderOut(nil)
    }

    private func observePresentation() {
        withObservationTracking {
            _ = viewModel.presentation
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

    private func observeAccessibilityOptions() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.surfaceState.reduceMotion =
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        let geometry = NotchGeometry(metrics: NotchScreenMetrics(screen: screen))
        if surfaceState.geometry != geometry {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { surfaceState.geometry = geometry }
        }
        transition(to: viewModel.presentation, on: screen, geometry: geometry)
    }

    private func transition(
        to target: NotchPresentation,
        on screen: NSScreen,
        geometry: NotchGeometry
    ) {
        transitionRevision &+= 1
        let revision = transitionRevision

        if target.isExpanded {
            let frame = geometry.panelFrame(on: screen.frame, expanded: true)
            setPanelFrame(frame)
            panel.isInteractive = true

            guard surfaceState.presentation != target else { return }
            let applyTarget = { [surfaceState] in surfaceState.presentation = target }
            guard let animation = surfaceState.animation else {
                applyTarget()
                return
            }

            if surfaceState.presentation.isExpanded {
                withAnimation(.easeInOut(duration: 0.18), applyTarget)
            } else {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.transitionRevision == revision,
                          self.viewModel.presentation == target else { return }
                    withAnimation(animation, applyTarget)
                }
            }
            return
        }

        panel.isInteractive = false
        guard surfaceState.presentation != .compact else {
            finishCollapse(revision: revision, screen: screen, geometry: geometry)
            return
        }
        guard let animation = surfaceState.animation else {
            surfaceState.presentation = .compact
            finishCollapse(revision: revision, screen: screen, geometry: geometry)
            return
        }

        withAnimation(animation, completionCriteria: .logicallyComplete) {
            surfaceState.presentation = .compact
        } completion: { [weak self] in
            Task { @MainActor in
                self?.finishCollapse(revision: revision, screen: screen, geometry: geometry)
            }
        }
    }

    private func finishCollapse(
        revision: Int,
        screen: NSScreen,
        geometry: NotchGeometry
    ) {
        guard transitionRevision == revision, !viewModel.isExpanded else { return }
        setPanelFrame(geometry.panelFrame(on: screen.frame, expanded: false))
    }

    private func setPanelFrame(_ frame: CGRect) {
        guard !NSEqualRects(panel.frame, frame) else { return }
        panel.setFrame(frame, display: true, animate: false)
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

}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
