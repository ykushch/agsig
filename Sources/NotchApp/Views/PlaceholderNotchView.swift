import HerdrClient
import SwiftUI

/// Stable root hosted by the panel. The transparent AppKit canvas can change
/// independently while this one black surface morphs between its three modes.
struct PlaceholderNotchView: View {
    @Bindable var model: NotchViewModel
    @Bindable var surface: NotchSurfaceState

    private var isCompact: Bool { surface.presentation == .compact }
    private var isCompactRevealed: Bool { surface.isCompactIndicatorRevealed }
    private var isAttachedToNotch: Bool { surface.geometry.topContentInset > 0 }
    private var compactBottomRadius: CGFloat {
        // Preserve the notch silhouette in both compact heights. A radius equal
        // to the revealed lip height pulls the lower left and right edges inward
        // instead of leaving a square black extension below the hardware notch.
        isAttachedToNotch ? 12 : (isCompactRevealed ? 10 : 2)
    }
    private var shellShape: NotchSurfaceShape {
        NotchSurfaceShape(
            topRadius: isAttachedToNotch ? 0 : (isCompact ? 6 : 12),
            bottomRadius: isCompact ? compactBottomRadius : 22)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shellShape
                .fill(NotchPalette.surface)
                .overlay(shellShape.stroke(NotchPalette.hairline, lineWidth: 1))

            CompactNotchSummary(
                model: model,
                surface: surface,
                topInset: surface.geometry.topContentInset)
                .opacity(isCompact ? 1 : 0)
                .scaleEffect(isCompact ? 1 : 0.92, anchor: .top)
                .allowsHitTesting(isCompact)

            if surface.presentation.isExpanded {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let snapshot = model.displaySnapshot(at: context.date)
                    ExpandedNotchSurface(
                        model: model,
                        surface: surface,
                        presentation: surface.presentation,
                        snapshot: snapshot,
                        topInset: surface.geometry.topContentInset)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(
            width: surface.visibleSize.width,
            height: surface.visibleSize.height,
            alignment: .top)
        .clipShape(shellShape)
        .contentShape(shellShape)
        .shadow(
            color: surface.presentation.isExpanded ? .black.opacity(0.48) : .clear,
            radius: 20,
            y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover(perform: surface.setCompactHovering)
        .onExitCommand(perform: model.collapse)
    }
}

private struct CompactNotchSummary: View {
    @Bindable var model: NotchViewModel
    @Bindable var surface: NotchSurfaceState
    let topInset: CGFloat

    private var pendingUpdateVersion: String? { model.pendingUpdate?.version.rawValue }

    var body: some View {
        Button(action: model.toggle) {
            VStack(spacing: 0) {
                Spacer(minLength: topInset)
                if surface.isCompactIndicatorRevealed {
                    HStack(spacing: 5) {
                        HerdrBrandMark()
                            .frame(width: 9, height: 9)
                            .foregroundStyle(.white.opacity(0.62))
                        Circle()
                            .fill(NotchPalette.status(model.overallStatus))
                            .frame(width: 5, height: 5)
                        Text(model.attentionCount > 0
                            ? "\(model.attentionCount)"
                            : "\(model.agentCount)")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                            .monospacedDigit()
                        if pendingUpdateVersion != nil {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(NotchPalette.updateAccent)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    // Total width stays 34pt either way, so the compact panel
                    // never resizes just because an update landed. The status
                    // color is never replaced — an update must not be mistaken
                    // for an agent that needs attention.
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(NotchPalette.status(model.overallStatus))
                            .frame(width: pendingUpdateVersion == nil ? 34 : 26, height: 3)
                        if pendingUpdateVersion != nil {
                            Capsule()
                                .fill(NotchPalette.updateAccent)
                                .frame(width: 4, height: 3)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var helpText: String {
        guard let version = pendingUpdateVersion else { return "herdr agents — click to expand" }
        return "herdr agents — NotchAgent \(version) is available"
    }

    private var accessibilityText: String {
        let base = "\(model.agentCount) agents, \(model.attentionCount) need input"
        guard let version = pendingUpdateVersion else { return base }
        return "\(base). NotchAgent \(version) is available"
    }
}

struct NotchSurfaceShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius),
            style: .continuous)
            .path(in: rect)
    }
}

enum NotchPalette {
    static let surface = Color(red: 0.025, green: 0.027, blue: 0.038)
    static let elevated = Color.white.opacity(0.065)
    static let hover = Color.white.opacity(0.105)
    static let selected = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.11)
    static let secondaryText = Color.white.opacity(0.54)
    static let tertiaryText = Color.white.opacity(0.34)
    /// Deliberately outside the `RollupStatus` palette below and the action
    /// colors used elsewhere (cyan for jump, purple for mode), so an available
    /// update reads as information rather than as something demanding a reply.
    static let updateAccent = Color(red: 0.62, green: 0.66, blue: 0.98)

    static func status(_ status: RollupStatus) -> Color {
        switch status {
        case .blocked: .red
        case .working: .orange
        case .done: .green
        case .idle: .blue
        case .unknown: .gray
        }
    }
}
