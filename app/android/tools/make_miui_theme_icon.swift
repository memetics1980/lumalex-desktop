import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: make_miui_theme_icon.swift INPUT.png MASK.png OUTPUT.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let maskURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])

guard
    let inputImage = NSImage(contentsOf: inputURL),
    let maskData = try? Data(contentsOf: maskURL),
    let mask = NSBitmapImageRep(data: maskData),
    mask.pixelsWide == 168,
    mask.pixelsHigh == 168,
    let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 168,
        pixelsHigh: 168,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 168 * 4,
        bitsPerPixel: 32
    ),
    let graphicsContext = NSGraphicsContext(bitmapImageRep: output)
else {
    fputs("Unable to decode the source icon or 168x168 theme mask\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
graphicsContext.imageInterpolation = .high
inputImage.draw(
    in: NSRect(x: 0, y: 0, width: 168, height: 168),
    from: NSRect(origin: .zero, size: inputImage.size),
    operation: .copy,
    fraction: 1,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high.rawValue]
)
graphicsContext.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// Theme-provided icons in “一时间” all use the same alpha silhouette as
// icon_mask.png. Copying that alpha exactly makes the LumaLex override a native
// themed icon, so MIUI no longer applies transform_config.xml's fallback zoom.
for y in 0..<168 {
    for x in 0..<168 {
        guard
            let sourceColor = output.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
            let maskColor = mask.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else { continue }

        output.setColor(
            NSColor(
                deviceRed: sourceColor.redComponent,
                green: sourceColor.greenComponent,
                blue: sourceColor.blueComponent,
                alpha: sourceColor.alphaComponent * maskColor.alphaComponent
            ),
            atX: x,
            y: y
        )
    }
}

guard let png = output.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode themed icon\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
