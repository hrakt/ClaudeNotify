import Cocoa

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ClaudeNotify.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let top = NSColor(calibratedRed: 0.42, green: 0.51, blue: 0.96, alpha: 1)
let bottom = NSColor(calibratedRed: 0.23, green: 0.29, blue: 0.78, alpha: 1)

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

    let glyphSize = canvas * 0.52
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
    if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let drawn = bell.size
        let scale = min(glyphSize / drawn.width, glyphSize / drawn.height)
        let target = NSSize(width: drawn.width * scale, height: drawn.height * scale)
        let origin = NSPoint(x: (canvas - target.width) / 2, y: (canvas - target.height) / 2)

        let tinted = NSImage(size: target)
        tinted.lockFocus()
        let glyphRect = NSRect(origin: .zero, size: target)
        bell.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        glyphRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: NSRect(origin: origin, size: target))
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
