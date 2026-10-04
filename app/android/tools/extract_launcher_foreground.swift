import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: extract_launcher_foreground.swift INPUT.png OUTPUT.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
    let inputData = try? Data(contentsOf: inputURL),
    let input = NSBitmapImageRep(data: inputData),
    let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: input.pixelsWide,
        pixelsHigh: input.pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: .alphaNonpremultiplied,
        bytesPerRow: input.pixelsWide * 4,
        bitsPerPixel: 32
    )
else {
    fputs("Unable to decode launcher icon\n", stderr)
    exit(1)
}

// The master uses a blue-only background whose blue channel is at least 76
// points above green. The white, teal and gold artwork is well outside that
// range. Feather the transition so the existing anti-aliased edges and page
// gradients survive when the artwork is placed on Android's separate
// adaptive-icon background layer.
for y in 0..<input.pixelsHigh {
    for x in 0..<input.pixelsWide {
        guard let color = input.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else { continue }
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        let blueDominance = (blue - green) * 255

        let linearAlpha = min(1, max(0, (76 - blueDominance) / 28))
        let alpha = linearAlpha * linearAlpha * (3 - 2 * linearAlpha)
        output.setColor(
            NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha),
            atX: x,
            y: y
        )
    }
}

guard let png = output.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode launcher foreground\n", stderr)
    exit(1)
}
try png.write(to: outputURL, options: .atomic)
