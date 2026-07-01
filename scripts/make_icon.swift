import AppKit

// Renders the traffic-light app icon (all three lamps lit) into an .iconset directory.
// Usage: swift scripts/make_icon.swift <output.iconset>
// Then:  iconutil -c icns <output.iconset> -o Packaging/AppIcon.icns

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    let s = CGFloat(pixels)
    let hw = s * 0.44, hh = s * 0.88
    let housing = CGRect(x: (s - hw) / 2, y: (s - hh) / 2, width: hw, height: hh)
    let corner = hw * 0.30
    ctx.addPath(CGPath(roundedRect: housing, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 1).cgColor)
    ctx.fillPath()

    let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
    let d = hw * 0.62
    let gap = (hh - CGFloat(colors.count) * d) / CGFloat(colors.count + 1)
    var top = housing.maxY - gap - d
    for color in colors {
        let rect = CGRect(x: s / 2 - d / 2, y: top, width: d, height: d)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: d * 0.35, color: color.withAlphaComponent(0.9).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        top -= d + gap
    }

    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        guard let data = drawIcon(pixels: base * scale) else { continue }
        let name = "icon_\(base)x\(base)\(suffix).png"
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
print("wrote iconset → \(outDir)")
