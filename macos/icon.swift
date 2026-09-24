import Cocoa
let directory = CommandLine.arguments[1]
guard let favicon = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
    fatalError("Cannot load workspace favicon SVG")
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        favicon.draw(in: NSRect(x: 0, y: 0, width: p, height: p), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
