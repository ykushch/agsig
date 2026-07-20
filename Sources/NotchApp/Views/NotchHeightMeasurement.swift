import SwiftUI

enum NotchMeasuredRegion: Hashable {
    case overviewContent
    case focusedContent
    case actionShelf
}

struct NotchHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [NotchMeasuredRegion: CGFloat] = [:]

    static func reduce(
        value: inout [NotchMeasuredRegion: CGFloat],
        nextValue: () -> [NotchMeasuredRegion: CGFloat]
    ) {
        for (region, height) in nextValue() {
            value[region] = max(value[region] ?? 0, height)
        }
    }
}

extension View {
    func reportNotchHeight(_ region: NotchMeasuredRegion) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: NotchHeightPreferenceKey.self,
                    value: [region: proxy.size.height])
            }
        }
    }
}
