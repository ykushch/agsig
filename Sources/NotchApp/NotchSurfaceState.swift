import Observation
import SwiftUI

@Observable
@MainActor
final class NotchSurfaceState {
    var presentation: NotchPresentation = .compact
    var geometry: NotchGeometry
    var reduceMotion: Bool

    init(geometry: NotchGeometry, reduceMotion: Bool) {
        self.geometry = geometry
        self.reduceMotion = reduceMotion
    }

    var visibleSize: CGSize {
        presentation.isExpanded ? geometry.expandedSize : geometry.compactSize
    }

    var animation: Animation? {
        reduceMotion ? nil : .interactiveSpring(response: 0.34, dampingFraction: 0.86)
    }
}
