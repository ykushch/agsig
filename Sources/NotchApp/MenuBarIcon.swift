import AppKit

/// The status-bar icon: the MacBook notch hanging from the top with an agent
/// status dot beneath it — same motif as the app icon (scripts/generate-app-icon.swift).
/// Drawn in code as a template image so it renders crisply at any scale and
/// follows the menu bar's light/dark appearance automatically.
enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()

            // Notch: hangs from the top edge with rounded bottom corners. The rect
            // extends past the canvas top so its rounded top corners are clipped off.
            let notch = NSBezierPath(roundedRect: NSRect(x: 3, y: 11.5, width: 12, height: 9),
                                     xRadius: 2.5, yRadius: 2.5)
            NSRect(x: 0, y: 0, width: 18, height: 16.5).clip()
            notch.fill()

            // Status dot.
            let dot = NSBezierPath(ovalIn: NSRect(x: 6.25, y: 2.5, width: 5.5, height: 5.5))
            dot.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch Agent"
        return image
    }
}
