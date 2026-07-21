import AppKit
import SwiftUI

/// Canonical herdr ram/terminal mark, rendered as a monochrome template so it
/// remains crisp and legible in the compact notch summary.
struct HerdrBrandMark: View {
    private static let resources: Bundle = {
        let name = "NotchAgent_NotchApp.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent(name),
        ].compactMap { $0 }
        return candidates.lazy.compactMap(Bundle.init(url:)).first ?? .main
    }()
    @MainActor private static let image: NSImage? = {
        guard let url = resources.url(
            forResource: "HerdrMark", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()

    @ViewBuilder
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "terminal.fill")
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }
}
