import Cocoa

// Renders AppIcon.icns: a blue→indigo squircle with white Wi-Fi arcs (matching the
// menu bar motif). Pure CoreGraphics so it runs headless — no image-gen model needed.
//   swift icon/make-icon.swift [output.icns]

let outPath = CommandLine.arguments.dropFirst().first ?? "icon/AppIcon.icns"

func renderPNG(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext

    // Rounded-rect (squircle-ish) background with an Apple-like margin.
    let margin = s * 0.092
    let rect = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.40, green: 0.27, blue: 0.85, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: margin, y: s - margin),
                           end: CGPoint(x: s - margin, y: margin), options: [])
    ctx.restoreGState()

    // White Wi-Fi arcs + dot, centred.
    let cx = s / 2, cy = s * 0.40
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)
    for r in [s * 0.135, s * 0.235, s * 0.335] {
        ctx.setLineWidth(s * 0.052)
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                   startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(NSColor.white.cgColor)
    let dot = s * 0.04
    ctx.fillEllipse(in: CGRect(x: cx - dot, y: cy - dot, width: dot * 2, height: dot * 2))

    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let tmp = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: tmp)
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
for (px, name) in sizes {
    try! renderPNG(pixels: px).write(to: URL(fileURLWithPath: "\(tmp)/\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp, "-o", outPath]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: tmp)
print(p.terminationStatus == 0 ? "wrote \(outPath)" : "iconutil failed")
