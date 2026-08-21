import Cocoa

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ClaudeNotify.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Warm clay rather than the blue every notification utility already uses. It
// stands out in a menu bar full of blue, and it sits next to Claude Code without
// borrowing anyone's mark to say so.
let top = NSColor(srgbRed: 238/255.0, green: 158/255.0, blue: 118/255.0, alpha: 1)
let bottom = NSColor(srgbRed: 198/255.0, green: 94/255.0, blue: 62/255.0, alpha: 1)

func render(_ size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let canvas = CGFloat(size)
    let inset = canvas * 0.06
    let plate = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = plate.width * 0.2237

    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)

    // One soft highlight across the top and nothing else. A bevelled rim was
    // tried and reads as a glossy button from fifteen years ago; current macOS
    // plates are flat with a gradient.
    NSGraphicsContext.saveGraphicsState()
    shape.setClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.14), NSColor(white: 1, alpha: 0)])?
        .draw(in: NSRect(x: plate.minX, y: plate.maxY - plate.height * 0.5,
                         width: plate.width, height: plate.height * 0.5), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let glyphSize = canvas * 0.52
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
    if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let drawn = bell.size
        let scale = min(glyphSize / drawn.width, glyphSize / drawn.height)
        let target = NSSize(width: drawn.width * scale, height: drawn.height * scale)
        // Nudged up off true centre: the clapper carries visual weight low, so a
        // mathematically centred bell looks like it has slipped down the plate.
        let origin = NSPoint(x: (canvas - target.width) / 2,
                             y: (canvas - target.height) / 2 + canvas * 0.012)

        let tinted = NSImage(size: target)
        tinted.lockFocus()
        let glyphRect = NSRect(origin: .zero, size: target)
        bell.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        glyphRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        // A shadow under the glyph, so the bell sits on the plate rather than
        // being painted onto it.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
        shadow.shadowBlurRadius = canvas * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.01)
        shadow.set()
        tinted.draw(in: NSRect(origin: origin, size: target))
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, size) in variants {
    guard let data = render(size) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

print("wrote \(variants.count) images to \(outputDir)")
