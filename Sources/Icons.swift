import Cocoa
import UserNotifications

// Every banner this app posts has so far carried the same bell, which is the
// app saying who it is rather than what happened. Four kinds now go out —
// finished, blocked on you, a meeting starting, a meeting ending — and at the
// distance a banner is read, a glyph and a colour land before any words do.
//
// The images are drawn rather than shipped, for the same reason the app icon is:
// changing one means changing code, not finding a file and re-exporting it.
struct NotificationIcon {
    let name: String
    let symbol: String
    let top: NSColor
    let bottom: NSColor

    static let finished = NotificationIcon(
        name: "finished", symbol: "checkmark",
        top: NSColor(srgbRed: 0.29, green: 0.72, blue: 0.44, alpha: 1),
        bottom: NSColor(srgbRed: 0.16, green: 0.55, blue: 0.35, alpha: 1))

    // Amber, and the only one that is not a calm colour: this is the banner that
    // means something is waiting on you rather than merely done.
    static let needsYou = NotificationIcon(
        name: "needs-you", symbol: "exclamationmark",
        top: NSColor(srgbRed: 0.98, green: 0.74, blue: 0.24, alpha: 1),
        bottom: NSColor(srgbRed: 0.91, green: 0.52, blue: 0.10, alpha: 1))

    static let meeting = NotificationIcon(
        name: "meeting", symbol: "moon.fill",
        top: NSColor(srgbRed: 0.45, green: 0.47, blue: 0.85, alpha: 1),
        bottom: NSColor(srgbRed: 0.30, green: 0.31, blue: 0.68, alpha: 1))

    static let resumed = NotificationIcon(
        name: "resumed", symbol: "bell.fill",
        top: NSColor(srgbRed: 0.36, green: 0.72, blue: 0.78, alpha: 1),
        bottom: NSColor(srgbRed: 0.20, green: 0.53, blue: 0.62, alpha: 1))

    static let all = [finished, needsYou, meeting, resumed]
}

extension AppDelegate {
    // Regenerated every launch rather than cached with a version stamp. It is a
    // handful of small draws once at startup, and the alternative is a stale
    // image surviving a change nobody remembered to invalidate.
    func renderNotificationIcons() {
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        for icon in NotificationIcon.all {
            guard let data = iconPNG(icon) else { continue }
            try? data.write(to: iconsDir.appendingPathComponent("\(icon.name).png"))
        }
    }

    func iconPNG(_ icon: NotificationIcon, size: CGFloat = 256) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // A circle, not a squircle. macOS already draws the app's rounded square
        // beside this one, and two rounded squares next to each other read as one
        // smudge; a disc separates cleanly at banner size.
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: size * 0.02, dy: size * 0.02))
        NSGradient(starting: icon.top, ending: icon.bottom)?.draw(in: disc, angle: -90)

        let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .bold)
        guard let glyph = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return rep.representation(using: .png, properties: [:]) }

        let tinted = NSImage(size: glyph.size, flipped: false) { rect in
            NSColor.white.set()
            rect.fill()
            glyph.draw(in: rect, from: NSRect.zero, operation: .destinationIn, fraction: 1)
            return true
        }

        let box = NSRect(x: (size - tinted.size.width) / 2,
                         y: (size - tinted.size.height) / 2,
                         width: tinted.size.width,
                         height: tinted.size.height)
        tinted.draw(in: box, from: NSRect.zero, operation: .sourceOver, fraction: 1)

        return rep.representation(using: .png, properties: [:])
    }

    // Attachments are copied out of the app's control by the notification centre,
    // so the same file can be handed over repeatedly. A failure here costs the
    // picture and nothing else.
    func attachment(_ icon: NotificationIcon) -> UNNotificationAttachment? {
        let url = iconsDir.appendingPathComponent("\(icon.name).png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? UNNotificationAttachment(identifier: icon.name, url: url, options: nil)
    }
}
