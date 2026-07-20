import HerdrClient
import SwiftUI

/// Stable root hosted by the panel. The transparent AppKit canvas can change
/// independently while this one black surface morphs between its three modes.
struct PlaceholderNotchView: View {
    @Bindable var model: NotchViewModel
    @Bindable var surface: NotchSurfaceState

    private var isCompact: Bool { surface.presentation == .compact }
    private var isAttachedToNotch: Bool { surface.geometry.topContentInset > 0 }
    private var shellShape: NotchSurfaceShape {
        NotchSurfaceShape(
            topRadius: isAttachedToNotch ? 0 : (isCompact ? 6 : 12),
            bottomRadius: isCompact ? 14 : 22)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shellShape
                .fill(NotchPalette.surface)
                .overlay(shellShape.stroke(NotchPalette.hairline, lineWidth: 1))

            CompactNotchSummary(model: model, topInset: surface.geometry.topContentInset)
                .opacity(isCompact ? 1 : 0)
                .scaleEffect(isCompact ? 1 : 0.92, anchor: .top)
                .allowsHitTesting(isCompact)

            if surface.presentation.isExpanded {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let snapshot = model.displaySnapshot(at: context.date)
                    ExpandedNotchSurface(
                        model: model,
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
        .onExitCommand(perform: model.collapse)
    }
}

private struct CompactNotchSummary: View {
    @Bindable var model: NotchViewModel
    let topInset: CGFloat

    var body: some View {
        Button(action: model.toggle) {
            VStack(spacing: 0) {
                Spacer(minLength: topInset)
                HStack(spacing: 5) {
                    Circle()
                        .fill(NotchPalette.status(model.overallStatus))
                        .frame(width: 6, height: 6)
                    Text(model.attentionCount > 0
                        ? "\(model.attentionCount) waiting"
                        : "\(model.agentCount) agents")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .monospacedDigit()
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("herdr agents — click to expand")
        .accessibilityLabel("\(model.agentCount) agents, \(model.attentionCount) need input")
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
